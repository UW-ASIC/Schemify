"""
Voltage Divider — simplest circuit to verify DC operating point.

    Vdd (3.3V)
      |
     [R1] 10k
      |
      +--- Vout
      |
     [R2] 10k
      |
     GND

Expected: Vout = 3.3 * R2/(R1+R2) = 1.65V
"""
from pyspice_rs import Circuit
from pyspice_rs.unit import u_V, u_kOhm

circuit = Circuit("Voltage Divider")

circuit.V("dd", "vdd", circuit.gnd, 3.3 @ u_V)
circuit.R("1", "vdd", "out", 10 @ u_kOhm)
circuit.R("2", "out", circuit.gnd, 10 @ u_kOhm)

print("--- Netlist ---")
print(circuit)

sim = circuit.simulator()
print("\n--- Simulator created ---")
print(repr(sim))
