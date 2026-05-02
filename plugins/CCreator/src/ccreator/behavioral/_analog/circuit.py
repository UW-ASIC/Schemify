from __future__ import annotations
from ccreator.core.circuit import BaseCircuit
from ccreator.core.errors import CircuitDefinitionError


class BehavioralAnalogCircuit(BaseCircuit):
    def _validate(self):
        name = type(self).__name__
        if not callable(getattr(self, 'transfer_function', None)):
            raise CircuitDefinitionError(name, "must define transfer_function(self, s)")
        if not callable(getattr(self, 'equations', None)):
            raise CircuitDefinitionError(name, "must define equations(self, t, y, u)")
