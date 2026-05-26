#!/usr/bin/env python3
"""CMOS transmission gate — bidirectional analog switch."""
from pyspice_rs import Circuit

circuit = Circuit('Transmission Gate')

circuit.model('nmos_1v8', 'nmos', level=1, kp=120e-6, vto=0.5)
circuit.model('pmos_1v8', 'pmos', level=1, kp=60e-6, vto=-0.5)

circuit.V(name='dd', positive='vdd', negative=circuit.gnd, value=1.8)

# Control signals
circuit.V(name='ctrl', positive='ctrl', negative=circuit.gnd, value=1.8)      # Active high
circuit.V(name='ctrlb', positive='ctrlb', negative=circuit.gnd, value=0)      # Active low (complement)

# Input signal
circuit.V(name='in', positive='vin', negative=circuit.gnd, value=0.9)

# Transmission gate: NMOS + PMOS in parallel
circuit.M(name='n', drain='vin', gate='ctrl', source='vout', bulk='0', model='nmos_1v8', W='2u', L='180n')
circuit.M(name='p', drain='vin', gate='ctrlb', source='vout', bulk='vdd', model='pmos_1v8', W='4u', L='180n')

# Load
circuit.R(name='load', positive='vout', negative=circuit.gnd, value=100e3)
circuit.C(name='load', positive='vout', negative=circuit.gnd, value=100e-15)

print(circuit)

simulator = circuit.simulator()
analysis = simulator.dc(Vin=slice(0, 1.8, 0.01))
