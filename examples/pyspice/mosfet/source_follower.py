#!/usr/bin/env python3
"""NMOS source follower (common-drain) — unity gain buffer."""
from pyspice_rs import Circuit

circuit = Circuit('Source Follower')

circuit.model('nmos_1v8', 'nmos', level=1, kp=120e-6, vto=0.5)

circuit.V(name='dd', positive='vdd', negative=circuit.gnd, value=1.8)
circuit.V(name='in', positive='vin', negative=circuit.gnd, value=1.2)

# Source follower transistor
circuit.M(name='1', drain='vdd', gate='vin', source='vout', bulk='0', model='nmos_1v8', W='20u', L='180n')

# Current source bias
circuit.I(name='bias', positive='vout', negative=circuit.gnd, value=200e-6)

# Load capacitance
circuit.C(name='load', positive='vout', negative=circuit.gnd, value=1e-12)

print(circuit)

simulator = circuit.simulator()
analysis = simulator.dc(Vin=slice(0, 1.8, 0.01))
