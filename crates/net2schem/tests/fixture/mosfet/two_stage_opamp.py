#!/usr/bin/env python3
"""Two-stage Miller-compensated CMOS op-amp."""
from pyspice_rs import Circuit

circuit = Circuit('Two-Stage Op-Amp')

circuit.model('nmos_1v8', 'nmos', level=1, kp=120e-6, vto=0.5)
circuit.model('pmos_1v8', 'pmos', level=1, kp=60e-6, vto=-0.5)

circuit.V(name='dd', positive='vdd', negative=circuit.gnd, value=1.8)
circuit.V(name='inp', positive='inp', negative=circuit.gnd, value=0.9)
circuit.V(name='inn', positive='inn', negative=circuit.gnd, value=0.9)

# First stage: diff pair with active load
circuit.M(name='1', drain='n1', gate='inp', source='tail', bulk='0', model='nmos_1v8', W='10u', L='500n')
circuit.M(name='2', drain='n2', gate='inn', source='tail', bulk='0', model='nmos_1v8', W='10u', L='500n')

# PMOS active load (first stage)
circuit.M(name='3', drain='n1', gate='n1', source='vdd', bulk='vdd', model='pmos_1v8', W='5u', L='500n')
circuit.M(name='4', drain='n2', gate='n1', source='vdd', bulk='vdd', model='pmos_1v8', W='5u', L='500n')

# Tail current source
circuit.I(name='tail', positive=circuit.gnd, negative='tail', value=100e-6)

# Second stage: common-source with current source load
circuit.M(name='5', drain='vout', gate='n2', source='0', bulk='0', model='nmos_1v8', W='40u', L='180n')
circuit.I(name='load', positive='vdd', negative='vout', value=500e-6)

# Miller compensation
circuit.C(name='c', positive='n2', negative='vout', value=2e-12)
circuit.R(name='z', positive='n2', negative='cc_node', value=500)  # Nulling resistor
circuit.C(name='c2', positive='cc_node', negative='vout', value=2e-12)

# Load capacitance
circuit.C(name='load', positive='vout', negative=circuit.gnd, value=5e-12)

print(circuit)
