#!/usr/bin/env python3
"""Testbench: Differential pair — input offset voltage measurement.

Sweeps differential input to find the zero-crossing of the
differential output (Voutp - Voutn = 0).
"""
from pyspice_rs import Circuit

circuit = Circuit('TB Diff Pair Offset')

# DUT
circuit.X('dut', 'diff_pair', 'inp', 'inn', 'outp', 'outn', 'vdd')

# Supply
circuit.V(name='dd', positive='vdd', negative=circuit.gnd, value=1.8)

# Fixed common-mode, sweep differential
circuit.V(name='cm', positive='vcm', negative=circuit.gnd, value=0.9)
circuit.V(name='dp', positive='inp', negative='vcm', value=0)
circuit.V(name='dn', positive='vcm', negative='inn', value=0)

# Measurement probes
circuit.R(name='p_p', positive='outp', negative=circuit.gnd, value=1e6)
circuit.R(name='p_n', positive='outn', negative=circuit.gnd, value=1e6)

print(circuit)

# Fine DC sweep around zero differential input
simulator = circuit.simulator()
analysis = simulator.dc(Vdp=slice(-50e-3, 50e-3, 0.1e-3))
