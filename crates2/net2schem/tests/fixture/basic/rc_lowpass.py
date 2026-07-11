#!/usr/bin/env python3
"""First-order RC low-pass filter. Cutoff at 1/(2*pi*R*C) = ~1.59 kHz."""
from pyspice_rs import Circuit

circuit = Circuit('RC Low-Pass Filter')

circuit.V(name='in', positive='vin', negative=circuit.gnd, value=1)
circuit.R(name='1', positive='vin', negative='vout', value=1e3)
circuit.C(name='1', positive='vout', negative=circuit.gnd, value=100e-9)

print(circuit)
