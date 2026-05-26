#!/usr/bin/env python3
"""Testbench: Ring oscillator — waveform capture + frequency extraction.

Captures all 3 node voltages to show phase relationship between stages.
Extracts oscillation frequency from zero-crossings.
"""
import json
import numpy as np
from pyspice_rs import Circuit

circuit = Circuit('TB Ring Oscillator Waveforms')

circuit.model('nmos_1v8', 'nmos', level=1, kp=120e-6, vto=0.5)
circuit.model('pmos_1v8', 'pmos', level=1, kp=60e-6, vto=-0.5)

circuit.V(name='dd', positive='vdd', negative=circuit.gnd, value=1.8)

# 3-stage ring oscillator (inline, not subcircuit for direct waveform access)
circuit.M(name='p1', drain='n1', gate='n3', source='vdd', bulk='vdd', model='pmos_1v8', W='2u', L='180n')
circuit.M(name='n1', drain='n1', gate='n3', source='0', bulk='0', model='nmos_1v8', W='1u', L='180n')
circuit.M(name='p2', drain='n2', gate='n1', source='vdd', bulk='vdd', model='pmos_1v8', W='2u', L='180n')
circuit.M(name='n2', drain='n2', gate='n1', source='0', bulk='0', model='nmos_1v8', W='1u', L='180n')
circuit.M(name='p3', drain='n3', gate='n2', source='vdd', bulk='vdd', model='pmos_1v8', W='2u', L='180n')
circuit.M(name='n3', drain='n3', gate='n2', source='0', bulk='0', model='nmos_1v8', W='1u', L='180n')

# Parasitic caps
circuit.C(name='1', positive='n1', negative=circuit.gnd, value=10e-15)
circuit.C(name='2', positive='n2', negative=circuit.gnd, value=10e-15)
circuit.C(name='3', positive='n3', negative=circuit.gnd, value=10e-15)

print(circuit)

simulator = circuit.simulator()
analysis = simulator.transient(step_time=1e-12, end_time=10e-9)

time = np.array(analysis.time)
v1 = np.array(analysis['n1'])
v2 = np.array(analysis['n2'])
v3 = np.array(analysis['n3'])

# Frequency extraction: find period from n1 zero-crossings
mid = 0.9  # VDD/2
crossings = np.where(np.diff(np.sign(v1 - mid)))[0]
if len(crossings) >= 4:
    rising = crossings[::2]
    if len(rising) >= 2:
        periods = np.diff(time[rising])
        freq = 1.0 / np.mean(periods)
    else:
        freq = 0
else:
    freq = 0

results = {
    "analysis": "transient",
    "traces": [
        {"name": "V(n1)", "x": time.tolist(), "y": v1.tolist(),
         "x_unit": "s", "y_unit": "V"},
        {"name": "V(n2)", "x": time.tolist(), "y": v2.tolist(),
         "x_unit": "s", "y_unit": "V"},
        {"name": "V(n3)", "x": time.tolist(), "y": v3.tolist(),
         "x_unit": "s", "y_unit": "V"},
    ],
    "measurements": {
        "frequency_hz": float(freq),
        "period_ps": float(1e12 / freq) if freq > 0 else 0,
        "stage_delay_ps": float(1e12 / (6 * freq)) if freq > 0 else 0,
    }
}
print(json.dumps(results))
