#!/usr/bin/env python3
"""Summing amplifier — adds three weighted inputs."""
from pyspice_rs import Circuit

circuit = Circuit('Summing Amplifier')

circuit.V(name='cc', positive='vcc', negative=circuit.gnd, value=15)
circuit.V(name='ee', positive='vee', negative=circuit.gnd, value=-15)

# Three input sources
circuit.V(name='1', positive='v1', negative=circuit.gnd, value=1.0)
circuit.V(name='2', positive='v2', negative=circuit.gnd, value=0.5)
circuit.V(name='3', positive='v3', negative=circuit.gnd, value=-0.3)

# Input resistors (equal weighting)
circuit.R(name='1', positive='v1', negative='vminus', value=10e3)
circuit.R(name='2', positive='v2', negative='vminus', value=10e3)
circuit.R(name='3', positive='v3', negative='vminus', value=10e3)

# Feedback resistor
circuit.R(name='f', positive='vminus', negative='vout', value=10e3)

# Op-amp (behavioral VCVS: E element)
circuit.E(name='amp', positive='vout', negative=circuit.gnd,
          control_positive=circuit.gnd, control_negative='vminus', voltage_gain=1e6)

print(circuit)
