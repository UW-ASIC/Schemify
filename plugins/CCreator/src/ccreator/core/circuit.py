from __future__ import annotations
import inspect
import pathlib
from abc import ABC, abstractmethod
from typing import TYPE_CHECKING

from ccreator.core.port import Port
from ccreator.core.errors import CircuitDefinitionError


class BaseCircuit(ABC):
    pass

    def _validate(self):
        pass

    def _resolve_rtl(self) -> str:
        if hasattr(self, 'rtl'):
            return self.rtl
        if hasattr(self, 'rtl_file'):
            caller_file = inspect.getfile(type(self))
            path = pathlib.Path(caller_file).parent / self.rtl_file
            return path.read_text()
        raise CircuitDefinitionError(
            type(self).__name__,
            "must define 'rtl' string or 'rtl_file' path"
        )

    def switch_pdk(
        self,
        target: str,
        source: str | None = None,
        use_lut: bool = True,
    ) -> str:
        """Remap this circuit's SPICE netlist to a different PDK.

        Uses gm/Id-preserving remapping (Av-preserving multi-L when LUTs
        are available, linear fallback otherwise).

        Args:
            target: Target PDK name (e.g. "sky130", "gf180mcu", "ihp_sg13g2").
            source: Source PDK name.  Auto-detected from model names if None.
            use_lut: Attempt gm/Id LUT-based remap (requires ngspice + PDK).

        Returns:
            Remapped SPICE netlist string.
        """
        from ccreator.realistic._analog.spice_export import to_spice_string
        from ccreator.pdk_switcherino import PDKSwitcher, get_pdk, auto_root

        spice = to_spice_string(self)

        src_pdk = auto_root(get_pdk(source)) if source else None
        tgt_pdk = auto_root(get_pdk(target))

        # Auto-detect source PDK from model names if not provided
        if src_pdk is None:
            from ccreator.pdk_switcherino import list_pdks
            spice_lower = spice.lower()
            for pdk in list_pdks():
                if pdk.nfet.lower() in spice_lower or pdk.pfet.lower() in spice_lower:
                    src_pdk = auto_root(pdk)
                    break
            if src_pdk is None:
                raise CircuitDefinitionError(
                    type(self).__name__,
                    "Cannot auto-detect source PDK from model names. "
                    "Pass source= explicitly."
                )

        switcher = PDKSwitcher(src_pdk, tgt_pdk)

        if use_lut:
            try:
                from ccreator.pdk_switcherino import get_lut
                from ccreator.pdk_switcherino.characterize import DeviceLUTFamily

                # Try Av-preserving multi-L first
                tgt_nfet_family = DeviceLUTFamily(
                    device=tgt_pdk.nfet,
                    luts={
                        L: get_lut(tgt_pdk, tgt_pdk.nfet, "nmos", L)
                        for L in tgt_pdk.discrete_lengths[:5]
                    },
                )
                tgt_pfet_family = DeviceLUTFamily(
                    device=tgt_pdk.pfet,
                    luts={
                        L: get_lut(tgt_pdk, tgt_pdk.pfet, "pmos", L)
                        for L in tgt_pdk.discrete_lengths[:5]
                    },
                )
                src_nfet = get_lut(src_pdk, src_pdk.nfet, "nmos", src_pdk.l_min * 1e6)
                src_pfet = get_lut(src_pdk, src_pdk.pfet, "pmos", src_pdk.l_min * 1e6)

                switcher.load_lut_families(
                    src_nfet, src_pfet,
                    tgt_nfet_family, tgt_pfet_family,
                )
            except Exception:
                pass  # fall back to linear scaling

        return switcher.remap_netlist(spice, bias_currents={})

    def optimize(
        self,
        targets: list[dict],
        testbench=None,
        model_lib: str = "",
        vdd: float = 1.8,
        max_iter: int = 50,
        initial_samples: int = 20,
        seed: int = 42,
        cache_dir: str | None = None,
        callback=None,
    ):
        """Bayesian gm/Id optimization of transistor sizing.

        Extracts MOSFETs from the circuit, builds a Problem, and runs
        Bayesian optimization to meet the given targets.

        Args:
            targets: List of spec dicts, each with keys:
                name (str), kind ("maximize"|"minimize"|">="|"<="),
                target (float, optional), weight (float, default 1.0).
            testbench: A CCreator testbench instance whose exported SPICE
                netlist will be used for evaluation.  If None, exports the
                circuit's own SPICE and requires external .meas directives.
            model_lib: Path to SPICE model library (.lib/.mod).
            vdd: Supply voltage.
            max_iter: Maximum optimization iterations.
            initial_samples: Latin Hypercube initial samples.
            seed: Random seed.
            cache_dir: Cache directory for characterization data.
            callback: Optional callable(iteration, observation).

        Returns:
            OptimizationResult with best_params, observations, etc.
        """
        from ccreator.gmid_optimizer import (
            GMIDOptimizer, Problem, Transistor, Specification, SpecKind,
        )
        from ccreator.gmid_optimizer.problem import Testbench
        from ccreator.realistic._analog.netlist_builder import NetlistBuilder

        # Build the circuit to extract MOSFETs
        nb = NetlistBuilder(type(self).__name__)
        self.build(nb)
        pyc = nb._pyspice_circuit

        transistors = []
        for elem in pyc.elements:
            elem_str = str(elem)
            if not elem_str.strip().upper().startswith('M'):
                continue
            parts = elem_str.split()
            name = parts[0][1:]  # strip 'M' prefix
            model = parts[5] if len(parts) > 5 else ""
            # Extract L from params
            L = 1e-7
            for part in parts[6:]:
                if part.upper().startswith('L='):
                    try:
                        L = float(part[2:])
                    except ValueError:
                        pass
            kind = "pmos" if "p" in model.lower() else "nmos"
            transistors.append(Transistor(
                instance=name, model=model, kind=kind, L=L,
            ))

        if not transistors:
            raise CircuitDefinitionError(
                type(self).__name__,
                "No MOSFETs found in circuit — nothing to optimize."
            )

        kind_map = {
            "minimize": SpecKind.MINIMIZE,
            "maximize": SpecKind.MAXIMIZE,
            ">=": SpecKind.GREATER_EQUAL,
            "<=": SpecKind.LESS_EQUAL,
            "==": SpecKind.EQUAL,
            "range": SpecKind.RANGE,
        }
        specs = [
            Specification(
                name=t["name"],
                kind=kind_map.get(t.get("kind", "maximize"), SpecKind.MAXIMIZE),
                target=t.get("target", 0.0),
                weight=t.get("weight", 1.0),
            )
            for t in targets
        ]

        # Export testbench SPICE for evaluation
        import tempfile
        tb_dir = pathlib.Path(cache_dir) if cache_dir else pathlib.Path(tempfile.mkdtemp())
        tb_dir.mkdir(parents=True, exist_ok=True)

        if testbench is not None:
            from ccreator.testbench.spice_export import export_testbench_spice
            tb_path = tb_dir / "testbench.sp"
            export_testbench_spice(testbench._builder, str(tb_path))
        else:
            from ccreator.realistic._analog.spice_export import export_spice
            tb_path = tb_dir / "circuit.sp"
            export_spice(self, str(tb_path))

        testbenches = [Testbench(
            path=str(tb_path),
            name=type(self).__name__,
            specs=specs,
        )]

        problem = Problem(transistors=transistors, testbenches=testbenches)

        optimizer = GMIDOptimizer(
            problem=problem,
            model_lib_path=model_lib,
            vdd=vdd,
            cache_dir=pathlib.Path(cache_dir) if cache_dir else None,
            max_iter=max_iter,
            initial_samples=initial_samples,
            seed=seed,
        )

        return optimizer.run(callback=callback)

    @property
    def export(self) -> 'ExportProxy':
        return ExportProxy(self)


class ExportProxy:
    def __init__(self, circuit: BaseCircuit):
        self._circuit = circuit

    def veriloga(self, path: str):
        from ccreator.behavioral._analog.codegen import export_veriloga
        export_veriloga(self._circuit, path)

    def spice(self, path: str):
        from ccreator.realistic._analog.spice_export import export_spice
        export_spice(self._circuit, path)

    def verilog(self, path: str):
        import pathlib
        src = self._circuit._resolve_rtl()
        pathlib.Path(path).parent.mkdir(parents=True, exist_ok=True)
        pathlib.Path(path).write_text(src)

    def synthesize(self, output: str, liberty: str | None = None, sv2v: bool = False):
        from ccreator.realistic._digital.synthesis import synthesize
        top = type(self._circuit).__name__
        src = self._circuit._resolve_rtl()
        synthesize(src, top, output, liberty=liberty, sv2v=sv2v)

    def schemify(self, path: str | None = None) -> list:
        """Export circuit as Schemify .chn schematic(s).

        Generates SPICE, then parses/places/routes it into schematic
        representation using the SpiceImport pipeline.

        Args:
            path: Output directory for .chn JSON files.  If None, returns
                the SchematicOutput objects without writing.

        Returns:
            List of SchematicOutput objects.
        """
        from ccreator.realistic._analog.spice_export import to_spice_string
        from ccreator.spice2schematic import import_spice

        spice = to_spice_string(self._circuit)
        outputs = import_spice(spice, source_path=type(self._circuit).__name__)

        if path is not None:
            out_dir = pathlib.Path(path)
            out_dir.mkdir(parents=True, exist_ok=True)
            for out in outputs:
                out.write_chn(out_dir)

        return outputs
