"""
Common-Emitter BJT Amplifier with voltage divider bias.

    Vcc (12V)
      |
     [Rc] 4.7k
      |
      +--- Vout
      |
    Q1 (2N2222A)  C
      |           |
      +--- Vb    B---[Rb2 10k]--- GND
      |
     [Re] 1k
      |
     GND

    Vcc---[Rb1 47k]---Vb
                       |
                      [Rb2 10k]---GND
"""
from pyspice_rs import Circuit
from pyspice_rs.unit import u_V, u_kOhm, u_uF

circuit = Circuit("CE BJT Amplifier")

# Supply
circuit.V("cc", "vcc", circuit.gnd, 12 @ u_V)

# Bias network
circuit.R("b1", "vcc", "base", 47e3)
circuit.R("b2", "base", circuit.gnd, 10e3)

# Transistor
circuit.BJT("1", "collector", "base", "emitter", model="2n2222a")
circuit.model("2n2222a", "NPN", BF=200, IS=1e-14)

# Collector & emitter resistors
circuit.R("c", "vcc", "collector", 4.7e3)
circuit.R("e", "emitter", circuit.gnd, 1e3)

# Coupling caps
circuit.C("in", "input", "base", 10 @ u_uF)
circuit.C("out", "collector", "output", 10 @ u_uF)

# Input signal
circuit.SinusoidalVoltageSource("in", "input", circuit.gnd,
                                 dc_offset=0.0, offset=0.0,
                                 amplitude=0.01, frequency=1000.0)

print("--- Netlist ---")
print(circuit)
