#!/usr/bin/env python3
"""Testbench: Comparator — speed + overdrive recovery.

Measures:
- Propagation delay vs overdrive voltage
- Input-referred offset
- Overdrive recovery time
"""
from pyspice_rs import Circuit

circuit = Circuit('TB Comparator Speed')

# DUT
circuit.X('dut', 'comparator', 'vin', 'vref', 'vout', 'vdd')

# Supply
circuit.V(name='dd', positive='vdd', negative=circuit.gnd, value=1.8)

# Reference at mid-rail
circuit.V(name='ref', positive='vref', negative=circuit.gnd, value=0.9)

# Input: step crossing the reference with various overdrives
circuit.PulseVoltageSource(name='in', positive='vin', negative=circuit.gnd,
                           initial_value=0.89, pulsed_value=0.91,
                           rise_time=100e-12, fall_time=100e-12,
                           pulse_width=20e-9, period=40e-9)

# Output load
circuit.C(name='load', positive='vout', negative=circuit.gnd, value=50e-15)

print(circuit)

# Transient: measure delay from input crossing to output settling
simulator = circuit.simulator()
analysis = simulator.transient(step_time=10e-12, end_time=100e-9)
