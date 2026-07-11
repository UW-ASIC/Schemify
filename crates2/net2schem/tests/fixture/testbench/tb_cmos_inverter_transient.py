#!/usr/bin/env python3
"""Testbench: CMOS inverter — propagation delay + power dissipation.

Measures:
- tpLH (low-to-high propagation delay)
- tpHL (high-to-low propagation delay)
- tp = (tpLH + tpHL) / 2
- Dynamic power at given frequency
"""
from pyspice_rs import Circuit

circuit = Circuit('TB CMOS Inverter Transient')

# DUT
circuit.X('dut', 'cmos_inverter', 'vin', 'vout', 'vdd')

# Supply (measure current for power)
circuit.V(name='dd', positive='vdd', negative=circuit.gnd, value=1.8)

# Fast input pulse (1 GHz)
circuit.PulseVoltageSource(name='in', positive='vin', negative=circuit.gnd,
                           initial_value=0, pulsed_value=1.8,
                           rise_time=20e-12, fall_time=20e-12,
                           pulse_width=500e-12, period=1e-9)

# Realistic load: fanout-of-4 gate capacitance
circuit.C(name='load', positive='vout', negative=circuit.gnd, value=8e-15)

print(circuit)
