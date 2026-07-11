#!/usr/bin/env python3
"""Resistive voltage divider — simplest possible circuit."""
from pyspice_rs import Circuit

circuit = Circuit('Voltage Divider')

circuit.V(name='in', positive='vin', negative=circuit.gnd, value=5)
circuit.R(name='1', positive='vin', negative='vout', value=10e3)
circuit.R(name='2', positive='vout', negative=circuit.gnd, value=10e3)

print(circuit)
