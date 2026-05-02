from __future__ import annotations


def _wrap(base_cls, cls):
    """Create Wrapped class with cls before base_cls in MRO so user attrs win."""
    class Wrapped(cls, base_cls):
        def __init__(self, **kwargs):
            defaults = getattr(cls, 'parameters', {})
            for k, v in {**defaults, **kwargs}.items():
                setattr(self, k, v)
            self._validate()

    Wrapped.__name__ = cls.__name__
    Wrapped.__qualname__ = cls.__qualname__
    Wrapped.__module__ = cls.__module__
    return Wrapped


def testbench(cls):
    from ccreator.testbench.testbench import BaseTestbench

    class Wrapped(cls, BaseTestbench):
        def __init__(self, **kwargs):
            defaults = getattr(cls, 'parameters', {})
            for k, v in {**defaults, **kwargs}.items():
                setattr(self, k, v)

    Wrapped.__name__ = cls.__name__
    Wrapped.__qualname__ = cls.__qualname__
    Wrapped.__module__ = cls.__module__
    return Wrapped
