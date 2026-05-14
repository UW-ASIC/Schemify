"""
Inverting Op-Amp using behavioral voltage source (ideal op-amp).

              Rf (10k)
    Vin ---[Rin 1k]---+---[Rf 10k]---+
                       |               |
                      (-) OpAmp      Vout
                       |
                      (+)---GND

Gain = -Rf/Rin = -10
"""
from pyspice_rs import Circuit
from pyspice_rs.unit import u_V, u_kOhm

circuit = Circuit("Inverting Op-Amp")

# Input
circuit.V("in", "vin", circuit.gnd, 0.1 @ u_V)

# Input resistor
circuit.R("in", "vin", "vm", 1 @ u_kOhm)

# Feedback resistor
circuit.R("f", "vm", "vout", 10 @ u_kOhm)

# Ideal op-amp: Vout = A * (Vp - Vm), with A very large
# Using behavioral source for ideal op-amp
circuit.BV("1", "vout", circuit.gnd, "1e6*(V(vp)-V(vm))")

# Non-inverting input to ground
circuit.R("gnd", "vp", circuit.gnd, 1 @ u_kOhm)

print("--- Netlist ---")
print(circuit)
print("\nExpected gain: -10 (Vout ~ -1V for Vin = 0.1V)")
