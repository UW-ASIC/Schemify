#!/usr/bin/env python3
"""Wheatstone bridge — balanced when R1/R2 = R3/R4."""
from pyspice_rs import Circuit

circuit = Circuit('Wheatstone Bridge')

circuit.V(name='in', positive='vin', negative=circuit.gnd, value=10)

# Left arm
circuit.R(name='1', positive='vin', negative='va', value=1e3)
circuit.R(name='2', positive='va', negative=circuit.gnd, value=2e3)

# Right arm
circuit.R(name='3', positive='vin', negative='vb', value=1e3)
circuit.R(name='4', positive='vb', negative=circuit.gnd, value=2.2e3)  # Slight imbalance

# Bridge galvanometer
circuit.R(name='g', positive='va', negative='vb', value=10e3)

print(circuit)

simulator = circuit.simulator()
analysis = simulator.operating_point()
