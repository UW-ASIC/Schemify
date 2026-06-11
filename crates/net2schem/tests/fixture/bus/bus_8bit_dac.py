#!/usr/bin/env python3
"""8-bit R-2R DAC with bus notation on digital inputs.

Uses data[7:0] bus for digital inputs — Schemify should parse
bracket notation and display as a bus on the schematic.
"""
from pyspice_rs import Circuit

circuit = Circuit('8-bit R-2R DAC')

R = 10e3

# 8-bit digital input bus: data[7:0]
# Setting binary 10101010 = 170 -> Vout ~ 170/256 * 3.3V = 2.19V
for i in range(8):
    bit_val = 3.3 if (0xAA >> i) & 1 else 0.0
    circuit.V(name=f'data[{i}]', positive=f'data[{i}]', negative=circuit.gnd, value=bit_val)

# R-2R ladder
circuit.R(name='term', positive='n0', negative=circuit.gnd, value=2 * R)

for i in range(8):
    circuit.R(name=f'2r{i}', positive=f'data[{i}]', negative=f'n{i}', value=2 * R)
    if i < 7:
        circuit.R(name=f'r{i}', positive=f'n{i}', negative=f'n{i+1}', value=R)

# Output from MSB node
circuit.R(name='out', positive='n7', negative='vout', value=1)

# Buffer load
circuit.R(name='load', positive='vout', negative=circuit.gnd, value=1e6)

print(circuit)
