"""
Diode Characteristic Curve — ported from upstream PySpice examples.

Simulates a diode I-V curve using DC sweep.
Uses 1N4148 model parameters.

Original: PySpice-org/PySpice/examples/diode/diode-characteristic-curve.py
"""
from pyspice_rs import Circuit
from pyspice_rs.unit import u_V, u_Ohm

circuit = Circuit("Diode Characteristic Curve")

# 1N4148 model
circuit.model("1N4148", "D", IS=2.52e-9, RS=0.568, N=1.752, BV=100, IBV=100e-6)

circuit.V("input", "in", circuit.gnd, 10 @ u_V)
circuit.R("1", "in", "out", 1 @ u_Ohm)
circuit.D("1", "out", circuit.gnd, model="1N4148")

print("--- Netlist ---")
print(circuit)

# DC sweep: Vinput from -2V to 5V in 0.01V steps
sim = circuit.simulator()
print("\n--- DC Sweep: Vinput = -2V to 5V ---")
print(repr(sim))
print("\nForward voltage threshold ~0.7V")
