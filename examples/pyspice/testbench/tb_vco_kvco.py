#!/usr/bin/env python3
"""Testbench: VCO — Kvco (frequency sensitivity) characterization.

Sweeps control voltage and measures oscillation frequency.
Kvco = dfosc/dVctrl (Hz/V).
"""
from pyspice_rs import Circuit

circuit = Circuit('TB VCO Kvco')

# DUT
circuit.X('dut', 'vco', 'n1', 'n2', 'n3', 'vctrl', 'vdd')

# Supply
circuit.V(name='dd', positive='vdd', negative=circuit.gnd, value=1.8)

# Control voltage: slow ramp to measure frequency at each level
circuit.V(name='ctrl', positive='vctrl', negative=circuit.gnd, value=0.9)

# Output buffer (for frequency counter)
circuit.C(name='probe', positive='n1', negative=circuit.gnd, value=1e-15)

print(circuit)

# Method 1: DC sweep
simulator = circuit.simulator()
analysis = simulator.dc(Vctrl=slice(0.3, 1.5, 0.05))
