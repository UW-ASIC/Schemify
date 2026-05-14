"""
NMOS Transistor Characteristic — ported from upstream PySpice examples.

Plots Id vs Vgs for an NMOS transistor.
Uses PTM 65nm-like model parameters.

Original: PySpice-org/PySpice/examples/transistor/nmos-transistor.py
"""
from pyspice_rs import Circuit
from pyspice_rs.unit import u_V

circuit = Circuit("NMOS Transistor")

Vdd = 1.1

circuit.V("gate", "gatenode", circuit.gnd, 0 @ u_V)
circuit.V("drain", "vdd", circuit.gnd, Vdd)
circuit.MOSFET("1", "vdd", "gatenode", circuit.gnd, circuit.gnd, model="nmos_65nm")

# Simple Level 1 model approximating 65nm
circuit.model("nmos_65nm", "NMOS", LEVEL=1, VTO=0.3, KP=400e-6)

print("--- Netlist ---")
print(circuit)

# DC sweep: Vgate from 0 to 1.1V
sim = circuit.simulator()
print("\n--- DC Sweep: Vgate = 0 to 1.1V ---")
print(repr(sim))
