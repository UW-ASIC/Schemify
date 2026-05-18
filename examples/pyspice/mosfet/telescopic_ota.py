#!/usr/bin/env python3
"""Telescopic cascode OTA — high gain, single-stage amplifier."""
from pyspice_rs import Circuit

circuit = Circuit('Telescopic OTA')

circuit.model('nmos_1v8', 'nmos', level=1, kp=120e-6, vto=0.5)
circuit.model('pmos_1v8', 'pmos', level=1, kp=60e-6, vto=-0.5)

circuit.V(name='dd', positive='vdd', negative=circuit.gnd, value=1.8)
circuit.V(name='inp', positive='inp', negative=circuit.gnd, value=0.9)
circuit.V(name='inn', positive='inn', negative=circuit.gnd, value=0.9)
circuit.V(name='bn', positive='vbn', negative=circuit.gnd, value=0.6)   # NMOS cascode bias
circuit.V(name='bp', positive='vbp', negative=circuit.gnd, value=1.2)   # PMOS cascode bias
circuit.V(name='bpt', positive='vbpt', negative=circuit.gnd, value=1.0)  # PMOS top bias

# PMOS load (cascode)
circuit.M(name='p1', drain='n1', gate='vbpt', source='vdd', bulk='vdd', model='pmos_1v8', W='10u', L='500n')
circuit.M(name='p2', drain='n2', gate='vbpt', source='vdd', bulk='vdd', model='pmos_1v8', W='10u', L='500n')
circuit.M(name='p3', drain='outp', gate='vbp', source='n1', bulk='vdd', model='pmos_1v8', W='10u', L='500n')
circuit.M(name='p4', drain='outn', gate='vbp', source='n2', bulk='vdd', model='pmos_1v8', W='10u', L='500n')

# NMOS input pair (cascode)
circuit.M(name='n1', drain='n3', gate='inp', source='tail', bulk='0', model='nmos_1v8', W='10u', L='180n')
circuit.M(name='n2', drain='n4', gate='inn', source='tail', bulk='0', model='nmos_1v8', W='10u', L='180n')
circuit.M(name='n3', drain='outp', gate='vbn', source='n3', bulk='0', model='nmos_1v8', W='10u', L='500n')
circuit.M(name='n4', drain='outn', gate='vbn', source='n4', bulk='0', model='nmos_1v8', W='10u', L='500n')

# Tail current
circuit.I(name='tail', positive=circuit.gnd, negative='tail', value=200e-6)

print(circuit)

simulator = circuit.simulator()
analysis = simulator.dc(Vinp=slice(0.4, 1.4, 0.001))  # Vinp matches SPICE name
