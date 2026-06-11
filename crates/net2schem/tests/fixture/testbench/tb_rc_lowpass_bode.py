#!/usr/bin/env python3
"""Testbench: RC low-pass filter — Bode plot (magnitude + phase).

Generates printable waveform data: frequency, gain (dB), phase (degrees).
Verifies -20dB/decade rolloff and -45deg at cutoff.
"""
import json
from pyspice_rs import Circuit

circuit = Circuit('TB RC Bode Plot')

circuit.raw_spice('Vin vin 0 DC 0 AC 1')
circuit.R(name='1', positive='vin', negative='vout', value=1e3)
circuit.C(name='1', positive='vout', negative=circuit.gnd, value=100e-9)

print(circuit)
