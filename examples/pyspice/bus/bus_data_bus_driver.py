#!/usr/bin/env python3
"""Tri-state bus driver: 8-bit data[7:0] with output enable.

When OE=1, driver passes din[7:0] to bus[7:0].
When OE=0, outputs are high-impedance (tri-state).
Exercises wide bus notation in Schemify.
"""
from pyspice_rs import Circuit

circuit = Circuit('8-bit Tri-State Bus Driver')

circuit.model('nmos_1v8', 'nmos', level=1, kp=120e-6, vto=0.5)
circuit.model('pmos_1v8', 'pmos', level=1, kp=60e-6, vto=-0.5)

circuit.V(name='dd', positive='vdd', negative=circuit.gnd, value=1.8)

# Output enable
circuit.V(name='oe', positive='oe', negative=circuit.gnd, value=1.8)  # Enabled

# OE complement
circuit.M(name='p_oeb', drain='oeb', gate='oe', source='vdd', bulk='vdd', model='pmos_1v8', W='2u', L='180n')
circuit.M(name='n_oeb', drain='oeb', gate='oe', source='0', bulk='0', model='nmos_1v8', W='1u', L='180n')

# 8-bit input: din[7:0] = 0xA5 = 10100101
data_val = 0xA5
for i in range(8):
    bit = 1.8 if (data_val >> i) & 1 else 0
    circuit.V(name=f'din[{i}]', positive=f'din[{i}]', negative=circuit.gnd, value=bit)

# Tri-state buffers: inverter + transmission gate controlled by OE
for i in range(8):
    # Inverter (buffer stage)
    circuit.M(name=f'p_buf{i}', drain=f'buf[{i}]', gate=f'din[{i}]', source='vdd', bulk='vdd', model='pmos_1v8', W='4u', L='180n')
    circuit.M(name=f'n_buf{i}', drain=f'buf[{i}]', gate=f'din[{i}]', source='0', bulk='0', model='nmos_1v8', W='2u', L='180n')

    # Second inverter (non-inverting buffer)
    circuit.M(name=f'p_drv{i}', drain=f'drv[{i}]', gate=f'buf[{i}]', source='vdd', bulk='vdd', model='pmos_1v8', W='8u', L='180n')
    circuit.M(name=f'n_drv{i}', drain=f'drv[{i}]', gate=f'buf[{i}]', source='0', bulk='0', model='nmos_1v8', W='4u', L='180n')

    # Tri-state output (TG)
    circuit.M(name=f'n_ts{i}', drain=f'drv[{i}]', gate='oe', source=f'bus[{i}]', bulk='0', model='nmos_1v8', W='4u', L='180n')
    circuit.M(name=f'p_ts{i}', drain=f'drv[{i}]', gate='oeb', source=f'bus[{i}]', bulk='vdd', model='pmos_1v8', W='8u', L='180n')

    # Bus pull-down (weak keeper)
    circuit.R(name=f'keeper{i}', positive=f'bus[{i}]', negative=circuit.gnd, value=1e6)
    circuit.C(name=f'cbus{i}', positive=f'bus[{i}]', negative=circuit.gnd, value=50e-15)

print(circuit)

simulator = circuit.simulator()
analysis = simulator.operating_point()
# Expected: bus[7:0] = 0xA5 pattern (high/low matching din)
