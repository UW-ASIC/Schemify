"""
RLC Filter — ported from upstream PySpice examples.

Four double-pole low-pass RLC filters with Q = 0.5, 1, 2, 4.
Plus a pass-band RLC filter.

Resonant frequency: f0 = 1/(2*pi*sqrt(LC))
Quality factor: Q = (1/R)*sqrt(L/C)

Original: PySpice-org/PySpice/examples/filter/rlc-filter.py
"""
import math
from pyspice_rs import Circuit
from pyspice_rs.unit import u_V, u_Ohm, u_mH, u_uF

inductance = 10e-3   # 10 mH
capacitance = 1e-6   # 1 uF

# ── Four low-pass RLC filters ──

circuit = Circuit("Four Double-Pole Low-Pass RLC Filter")

circuit.SinusoidalVoltageSource("input", "in", circuit.gnd,
                                 dc_offset=0.0, offset=0.0,
                                 amplitude=1.0, frequency=1000.0)

# Q = 0.5 (R=200)
circuit.R("1", "in", "n1", 200.0)
circuit.L("1", "n1", "out5", inductance)
circuit.C("1", "out5", circuit.gnd, capacitance)

# Q = 1 (R=100)
circuit.R("2", "in", "n2", 100.0)
circuit.L("2", "n2", "out1", inductance)
circuit.C("2", "out1", circuit.gnd, capacitance)

# Q = 2 (R=50)
circuit.R("3", "in", "n3", 50.0)
circuit.L("3", "n3", "out2", inductance)
circuit.C("3", "out2", circuit.gnd, capacitance)

# Q = 4 (R=25)
circuit.R("4", "in", "n4", 25.0)
circuit.L("4", "n4", "out4", inductance)
circuit.C("4", "out4", circuit.gnd, capacitance)

resonant_frequency = 1 / (2 * math.pi * math.sqrt(inductance * capacitance))

print("--- Netlist ---")
print(circuit)
print(f"\nResonant frequency: {resonant_frequency:.1f} Hz")

# ── Pass-band RLC filter ──

circuit2 = Circuit("Pass-Band RLC Filter")
circuit2.SinusoidalVoltageSource("input", "in", circuit2.gnd,
                                  dc_offset=0.0, offset=0.0,
                                  amplitude=1.0, frequency=1000.0)
circuit2.L("1", "in", "n2", inductance)
circuit2.C("1", "n2", "out", capacitance)
circuit2.R("1", "out", circuit2.gnd, 25.0)

print("\n--- Pass-Band RLC Filter ---")
print(circuit2)
