#!/usr/bin/env python3
"""BJT current mirror — Widlar topology."""
from pyspice_rs import Circuit

circuit = Circuit('BJT Current Mirror')

circuit.model('2N2222', 'npn', bf=100, **{'is': 1e-14}, vaf=50)

circuit.V(name='cc', positive='vcc', negative=circuit.gnd, value=5)

# Reference current set by resistor
circuit.R(name='ref', positive='vcc', negative='iref', value=47e3)

# Diode-connected reference
circuit.Q(name='1', collector='iref', base='iref', emitter=circuit.gnd, model='2N2222')

# Mirror transistor
circuit.Q(name='2', collector='iout', base='iref', emitter=circuit.gnd, model='2N2222')

# Load
circuit.R(name='load', positive='vcc', negative='iout', value=10e3)

print(circuit)

simulator = circuit.simulator()
analysis = simulator.operating_point()
