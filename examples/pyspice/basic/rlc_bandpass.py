#!/usr/bin/env python3
"""Series RLC band-pass filter. Resonance at f0 = 1/(2*pi*sqrt(L*C))."""
from pyspice_rs import Circuit

circuit = Circuit('RLC Band-Pass Filter')

circuit.V(name='in', positive='vin', negative=circuit.gnd, value=1)
circuit.R(name='1', positive='vin', negative='n1', value=50)
circuit.L(name='1', positive='n1', negative='n2', value=1e-3)       # 1 mH
circuit.C(name='1', positive='n2', negative='vout', value=10e-9)    # 10 nF -> f0 ~ 50 kHz
circuit.R(name='load', positive='vout', negative=circuit.gnd, value=1e3)

print(circuit)

simulator = circuit.simulator()
analysis = simulator.ac(variation='dec', number_of_points=50,
                        start_frequency=1e3, stop_frequency=1e6)
