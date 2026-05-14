"""
AC Coupled Amplifier — ported from upstream PySpice examples.

Common-emitter amplifier with AC coupling capacitors.

Original: PySpice-org/PySpice/examples/transistor/ac-coupled-amplifier.py
"""
from pyspice_rs import Circuit
from pyspice_rs.unit import u_V, u_kOhm, u_uF, u_pF, u_Ohm

circuit = Circuit("AC Coupled Amplifier")

# Power supply
circuit.V("cc", "vcc", circuit.gnd, 15 @ u_V)

# Input signal
circuit.SinusoidalVoltageSource("input", "in", circuit.gnd,
                                 dc_offset=0.0, offset=0.0,
                                 amplitude=0.5, frequency=1000.0)

# Input coupling
circuit.C("in", "in", "base", 10 @ u_uF)

# Bias network
circuit.R("1", "vcc", "base", 100 @ u_kOhm)
circuit.R("2", "base", circuit.gnd, 20 @ u_kOhm)

# NPN transistor
circuit.BJT("1", "collector", "base", "emitter", model="npn_amp")
circuit.model("npn_amp", "NPN", BF=80, CJC=5e-12, RB=100)

# Collector resistor
circuit.R("c", "vcc", "collector", 10 @ u_kOhm)

# Emitter resistor + bypass cap
circuit.R("e", "emitter", circuit.gnd, 2 @ u_kOhm)
circuit.C("e", "emitter", circuit.gnd, 10 @ u_uF)

# Output coupling
circuit.C("out", "collector", "output", 10 @ u_uF)

# Load
circuit.R("load", "output", circuit.gnd, 1e6)

print("--- Netlist ---")
print(circuit)

sim = circuit.simulator()
print("\n--- Transient analysis: 2 periods of 1kHz ---")
print(repr(sim))
