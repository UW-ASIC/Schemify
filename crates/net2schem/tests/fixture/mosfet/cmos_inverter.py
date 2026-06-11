#!/usr/bin/env python3
"""CMOS inverter — fundamental digital/analog building block."""
from pyspice_rs import Circuit

circuit = Circuit('CMOS Inverter')

circuit.model('nmos_1v8', 'nmos', level=1, kp=120e-6, vto=0.5)
circuit.model('pmos_1v8', 'pmos', level=1, kp=60e-6, vto=-0.5)

circuit.V(name='dd', positive='vdd', negative=circuit.gnd, value=1.8)
circuit.V(name='in', positive='vin', negative=circuit.gnd, value=0.9)

# PMOS (pull-up), 2x width for symmetric switching
circuit.M(name='p', drain='vout', gate='vin', source='vdd', bulk='vdd', model='pmos_1v8', W='2u', L='180n')

# NMOS (pull-down)
circuit.M(name='n', drain='vout', gate='vin', source='0', bulk='0', model='nmos_1v8', W='1u', L='180n')

print(circuit)
