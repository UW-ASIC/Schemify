from .problem import Problem, Transistor, Resistor, Specification, SpecKind

__all__ = [
    "Problem",
    "Transistor",
    "Resistor",
    "Specification",
    "SpecKind",
    "GMIDOptimizer",
    "GmIdLookup",
]


def __getattr__(name):
    """Lazy-load heavy modules (torch/botorch) only when needed."""
    if name == "GMIDOptimizer":
        from .optimizer import GMIDOptimizer
        return GMIDOptimizer
    if name == "GmIdLookup":
        from .gmid import GmIdLookup
        return GmIdLookup
    raise AttributeError(f"module {__name__!r} has no attribute {name!r}")
