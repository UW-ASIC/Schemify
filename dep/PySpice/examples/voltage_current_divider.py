"""
Voltage and Current Divider — ported from upstream PySpice examples.

Demonstrates fundamental circuit laws:
  Voltage divider: V_out/V_in = R2/(R1+R2)
  Current divider: I_out/I_in = R1/(R1+R2)

Original: PySpice-org/PySpice/examples/fundamental-laws/voltage-current-divider.py
"""
from pyspice_rs import Circuit
from pyspice_rs.unit import u_V, u_kOhm, u_A

# ── Voltage Divider ──

circuit = Circuit("Voltage Divider")
circuit.V("input", "in", circuit.gnd, 10 @ u_V)
circuit.R("1", "in", "out", 2 @ u_kOhm)
circuit.R("2", "out", circuit.gnd, 1 @ u_kOhm)

print("--- Voltage Divider ---")
print(circuit)
print("Expected Vout = 10 * 1k/(2k+1k) = 3.33V")

sim = circuit.simulator()
print(repr(sim))

# ── Current Divider ──

circuit2 = Circuit("Current Divider")
circuit2.I("input", circuit2.gnd, "in", 1 @ u_A)
circuit2.R("1", "in", circuit2.gnd, 2 @ u_kOhm)
circuit2.R("2", "in", circuit2.gnd, 1 @ u_kOhm)

print("\n--- Current Divider ---")
print(circuit2)
print("Expected I_R2 = 1A * 2k/(2k+1k) = 0.667A")
