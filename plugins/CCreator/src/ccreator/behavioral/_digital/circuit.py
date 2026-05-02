from __future__ import annotations
from ccreator.core.circuit import BaseCircuit
from ccreator.core.errors import CircuitDefinitionError


class BehavioralDigitalCircuit(BaseCircuit):
    def _validate(self):
        name = type(self).__name__
        if not hasattr(self, 'rtl') and not hasattr(self, 'rtl_file'):
            raise CircuitDefinitionError(name, "must define 'rtl' string or 'rtl_file' path")
