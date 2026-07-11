#!/usr/bin/env python3
"""Testbench: Charge pump — voltage buildup waveforms.

Shows step-by-step voltage multiplication and ripple at each stage.
"""
import json
from pyspice_rs import Circuit

circuit = Circuit('TB Charge Pump Waveforms')

circuit.model('nmos_1v8', 'nmos', level=1, kp=120e-6, vto=0.5)

circuit.V(name='dd', positive='vdd', negative=circuit.gnd, value=1.8)

# Non-overlapping clocks at 100 MHz
circuit.PulseVoltageSource(name='clk1', positive='phi1', negative=circuit.gnd,
                           initial_value=0, pulsed_value=1.8,
                           rise_time=100e-12, fall_time=100e-12,
                           pulse_width=4e-9, period=10e-9)
circuit.PulseVoltageSource(name='clk2', positive='phi2', negative=circuit.gnd,
                           initial_value=0, pulsed_value=1.8,
                           rise_time=100e-12, fall_time=100e-12,
                           pulse_width=4e-9, period=10e-9)

# 3-stage Dickson with diode-connected NMOS
circuit.M(name='d1', drain='n1', gate='n1', source='vdd', bulk='vdd', model='nmos_1v8', W='5u', L='180n')
circuit.C(name='p1', positive='n1', negative='phi1', value=5e-12)

circuit.M(name='d2', drain='n2', gate='n2', source='n1', bulk='n1', model='nmos_1v8', W='5u', L='180n')
circuit.C(name='p2', positive='n2', negative='phi2', value=5e-12)

circuit.M(name='d3', drain='n3', gate='n3', source='n2', bulk='n2', model='nmos_1v8', W='5u', L='180n')
circuit.C(name='p3', positive='n3', negative='phi1', value=5e-12)

circuit.M(name='d4', drain='vout', gate='vout', source='n3', bulk='n3', model='nmos_1v8', W='5u', L='180n')
circuit.C(name='out', positive='vout', negative=circuit.gnd, value=20e-12)

# Load
circuit.R(name='load', positive='vout', negative=circuit.gnd, value=500e3)

print(circuit)
