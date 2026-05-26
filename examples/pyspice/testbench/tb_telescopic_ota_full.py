#!/usr/bin/env python3
"""Testbench: Telescopic OTA — full characterization suite.

Runs multiple analyses in one file:
1. DC operating point (bias currents, node voltages)
2. Open-loop AC (gain, bandwidth, phase margin)
3. Input common-mode range
"""
from pyspice_rs import Circuit

circuit = Circuit('TB Telescopic OTA Full')

# DUT
circuit.X('dut', 'telescopic_ota', 'inp', 'inn', 'outp', 'outn', 'vdd',
          'vbn', 'vbp', 'vbpt')

# Supply
circuit.V(name='dd', positive='vdd', negative=circuit.gnd, value=1.8)

# Bias voltages (from bias generator or external)
circuit.V(name='bn', positive='vbn', negative=circuit.gnd, value=0.6)
circuit.V(name='bp', positive='vbp', negative=circuit.gnd, value=1.2)
circuit.V(name='bpt', positive='vbpt', negative=circuit.gnd, value=1.0)

# Common-mode + differential stimulus
circuit.V(name='cm', positive='vcm', negative=circuit.gnd, value=0.9)
circuit.raw_spice('Vdp inp vcm DC 0 AC 0.5')
circuit.raw_spice('Vdn vcm inn DC 0 AC -0.5')

# Output loads (symmetric)
circuit.C(name='lp', positive='outp', negative=circuit.gnd, value=2e-12)
circuit.C(name='ln', positive='outn', negative=circuit.gnd, value=2e-12)

print(circuit)

# --- Analysis 1: Operating point ---
simulator = circuit.simulator()
analysis = simulator.operating_point()

# --- Analysis 2: AC open-loop gain ---
analysis = simulator.ac(variation='dec', number_of_points=50,
                        start_frequency=1, stop_frequency=10e9)

# --- Analysis 3: Input common-mode range ---
analysis = simulator.dc(Vcm=slice(0.3, 1.5, 0.005))
