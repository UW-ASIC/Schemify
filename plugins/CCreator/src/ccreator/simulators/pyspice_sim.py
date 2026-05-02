from __future__ import annotations
import shutil
import numpy as np
from typing import TYPE_CHECKING

from ccreator.core.simulation_result import SimulationResult
from ccreator.core.errors import ToolNotFoundError, SimulationError
from ccreator.simulators.base import AbstractSimulator
from ccreator.realistic._analog.netlist_builder import _safe_node

if TYPE_CHECKING:
    from ccreator.realistic._analog.circuit import RealisticAnalogCircuit


class PySpiceSimulator(AbstractSimulator):
    def __init__(self, circuit: 'RealisticAnalogCircuit'):
        self._circuit = circuit
        if not shutil.which('ngspice'):
            raise ToolNotFoundError('ngspice')

    def ac(self, fstart: float = 1.0, fstop: float = 1e6,
           points: int = 200, variation: str = 'dec') -> SimulationResult:
        from ccreator.realistic._analog.netlist_builder import NetlistBuilder

        name = type(self._circuit).__name__
        ports = getattr(self._circuit, 'ports', [])
        in_port = next((p.name for p in ports if p.direction == 'input'), 'in')
        out_port = next((p.name for p in ports if p.direction == 'output'), 'out')
        gnd_port = next((p.name for p in ports if p.direction == 'inout'), None)

        nb = NetlistBuilder(f'{name}_sim', ground=gnd_port)
        self._circuit.build(nb)
        circ = nb._pyspice_circuit

        safe_in = _safe_node(in_port)
        safe_out = _safe_node(out_port)

        try:
            circ.V('input', safe_in, circ.gnd, 'dc 0 ac 1')
        except Exception:
            pass

        try:
            simulator = circ.simulator(temperature=27, nominal_temperature=27)
            analysis = simulator.ac(
                variation=variation,
                number_of_points=points,
                start_frequency=fstart,
                stop_frequency=fstop,
            )

            freqs = np.array(analysis.frequency.as_ndarray())
            H = np.array(analysis[safe_out].as_ndarray())
            magnitude_db = 20 * np.log10(np.abs(H) + 1e-300)
            phase_deg = np.angle(H, deg=True)

            return SimulationResult(
                kind='ac',
                circuit=self._circuit,
                x=freqs,
                y={'magnitude_db': magnitude_db, 'phase_deg': phase_deg, 'H': H},
                metadata={'backend': 'ngspice'},
            )
        except (ToolNotFoundError,):
            raise
        except Exception as e:
            raise SimulationError(name, 'ngspice', str(e))

    def tran(self, step: float = 1e-6, end: float = 1e-3) -> SimulationResult:
        from ccreator.realistic._analog.netlist_builder import NetlistBuilder

        name = type(self._circuit).__name__
        ports = getattr(self._circuit, 'ports', [])
        out_port = next((p.name for p in ports if p.direction == 'output'), 'out')
        gnd_port = next((p.name for p in ports if p.direction == 'inout'), None)
        safe_out = _safe_node(out_port)

        nb = NetlistBuilder(f'{name}_sim', ground=gnd_port)
        self._circuit.build(nb)
        circ = nb._pyspice_circuit

        try:
            simulator = circ.simulator(temperature=27, nominal_temperature=27)
            analysis = simulator.transient(step_time=step, end_time=end)

            t = np.array(analysis.time.as_ndarray())
            y = np.array(analysis[safe_out].as_ndarray())

            return SimulationResult(
                kind='tran',
                circuit=self._circuit,
                x=t,
                y={out_port: y},
                metadata={'backend': 'ngspice'},
            )
        except (ToolNotFoundError,):
            raise
        except Exception as e:
            raise SimulationError(name, 'ngspice', str(e))

    def dc(self, start: float = 0.0, stop: float = 5.0, step: float = 0.1) -> SimulationResult:
        raise NotImplementedError("DC sweep not yet implemented for PySpice simulator")
