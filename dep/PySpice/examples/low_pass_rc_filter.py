"""
Low-Pass RC Filter — ported from upstream PySpice examples.

AC analysis to generate Bode diagram.
Break frequency: fc = 1/(2*pi*R*C)

Original: PySpice-org/PySpice/examples/filter/low-pass-rc-filter.py
"""
import math
from pyspice_rs import Circuit
from pyspice_rs.unit import u_V, u_kOhm, u_uF, u_Hz, u_MHz

circuit = Circuit("Low-Pass RC Filter")

circuit.SinusoidalVoltageSource("input", "in", circuit.gnd,
                                 dc_offset=0.0, offset=0.0,
                                 amplitude=1.0, frequency=1000.0)
circuit.R("1", "in", "out", 1e3)
circuit.C("1", "out", circuit.gnd, 1e-6)

# Break frequency
R = 1e3
C = 1e-6
break_frequency = 1 / (2 * math.pi * R * C)

print("--- Netlist ---")
print(circuit)
print(f"\nBreak frequency: {break_frequency:.1f} Hz")

# AC analysis from 1 Hz to 1 MHz
sim = circuit.simulator()
print("\n--- AC analysis: 1Hz to 1MHz ---")
print(repr(sim))
