#!/usr/bin/env python3
"""Voltage-controlled oscillator — current-starved ring oscillator."""
from pyspice_rs import Circuit

circuit = Circuit('Current-Starved VCO')

circuit.model('nmos_1v8', 'nmos', level=1, kp=120e-6, vto=0.5)
circuit.model('pmos_1v8', 'pmos', level=1, kp=60e-6, vto=-0.5)

circuit.V(name='dd', positive='vdd', negative=circuit.gnd, value=1.8)
circuit.V(name='ctrl', positive='vctrl', negative=circuit.gnd, value=0.9)

# Current-starved inverter stage 1
circuit.M(name='pb1', drain='vdd_s1', gate='vctrl', source='vdd', bulk='vdd', model='pmos_1v8', W='2u', L='180n')
circuit.M(name='p1', drain='n1', gate='n3', source='vdd_s1', bulk='vdd', model='pmos_1v8', W='2u', L='180n')
circuit.M(name='n1', drain='n1', gate='n3', source='gnd_s1', bulk='0', model='nmos_1v8', W='1u', L='180n')
circuit.M(name='nb1', drain='gnd_s1', gate='vctrl', source='0', bulk='0', model='nmos_1v8', W='1u', L='180n')

# Stage 2
circuit.M(name='pb2', drain='vdd_s2', gate='vctrl', source='vdd', bulk='vdd', model='pmos_1v8', W='2u', L='180n')
circuit.M(name='p2', drain='n2', gate='n1', source='vdd_s2', bulk='vdd', model='pmos_1v8', W='2u', L='180n')
circuit.M(name='n2', drain='n2', gate='n1', source='gnd_s2', bulk='0', model='nmos_1v8', W='1u', L='180n')
circuit.M(name='nb2', drain='gnd_s2', gate='vctrl', source='0', bulk='0', model='nmos_1v8', W='1u', L='180n')

# Stage 3 (feeds back)
circuit.M(name='pb3', drain='vdd_s3', gate='vctrl', source='vdd', bulk='vdd', model='pmos_1v8', W='2u', L='180n')
circuit.M(name='p3', drain='n3', gate='n2', source='vdd_s3', bulk='vdd', model='pmos_1v8', W='2u', L='180n')
circuit.M(name='n3', drain='n3', gate='n2', source='gnd_s3', bulk='0', model='nmos_1v8', W='1u', L='180n')
circuit.M(name='nb3', drain='gnd_s3', gate='vctrl', source='0', bulk='0', model='nmos_1v8', W='1u', L='180n')

# Parasitic caps
circuit.C(name='1', positive='n1', negative=circuit.gnd, value=10e-15)
circuit.C(name='2', positive='n2', negative=circuit.gnd, value=10e-15)
circuit.C(name='3', positive='n3', negative=circuit.gnd, value=10e-15)

print(circuit)
