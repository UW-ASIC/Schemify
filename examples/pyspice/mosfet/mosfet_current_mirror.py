#!/usr/bin/env python3
"""Simple NMOS current mirror."""
from pyspice_rs import Circuit

circuit = Circuit('NMOS Current Mirror')

circuit.model('nmos_1v8', 'nmos', level=1, kp=120e-6, vto=0.5)

circuit.V(name='dd', positive='vdd', negative=circuit.gnd, value=1.8)

# Reference current
circuit.I(name='ref', positive='vdd', negative='iref', value=50e-6)

# Diode-connected reference transistor
circuit.M(name='1', drain='iref', gate='iref', source='0', bulk='0', model='nmos_1v8', W='2u', L='500n')

# Mirror transistor
circuit.M(name='2', drain='iout', gate='iref', source='0', bulk='0', model='nmos_1v8', W='2u', L='500n')

# Load resistor to observe output current
circuit.R(name='load', positive='vdd', negative='iout', value=10e3)

print(circuit)

simulator = circuit.simulator()
analysis = simulator.operating_point()
