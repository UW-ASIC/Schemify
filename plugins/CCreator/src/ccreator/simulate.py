from __future__ import annotations
from typing import TYPE_CHECKING

from ccreator.core.simulation_result import SimulationResult, ComparisonResult

if TYPE_CHECKING:
    from ccreator.core.circuit import BaseCircuit


class SimulatorProxy:
    def __init__(self, circuit: 'BaseCircuit'):
        self._circuit = circuit

    def _get_analog_sim(self):
        from ccreator.behavioral._analog.circuit import BehavioralAnalogCircuit
        from ccreator.realistic._analog.circuit import RealisticAnalogCircuit

        if isinstance(self._circuit, BehavioralAnalogCircuit):
            from ccreator.simulators.scipy_analog import ScipyAnalogSimulator
            return ScipyAnalogSimulator(self._circuit)
        elif isinstance(self._circuit, RealisticAnalogCircuit):
            from ccreator.simulators.pyspice_sim import PySpiceSimulator
            return PySpiceSimulator(self._circuit)
        else:
            raise TypeError(f"[{type(self._circuit).__name__}] Unsupported circuit type for analog simulation")

    def _get_digital_sim(self):
        from ccreator.simulators.verilator import VerilatorSimulator
        return VerilatorSimulator(self._circuit)

    def ac(self, fstart: float = 1.0, fstop: float = 1e6,
           points: int = 200, variation: str = 'dec') -> SimulationResult:
        return self._get_analog_sim().ac(
            fstart=fstart, fstop=fstop, points=points, variation=variation
        )

    def dc(self, start: float = 0.0, stop: float = 5.0, step: float = 0.1) -> SimulationResult:
        return self._get_analog_sim().dc(start=start, stop=stop, step=step)

    def tran(self, step: float = 1e-6, end: float = 1e-3, **kwargs) -> SimulationResult:
        return self._get_analog_sim().tran(step=step, end=end, **kwargs)

    def functional(self, inputs: dict) -> SimulationResult:
        return self._get_digital_sim().functional(inputs=inputs)

    def rtl(self, cycles: int = 100, clk_period_ns: float = 10) -> SimulationResult:
        return self._get_digital_sim().rtl(cycles=cycles, clk_period_ns=clk_period_ns)


def simulate(circuit: 'BaseCircuit') -> SimulatorProxy:
    return SimulatorProxy(circuit)


def compare(r1: SimulationResult, r2: SimulationResult) -> ComparisonResult:
    from ccreator.compare.comparator import compare as _compare
    return _compare(r1, r2)
