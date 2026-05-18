#!/usr/bin/env python3
"""Common-source amplifier with PMOS active load for higher gain."""
from pyspice_rs import Circuit

circuit = Circuit('CS Active Load')

circuit.model('nmos_1v8', 'nmos', level=1, kp=120e-6, vto=0.5)
circuit.model('pmos_1v8', 'pmos', level=1, kp=60e-6, vto=-0.5)

circuit.V(name='dd', positive='vdd', negative=circuit.gnd, value=1.8)
circuit.V(name='in', positive='vin', negative=circuit.gnd, value=0.7)
circuit.V(name='bias', positive='vbias', negative=circuit.gnd, value=1.0)

# NMOS input transistor
circuit.M(name='1', drain='vout', gate='vin', source='0', bulk='0', model='nmos_1v8', W='5u', L='500n')

# PMOS active load (biased)
circuit.M(name='2', drain='vout', gate='vbias', source='vdd', bulk='vdd', model='pmos_1v8', W='10u', L='500n')

print(circuit)

simulator = circuit.simulator()
analysis = simulator.dc(Vin=slice(0, 1.8, 0.005))
