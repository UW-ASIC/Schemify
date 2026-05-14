"""
MOSFET Current Mirror — demonstrates matched transistors.

    Vdd (3.3V)
      |         |
    M1 (D)    M2 (D)
      |         |
      +---+     +--- Iout
      |   |
    M1 (G)+---M2 (G)
      |
    M1 (S)    M2 (S)
      |         |
     GND       GND

    Iref ---[Rref]--- M1(D)

Iout should mirror Iref (assuming matched W/L).
"""
from pyspice_rs import Circuit
from pyspice_rs.unit import u_V, u_kOhm, u_uA

circuit = Circuit("Current Mirror")

# Supply
circuit.V("dd", "vdd", circuit.gnd, 3.3 @ u_V)

# Reference current (via resistor)
circuit.R("ref", "vdd", "drain1", 16.5 @ u_kOhm)  # ~200uA at Vgs~0.7V

# Mirror transistors
circuit.MOSFET("1", "drain1", "drain1", circuit.gnd, circuit.gnd, model="nmos_3p3")
circuit.MOSFET("2", "drain2", "drain1", circuit.gnd, circuit.gnd, model="nmos_3p3")

# Load on mirror output
circuit.R("load", "vdd", "drain2", 10 @ u_kOhm)

# Model
circuit.model("nmos_3p3", "NMOS", LEVEL=1, VTO=0.7, KP=110e-6)

print("--- Netlist ---")
print(circuit)
