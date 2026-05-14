"""
Series RLC Bandpass Filter — demonstrates inductor and resonance.

    Vin ---[R 50]---[L 1mH]---+--- Vout
                                |
                               [C 10nF]
                                |
                               GND

Resonant frequency: f0 = 1/(2*pi*sqrt(LC)) ~ 50.3 kHz
Q factor: Q = (1/R)*sqrt(L/C) ~ 6.32
"""
from pyspice_rs import Circuit
from pyspice_rs.unit import u_V, u_Ohm, u_mH, u_nF

circuit = Circuit("RLC Bandpass Filter")

circuit.V("in", "input", circuit.gnd, 1 @ u_V)
circuit.R("1", "input", "node1", 50 @ u_Ohm)
circuit.L("1", "node1", "output", 1 @ u_mH)
circuit.C("1", "output", circuit.gnd, 10 @ u_nF)

print("--- Netlist ---")
print(circuit)
print("\nResonant frequency: ~50.3 kHz")
print("Q factor: ~6.32")
