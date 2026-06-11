#!/usr/bin/env python3
"""BJT cascode amplifier — high gain, wide bandwidth."""
from pyspice_rs import Circuit

circuit = Circuit('BJT Cascode Amplifier')

circuit.model('2N2222', 'npn', bf=100, **{'is': 1e-14}, vaf=50)

circuit.V(name='cc', positive='vcc', negative=circuit.gnd, value=12)
circuit.V(name='in', positive='vin', negative=circuit.gnd, value=0)

# Bias network for CE stage
circuit.R(name='b1', positive='vcc', negative='base_ce', value=100e3)
circuit.R(name='b2', positive='base_ce', negative=circuit.gnd, value=22e3)

# Bias for CB stage
circuit.R(name='b3', positive='vcc', negative='base_cb', value=56e3)
circuit.R(name='b4', positive='base_cb', negative=circuit.gnd, value=22e3)
circuit.C(name='bypass', positive='base_cb', negative=circuit.gnd, value=100e-6)

# CE transistor (input)
circuit.C(name='in', positive='vin', negative='base_ce', value=1e-6)
circuit.Q(name='1', collector='mid', base='base_ce', emitter='emitter', model='2N2222')
circuit.R(name='e', positive='emitter', negative=circuit.gnd, value=470)

# CB transistor (cascode)
circuit.Q(name='2', collector='vout', base='base_cb', emitter='mid', model='2N2222')
circuit.R(name='c', positive='vcc', negative='vout', value=4.7e3)

# Output coupling
circuit.C(name='out', positive='vout', negative='output', value=1e-6)
circuit.R(name='load', positive='output', negative=circuit.gnd, value=10e3)

print(circuit)
