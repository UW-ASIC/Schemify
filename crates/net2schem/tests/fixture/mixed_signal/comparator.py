#!/usr/bin/env python3
"""CMOS comparator with hysteresis (Schmitt trigger behavior)."""
from pyspice_rs import Circuit

circuit = Circuit('CMOS Comparator')

circuit.model('nmos_1v8', 'nmos', level=1, kp=120e-6, vto=0.5)
circuit.model('pmos_1v8', 'pmos', level=1, kp=60e-6, vto=-0.5)

circuit.V(name='dd', positive='vdd', negative=circuit.gnd, value=1.8)

# Ramp input
circuit.PulseVoltageSource(name='in', positive='vin', negative=circuit.gnd,
                           initial_value=0, pulsed_value=1.8,
                           rise_time=10e-6, fall_time=10e-6,
                           pulse_width=1e-9, period=20e-6)

# Reference
circuit.V(name='ref', positive='vref', negative=circuit.gnd, value=0.9)

# Diff pair
circuit.M(name='1', drain='n1', gate='vin', source='tail', bulk='0', model='nmos_1v8', W='5u', L='180n')
circuit.M(name='2', drain='n2', gate='vref', source='tail', bulk='0', model='nmos_1v8', W='5u', L='180n')

# Active load
circuit.M(name='3', drain='n1', gate='n1', source='vdd', bulk='vdd', model='pmos_1v8', W='2u', L='180n')
circuit.M(name='4', drain='n2', gate='n1', source='vdd', bulk='vdd', model='pmos_1v8', W='2u', L='180n')

# Tail current
circuit.I(name='tail', positive=circuit.gnd, negative='tail', value=50e-6)

# Output inverter for rail-to-rail swing
circuit.M(name='p5', drain='vout', gate='n2', source='vdd', bulk='vdd', model='pmos_1v8', W='4u', L='180n')
circuit.M(name='n5', drain='vout', gate='n2', source='0', bulk='0', model='nmos_1v8', W='2u', L='180n')

# Positive feedback for hysteresis
circuit.M(name='hyst', drain='tail', gate='vout', source='hyst_src', bulk='0', model='nmos_1v8', W='500n', L='500n')
circuit.I(name='hyst', positive=circuit.gnd, negative='hyst_src', value=5e-6)

print(circuit)
