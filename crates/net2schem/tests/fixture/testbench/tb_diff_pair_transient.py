#!/usr/bin/env python3
"""Testbench: Differential pair — transient waveforms.

Applies a differential sine input and captures:
- Input waveforms (Vinp, Vinn)
- Output waveforms (Voutp, Voutn)
- Differential output (Voutp - Voutn)
"""
import json
from pyspice_rs import Circuit

circuit = Circuit('TB Diff Pair Transient')

circuit.model('nmos_1v8', 'nmos', level=1, kp=120e-6, vto=0.5)

circuit.V(name='dd', positive='vdd', negative=circuit.gnd, value=1.8)

# Load resistors
circuit.R(name='d1', positive='vdd', negative='outp', value=10e3)
circuit.R(name='d2', positive='vdd', negative='outn', value=10e3)

# Diff pair
circuit.M(name='1', drain='outp', gate='inp', source='tail', bulk='0', model='nmos_1v8', W='10u', L='180n')
circuit.M(name='2', drain='outn', gate='inn', source='tail', bulk='0', model='nmos_1v8', W='10u', L='180n')

# Tail current
circuit.I(name='tail', positive=circuit.gnd, negative='tail', value=100e-6)

# Differential sine input: 10 mVpp at 1 MHz around 0.9V CM
circuit.SinusoidalVoltageSource(name='inp', positive='inp', negative=circuit.gnd,
                                 dc_offset=0.9, offset=0.9,
                                 amplitude=5e-3, frequency=1e6)
circuit.SinusoidalVoltageSource(name='inn', positive='inn', negative=circuit.gnd,
                                 dc_offset=0.9, offset=0.9,
                                 amplitude=-5e-3, frequency=1e6)

print(circuit)
