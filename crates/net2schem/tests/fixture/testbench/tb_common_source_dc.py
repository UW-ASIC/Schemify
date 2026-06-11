#!/usr/bin/env python3
"""Testbench: Common-source amp — DC transfer curve + operating point."""
from pyspice_rs import Circuit

circuit = Circuit('TB Common Source DC')

# DUT
circuit.X('dut', 'common_source', 'vin', 'vout', 'vdd')

# Supplies
circuit.V(name='dd', positive='vdd', negative=circuit.gnd, value=1.8)
circuit.V(name='in', positive='vin', negative=circuit.gnd, value=0.7)

# Probe load
circuit.R(name='probe', positive='vout', negative='vout_probe', value=1)

print(circuit)
