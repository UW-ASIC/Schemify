#!/usr/bin/env python3
"""2-to-4 decoder with bus notation: addr[1:0] -> out[3:0].

CMOS NOR-based decoder. Only one output is active (low) at a time.
"""
from pyspice_rs import Circuit

circuit = Circuit('2-to-4 Decoder')

circuit.model('nmos_1v8', 'nmos', level=1, kp=120e-6, vto=0.5)
circuit.model('pmos_1v8', 'pmos', level=1, kp=60e-6, vto=-0.5)

circuit.V(name='dd', positive='vdd', negative=circuit.gnd, value=1.8)

# Address bus: addr[1:0] = 10 (select output 2)
circuit.V(name='addr[0]', positive='addr[0]', negative=circuit.gnd, value=0)
circuit.V(name='addr[1]', positive='addr[1]', negative=circuit.gnd, value=1.8)

# Enable (active high)
circuit.V(name='en', positive='en', negative=circuit.gnd, value=1.8)

# Inverters for address lines
circuit.M(name='p_a0b', drain='addr_b[0]', gate='addr[0]', source='vdd', bulk='vdd', model='pmos_1v8', W='2u', L='180n')
circuit.M(name='n_a0b', drain='addr_b[0]', gate='addr[0]', source='0', bulk='0', model='nmos_1v8', W='1u', L='180n')
circuit.M(name='p_a1b', drain='addr_b[1]', gate='addr[1]', source='vdd', bulk='vdd', model='pmos_1v8', W='2u', L='180n')
circuit.M(name='n_a1b', drain='addr_b[1]', gate='addr[1]', source='0', bulk='0', model='nmos_1v8', W='1u', L='180n')

# out[0]: active when addr = 00 -> AND(!a1, !a0, en)
# NAND(!a1, !a0)
circuit.M(name='p_n0a', drain='nand0', gate='addr_b[1]', source='vdd', bulk='vdd', model='pmos_1v8', W='2u', L='180n')
circuit.M(name='p_n0b', drain='nand0', gate='addr_b[0]', source='vdd', bulk='vdd', model='pmos_1v8', W='2u', L='180n')
circuit.M(name='n_n0a', drain='nand0', gate='addr_b[1]', source='mid0', bulk='0', model='nmos_1v8', W='2u', L='180n')
circuit.M(name='n_n0b', drain='mid0', gate='addr_b[0]', source='0', bulk='0', model='nmos_1v8', W='2u', L='180n')
circuit.M(name='p_o0', drain='out[0]', gate='nand0', source='vdd', bulk='vdd', model='pmos_1v8', W='2u', L='180n')
circuit.M(name='n_o0', drain='out[0]', gate='nand0', source='0', bulk='0', model='nmos_1v8', W='1u', L='180n')

# out[1]: active when addr = 01 -> AND(!a1, a0, en)
circuit.M(name='p_n1a', drain='nand1', gate='addr_b[1]', source='vdd', bulk='vdd', model='pmos_1v8', W='2u', L='180n')
circuit.M(name='p_n1b', drain='nand1', gate='addr[0]', source='vdd', bulk='vdd', model='pmos_1v8', W='2u', L='180n')
circuit.M(name='n_n1a', drain='nand1', gate='addr_b[1]', source='mid1', bulk='0', model='nmos_1v8', W='2u', L='180n')
circuit.M(name='n_n1b', drain='mid1', gate='addr[0]', source='0', bulk='0', model='nmos_1v8', W='2u', L='180n')
circuit.M(name='p_o1', drain='out[1]', gate='nand1', source='vdd', bulk='vdd', model='pmos_1v8', W='2u', L='180n')
circuit.M(name='n_o1', drain='out[1]', gate='nand1', source='0', bulk='0', model='nmos_1v8', W='1u', L='180n')

# out[2]: active when addr = 10 -> AND(a1, !a0, en)
circuit.M(name='p_n2a', drain='nand2', gate='addr[1]', source='vdd', bulk='vdd', model='pmos_1v8', W='2u', L='180n')
circuit.M(name='p_n2b', drain='nand2', gate='addr_b[0]', source='vdd', bulk='vdd', model='pmos_1v8', W='2u', L='180n')
circuit.M(name='n_n2a', drain='nand2', gate='addr[1]', source='mid2', bulk='0', model='nmos_1v8', W='2u', L='180n')
circuit.M(name='n_n2b', drain='mid2', gate='addr_b[0]', source='0', bulk='0', model='nmos_1v8', W='2u', L='180n')
circuit.M(name='p_o2', drain='out[2]', gate='nand2', source='vdd', bulk='vdd', model='pmos_1v8', W='2u', L='180n')
circuit.M(name='n_o2', drain='out[2]', gate='nand2', source='0', bulk='0', model='nmos_1v8', W='1u', L='180n')

# out[3]: active when addr = 11 -> AND(a1, a0, en)
circuit.M(name='p_n3a', drain='nand3', gate='addr[1]', source='vdd', bulk='vdd', model='pmos_1v8', W='2u', L='180n')
circuit.M(name='p_n3b', drain='nand3', gate='addr[0]', source='vdd', bulk='vdd', model='pmos_1v8', W='2u', L='180n')
circuit.M(name='n_n3a', drain='nand3', gate='addr[1]', source='mid3', bulk='0', model='nmos_1v8', W='2u', L='180n')
circuit.M(name='n_n3b', drain='mid3', gate='addr[0]', source='0', bulk='0', model='nmos_1v8', W='2u', L='180n')
circuit.M(name='p_o3', drain='out[3]', gate='nand3', source='vdd', bulk='vdd', model='pmos_1v8', W='2u', L='180n')
circuit.M(name='n_o3', drain='out[3]', gate='nand3', source='0', bulk='0', model='nmos_1v8', W='1u', L='180n')

print(circuit)
