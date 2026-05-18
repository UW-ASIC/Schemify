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

# AC sweep: 10 Hz to 10 MHz, 20 points per decade
simulator = circuit.simulator()
analysis = simulator.ac(variation='dec', number_of_points=20,
                        start_frequency=10, stop_frequency=10e6)
