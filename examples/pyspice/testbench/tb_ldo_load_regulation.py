#!/usr/bin/env python3
"""Testbench: LDO regulator — load transient + regulation.

Measures:
- Load regulation: Vout change vs Iload
- Load transient response: voltage droop/overshoot on current step
"""
from pyspice_rs import Circuit

circuit = Circuit('TB LDO Load Regulation')

circuit.model('nmos_1v8', 'nmos', level=1, kp=120e-6, vto=0.5)

# DUT
circuit.X('dut', 'ldo_regulator', 'vin', 'vout', 'vref')

# Input supply
circuit.V(name='in', positive='vin', negative=circuit.gnd, value=3.3)

# Reference voltage
circuit.V(name='ref', positive='vref', negative=circuit.gnd, value=1.2)

# Output capacitor (external)
circuit.R(name='esr', positive='vout', negative='cap_node', value=30e-3)
circuit.C(name='out', positive='cap_node', negative=circuit.gnd, value=4.7e-6)

# Load current step: 1mA to 50mA in 100ns
circuit.PulseVoltageSource(name='ctrl', positive='vctrl', negative=circuit.gnd,
                           initial_value=0, pulsed_value=1.8,
                           rise_time=100e-9, fall_time=100e-9,
                           pulse_width=50e-6, period=100e-6)

# Switchable load using NMOS as current sink
circuit.M(name='load', drain='vout', gate='vctrl', source='rsense', bulk='0', model='nmos_1v8', W='500u', L='180n')
circuit.R(name='sense', positive='rsense', negative=circuit.gnd, value=1)

# Baseline light load
circuit.R(name='light', positive='vout', negative=circuit.gnd, value=1.8e3)  # ~1mA

print(circuit)

# Transient: observe load step response
simulator = circuit.simulator()
analysis = simulator.transient(step_time=10e-9, end_time=200e-6)
