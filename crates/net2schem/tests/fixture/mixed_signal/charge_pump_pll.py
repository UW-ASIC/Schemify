#!/usr/bin/env python3
"""Charge pump for PLL — converts UP/DN pulses to analog control voltage."""
from pyspice_rs import Circuit

circuit = Circuit('PLL Charge Pump')

circuit.model('nmos_1v8', 'nmos', level=1, kp=120e-6, vto=0.5)
circuit.model('pmos_1v8', 'pmos', level=1, kp=60e-6, vto=-0.5)

circuit.V(name='dd', positive='vdd', negative=circuit.gnd, value=1.8)

# UP pulse (charge)
circuit.PulseVoltageSource(name='up', positive='up', negative=circuit.gnd,
                           initial_value=0, pulsed_value=1.8,
                           rise_time=50e-12, fall_time=50e-12,
                           pulse_width=500e-12, period=10e-9)

# DN pulse (discharge)
circuit.PulseVoltageSource(name='dn', positive='dn', negative=circuit.gnd,
                           initial_value=0, pulsed_value=1.8,
                           rise_time=50e-12, fall_time=50e-12,
                           pulse_width=200e-12, period=10e-9)

# Charge pump current sources
# UP switch: PMOS sources current to output
circuit.M(name='p1', drain='vdd', gate='vdd', source='src_p', bulk='vdd', model='pmos_1v8', W='10u', L='500n')
circuit.M(name='p_sw', drain='src_p', gate='up_b', source='vctrl', bulk='vdd', model='pmos_1v8', W='5u', L='180n')

# DN switch: NMOS sinks current from output
circuit.M(name='n1', drain='src_n', gate='vbn', source='0', bulk='0', model='nmos_1v8', W='5u', L='500n')
circuit.M(name='n_sw', drain='vctrl', gate='dn', source='src_n', bulk='0', model='nmos_1v8', W='5u', L='180n')

# Bias voltages
circuit.V(name='bn', positive='vbn', negative=circuit.gnd, value=0.5)

# UP_bar inverter
circuit.M(name='p_inv', drain='up_b', gate='up', source='vdd', bulk='vdd', model='pmos_1v8', W='2u', L='180n')
circuit.M(name='n_inv', drain='up_b', gate='up', source='0', bulk='0', model='nmos_1v8', W='1u', L='180n')

# Loop filter (second-order)
circuit.R(name='z', positive='vctrl', negative='n_filt', value=5e3)
circuit.C(name='1', positive='n_filt', negative=circuit.gnd, value=10e-12)
circuit.C(name='2', positive='vctrl', negative=circuit.gnd, value=1e-12)

print(circuit)
