#!/usr/bin/env python3
"""CMOS SR latch from cross-coupled NOR gates."""
from pyspice_rs import Circuit

circuit = Circuit('SR Latch')

circuit.model('nmos_1v8', 'nmos', level=1, kp=120e-6, vto=0.5)
circuit.model('pmos_1v8', 'pmos', level=1, kp=60e-6, vto=-0.5)

circuit.V(name='dd', positive='vdd', negative=circuit.gnd, value=1.8)

# S input (pulse to set)
circuit.PulseVoltageSource(name='s', positive='vs', negative=circuit.gnd,
                           initial_value=0, pulsed_value=1.8,
                           rise_time=100e-12, fall_time=100e-12,
                           pulse_width=1e-9, period=10e-9)

# R input (pulse to reset, delayed)
circuit.PulseVoltageSource(name='r', positive='vr', negative=circuit.gnd,
                           initial_value=0, pulsed_value=1.8,
                           rise_time=100e-12, fall_time=100e-12,
                           pulse_width=1e-9, period=10e-9)

# NOR gate 1 (inputs: S, Qbar -> output: Q)
circuit.M(name='p1a', drain='mid1', gate='vs', source='vdd', bulk='vdd', model='pmos_1v8', W='4u', L='180n')
circuit.M(name='p1b', drain='q', gate='qbar', source='mid1', bulk='vdd', model='pmos_1v8', W='4u', L='180n')
circuit.M(name='n1a', drain='q', gate='vs', source='0', bulk='0', model='nmos_1v8', W='1u', L='180n')
circuit.M(name='n1b', drain='q', gate='qbar', source='0', bulk='0', model='nmos_1v8', W='1u', L='180n')

# NOR gate 2 (inputs: R, Q -> output: Qbar)
circuit.M(name='p2a', drain='mid2', gate='vr', source='vdd', bulk='vdd', model='pmos_1v8', W='4u', L='180n')
circuit.M(name='p2b', drain='qbar', gate='q', source='mid2', bulk='vdd', model='pmos_1v8', W='4u', L='180n')
circuit.M(name='n2a', drain='qbar', gate='vr', source='0', bulk='0', model='nmos_1v8', W='1u', L='180n')
circuit.M(name='n2b', drain='qbar', gate='q', source='0', bulk='0', model='nmos_1v8', W='1u', L='180n')

print(circuit)

simulator = circuit.simulator()
analysis = simulator.transient(step_time=10e-12, end_time=20e-9)
