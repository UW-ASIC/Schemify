#!/usr/bin/env python3
"""Common-source NMOS amplifier with resistive load."""
from pyspice_rs import Circuit

circuit = Circuit('Common Source Amplifier')

circuit.model('nmos_1v8', 'nmos', level=1, kp=120e-6, vto=0.5)

circuit.V(name='dd', positive='vdd', negative=circuit.gnd, value=1.8)
circuit.V(name='in', positive='vin', negative=circuit.gnd, value=0.7)

circuit.R(name='d', positive='vdd', negative='vout', value=5e3)
circuit.M(name='1', drain='vout', gate='vin', source='0', bulk='0', model='nmos_1v8', W='10u', L='180n')

print(circuit)
