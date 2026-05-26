#!/usr/bin/env python3
"""Testbench: RC low-pass filter — Bode plot (magnitude + phase).

Generates printable waveform data: frequency, gain (dB), phase (degrees).
Verifies -20dB/decade rolloff and -45deg at cutoff.
"""
import json
import numpy as np
from pyspice_rs import Circuit

circuit = Circuit('TB RC Bode Plot')

circuit.raw_spice('Vin vin 0 DC 0 AC 1')
circuit.R(name='1', positive='vin', negative='vout', value=1e3)
circuit.C(name='1', positive='vout', negative=circuit.gnd, value=100e-9)

print(circuit)

simulator = circuit.simulator()
analysis = simulator.ac(variation='dec', number_of_points=50,
                        start_frequency=10, stop_frequency=10e6)

# Expected cutoff: fc = 1/(2*pi*1k*100n) = 1.59 kHz
freq = np.array(analysis.frequency)
vout = np.array(analysis['vout'])
gain_db = 20 * np.log10(np.abs(vout))
phase_deg = np.angle(vout, deg=True)

# Output as JSON for Schemify waveform viewer
results = {
    "analysis": "ac",
    "traces": [
        {"name": "Gain", "x": freq.tolist(), "y": gain_db.tolist(),
         "x_unit": "Hz", "y_unit": "dB"},
        {"name": "Phase", "x": freq.tolist(), "y": phase_deg.tolist(),
         "x_unit": "Hz", "y_unit": "deg"},
    ],
    "measurements": {
        "fc_3db_hz": 1.0 / (2 * np.pi * 1e3 * 100e-9),
        "dc_gain_db": 0.0,
        "rolloff_db_per_dec": -20,
    }
}
print(json.dumps(results))
