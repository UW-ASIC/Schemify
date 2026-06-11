#!/usr/bin/env python3
"""4:1 analog multiplexer with bus inputs: in[3:0], sel[1:0].

Uses CMOS transmission gates as switches.
Demonstrates bus on inputs and select lines.
"""
from pyspice_rs import Circuit

circuit = Circuit('4:1 Analog Mux')

circuit.model('nmos_1v8', 'nmos', level=1, kp=120e-6, vto=0.5)
circuit.model('pmos_1v8', 'pmos', level=1, kp=60e-6, vto=-0.5)

circuit.V(name='dd', positive='vdd', negative=circuit.gnd, value=1.8)

# 4 analog inputs: in[3:0]
circuit.V(name='in[0]', positive='in[0]', negative=circuit.gnd, value=0.3)
circuit.V(name='in[1]', positive='in[1]', negative=circuit.gnd, value=0.6)
circuit.V(name='in[2]', positive='in[2]', negative=circuit.gnd, value=0.9)
circuit.V(name='in[3]', positive='in[3]', negative=circuit.gnd, value=1.2)

# Select lines: sel[1:0] — selecting input 2 (sel = 10)
circuit.V(name='sel[0]', positive='sel[0]', negative=circuit.gnd, value=0)
circuit.V(name='sel[1]', positive='sel[1]', negative=circuit.gnd, value=1.8)

# Inverters for sel
circuit.M(name='p_s0b', drain='sel_b[0]', gate='sel[0]', source='vdd', bulk='vdd', model='pmos_1v8', W='2u', L='180n')
circuit.M(name='n_s0b', drain='sel_b[0]', gate='sel[0]', source='0', bulk='0', model='nmos_1v8', W='1u', L='180n')
circuit.M(name='p_s1b', drain='sel_b[1]', gate='sel[1]', source='vdd', bulk='vdd', model='pmos_1v8', W='2u', L='180n')
circuit.M(name='n_s1b', drain='sel_b[1]', gate='sel[1]', source='0', bulk='0', model='nmos_1v8', W='1u', L='180n')

# Transmission gates for each input
# TG0: en when sel[1:0] = 00
circuit.M(name='n_tg0', drain='in[0]', gate='sel_b[1]', source='vout', bulk='0', model='nmos_1v8', W='2u', L='180n')
circuit.M(name='p_tg0', drain='in[0]', gate='sel[1]', source='vout', bulk='vdd', model='pmos_1v8', W='4u', L='180n')

# TG1: en when sel[1:0] = 01
circuit.M(name='n_tg1', drain='in[1]', gate='sel[0]', source='vout', bulk='0', model='nmos_1v8', W='2u', L='180n')
circuit.M(name='p_tg1', drain='in[1]', gate='sel_b[0]', source='vout', bulk='vdd', model='pmos_1v8', W='4u', L='180n')

# TG2: en when sel[1:0] = 10 (this one is active)
circuit.M(name='n_tg2', drain='in[2]', gate='sel[1]', source='vout', bulk='0', model='nmos_1v8', W='2u', L='180n')
circuit.M(name='p_tg2', drain='in[2]', gate='sel_b[1]', source='vout', bulk='vdd', model='pmos_1v8', W='4u', L='180n')

# TG3: en when sel[1:0] = 11
circuit.M(name='n_tg3', drain='in[3]', gate='sel[1]', source='vout', bulk='0', model='nmos_1v8', W='2u', L='180n')
circuit.M(name='p_tg3', drain='in[3]', gate='sel_b[1]', source='vout', bulk='vdd', model='pmos_1v8', W='4u', L='180n')

# Output load
circuit.C(name='out', positive='vout', negative=circuit.gnd, value=100e-15)

print(circuit)
