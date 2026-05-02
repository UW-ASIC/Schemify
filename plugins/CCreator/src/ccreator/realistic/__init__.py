from ccreator.core.decorators import _wrap


def analog(cls):
    from ccreator.realistic._analog.circuit import RealisticAnalogCircuit
    return _wrap(RealisticAnalogCircuit, cls)


def digital(cls):
    from ccreator.realistic._digital.circuit import RealisticDigitalCircuit
    return _wrap(RealisticDigitalCircuit, cls)
