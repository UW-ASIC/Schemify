#!/usr/bin/env python3
"""First-order RL high-pass filter."""
from pyspice_rs import Circuit

circuit = Circuit('RL High-Pass Filter')

circuit.V(name='in', positive='vin', negative=circuit.gnd, value=1)
circuit.L(name='1', positive='vin', negative='vout', value=10e-3)  # 10 mH
circuit.R(name='1', positive='vout', negative=circuit.gnd, value=1e3)

print(circuit)

simulator = circuit.simulator()
analysis = simulator.ac(variation='dec', number_of_points=20,
                        start_frequency=1, stop_frequency=1e6)
