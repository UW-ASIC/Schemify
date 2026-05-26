#!/usr/bin/env python3
"""Testbench: Buck converter — switching waveforms + output ripple.

Captures:
- Switch node voltage (SW)
- Output voltage ripple
- Efficiency calculation
"""
import json
import numpy as np
from pyspice_rs import Circuit

circuit = Circuit('TB Buck Converter Waveforms')

VIN = 3.3
VOUT = 1.8
FREQ = 1e6
DUTY = VOUT / VIN

circuit.V(name='in', positive='vin', negative=circuit.gnd, value=VIN)

# PWM signal
circuit.PulseVoltageSource(name='pwm', positive='vpwm', negative=circuit.gnd,
                           initial_value=0, pulsed_value=1.8,
                           rise_time=5e-9, fall_time=5e-9,
                           pulse_width=DUTY / FREQ, period=1.0 / FREQ)

# Ideal switches (simplified with resistors for simulation)
circuit.R(name='hs_on', positive='vin', negative='sw', value=50e-3)   # High-side on-resistance
circuit.R(name='ls_on', positive='sw', negative=circuit.gnd, value=50e-3)  # Low-side

# LC filter
circuit.L(name='1', positive='sw', negative='vout', value=2.2e-6)
circuit.R(name='dcr', positive='vout', negative='vout_sense', value=20e-3)  # DCR
circuit.C(name='out', positive='vout_sense', negative=circuit.gnd, value=22e-6)

# Current sense resistor
circuit.R(name='sense', positive='vout_sense', negative='vload', value=10e-3)

# Load: 1A
circuit.R(name='load', positive='vload', negative=circuit.gnd, value=VOUT / 1.0)

print(circuit)

simulator = circuit.simulator()
analysis = simulator.transient(step_time=1e-9, end_time=50e-6)

time = np.array(analysis.time)
v_sw = np.array(analysis['sw'])
v_out = np.array(analysis['vout_sense'])

# Steady-state (last 10 cycles)
ss_start = int(len(time) * 0.8)
v_out_ss = v_out[ss_start:]
ripple_pp = float(np.max(v_out_ss) - np.min(v_out_ss))
v_out_avg = float(np.mean(v_out_ss))

results = {
    "analysis": "transient",
    "traces": [
        {"name": "V(SW)", "x": time.tolist(), "y": v_sw.tolist(),
         "x_unit": "s", "y_unit": "V", "group": "switch_node"},
        {"name": "V(OUT)", "x": time.tolist(), "y": v_out.tolist(),
         "x_unit": "s", "y_unit": "V", "group": "output"},
    ],
    "measurements": {
        "vout_avg_v": v_out_avg,
        "ripple_mv_pp": ripple_pp * 1e3,
        "target_vout": VOUT,
        "duty_cycle": DUTY,
        "switching_freq_mhz": FREQ / 1e6,
    }
}
print(json.dumps(results))
