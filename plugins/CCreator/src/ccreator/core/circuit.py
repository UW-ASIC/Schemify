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

    # NOTE: switch_pdk() has been removed. PDK switching is now handled by
    # the PDKSwitcher plugin and core Schemify host API.

    # NOTE: optimize() has been removed. gm/Id optimization is now handled by
    # the core optimizer (src/optimizer/) accessible via host API
    # (optimizerRun / optimizerGetResult).

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

        Generates SPICE netlist from the circuit, then uses CCreator's
        built-in fallback parser to produce component dicts for placement.

        NOTE: For full-fidelity SPICE import with layout/routing, use the
        core Schemify SPICE import via the host API (spiceImport command)
        instead of this method.

        Args:
            path: Output directory for .chn files.  If None, returns
                the component dicts without writing.

        Returns:
            List of component dicts.
        """
        from ccreator.realistic._analog.spice_export import to_spice_string

        spice = to_spice_string(self._circuit)

        # Use the built-in fallback parser (no dependency on bundled spice2schematic)
        components = _fallback_parse_spice(spice)

        if path is not None:
            import json
            out_dir = pathlib.Path(path)
            out_dir.mkdir(parents=True, exist_ok=True)
            name = type(self._circuit).__name__
            out_file = out_dir / f"{name}.json"
            out_file.write_text(json.dumps(components, indent=2))

        return components


def _fallback_parse_spice(spice_text: str) -> list[dict]:
    """Minimal SPICE parser for extracting component info.

    For full SPICE import with placement and routing, use the core
    Schemify host API (spiceImport command).
    """
    from typing import Any

    components: list[dict[str, Any]] = []
    x_offset = 100
    y_offset = -100
    spacing = 200
    idx = 0

    for line in spice_text.split("\n"):
        line = line.strip()
        if not line or line.startswith("*") or line.startswith("."):
            continue
        prefix = line[0].lower()
        parts = line.split()
        if len(parts) < 3:
            continue

        name = parts[0]
        sym_map = {
            "r": "res", "c": "capa", "l": "ind", "m": "nmos4",
            "v": "vsource", "i": "isource", "x": "subckt",
        }
        sym = sym_map.get(prefix, "vsource")
        x = x_offset + (idx % 5) * spacing
        y = y_offset - (idx // 5) * 120

        comp: dict[str, Any] = {
            "name": name,
            "symbol": sym,
            "kind": prefix,
            "x": x,
            "y": y,
            "props": [],
        }

        if prefix in ("r", "c", "l") and len(parts) >= 4:
            comp["props"].append({"key": "value", "val": parts[3]})
        elif prefix == "m" and len(parts) >= 6:
            comp["props"].append({"key": "model", "val": parts[5]})
            comp["symbol"] = "nmos4"

        components.append(comp)
        idx += 1

    return components
