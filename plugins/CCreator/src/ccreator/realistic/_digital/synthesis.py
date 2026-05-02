from __future__ import annotations
import subprocess
import shutil
import tempfile
from pathlib import Path

from ccreator.core.errors import ToolNotFoundError, SimulationError


def _check(result: subprocess.CompletedProcess, tool: str, circuit_name: str = ''):
    if result.returncode != 0:
        raise SimulationError(circuit_name or tool, tool, result.stderr)


def synthesize(rtl_source: str, top: str, output_path: str,
               liberty: str | None = None, sv2v: bool = False):
    if not shutil.which('yosys'):
        raise ToolNotFoundError('yosys')

    output_path_obj = Path(output_path)
    output_path_obj.parent.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory() as tmp:
        src = Path(tmp) / 'input.sv'
        src.write_text(rtl_source)

        if sv2v:
            if not shutil.which('sv2v'):
                raise ToolNotFoundError('sv2v')
            result = subprocess.run(['sv2v', str(src)], capture_output=True, text=True)
            _check(result, 'sv2v', top)
            src = Path(tmp) / 'input.v'
            src.write_text(result.stdout)

        if liberty:
            synth_cmd = (
                f'synth -top {top}; '
                f'dfflibmap -liberty {liberty}; '
                f'abc -liberty {liberty}; '
                f'write_verilog {output_path}'
            )
        else:
            synth_cmd = f'synth -top {top}; write_verilog {output_path}'

        result = subprocess.run(
            ['yosys', '-p', synth_cmd, str(src)],
            capture_output=True, text=True
        )
        _check(result, 'yosys', top)
