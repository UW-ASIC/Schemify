from __future__ import annotations
import shutil
import numpy as np
from typing import Any

from ccreator.core.simulation_result import SimulationResult
from ccreator.core.errors import ToolNotFoundError, SimulationError


class _InstanceRecord:
    def __init__(self, circuit, name: str, connections: dict[str, str]):
        self.circuit = circuit
        self.name = name
        self.connections = connections  # port_name -> node_name


class _AnalysisRequest:
    def __init__(self, kind: str, kwargs: dict):
        self.kind = kind
        self.kwargs = kwargs


class TestbenchBuilder:
    def __init__(self, name: str):
        self._name = name
        self._instances: list[_InstanceRecord] = []
        self._sources: list[dict] = []
        self._probes: list[str] = []
        self._analysis: list[_AnalysisRequest] = []

    def instance(self, circuit, name: str, connections: dict[str, str]) -> _InstanceRecord:
        from ccreator.behavioral._analog.circuit import BehavioralAnalogCircuit
        if isinstance(circuit, BehavioralAnalogCircuit):
            raise NotImplementedError(
                f"[{type(circuit).__name__}] behavioral.analog circuits in testbenches "
                "are not supported in v1 (see CLAUDE.md §4)"
            )
        rec = _InstanceRecord(circuit, name, connections)
        self._instances.append(rec)
        return rec

    def V(self, name: str, n_plus: str, n_minus: str, **kwargs):
        self._sources.append({'type': 'V', 'name': name, 'n+': n_plus, 'n-': n_minus, **kwargs})

    def I(self, name: str, n_plus: str, n_minus: str, **kwargs):
        self._sources.append({'type': 'I', 'name': name, 'n+': n_plus, 'n-': n_minus, **kwargs})

    def probe(self, *node_names: str):
        self._probes.extend(node_names)

    def ac(self, variation: str = 'dec', points: int = 100,
           fstart: float = 1.0, fstop: float = 1e6):
        self._analysis.append(_AnalysisRequest('ac', {
            'variation': variation, 'points': points,
            'fstart': fstart, 'fstop': fstop,
        }))

    def tran(self, step: float = 1e-6, end: float = 1e-3):
        self._analysis.append(_AnalysisRequest('tran', {'step': step, 'end': end}))

    def dc(self, source: str, start: float = 0, stop: float = 5, step: float = 0.1):
        self._analysis.append(_AnalysisRequest('dc', {
            'source': source, 'start': start, 'stop': stop, 'step': step,
        }))

    def run(self) -> SimulationResult:
        if not shutil.which('ngspice'):
            raise ToolNotFoundError('ngspice')

        from ccreator.testbench.spice_export import build_pyspice_circuit
        from ccreator.realistic._analog.netlist_builder import _safe_node
        circ = build_pyspice_circuit(self)

        if not self._analysis:
            raise ValueError(f"[{self._name}] No analysis defined. Call tb.ac(), tb.tran(), or tb.dc().")

        req = self._analysis[0]
        try:
            simulator = circ.simulator(temperature=27, nominal_temperature=27)

            if req.kind == 'ac':
                kw = req.kwargs
                analysis = simulator.ac(
                    variation=kw['variation'],
                    number_of_points=kw['points'],
                    start_frequency=kw['fstart'],
                    stop_frequency=kw['fstop'],
                )
                freqs = np.array(analysis.frequency.as_ndarray())
                y = {}
                for probe in self._probes:
                    safe_probe = _safe_node(probe)
                    try:
                        H = np.array(analysis[safe_probe].as_ndarray())
                        y[probe] = H
                        y[f'{probe}_magnitude_db'] = 20 * np.log10(np.abs(H) + 1e-300)
                        y[f'{probe}_phase_deg'] = np.angle(H, deg=True)
                    except Exception:
                        pass
                return SimulationResult(
                    kind='ac', circuit=self, x=freqs, y=y,
                    metadata={'backend': 'ngspice', 'testbench': self._name},
                )

            elif req.kind == 'tran':
                kw = req.kwargs
                analysis = simulator.transient(step_time=kw['step'], end_time=kw['end'])
                t = np.array(analysis.time.as_ndarray())
                y = {}
                for probe in self._probes:
                    safe_probe = _safe_node(probe)
                    try:
                        y[probe] = np.array(analysis[safe_probe].as_ndarray())
                    except Exception:
                        pass
                return SimulationResult(
                    kind='tran', circuit=self, x=t, y=y,
                    metadata={'backend': 'ngspice', 'testbench': self._name},
                )

            elif req.kind == 'dc':
                kw = req.kwargs
                source_name = kw['source']
                # Find the SPICE element name: type prefix + user name
                spice_name = source_name
                for s in self._sources:
                    if s['name'] == source_name:
                        spice_name = s['type'] + source_name
                        break
                sweep_kwargs = {spice_name: slice(kw['start'], kw['stop'], kw['step'])}
                analysis = simulator.dc(**sweep_kwargs)
                sweep_var = np.array(analysis.sweep.as_ndarray())
                y = {}
                for probe in self._probes:
                    safe_probe = _safe_node(probe)
                    try:
                        y[probe] = np.array(analysis[safe_probe].as_ndarray())
                    except Exception:
                        pass
                return SimulationResult(
                    kind='dc', circuit=self, x=sweep_var, y=y,
                    metadata={'backend': 'ngspice', 'testbench': self._name},
                )

            else:
                raise NotImplementedError(f"Analysis kind '{req.kind}' not yet implemented in TestbenchBuilder.run()")

        except (ToolNotFoundError, NotImplementedError):
            raise
        except Exception as e:
            raise SimulationError(self._name, 'ngspice', str(e))
