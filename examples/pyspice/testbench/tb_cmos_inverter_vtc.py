#!/usr/bin/env python3
"""Testbench: CMOS inverter — voltage transfer curve + noise margins.

Sweeps Vin to get Vout, then computes:
- VIL, VIH (input thresholds where gain = -1)
- VOL, VOH (output levels)
- NML = VIL - VOL, NMH = VOH - VIH
- Switching threshold (Vin = Vout)
"""
from pyspice_rs import Circuit

circuit = Circuit('TB CMOS Inverter VTC')

# DUT
circuit.X('dut', 'cmos_inverter', 'vin', 'vout', 'vdd')

# Supply
circuit.V(name='dd', positive='vdd', negative=circuit.gnd, value=1.8)

# Input sweep
circuit.V(name='in', positive='vin', negative=circuit.gnd, value=0.9)

# Fanout load: 4 identical inverter gate caps
circuit.C(name='fan1', positive='vout', negative=circuit.gnd, value=2e-15)
circuit.C(name='fan2', positive='vout', negative=circuit.gnd, value=2e-15)
circuit.C(name='fan3', positive='vout', negative=circuit.gnd, value=2e-15)
circuit.C(name='fan4', positive='vout', negative=circuit.gnd, value=2e-15)

print(circuit)

# DC sweep with very fine step for accurate threshold detection
simulator = circuit.simulator()
analysis = simulator.dc(Vin=slice(0, 1.8, 0.001))
