#!/usr/bin/env python3
"""Emitter follower (common-collector) — impedance buffer."""
from pyspice_rs import Circuit

circuit = Circuit('Emitter Follower')

circuit.model('2N2222', 'npn', bf=100, **{'is': 1e-14}, vaf=50)

circuit.V(name='cc', positive='vcc', negative=circuit.gnd, value=12)
circuit.V(name='in', positive='vin', negative=circuit.gnd, value=6)

# Bias
circuit.R(name='1', positive='vcc', negative='base', value=100e3)
circuit.R(name='2', positive='base', negative=circuit.gnd, value=100e3)

# AC coupling
circuit.C(name='in', positive='vin', negative='base', value=1e-6)

# Transistor
circuit.Q(name='1', collector='vcc', base='base', emitter='vout', model='2N2222')

# Emitter resistor
circuit.R(name='e', positive='vout', negative=circuit.gnd, value=1e3)

# Output coupling + load
circuit.C(name='out', positive='vout', negative='output', value=10e-6)
circuit.R(name='load', positive='output', negative=circuit.gnd, value=100)

print(circuit)

simulator = circuit.simulator()
analysis = simulator.dc(Vin=slice(0, 12, 0.05))
