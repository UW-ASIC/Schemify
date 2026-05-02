from __future__ import annotations
from ccreator.core.circuit import BaseCircuit
from ccreator.core.errors import CircuitDefinitionError


class RealisticAnalogCircuit(BaseCircuit):
    def _validate(self):
        name = type(self).__name__
        if not callable(getattr(self, 'build', None)):
            raise CircuitDefinitionError(name, "must define build(self, n)")
