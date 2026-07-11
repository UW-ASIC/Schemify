#!/usr/bin/env python3
"""CMOS sample-and-hold circuit using transmission gate."""
from pyspice_rs import Circuit

circuit = Circuit('Sample and Hold')

circuit.model('nmos_1v8', 'nmos', level=1, kp=120e-6, vto=0.5)
circuit.model('pmos_1v8', 'pmos', level=1, kp=60e-6, vto=-0.5)

circuit.V(name='dd', positive='vdd', negative=circuit.gnd, value=1.8)

# Analog input: slow sine wave
circuit.SinusoidalVoltageSource(name='in', positive='vin', negative=circuit.gnd,
                                 dc_offset=0.9, offset=0.9,
                                 amplitude=0.4, frequency=10e3)

# Sampling clock
circuit.PulseVoltageSource(name='clk', positive='phi', negative=circuit.gnd,
                           initial_value=0, pulsed_value=1.8,
                           rise_time=100e-12, fall_time=100e-12,
                           pulse_width=25e-9, period=100e-9)

# Complementary clock
circuit.PulseVoltageSource(name='clkb', positive='phib', negative=circuit.gnd,
                           initial_value=1.8, pulsed_value=0,
                           rise_time=100e-12, fall_time=100e-12,
                           pulse_width=25e-9, period=100e-9)

# Transmission gate switch
circuit.M(name='ns', drain='vin', gate='phi', source='vhold', bulk='0', model='nmos_1v8', W='2u', L='180n')
circuit.M(name='ps', drain='vin', gate='phib', source='vhold', bulk='vdd', model='pmos_1v8', W='4u', L='180n')

# Hold capacitor
circuit.C(name='hold', positive='vhold', negative=circuit.gnd, value=1e-12)

# Buffer (source follower)
circuit.M(name='buf', drain='vdd', gate='vhold', source='vout', bulk='0', model='nmos_1v8', W='10u', L='180n')
circuit.I(name='bias', positive='vout', negative=circuit.gnd, value=100e-6)

print(circuit)
