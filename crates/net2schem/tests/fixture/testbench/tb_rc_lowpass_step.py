#!/usr/bin/env python3
"""Testbench: RC low-pass filter — step response (rise time, settling)."""
from pyspice_rs import Circuit

circuit = Circuit('TB RC Low-Pass Step')

# DUT
circuit.X('dut', 'rc_lowpass', 'vin', 'vout')

# Step input: 0V to 1V with fast edge
circuit.PulseVoltageSource(name='in', positive='vin', negative=circuit.gnd,
                           initial_value=0, pulsed_value=1.0,
                           rise_time=1e-9, fall_time=1e-9,
                           pulse_width=10e-3, period=20e-3)

# Measurement load
circuit.R(name='load', positive='vout', negative=circuit.gnd, value=1e6)

print(circuit)
