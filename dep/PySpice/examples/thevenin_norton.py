"""
Thevenin and Norton Theorem — ported from upstream PySpice examples.

Thévenin: voltage source + series resistance
Norton: current source + parallel resistance

Both should produce identical load voltage.

Original: PySpice-org/PySpice/examples/fundamental-laws/thevenin-norton-theorem.py
"""
from pyspice_rs import Circuit
from pyspice_rs.unit import u_V, u_Ohm, u_kOhm

# ── Thévenin Representation ──

thevenin = Circuit("Thevenin Representation")
thevenin.V("input", "node1", thevenin.gnd, 10 @ u_V)
thevenin.R("generator", "node1", "load", 10 @ u_Ohm)
thevenin.R("load", "load", thevenin.gnd, 1 @ u_kOhm)

print("--- Thévenin Circuit ---")
print(thevenin)

sim = thevenin.simulator()
print(repr(sim))

# ── Norton Representation ──
# Ino = Vth/Rth = 10/10 = 1A
# Rno = Rth = 10 Ohm

norton = Circuit("Norton Representation")
norton.I("input", norton.gnd, "load", 1.0)  # 1A
norton.R("generator", "load", norton.gnd, 10 @ u_Ohm)
norton.R("load", "load", norton.gnd, 1 @ u_kOhm)

print("\n--- Norton Circuit ---")
print(norton)

# Both should give: V_load = 10 * 1000/(10+1000) = 9.901V
print("\nExpected load voltage (both): 9.901V")
