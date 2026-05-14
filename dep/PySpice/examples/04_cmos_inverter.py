"""
CMOS Inverter — DC sweep to generate VTC (Voltage Transfer Characteristic).

    Vdd (1.8V)
      |
    M2 (PMOS)  S=Vdd, G=Vin, D=Vout
      |
      +--- Vout
      |
    M1 (NMOS)  D=Vout, G=Vin, S=GND
      |
     GND
"""
from pyspice_rs import Circuit
from pyspice_rs.unit import u_V

circuit = Circuit("CMOS Inverter")

# Supply
circuit.V("dd", "vdd", circuit.gnd, 1.8 @ u_V)

# Input
circuit.V("in", "vin", circuit.gnd, 0.9 @ u_V)

# NMOS: drain=out, gate=vin, source=gnd, bulk=gnd
circuit.MOSFET("1", "vout", "vin", circuit.gnd, circuit.gnd, model="nmos_1v8")

# PMOS: drain=out, gate=vin, source=vdd, bulk=vdd
circuit.MOSFET("2", "vout", "vin", "vdd", "vdd", model="pmos_1v8")

# Models
circuit.model("nmos_1v8", "NMOS", LEVEL=1, VTO=0.4, KP=200e-6)
circuit.model("pmos_1v8", "PMOS", LEVEL=1, VTO=-0.4, KP=100e-6)

# Load cap
circuit.C("load", "vout", circuit.gnd, 1e-12)

print("--- Netlist ---")
print(circuit)

sim = circuit.simulator()
print("\n--- DC sweep setup: Vin from 0 to 1.8V ---")
print(repr(sim))
