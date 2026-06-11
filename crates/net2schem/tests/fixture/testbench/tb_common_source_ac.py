#!/usr/bin/env python3
"""Testbench: Common-source amp — AC gain and bandwidth."""
from pyspice_rs import Circuit

circuit = Circuit('TB Common Source AC')

# DUT
circuit.X('dut', 'common_source', 'vin', 'vout', 'vdd')

# Supply
circuit.V(name='dd', positive='vdd', negative=circuit.gnd, value=1.8)

# DC bias + AC stimulus
circuit.raw_spice('Vin vin 0 DC 0.7 AC 1')

# Output load + coupling
circuit.C(name='out', positive='vout', negative='vout_ac', value=1e-6)
circuit.R(name='load', positive='vout_ac', negative=circuit.gnd, value=100e3)

print(circuit)
