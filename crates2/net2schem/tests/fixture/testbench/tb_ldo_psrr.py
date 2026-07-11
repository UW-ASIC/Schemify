#!/usr/bin/env python3
"""Testbench: LDO regulator — PSRR (Power Supply Rejection Ratio).

PSRR(f) = 20*log10(Vin_ripple / Vout_ripple) in dB.
Higher is better — good LDO has >40dB at 1MHz.
"""
from pyspice_rs import Circuit

circuit = Circuit('TB LDO PSRR')

# DUT
circuit.X('dut', 'ldo_regulator', 'vin', 'vout', 'vref')

# DC supply + AC ripple on input
circuit.raw_spice('Vin vin 0 DC 3.3 AC 1')

# Clean reference (no AC)
circuit.V(name='ref', positive='vref', negative=circuit.gnd, value=1.2)

# External output cap
circuit.C(name='out', positive='vout', negative=circuit.gnd, value=4.7e-6)

# Constant load
circuit.R(name='load', positive='vout', negative=circuit.gnd, value=36)  # ~50mA

print(circuit)
