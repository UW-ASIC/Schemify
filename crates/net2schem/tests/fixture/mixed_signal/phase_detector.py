#!/usr/bin/env python3
"""CMOS phase-frequency detector (PFD) for PLL applications."""
from pyspice_rs import Circuit

circuit = Circuit('Phase Frequency Detector')

circuit.model('nmos_1v8', 'nmos', level=1, kp=120e-6, vto=0.5)
circuit.model('pmos_1v8', 'pmos', level=1, kp=60e-6, vto=-0.5)

circuit.V(name='dd', positive='vdd', negative=circuit.gnd, value=1.8)

# Reference clock: 100 MHz
circuit.PulseVoltageSource(name='ref', positive='fref', negative=circuit.gnd,
                           initial_value=0, pulsed_value=1.8,
                           rise_time=50e-12, fall_time=50e-12,
                           pulse_width=5e-9, period=10e-9)

# Feedback clock: 100 MHz with phase offset
circuit.PulseVoltageSource(name='fb', positive='ffb', negative=circuit.gnd,
                           initial_value=0, pulsed_value=1.8,
                           rise_time=50e-12, fall_time=50e-12,
                           pulse_width=5e-9, period=10e-9)

# D flip-flop 1 (UP output)
circuit.M(name='p_up1', drain='n_up', gate='fref', source='vdd', bulk='vdd', model='pmos_1v8', W='2u', L='180n')
circuit.M(name='n_up1', drain='n_up', gate='fref', source='rst', bulk='0', model='nmos_1v8', W='1u', L='180n')
circuit.M(name='p_up2', drain='up', gate='n_up', source='vdd', bulk='vdd', model='pmos_1v8', W='2u', L='180n')
circuit.M(name='n_up2', drain='up', gate='n_up', source='0', bulk='0', model='nmos_1v8', W='1u', L='180n')

# D flip-flop 2 (DN output)
circuit.M(name='p_dn1', drain='n_dn', gate='ffb', source='vdd', bulk='vdd', model='pmos_1v8', W='2u', L='180n')
circuit.M(name='n_dn1', drain='n_dn', gate='ffb', source='rst', bulk='0', model='nmos_1v8', W='1u', L='180n')
circuit.M(name='p_dn2', drain='dn', gate='n_dn', source='vdd', bulk='vdd', model='pmos_1v8', W='2u', L='180n')
circuit.M(name='n_dn2', drain='dn', gate='n_dn', source='0', bulk='0', model='nmos_1v8', W='1u', L='180n')

# Reset: NAND(UP, DN) -> inverter -> rst
circuit.M(name='p_rst1', drain='nand_out', gate='up', source='vdd', bulk='vdd', model='pmos_1v8', W='2u', L='180n')
circuit.M(name='p_rst2', drain='nand_out', gate='dn', source='vdd', bulk='vdd', model='pmos_1v8', W='2u', L='180n')
circuit.M(name='n_rst1', drain='nand_out', gate='up', source='nand_mid', bulk='0', model='nmos_1v8', W='2u', L='180n')
circuit.M(name='n_rst2', drain='nand_mid', gate='dn', source='0', bulk='0', model='nmos_1v8', W='2u', L='180n')

# Inverter for reset
circuit.M(name='p_inv', drain='rst', gate='nand_out', source='vdd', bulk='vdd', model='pmos_1v8', W='2u', L='180n')
circuit.M(name='n_inv', drain='rst', gate='nand_out', source='0', bulk='0', model='nmos_1v8', W='1u', L='180n')

print(circuit)
