#!/usr/bin/env python3
"""CMOS LDO voltage regulator — error amp + pass transistor + feedback."""
from pyspice_rs import Circuit

circuit = Circuit('LDO Regulator')

circuit.model('nmos_1v8', 'nmos', level=1, kp=120e-6, vto=0.5)
circuit.model('pmos_1v8', 'pmos', level=1, kp=60e-6, vto=-0.5)

circuit.V(name='in', positive='vin', negative=circuit.gnd, value=3.3)
circuit.V(name='ref', positive='vref', negative=circuit.gnd, value=1.2)

# Error amplifier (diff pair + active load)
circuit.M(name='1', drain='n1', gate='vref', source='tail', bulk='0', model='nmos_1v8', W='5u', L='500n')
circuit.M(name='2', drain='gate', gate='fb', source='tail', bulk='0', model='nmos_1v8', W='5u', L='500n')
circuit.M(name='3', drain='n1', gate='n1', source='vin', bulk='vin', model='pmos_1v8', W='4u', L='500n')
circuit.M(name='4', drain='gate', gate='n1', source='vin', bulk='vin', model='pmos_1v8', W='4u', L='500n')

# Tail current source
circuit.I(name='tail', positive=circuit.gnd, negative='tail', value=20e-6)

# PMOS pass transistor
circuit.M(name='pass', drain='vout', gate='gate', source='vin', bulk='vin', model='pmos_1v8', W='200u', L='180n')

# Feedback resistor divider (Vout = Vref * (1 + R1/R2))
circuit.R(name='1', positive='vout', negative='fb', value=180e3)
circuit.R(name='2', positive='fb', negative=circuit.gnd, value=120e3)

# Output cap + ESR
circuit.R(name='esr', positive='vout', negative='cap_node', value=50e-3)
circuit.C(name='out', positive='cap_node', negative=circuit.gnd, value=1e-6)

# Load
circuit.R(name='load', positive='vout', negative=circuit.gnd, value=100)

print(circuit)

simulator = circuit.simulator()
analysis = simulator.dc(Vin=slice(1.5, 5.0, 0.01))
