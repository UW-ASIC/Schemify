#!/usr/bin/env python3
"""Testbench: Differential pair — transient waveforms.

Applies a differential sine input and captures:
- Input waveforms (Vinp, Vinn)
- Output waveforms (Voutp, Voutn)
- Differential output (Voutp - Voutn)
"""
import json
import numpy as np
from pyspice_rs import Circuit

circuit = Circuit('TB Diff Pair Transient')

circuit.model('nmos_1v8', 'nmos', level=1, kp=120e-6, vto=0.5)

circuit.V(name='dd', positive='vdd', negative=circuit.gnd, value=1.8)

# Load resistors
circuit.R(name='d1', positive='vdd', negative='outp', value=10e3)
circuit.R(name='d2', positive='vdd', negative='outn', value=10e3)

# Diff pair
circuit.M(name='1', drain='outp', gate='inp', source='tail', bulk='0', model='nmos_1v8', W='10u', L='180n')
circuit.M(name='2', drain='outn', gate='inn', source='tail', bulk='0', model='nmos_1v8', W='10u', L='180n')

# Tail current
circuit.I(name='tail', positive=circuit.gnd, negative='tail', value=100e-6)

# Differential sine input: 10 mVpp at 1 MHz around 0.9V CM
circuit.SinusoidalVoltageSource(name='inp', positive='inp', negative=circuit.gnd,
                                 dc_offset=0.9, offset=0.9,
                                 amplitude=5e-3, frequency=1e6)
circuit.SinusoidalVoltageSource(name='inn', positive='inn', negative=circuit.gnd,
                                 dc_offset=0.9, offset=0.9,
                                 amplitude=-5e-3, frequency=1e6)

print(circuit)

simulator = circuit.simulator()
analysis = simulator.transient(step_time=1e-9, end_time=5e-6)

# Waveform output
time = np.array(analysis.time)
vinp = np.array(analysis['inp'])
vinn = np.array(analysis['inn'])
voutp = np.array(analysis['outp'])
voutn = np.array(analysis['outn'])

results = {
    "analysis": "transient",
    "traces": [
        {"name": "V(inp)", "x": time.tolist(), "y": vinp.tolist(),
         "x_unit": "s", "y_unit": "V", "group": "input"},
        {"name": "V(inn)", "x": time.tolist(), "y": vinn.tolist(),
         "x_unit": "s", "y_unit": "V", "group": "input"},
        {"name": "V(outp)", "x": time.tolist(), "y": voutp.tolist(),
         "x_unit": "s", "y_unit": "V", "group": "output"},
        {"name": "V(outn)", "x": time.tolist(), "y": voutn.tolist(),
         "x_unit": "s", "y_unit": "V", "group": "output"},
        {"name": "V(outp)-V(outn)", "x": time.tolist(),
         "y": (voutp - voutn).tolist(),
         "x_unit": "s", "y_unit": "V", "group": "diff_output"},
    ],
    "measurements": {
        "diff_gain": float(np.max(voutp - voutn) / 10e-3),
    }
}
print(json.dumps(results))
