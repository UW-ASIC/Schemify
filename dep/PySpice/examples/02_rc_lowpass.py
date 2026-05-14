"""
RC Low-Pass Filter — demonstrates AC analysis setup.

    Vin ---[R1 1k]---+--- Vout
                      |
                     [C1 10nF]
                      |
                     GND

Cutoff frequency: fc = 1/(2*pi*R*C) = 1/(2*pi*1e3*10e-9) ~ 15.9 kHz
"""
from pyspice_rs import Circuit
from pyspice_rs.unit import u_V, u_kOhm, u_nF, u_kHz

circuit = Circuit("RC Low-Pass Filter")

circuit.V("in", "input", circuit.gnd, 1.0 @ u_V)
circuit.R("1", "input", "output", 1 @ u_kOhm)
circuit.C("1", "output", circuit.gnd, 10 @ u_nF)

print("--- Netlist ---")
print(circuit)

sim = circuit.simulator()
print("\n--- Simulator created ---")
print(repr(sim))
print("\nCutoff frequency: ~15.9 kHz")
