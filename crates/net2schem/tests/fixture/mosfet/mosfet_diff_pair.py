#!/usr/bin/env python3
"""NMOS differential pair with resistive loads."""
from pyspice_rs import Circuit

circuit = Circuit('Differential Pair')

circuit.model('nmos_1v8', 'nmos', level=1, kp=120e-6, vto=0.5)

circuit.V(name='dd', positive='vdd', negative=circuit.gnd, value=1.8)
circuit.V(name='inp', positive='inp', negative=circuit.gnd, value=0.9)
circuit.V(name='inn', positive='inn', negative=circuit.gnd, value=0.9)

# Load resistors
circuit.R(name='d1', positive='vdd', negative='outp', value=10e3)
circuit.R(name='d2', positive='vdd', negative='outn', value=10e3)

# Diff pair transistors
circuit.M(name='1', drain='outp', gate='inp', source='tail', bulk='0', model='nmos_1v8', W='10u', L='180n')
circuit.M(name='2', drain='outn', gate='inn', source='tail', bulk='0', model='nmos_1v8', W='10u', L='180n')

# Tail current source
circuit.I(name='tail', positive=circuit.gnd, negative='tail', value=100e-6)

print(circuit)
