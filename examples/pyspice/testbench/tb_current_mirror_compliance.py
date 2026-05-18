#!/usr/bin/env python3
"""Testbench: Current mirror — output compliance + mismatch.

Sweeps output voltage to measure:
- Output current vs. Vds (compliance range)
- Output resistance (Rout = dVds / dIout)
- Mirror ratio accuracy
"""
from pyspice_rs import Circuit

circuit = Circuit('TB Current Mirror Compliance')

# DUT
circuit.X('dut', 'current_mirror', 'iref', 'iout', 'vdd')

# Supply
circuit.V(name='dd', positive='vdd', negative=circuit.gnd, value=1.8)

# Reference current
circuit.I(name='ref', positive='vdd', negative='iref', value=50e-6)

# Sweep output voltage
circuit.V(name='out', positive='iout', negative=circuit.gnd, value=0.9)

print(circuit)

# DC sweep: output voltage from 0V to VDD
simulator = circuit.simulator()
analysis = simulator.dc(Vout=slice(0, 1.8, 0.005))
