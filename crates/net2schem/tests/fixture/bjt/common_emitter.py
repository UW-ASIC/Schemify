#!/usr/bin/env python3
"""Common-emitter BJT amplifier with voltage divider bias."""
from pyspice_rs import Circuit

circuit = Circuit('Common Emitter Amplifier')

circuit.model('2N2222', 'npn', bf=100, **{'is': 1e-14}, vaf=50)

circuit.V(name='cc', positive='vcc', negative=circuit.gnd, value=5)
circuit.V(name='in', positive='vin', negative=circuit.gnd, value=0)  # AC source

# Bias network
circuit.R(name='1', positive='vcc', negative='base', value=56e3)
circuit.R(name='2', positive='base', negative=circuit.gnd, value=10e3)

# AC coupling
circuit.C(name='in', positive='vin', negative='base', value=10e-6)
circuit.C(name='out', positive='vout', negative='output', value=10e-6)

# Transistor
circuit.Q(name='1', collector='vout', base='base', emitter='emitter', model='2N2222')

# Collector and emitter resistors
circuit.R(name='c', positive='vcc', negative='vout', value=2.2e3)
circuit.R(name='e', positive='emitter', negative=circuit.gnd, value=1e3)

# Emitter bypass cap
circuit.C(name='e', positive='emitter', negative=circuit.gnd, value=100e-6)

# Output load
circuit.R(name='load', positive='output', negative=circuit.gnd, value=10e3)

print(circuit)
