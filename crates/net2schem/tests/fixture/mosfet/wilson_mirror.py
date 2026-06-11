#!/usr/bin/env python3
"""Wilson current mirror — improved output impedance over simple mirror."""
from pyspice_rs import Circuit

circuit = Circuit('Wilson Current Mirror')

circuit.model('nmos_1v8', 'nmos', level=1, kp=120e-6, vto=0.5)

circuit.V(name='dd', positive='vdd', negative=circuit.gnd, value=1.8)
circuit.I(name='ref', positive='vdd', negative='iref', value=50e-6)

# Wilson topology (NMOS)
circuit.M(name='1', drain='n1', gate='iref', source='0', bulk='0', model='nmos_1v8', W='2u', L='500n')
circuit.M(name='2', drain='iref', gate='n1', source='0', bulk='0', model='nmos_1v8', W='2u', L='500n')
circuit.M(name='3', drain='iout', gate='n1', source='0', bulk='0', model='nmos_1v8', W='2u', L='500n')

# Load
circuit.V(name='out', positive='vdd', negative='iout', value=0)

print(circuit)
