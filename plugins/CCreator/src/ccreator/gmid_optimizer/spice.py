"""Simulation interface.

Characterization is handled by the GmIDVisualizer C++ library (see gmid.py).
This module handles:
1. Testbench simulation with parameter substitution
2. Result parsing
"""

from __future__ import annotations

import re
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

from .gmid import GmIdLookup, characterise
from .problem import Transistor


@dataclass
class SimResult:
    valid: bool = False
    elapsed_ms: int = 0
    measurements: dict[str, float] = None

    def __post_init__(self):
        if self.measurements is None:
            self.measurements = {}

    def get(self, name: str) -> Optional[float]:
        return self.measurements.get(name)


def run_ngspice(netlist_path: Path, timeout_s: float = 60.0) -> str:
    """Run ngspice in batch mode and return raw stdout."""
    result = subprocess.run(
        ["ngspice", "-b", str(netlist_path)],
        capture_output=True, text=True, timeout=timeout_s,
    )
    return result.stdout + result.stderr


def parse_measure_output(output: str) -> dict[str, float]:
    """Parse .measure results from ngspice output.

    ngspice prints measure results like:
        gain_db = 4.23000e+01
        phase_margin = 6.73000e+01
    """
    measurements = {}
    for line in output.splitlines():
        line = line.strip()
        m = re.match(r"^(\w+)\s*=\s*([+-]?\d+\.?\d*(?:[eE][+-]?\d+)?)", line)
        if m:
            measurements[m.group(1)] = float(m.group(2))
    return measurements


def run_characterization(
    transistor: Transistor,
    model_lib_path: str,
    vdd: float = 1.8,
    cache_dir: Optional[Path] = None,
) -> GmIdLookup:
    """Run characterization via GmIDVisualizer C++ library.

    Results cached as .npz to avoid re-running for same (model, L).
    """
    lookup = GmIdLookup(model=transistor.model, L=transistor.L)

    # Check cache
    if cache_dir:
        cache_dir.mkdir(parents=True, exist_ok=True)
        cache_file = cache_dir / f"{transistor.model}_L{transistor.L:.4e}.npz"
        if cache_file.exists():
            lookup.load(cache_file)
            return lookup

    # Convert L from meters to um for the C++ API
    length_um = transistor.L * 1e6

    # Run characterization via C++ FFI
    with tempfile.TemporaryDirectory() as tmpdir:
        plots = characterise(
            model_file=model_lib_path,
            device_name=transistor.model,
            kind=transistor.kind,
            out_dir=tmpdir,
            vgs_stop=vdd,
            vds_stop=vdd,
            length_um=length_um,
        )

    lookup.build_from_plots(plots)

    # Cache
    if cache_dir:
        lookup.save(cache_file)

    return lookup


def substitute_params(
    netlist_template: str,
    substitutions: dict[str, dict[str, str]],
) -> str:
    """Substitute component parameters into a netlist template.

    substitutions: {instance_name: {param_name: value_str}}
    """
    lines = netlist_template.splitlines()
    result = []

    for line in lines:
        modified = line
        for instance, params in substitutions.items():
            stripped = line.strip()
            if stripped.upper().startswith(instance.upper()):
                for param, value in params.items():
                    pattern = rf"({param}\s*=\s*)[^\s]+"
                    modified = re.sub(pattern, rf"\g<1>{value}", modified, flags=re.IGNORECASE)
            for param, value in params.items():
                param_pattern = rf"(\.param\s+{param}_{instance}\s*=\s*)[^\s]+"
                modified = re.sub(param_pattern, rf"\g<1>{value}", modified, flags=re.IGNORECASE)
        result.append(modified)

    return "\n".join(result)


def run_testbench(
    netlist_path: Path,
    substitutions: dict[str, dict[str, str]],
    timeout_s: float = 60.0,
) -> SimResult:
    """Run a testbench with parameter substitutions and parse results."""
    import time

    template = netlist_path.read_text()
    netlist = substitute_params(template, substitutions)

    start = time.monotonic()

    with tempfile.TemporaryDirectory() as tmpdir:
        tmppath = Path(tmpdir)
        run_file = tmppath / "run.sp"
        run_file.write_text(netlist)

        try:
            output = run_ngspice(run_file, timeout_s=timeout_s)
        except subprocess.TimeoutExpired:
            return SimResult(valid=False, elapsed_ms=int(timeout_s * 1000))
        except Exception:
            return SimResult(valid=False)

    elapsed_ms = int((time.monotonic() - start) * 1000)
    measurements = parse_measure_output(output)

    return SimResult(
        valid=len(measurements) > 0,
        elapsed_ms=elapsed_ms,
        measurements=measurements,
    )
