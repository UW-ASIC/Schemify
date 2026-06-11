#!/usr/bin/env python3
"""Non-inverting op-amp amplifier. Gain = 1 + Rf/Rg = 11."""
from pyspice_rs import Circuit

circuit = Circuit('Non-Inverting Amplifier')

circuit.V(name='cc', positive='vcc', negative=circuit.gnd, value=15)
circuit.V(name='ee', positive='vee', negative=circuit.gnd, value=-15)
circuit.V(name='in', positive='vin', negative=circuit.gnd, value=0.1)

# Input to non-inverting terminal
circuit.R(name='in', positive='vin', negative='vplus', value=100)

# Feedback network
circuit.R(name='g', positive='vminus', negative=circuit.gnd, value=1e3)
circuit.R(name='f', positive='vminus', negative='vout', value=10e3)

# Op-amp (behavioral VCVS: E element)
circuit.E(name='amp', positive='vout', negative=circuit.gnd,
          control_positive='vplus', control_negative='vminus', voltage_gain=1e6)

print(circuit)
