#!/usr/bin/env python3
"""4x4 SRAM cell array with bus notation: addr[1:0], data[3:0], wl[3:0], bl[3:0].

Demonstrates multi-bit bus wiring in a memory structure.
"""
from pyspice_rs import Circuit

circuit = Circuit('4x4 SRAM Array')

circuit.model('nmos_1v8', 'nmos', level=1, kp=120e-6, vto=0.5)
circuit.model('pmos_1v8', 'pmos', level=1, kp=60e-6, vto=-0.5)

circuit.V(name='dd', positive='vdd', negative=circuit.gnd, value=1.8)

# Word lines: wl[3:0] (active high, select a row)
for i in range(4):
    val = 1.8 if i == 0 else 0.0  # Select row 0
    circuit.V(name=f'wl[{i}]', positive=f'wl[{i}]', negative=circuit.gnd, value=val)

# Bit lines: bl[3:0] and blb[3:0] (complement)
# Pre-charged to VDD/2
for i in range(4):
    circuit.V(name=f'pre_bl[{i}]', positive=f'bl[{i}]', negative=circuit.gnd, value=0.9)
    circuit.V(name=f'pre_blb[{i}]', positive=f'blb[{i}]', negative=circuit.gnd, value=0.9)

# SRAM cells: 6T cell at each intersection
for row in range(4):
    for col in range(4):
        prefix = f'r{row}c{col}'
        wl = f'wl[{row}]'
        bl = f'bl[{col}]'
        blb = f'blb[{col}]'

        # Cross-coupled inverters
        circuit.M(name=f'{prefix}_p1', drain=f'{prefix}_q', gate=f'{prefix}_qb', source='vdd', bulk='vdd', model='pmos_1v8', W='1u', L='180n')
        circuit.M(name=f'{prefix}_n1', drain=f'{prefix}_q', gate=f'{prefix}_qb', source='0', bulk='0', model='nmos_1v8', W='500n', L='180n')
        circuit.M(name=f'{prefix}_p2', drain=f'{prefix}_qb', gate=f'{prefix}_q', source='vdd', bulk='vdd', model='pmos_1v8', W='1u', L='180n')
        circuit.M(name=f'{prefix}_n2', drain=f'{prefix}_qb', gate=f'{prefix}_q', source='0', bulk='0', model='nmos_1v8', W='500n', L='180n')

        # Access transistors
        circuit.M(name=f'{prefix}_acc1', drain=bl, gate=wl, source=f'{prefix}_q', bulk='0', model='nmos_1v8', W='1u', L='180n')
        circuit.M(name=f'{prefix}_acc2', drain=blb, gate=wl, source=f'{prefix}_qb', bulk='0', model='nmos_1v8', W='1u', L='180n')

# Sense amplifiers reading bl[3:0]
for i in range(4):
    circuit.M(name=f'sa_p{i}', drain=f'data[{i}]', gate=f'blb[{i}]', source='vdd', bulk='vdd', model='pmos_1v8', W='2u', L='180n')
    circuit.M(name=f'sa_n{i}', drain=f'data[{i}]', gate=f'bl[{i}]', source='0', bulk='0', model='nmos_1v8', W='1u', L='180n')

print(circuit)

simulator = circuit.simulator()
analysis = simulator.operating_point()
