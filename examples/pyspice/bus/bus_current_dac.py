#!/usr/bin/env python3
"""4-bit binary-weighted current-steering DAC with bus: code[3:0].

Current sources are binary weighted (I, 2I, 4I, 8I).
Switches steer current to output or dummy node.
Bus notation on digital control inputs.
"""
from pyspice_rs import Circuit

circuit = Circuit('4-bit Current DAC')

circuit.model('nmos_1v8', 'nmos', level=1, kp=120e-6, vto=0.5)
circuit.model('pmos_1v8', 'pmos', level=1, kp=60e-6, vto=-0.5)

circuit.V(name='dd', positive='vdd', negative=circuit.gnd, value=1.8)
circuit.V(name='bias', positive='vbias', negative=circuit.gnd, value=0.6)

# Unit current = 10 uA, full-scale = 150 uA
I_UNIT = 10e-6

# Digital control bus: code[3:0] — sweep all 16 codes
# Start with code = 1010 (10) -> Iout = 10 * 10uA = 100uA
code_val = 10
for i in range(4):
    bit = 1.8 if (code_val >> i) & 1 else 0
    circuit.V(name=f'code[{i}]', positive=f'code[{i}]', negative=circuit.gnd, value=bit)

# Binary-weighted NMOS current sources
weights = [1, 2, 4, 8]
for i in range(4):
    w_mult = weights[i]
    w_um = 2 * w_mult  # width in microns

    # Current source MOSFET
    circuit.M(name=f'cs{i}', drain=f'src[{i}]', gate='vbias', source='0', bulk='0', model='nmos_1v8', W=f'{w_um}u', L='1u')

    # Steering switch: code[i]=1 -> current to iout, else to dummy
    circuit.M(name=f'sw_on{i}', drain='iout', gate=f'code[{i}]', source=f'src[{i}]', bulk='0', model='nmos_1v8', W='2u', L='180n')
    circuit.M(name=f'sw_off{i}', drain='idummy', gate=f'code_b[{i}]', source=f'src[{i}]', bulk='0', model='nmos_1v8', W='2u', L='180n')

    # Complementary control
    circuit.M(name=f'p_inv{i}', drain=f'code_b[{i}]', gate=f'code[{i}]', source='vdd', bulk='vdd', model='pmos_1v8', W='2u', L='180n')
    circuit.M(name=f'n_inv{i}', drain=f'code_b[{i}]', gate=f'code[{i}]', source='0', bulk='0', model='nmos_1v8', W='1u', L='180n')

# Output termination (virtual ground from TIA or resistor)
circuit.R(name='out', positive='vdd', negative='iout', value=5e3)
circuit.R(name='dummy', positive='vdd', negative='idummy', value=5e3)

# Output voltage probe
circuit.C(name='out', positive='iout', negative=circuit.gnd, value=1e-12)

print(circuit)

simulator = circuit.simulator()
analysis = simulator.operating_point()

# Full transfer function test:
# for code in range(16):
#     set code[3:0] = binary(code)
#     measure Vout (or Iout)
# Plot DNL, INL from measured values
