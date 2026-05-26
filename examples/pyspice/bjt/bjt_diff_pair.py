#!/usr/bin/env python3
"""BJT differential pair with resistive loads."""
from pyspice_rs import Circuit

circuit = Circuit('BJT Differential Pair')

circuit.model('2N2222', 'npn', bf=100, **{'is': 1e-14}, vaf=50)

circuit.V(name='cc', positive='vcc', negative=circuit.gnd, value=5)
circuit.V(name='inp', positive='inp', negative=circuit.gnd, value=2.5)
circuit.V(name='inn', positive='inn', negative=circuit.gnd, value=2.5)

# Collector loads
circuit.R(name='c1', positive='vcc', negative='outp', value=5e3)
circuit.R(name='c2', positive='vcc', negative='outn', value=5e3)

# Diff pair
circuit.Q(name='1', collector='outp', base='inp', emitter='tail', model='2N2222')
circuit.Q(name='2', collector='outn', base='inn', emitter='tail', model='2N2222')

# Tail current source
circuit.I(name='tail', positive='tail', negative=circuit.gnd, value=500e-6)

print(circuit)

simulator = circuit.simulator()
analysis = simulator.dc(Vinp=slice(2.0, 3.0, 0.005))
