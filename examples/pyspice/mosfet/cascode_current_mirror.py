#!/usr/bin/env python3
"""Cascode current mirror — high output impedance for better matching."""
from pyspice_rs import Circuit

circuit = Circuit('Cascode Current Mirror')

circuit.model('nmos_1v8', 'nmos', level=1, kp=120e-6, vto=0.5)

circuit.V(name='dd', positive='vdd', negative=circuit.gnd, value=1.8)
circuit.V(name='bias', positive='vcasc', negative=circuit.gnd, value=0.8)

# Reference current
circuit.I(name='ref', positive='vdd', negative='iref', value=50e-6)

# Reference leg: cascode + diode
circuit.M(name='1', drain='iref', gate='iref', source='src1', bulk='0', model='nmos_1v8', W='2u', L='500n')
circuit.M(name='3', drain='src1', gate='vcasc', source='0', bulk='0', model='nmos_1v8', W='2u', L='500n')

# Mirror leg: cascode output
circuit.M(name='2', drain='iout', gate='iref', source='src2', bulk='0', model='nmos_1v8', W='2u', L='500n')
circuit.M(name='4', drain='src2', gate='vcasc', source='0', bulk='0', model='nmos_1v8', W='2u', L='500n')

# Sweep output to see output impedance
circuit.V(name='out', positive='vdd', negative='iout', value=0)

print(circuit)

simulator = circuit.simulator()
analysis = simulator.dc(Vout=slice(0, 1.8, 0.01))
