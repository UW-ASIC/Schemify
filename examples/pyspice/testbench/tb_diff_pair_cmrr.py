#!/usr/bin/env python3
"""Testbench: Differential pair — CMRR measurement.

Measures differential gain (Ad) and common-mode gain (Acm)
separately, then computes CMRR = Ad/Acm.
"""
from pyspice_rs import Circuit

circuit = Circuit('TB Diff Pair CMRR')

# DUT
circuit.X('dut', 'diff_pair', 'inp', 'inn', 'outp', 'outn', 'vdd')

# Supply
circuit.V(name='dd', positive='vdd', negative=circuit.gnd, value=1.8)

# Common-mode + differential stimulus
circuit.V(name='cm', positive='vcm', negative=circuit.gnd, value=0.9)
circuit.raw_spice('Vdp inp vcm DC 0 AC 0.5')    # +0.5 * Vdm
circuit.raw_spice('Vdn vcm inn DC 0 AC 0.5')    # -0.5 * Vdm

# Output measurement (differential)
circuit.R(name='probe_p', positive='outp', negative=circuit.gnd, value=1e6)
circuit.R(name='probe_n', positive='outn', negative=circuit.gnd, value=1e6)

print(circuit)

# Step 1: Differential-mode AC gain
simulator = circuit.simulator()
analysis = simulator.ac(variation='dec', number_of_points=20,
                        start_frequency=1, stop_frequency=1e9)
