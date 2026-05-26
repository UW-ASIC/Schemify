#!/usr/bin/env python3
"""Testbench: Two-stage op-amp — open-loop gain + phase margin.

Measures:
- DC open-loop gain (A0)
- Unity-gain bandwidth (UGBW)
- Phase margin at UGBW
- Gain margin
"""
from pyspice_rs import Circuit

circuit = Circuit('TB Two-Stage Op-Amp Open Loop')

# DUT
circuit.X('dut', 'two_stage_opamp', 'inp', 'inn', 'vout', 'vdd')

# Supply
circuit.V(name='dd', positive='vdd', negative=circuit.gnd, value=1.8)

# Bias: set both inputs to mid-rail for operating point
circuit.V(name='cm', positive='vcm', negative=circuit.gnd, value=0.9)

# AC stimulus on + input only (open loop)
circuit.raw_spice('Vinp inp vcm DC 0 AC 1')
circuit.V(name='inn', positive='inn', negative='vcm', value=0)

# Load capacitance (typical)
circuit.C(name='load', positive='vout', negative=circuit.gnd, value=5e-12)

print(circuit)

# AC analysis: wide sweep
simulator = circuit.simulator()
analysis = simulator.ac(variation='dec', number_of_points=50,
                        start_frequency=1, stop_frequency=10e9)
