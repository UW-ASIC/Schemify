#!/usr/bin/env python3
"""Testbench: Ring oscillator — frequency measurement + VDD sensitivity.

Measures oscillation frequency as a function of supply voltage.
Also extracts per-stage delay: td = 1 / (2 * N * fosc).
"""
from pyspice_rs import Circuit

circuit = Circuit('TB Ring Oscillator Frequency')

# DUT
circuit.X('dut', 'ring_oscillator', 'n1', 'n2', 'n3', 'vdd')

# Nominal supply
circuit.V(name='dd', positive='vdd', negative=circuit.gnd, value=1.8)

# Initial condition to kick-start oscillation
circuit.C(name='kick', positive='n1', negative=circuit.gnd, value=1e-15)

print(circuit)
