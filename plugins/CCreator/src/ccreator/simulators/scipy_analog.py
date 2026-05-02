from __future__ import annotations
import numpy as np
from typing import TYPE_CHECKING

from ccreator.core.simulation_result import SimulationResult
from ccreator.simulators.base import AbstractSimulator

if TYPE_CHECKING:
    from ccreator.behavioral._analog.circuit import BehavioralAnalogCircuit


class ScipyAnalogSimulator(AbstractSimulator):
    def __init__(self, circuit: 'BehavioralAnalogCircuit'):
        self._circuit = circuit

    def _get_scipy_system(self):
        import sympy as sp
        from scipy import signal

        s = sp.Symbol('s')
        H = self._circuit.transfer_function(s)
        H_simplified = sp.simplify(H)
        numer, denom = sp.fraction(sp.together(H_simplified))
        numer_poly = sp.Poly(sp.expand(numer), s)
        denom_poly = sp.Poly(sp.expand(denom), s)
        num = [float(c) for c in numer_poly.all_coeffs()]
        den = [float(c) for c in denom_poly.all_coeffs()]
        return signal.TransferFunction(num, den)

    def ac(self, fstart: float = 1.0, fstop: float = 1e6,
           points: int = 200, variation: str = 'dec') -> SimulationResult:
        from scipy import signal as sig

        sys = self._get_scipy_system()

        if variation == 'lin':
            freqs = np.linspace(fstart, fstop, points)
        else:
            freqs = np.logspace(np.log10(fstart), np.log10(fstop), points)

        w = 2 * np.pi * freqs
        w_out, H = sig.freqs(sys.num, sys.den, worN=w)
        magnitude_db = 20 * np.log10(np.abs(H) + 1e-300)
        phase_deg = np.angle(H, deg=True)

        return SimulationResult(
            kind='ac',
            circuit=self._circuit,
            x=freqs,
            y={'magnitude_db': magnitude_db, 'phase_deg': phase_deg, 'H': H},
            metadata={'backend': 'scipy', 'variation': variation},
        )

    def tran(self, step: float = 1e-6, end: float = 1e-3,
             input_fn=None) -> SimulationResult:
        from scipy.integrate import solve_ivp

        t_span = (0.0, end)
        t_eval = np.arange(0.0, end, step)

        if input_fn is None:
            def input_fn(t):
                return {'in': float(t > 0)}

        def dydt(t, y):
            u = input_fn(t)
            return self._circuit.equations(t, y, u)

        ports = getattr(self._circuit, 'ports', [])
        n_states = len([p for p in ports if p.direction == 'output'])
        if n_states == 0:
            n_states = 1

        sol = solve_ivp(dydt, t_span, [0.0] * n_states, t_eval=t_eval, dense_output=False)

        y_dict = {}
        ports_out = [p.name for p in ports if p.direction == 'output']
        for i, name in enumerate(ports_out):
            if i < sol.y.shape[0]:
                y_dict[name] = sol.y[i]

        return SimulationResult(
            kind='tran',
            circuit=self._circuit,
            x=sol.t,
            y=y_dict,
            metadata={'backend': 'scipy'},
        )

    def dc(self, **kwargs) -> SimulationResult:
        raise NotImplementedError("DC sweep not implemented for behavioral analog circuits")
