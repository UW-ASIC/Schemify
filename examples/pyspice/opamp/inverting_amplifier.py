#!/usr/bin/env python3
"""Inverting op-amp amplifier. Gain = -Rf/Rin = -10."""
from pyspice_rs import Circuit

circuit = Circuit('Inverting Amplifier')

circuit.V(name='cc', positive='vcc', negative=circuit.gnd, value=15)
circuit.V(name='ee', positive='vee', negative=circuit.gnd, value=-15)
circuit.V(name='in', positive='vin', negative=circuit.gnd, value=0.1)

circuit.R(name='in', positive='vin', negative='vminus', value=1e3)
circuit.R(name='f', positive='vminus', negative='vout', value=10e3)

# Non-inverting input to ground
circuit.R(name='gnd', positive=circuit.gnd, negative='vplus', value=1e3)

# Op-amp (behavioral VCVS: E element)
circuit.E(name='amp', positive='vout', negative=circuit.gnd,
          control_positive='vplus', control_negative='vminus', voltage_gain=1e6)

print(circuit)

simulator = circuit.simulator()
analysis = simulator.dc(Vin=slice(-1, 1, 0.01))
