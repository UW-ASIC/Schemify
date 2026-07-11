#!/usr/bin/env python3
"""Testbench: Two-stage op-amp — closed-loop unity-gain buffer.

Tests stability in unity-gain feedback configuration:
- Step response (overshoot, settling time, ringing)
- Closed-loop bandwidth
- Slew rate
"""
from pyspice_rs import Circuit

circuit = Circuit('TB Two-Stage Op-Amp Closed Loop')

# DUT
circuit.X('dut', 'two_stage_opamp', 'inp', 'inn', 'vout', 'vdd')

# Supply
circuit.V(name='dd', positive='vdd', negative=circuit.gnd, value=1.8)

# Unity-gain feedback: connect output to inverting input
circuit.V(name='fb', positive='inn', negative='vout', value=0)

# Step input
circuit.PulseVoltageSource(name='in', positive='inp', negative=circuit.gnd,
                           initial_value=0.7, pulsed_value=1.1,
                           rise_time=100e-12, fall_time=100e-12,
                           pulse_width=500e-9, period=1e-6)

# Load
circuit.C(name='load', positive='vout', negative=circuit.gnd, value=5e-12)
circuit.R(name='load', positive='vout', negative=circuit.gnd, value=100e3)

print(circuit)
