from __future__ import annotations
import keyword


def _safe_node(name: str) -> str:
    """Prefix Python keywords so PySpice doesn't reject them."""
    if keyword.iskeyword(name):
        return f'n_{name}'
    return name


class NetlistBuilder:
    def __init__(self, name: str, ground: str | None = None, _pyspice_obj=None):
        if _pyspice_obj is not None:
            self._circuit = _pyspice_obj
        else:
            from PySpice.Spice.Netlist import Circuit
            self._circuit = Circuit(name)
        self._name = name
        self._ground = ground

    def _n(self, name: str):
        """Map node name to PySpice node. Ground port maps to circ.gnd."""
        if self._ground and name == self._ground:
            return self._circuit.gnd
        return _safe_node(name)

    def R(self, name, n1, n2, value):
        self._circuit.R(name, self._n(n1), self._n(n2), value)

    def C(self, name, n1, n2, value):
        self._circuit.C(name, self._n(n1), self._n(n2), value)

    def L(self, name, n1, n2, value):
        self._circuit.L(name, self._n(n1), self._n(n2), value)

    def V(self, name, n1, n2, **kwargs):
        self._circuit.V(name, self._n(n1), self._n(n2), **kwargs)

    def I(self, name, n1, n2, **kwargs):
        self._circuit.I(name, self._n(n1), self._n(n2), **kwargs)

    def MOSFET(self, name, drain, gate, source, bulk, model, **kwargs):
        self._circuit.MOSFET(name, self._n(drain), self._n(gate),
                             self._n(source), self._n(bulk), model=model, **kwargs)

    def BJT(self, name, collector, base, emitter, model, **kwargs):
        self._circuit.BJT(name, self._n(collector), self._n(base),
                          self._n(emitter), model=model, **kwargs)

    def raw(self, spice_line: str):
        self._circuit.raw_spice += spice_line + '\n'

    @property
    def _pyspice_circuit(self):
        return self._circuit
