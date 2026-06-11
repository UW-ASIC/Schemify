#!/usr/bin/env python3
"""Testbench: Voltage divider — DC sweep + load regulation test."""
from pyspice_rs import Circuit

circuit = Circuit('TB Voltage Divider')

# DUT instantiation (resolved to voltage_divider.chn)
circuit.X('dut', 'voltage_divider', 'vin', 'vout')

# Supply sweep
circuit.V(name='in', positive='vin', negative=circuit.gnd, value=5)

# Variable load to test regulation
circuit.R(name='load', positive='vout', negative=circuit.gnd, value=10e3)

print(circuit)
