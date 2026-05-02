from ccreator import behavioral, realistic
from ccreator.core.decorators import testbench
from ccreator.core.port import Port
from ccreator.core.errors import CircuitDefinitionError, ToolNotFoundError, SimulationError
from ccreator.simulate import simulate, compare


def __getattr__(name):
    """Lazy-load integrated subpackages to avoid heavy deps at import time."""
    if name == "pdk_switcherino":
        from ccreator import pdk_switcherino
        return pdk_switcherino
    if name == "gmid_optimizer":
        from ccreator import gmid_optimizer
        return gmid_optimizer
    if name == "spice2schematic":
        from ccreator import spice2schematic
        return spice2schematic
    raise AttributeError(f"module 'ccreator' has no attribute {name!r}")
