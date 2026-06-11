#!/usr/bin/env python3
"""CMOS NOR gate — 2 parallel NMOS + 2 series PMOS."""
from pyspice_rs import Circuit

circuit = Circuit('CMOS NOR Gate')

circuit.model('nmos_1v8', 'nmos', level=1, kp=120e-6, vto=0.5)
circuit.model('pmos_1v8', 'pmos', level=1, kp=60e-6, vto=-0.5)

circuit.V(name='dd', positive='vdd', negative=circuit.gnd, value=1.8)

# Inputs
circuit.V(name='a', positive='va', negative=circuit.gnd, value=0)
circuit.V(name='b', positive='vb', negative=circuit.gnd, value=0)

# PMOS pull-up network (series)
circuit.M(name='p1', drain='mid', gate='va', source='vdd', bulk='vdd', model='pmos_1v8', W='4u', L='180n')
circuit.M(name='p2', drain='vout', gate='vb', source='mid', bulk='vdd', model='pmos_1v8', W='4u', L='180n')

# NMOS pull-down network (parallel)
circuit.M(name='n1', drain='vout', gate='va', source='0', bulk='0', model='nmos_1v8', W='1u', L='180n')
circuit.M(name='n2', drain='vout', gate='vb', source='0', bulk='0', model='nmos_1v8', W='1u', L='180n')

# Load capacitance
circuit.C(name='load', positive='vout', negative=circuit.gnd, value=10e-15)

print(circuit)
