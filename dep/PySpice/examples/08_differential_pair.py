"""
MOSFET Differential Pair — fundamental analog building block.

        Vdd (3.3V)
       /         \
    [Rd1]       [Rd2]  (5k each)
      |           |
    Vout-       Vout+
      |           |
    M1 (D)     M2 (D)
      |           |
    M1 (G)     M2 (G)
   Vin-        Vin+
      |           |
    M1 (S)     M2 (S)
       \         /
        +---+---+
            |
          [Iss] 200uA (current source)
            |
           GND
"""
from pyspice_rs import Circuit
from pyspice_rs.unit import u_V, u_kOhm, u_uA

circuit = Circuit("Differential Pair")

# Supply
circuit.V("dd", "vdd", circuit.gnd, 3.3 @ u_V)

# Load resistors
circuit.R("d1", "vdd", "vout_m", 5 @ u_kOhm)
circuit.R("d2", "vdd", "vout_p", 5 @ u_kOhm)

# Diff pair MOSFETs
circuit.MOSFET("1", "vout_m", "vin_m", "tail", "gnd", model="nmos_3p3")
circuit.MOSFET("2", "vout_p", "vin_p", "tail", "gnd", model="nmos_3p3")

# Tail current source
circuit.I("ss", circuit.gnd, "tail", 200 @ u_uA)

# MOSFET model
circuit.model("nmos_3p3", "NMOS", LEVEL=1, VTO=0.7, KP=110e-6)

# Bias inputs
circuit.V("cm", "vcm", circuit.gnd, 1.65)
circuit.V("dm", "vin_p", "vcm", 0.005)
circuit.R("bias", "vcm", "vin_m", 0.001)

print("--- Netlist ---")
print(circuit)
