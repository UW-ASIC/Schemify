#!/usr/bin/env python3
"""CMOS NAND gate — 2 series NMOS + 2 parallel PMOS."""
from pyspice_rs import Circuit

circuit = Circuit('CMOS NAND Gate')

circuit.model('nmos_1v8', 'nmos', level=1, kp=120e-6, vto=0.5)
circuit.model('pmos_1v8', 'pmos', level=1, kp=60e-6, vto=-0.5)

circuit.V(name='dd', positive='vdd', negative=circuit.gnd, value=1.8)

# Inputs
circuit.V(name='a', positive='va', negative=circuit.gnd, value=1.8)
circuit.V(name='b', positive='vb', negative=circuit.gnd, value=1.8)

# PMOS pull-up network (parallel)
circuit.M(name='p1', drain='vout', gate='va', source='vdd', bulk='vdd', model='pmos_1v8', W='2u', L='180n')
circuit.M(name='p2', drain='vout', gate='vb', source='vdd', bulk='vdd', model='pmos_1v8', W='2u', L='180n')

# NMOS pull-down network (series)
circuit.M(name='n1', drain='vout', gate='va', source='mid', bulk='0', model='nmos_1v8', W='2u', L='180n')
circuit.M(name='n2', drain='mid', gate='vb', source='0', bulk='0', model='nmos_1v8', W='2u', L='180n')

# Load capacitance
circuit.C(name='load', positive='vout', negative=circuit.gnd, value=10e-15)

print(circuit)
