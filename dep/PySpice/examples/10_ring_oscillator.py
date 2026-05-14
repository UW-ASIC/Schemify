"""
3-Stage CMOS Ring Oscillator — transient analysis.

Each stage is a CMOS inverter feeding the next.
Stage 3 output feeds back to Stage 1 input.

    +--[INV1]--[INV2]--[INV3]--+
    |                           |
    +---------------------------+

Oscillation frequency depends on gate delay.
"""
from pyspice_rs import Circuit
from pyspice_rs.unit import u_V

circuit = Circuit("Ring Oscillator")

# Supply
circuit.V("dd", "vdd", circuit.gnd, 1.8 @ u_V)

# Models
circuit.model("nmos_1v8", "NMOS", LEVEL=1, VTO=0.4, KP=200e-6)
circuit.model("pmos_1v8", "PMOS", LEVEL=1, VTO=-0.4, KP=100e-6)

# Stage 1
circuit.MOSFET("1n", "n1", "n3", circuit.gnd, circuit.gnd, model="nmos_1v8")
circuit.MOSFET("1p", "n1", "n3", "vdd", "vdd", model="pmos_1v8")

# Stage 2
circuit.MOSFET("2n", "n2", "n1", circuit.gnd, circuit.gnd, model="nmos_1v8")
circuit.MOSFET("2p", "n2", "n1", "vdd", "vdd", model="pmos_1v8")

# Stage 3
circuit.MOSFET("3n", "n3", "n2", circuit.gnd, circuit.gnd, model="nmos_1v8")
circuit.MOSFET("3p", "n3", "n2", "vdd", "vdd", model="pmos_1v8")

# Load caps (model gate capacitance)
circuit.C("1", "n1", circuit.gnd, 10e-15)
circuit.C("2", "n2", circuit.gnd, 10e-15)
circuit.C("3", "n3", circuit.gnd, 10e-15)

print("--- Netlist ---")
print(circuit)

sim = circuit.simulator()
print("\n--- Transient: 0 to 10ns ---")
print(repr(sim))
