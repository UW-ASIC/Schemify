"""
Full-Wave Bridge Rectifier with filter cap.

    Vin (AC) ---+---D1-->--+---+--- Vout
                |           |   |
                |          [C] [Rload]
                |           |   |
                +---D2--<--+---+--- GND

Uses 4 diodes in bridge configuration.
"""
from pyspice_rs import Circuit
from pyspice_rs.unit import u_V, u_kOhm, u_uF

circuit = Circuit("Bridge Rectifier")

# AC input
circuit.SinusoidalVoltageSource("in", "ac_p", "ac_m",
                                 dc_offset=0.0, offset=0.0,
                                 amplitude=12.0, frequency=60.0)

# Diode model
circuit.model("1N4148", "D", IS=2.52e-9, RS=0.568, N=1.752)

# Bridge diodes
circuit.D("1", "ac_p", "out_p", model="1N4148")
circuit.D("2", "out_m", "ac_p", model="1N4148")
circuit.D("3", "ac_m", "out_p", model="1N4148")
circuit.D("4", "out_m", "ac_m", model="1N4148")

# Filter and load
circuit.C("1", "out_p", "out_m", 100 @ u_uF)
circuit.R("load", "out_p", "out_m", 1 @ u_kOhm)

# Ground reference
circuit.V("ref", "out_m", circuit.gnd, 0.0)

print("--- Netlist ---")
print(circuit)
