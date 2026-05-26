#!/usr/bin/env python3
"""Testbench: Bandgap reference — temperature sweep.

Measures output voltage stability across -40C to 125C.
A good bandgap has <50ppm/C temperature coefficient.
"""
from pyspice_rs import Circuit

circuit = Circuit('TB Bandgap Temperature')

# DUT
circuit.X('dut', 'bandgap_reference', 'vref', 'vcc')

# Supply
circuit.V(name='cc', positive='vcc', negative=circuit.gnd, value=3.3)

# Measurement probe (high impedance)
circuit.R(name='probe', positive='vref', negative=circuit.gnd, value=10e6)

print(circuit)

# Temperature sweep: -40C to 125C (industrial range)
simulator = circuit.simulator()
analysis = simulator.dc(temperature=slice(-40, 125, 1))
