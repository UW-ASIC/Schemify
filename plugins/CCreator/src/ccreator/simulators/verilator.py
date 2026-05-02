from __future__ import annotations
import shutil
import subprocess
import tempfile
import numpy as np
from pathlib import Path
from typing import TYPE_CHECKING

from ccreator.core.simulation_result import SimulationResult
from ccreator.core.errors import ToolNotFoundError, SimulationError

if TYPE_CHECKING:
    from ccreator.core.circuit import BaseCircuit


class VerilatorSimulator:
    def __init__(self, circuit: 'BaseCircuit'):
        self._circuit = circuit
        if not shutil.which('verilator'):
            raise ToolNotFoundError('verilator')

    def functional(self, inputs: dict[str, list]) -> SimulationResult:
        """Run Verilator simulation with given input vectors, return output table."""
        name = type(self._circuit).__name__
        rtl_src = self._circuit._resolve_rtl()
        ports = getattr(self._circuit, 'ports', [])

        in_ports = [p for p in ports if p.direction == 'input']
        out_ports = [p for p in ports if p.direction == 'output']

        # Determine number of test vectors
        n_vectors = max(len(v) for v in inputs.values())

        # Generate C++ testbench
        tb_src = _generate_functional_tb(name, ports, inputs, n_vectors)

        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            rtl_file = tmp_path / f'{name}.v'
            rtl_file.write_text(rtl_src)
            tb_file = tmp_path / f'tb_{name}.cpp'
            tb_file.write_text(tb_src)

            # Verilate
            result = subprocess.run(
                ['verilator', '--cc', '--exe', '--build', '-j', '0',
                 '--top-module', name, str(rtl_file), str(tb_file),
                 '--Mdir', str(tmp_path / 'obj_dir')],
                capture_output=True, text=True, cwd=tmp
            )
            if result.returncode != 0:
                raise SimulationError(name, 'verilator', result.stderr)

            sim_bin = tmp_path / 'obj_dir' / f'V{name}'
            result = subprocess.run([str(sim_bin)], capture_output=True, text=True)
            if result.returncode != 0:
                raise SimulationError(name, 'verilator-sim', result.stderr)

            y = _parse_functional_output(result.stdout, out_ports)

        return SimulationResult(
            kind='functional',
            circuit=self._circuit,
            x=np.arange(n_vectors),
            y=y,
            metadata={'backend': 'verilator', 'inputs': inputs},
        )

    def rtl(self, cycles: int = 100, clk_period_ns: float = 10) -> SimulationResult:
        """Run cycle-accurate RTL simulation."""
        name = type(self._circuit).__name__
        rtl_src = self._circuit._resolve_rtl()
        ports = getattr(self._circuit, 'ports', [])

        out_ports = [p for p in ports if p.direction == 'output']

        tb_src = _generate_rtl_tb(name, ports, cycles, clk_period_ns)

        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            rtl_file = tmp_path / f'{name}.v'
            rtl_file.write_text(rtl_src)
            tb_file = tmp_path / f'tb_{name}.cpp'
            tb_file.write_text(tb_src)

            result = subprocess.run(
                ['verilator', '--cc', '--exe', '--build', '-j', '0',
                 '--top-module', name, str(rtl_file), str(tb_file),
                 '--Mdir', str(tmp_path / 'obj_dir')],
                capture_output=True, text=True, cwd=tmp
            )
            if result.returncode != 0:
                raise SimulationError(name, 'verilator', result.stderr)

            sim_bin = tmp_path / 'obj_dir' / f'V{name}'
            result = subprocess.run([str(sim_bin)], capture_output=True, text=True)
            if result.returncode != 0:
                raise SimulationError(name, 'verilator-sim', result.stderr)

            y = _parse_functional_output(result.stdout, out_ports)

        return SimulationResult(
            kind='rtl',
            circuit=self._circuit,
            x=np.arange(cycles),
            y=y,
            metadata={'backend': 'verilator', 'cycles': cycles, 'clk_period_ns': clk_period_ns},
        )


def _generate_functional_tb(name: str, ports, inputs: dict, n_vectors: int) -> str:
    in_ports = [p for p in ports if p.direction == 'input']
    out_ports = [p for p in ports if p.direction == 'output']

    lines = [
        f'#include "V{name}.h"',
        '#include "verilated.h"',
        '#include <iostream>',
        'int main(int argc, char** argv) {',
        '    VerilatedContext* contextp = new VerilatedContext;',
        '    contextp->commandArgs(argc, argv);',
        f'    V{name}* top = new V{name}{{contextp}};',
        f'    for (int i = 0; i < {n_vectors}; i++) {{',
    ]

    # Set inputs
    for p in in_ports:
        if p.name in inputs:
            vals = list(inputs[p.name])
            lines.append(f'        int {p.name}_vals[] = {{{", ".join(str(v) for v in vals)}}};')
            lines.append(f'        top->{p.name} = {p.name}_vals[i < {len(vals)} ? i : {len(vals)-1}];')

    lines += [
        '        top->eval();',
    ]

    # Print outputs
    for p in out_ports:
        lines.append(f'        std::cout << "{p.name}=" << (int)top->{p.name} << "\\n";')

    lines += [
        '    }',
        '    delete top;',
        '    delete contextp;',
        '    return 0;',
        '}',
    ]
    return '\n'.join(lines)


def _generate_rtl_tb(name: str, ports, cycles: int, clk_period_ns: float) -> str:
    out_ports = [p for p in ports if p.direction == 'output']
    clk_ports = [p for p in ports if p.name in ('clk', 'clock')]

    lines = [
        f'#include "V{name}.h"',
        '#include "verilated.h"',
        '#include <iostream>',
        'int main(int argc, char** argv) {',
        '    VerilatedContext* contextp = new VerilatedContext;',
        '    contextp->commandArgs(argc, argv);',
        f'    V{name}* top = new V{name}{{contextp}};',
        f'    for (int i = 0; i < {cycles}; i++) {{',
    ]

    if clk_ports:
        clk = clk_ports[0].name
        lines += [
            f'        top->{clk} = 0; top->eval();',
            f'        top->{clk} = 1; top->eval();',
        ]
    else:
        lines.append('        top->eval();')

    for p in out_ports:
        lines.append(f'        std::cout << "{p.name}=" << (int)top->{p.name} << "\\n";')

    lines += [
        '    }',
        '    delete top;',
        '    delete contextp;',
        '    return 0;',
        '}',
    ]
    return '\n'.join(lines)


def _parse_functional_output(stdout: str, out_ports) -> dict[str, np.ndarray]:
    result = {p.name: [] for p in out_ports}
    for line in stdout.strip().splitlines():
        if '=' in line:
            key, val = line.split('=', 1)
            key = key.strip()
            if key in result:
                try:
                    result[key].append(int(val.strip()))
                except ValueError:
                    pass
    return {k: np.array(v) for k, v in result.items()}
