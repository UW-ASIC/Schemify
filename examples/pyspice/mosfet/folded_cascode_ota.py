#!/usr/bin/env python3
"""Folded-cascode OTA — wider input range than telescopic."""
from pyspice_rs import Circuit

circuit = Circuit('Folded Cascode OTA')

circuit.model('nmos_1v8', 'nmos', level=1, kp=120e-6, vto=0.5)
circuit.model('pmos_1v8', 'pmos', level=1, kp=60e-6, vto=-0.5)

circuit.V(name='dd', positive='vdd', negative=circuit.gnd, value=1.8)
circuit.V(name='inp', positive='inp', negative=circuit.gnd, value=0.9)
circuit.V(name='inn', positive='inn', negative=circuit.gnd, value=0.9)
circuit.V(name='bn', positive='vbn', negative=circuit.gnd, value=0.5)
circuit.V(name='bp', positive='vbp', negative=circuit.gnd, value=1.3)

# PMOS input pair
circuit.M(name='p1', drain='n1', gate='inp', source='vdd', bulk='vdd', model='pmos_1v8', W='20u', L='500n')
circuit.M(name='p2', drain='n2', gate='inn', source='vdd', bulk='vdd', model='pmos_1v8', W='20u', L='500n')

# NMOS folded cascode
circuit.M(name='n1', drain='n1', gate='vbn', source='n3', bulk='0', model='nmos_1v8', W='5u', L='500n')
circuit.M(name='n2', drain='n2', gate='vbn', source='n4', bulk='0', model='nmos_1v8', W='5u', L='500n')

# NMOS current sources
circuit.I(name='b1', positive=circuit.gnd, negative='n3', value=100e-6)
circuit.I(name='b2', positive=circuit.gnd, negative='n4', value=100e-6)

# PMOS cascode load
circuit.M(name='p3', drain='outp', gate='vbp', source='n5', bulk='vdd', model='pmos_1v8', W='10u', L='500n')
circuit.M(name='p4', drain='outn', gate='vbp', source='n6', bulk='vdd', model='pmos_1v8', W='10u', L='500n')
circuit.M(name='p5', drain='n5', gate='n5', source='vdd', bulk='vdd', model='pmos_1v8', W='10u', L='500n')
circuit.M(name='p6', drain='n6', gate='n6', source='vdd', bulk='vdd', model='pmos_1v8', W='10u', L='500n')

# Tail current
circuit.I(name='tail', positive='vdd', negative='tail_node', value=200e-6)

print(circuit)
