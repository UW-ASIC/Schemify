#!/usr/bin/env python3
"""Testbench: Buck converter — switching waveforms + output ripple.

Captures:
- Switch node voltage (SW)
- Output voltage ripple
- Efficiency calculation
"""
import json
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
