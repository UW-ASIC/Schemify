#!/usr/bin/env python3
"""Synchronous buck converter — 3.3V to 1.8V, 1 MHz switching."""
from pyspice_rs import Circuit

circuit = Circuit('Buck Converter')

circuit.model('nmos_1v8', 'nmos', level=1, kp=120e-6, vto=0.5)
circuit.model('pmos_1v8', 'pmos', level=1, kp=60e-6, vto=-0.5)

circuit.V(name='in', positive='vin', negative=circuit.gnd, value=3.3)

# PWM control signal (duty cycle ~ 1.8/3.3 ~ 55%)
circuit.PulseVoltageSource(name='pwm', positive='vpwm', negative=circuit.gnd,
                           initial_value=0, pulsed_value=1.8,
                           rise_time=10e-9, fall_time=10e-9,
                           pulse_width=545e-9, period=1e-6)

# High-side PMOS switch
circuit.M(name='hs', drain='vin', gate='vpwm', source='sw', bulk='vin', model='pmos_1v8', W='500u', L='180n')

# Low-side NMOS switch (synchronous rectifier)
circuit.M(name='ls', drain='sw', gate='vpwm', source='0', bulk='0', model='nmos_1v8', W='250u', L='180n')

# LC output filter
circuit.L(name='1', positive='sw', negative='vout', value=1e-6)        # 1 uH
circuit.C(name='out', positive='vout', negative=circuit.gnd, value=10e-6)  # 10 uF
circuit.R(name='esr', positive='vout', negative='vesr', value=10e-3)

# Load
circuit.R(name='load', positive='vout', negative=circuit.gnd, value=1.8)  # ~1A

print(circuit)
