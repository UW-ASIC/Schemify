from ccreator.core.decorators import _wrap


def analog(cls):
    from ccreator.behavioral._analog.circuit import BehavioralAnalogCircuit
    return _wrap(BehavioralAnalogCircuit, cls)


def digital(cls):
    from ccreator.behavioral._digital.circuit import BehavioralDigitalCircuit
    return _wrap(BehavioralDigitalCircuit, cls)
