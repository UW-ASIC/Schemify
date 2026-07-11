#!/usr/bin/env python3
"""Brokaw bandgap voltage reference — ~1.25V output, temperature-stable."""
from pyspice_rs import Circuit

circuit = Circuit('Bandgap Reference')

circuit.model('pmos_1v8', 'pmos', level=1, kp=60e-6, vto=-0.5)
circuit.model('npn_1x', 'npn', bf=100, **{'is': 1e-15})
circuit.model('npn_8x', 'npn', bf=100, **{'is': 8e-15})

circuit.V(name='cc', positive='vcc', negative=circuit.gnd, value=3.3)

# Op-amp (behavioral) forces VA = VB
circuit.E(name='amp', positive='opout', negative=circuit.gnd,
          control_positive='va', control_negative='vb', voltage_gain=1e6)

# Current mirror (PMOS)
circuit.M(name='p1', drain='va', gate='opout', source='vcc', bulk='vcc', model='pmos_1v8', W='10u', L='1u')
circuit.M(name='p2', drain='vb', gate='opout', source='vcc', bulk='vcc', model='pmos_1v8', W='10u', L='1u')

# BJTs (Q1: 1x, Q2: 8x area via parallel)
circuit.Q(name='1', collector=circuit.gnd, base=circuit.gnd, emitter='va', model='npn_1x')
circuit.R(name='1', positive='va', negative='vref', value=10e3)

# Q2 with PTAT resistor
circuit.Q(name='2', collector=circuit.gnd, base=circuit.gnd, emitter='n1', model='npn_8x')
circuit.R(name='ptat', positive='vb', negative='n1', value=7.4e3)
circuit.R(name='2', positive='n1', negative='vref', value=10e3)

# Output
circuit.R(name='out', positive='vref', negative=circuit.gnd, value=100e3)

print(circuit)
