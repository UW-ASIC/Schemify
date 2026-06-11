#!/usr/bin/env python3
"""Testbench: RC low-pass filter — AC magnitude/phase response."""
from pyspice_rs import Circuit

circuit = Circuit('TB RC Low-Pass AC')

# DUT
circuit.X('dut', 'rc_lowpass', 'vin', 'vout')

# AC stimulus: 1V amplitude for normalized gain
circuit.raw_spice('Vin vin 0 DC 0 AC 1')

# Optional output load
circuit.R(name='load', positive='vout', negative=circuit.gnd, value=1e6)

print(circuit)
