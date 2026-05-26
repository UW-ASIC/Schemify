#!/usr/bin/env python3
"""4-bit shift register with bus output: q[3:0].

Serial-in, parallel-out using D flip-flops (transmission-gate based).
Exercises bus parsing on output nets.
"""
from pyspice_rs import Circuit

circuit = Circuit('4-bit Shift Register')

circuit.model('nmos_1v8', 'nmos', level=1, kp=120e-6, vto=0.5)
circuit.model('pmos_1v8', 'pmos', level=1, kp=60e-6, vto=-0.5)

circuit.V(name='dd', positive='vdd', negative=circuit.gnd, value=1.8)

# Clock
circuit.PulseVoltageSource(name='clk', positive='clk', negative=circuit.gnd,
                           initial_value=0, pulsed_value=1.8,
                           rise_time=50e-12, fall_time=50e-12,
                           pulse_width=5e-9, period=10e-9)

# Clock complement
circuit.M(name='p_clkb', drain='clkb', gate='clk', source='vdd', bulk='vdd', model='pmos_1v8', W='2u', L='180n')
circuit.M(name='n_clkb', drain='clkb', gate='clk', source='0', bulk='0', model='nmos_1v8', W='1u', L='180n')

# Serial data input: 1,0,1,1 pattern
circuit.PulseVoltageSource(name='din', positive='din', negative=circuit.gnd,
                           initial_value=1.8, pulsed_value=0,
                           rise_time=50e-12, fall_time=50e-12,
                           pulse_width=10e-9, period=40e-9)

# 4 stages of master-slave D flip-flops (simplified with TG latches)
stages = ['din', 'q[0]', 'q[1]', 'q[2]', 'q[3]']

for i in range(4):
    d_in = stages[i]
    q_out = stages[i + 1]
    m = f'master{i}'

    # Master latch (transparent when clk=0)
    circuit.M(name=f'n_m{i}', drain=d_in, gate='clkb', source=m, bulk='0', model='nmos_1v8', W='1u', L='180n')
    circuit.M(name=f'p_m{i}', drain=d_in, gate='clk', source=m, bulk='vdd', model='pmos_1v8', W='2u', L='180n')

    # Master storage (inverter feedback)
    circuit.M(name=f'p_mi{i}', drain=f'mb{i}', gate=m, source='vdd', bulk='vdd', model='pmos_1v8', W='1u', L='180n')
    circuit.M(name=f'n_mi{i}', drain=f'mb{i}', gate=m, source='0', bulk='0', model='nmos_1v8', W='500n', L='180n')
    circuit.C(name=f'cm{i}', positive=m, negative=circuit.gnd, value=2e-15)

    # Slave latch (transparent when clk=1)
    circuit.M(name=f'n_s{i}', drain=m, gate='clk', source=q_out, bulk='0', model='nmos_1v8', W='1u', L='180n')
    circuit.M(name=f'p_s{i}', drain=m, gate='clkb', source=q_out, bulk='vdd', model='pmos_1v8', W='2u', L='180n')

    # Slave storage
    circuit.M(name=f'p_si{i}', drain=f'sb{i}', gate=q_out, source='vdd', bulk='vdd', model='pmos_1v8', W='1u', L='180n')
    circuit.M(name=f'n_si{i}', drain=f'sb{i}', gate=q_out, source='0', bulk='0', model='nmos_1v8', W='500n', L='180n')
    circuit.C(name=f'cs{i}', positive=q_out, negative=circuit.gnd, value=2e-15)

print(circuit)

simulator = circuit.simulator()
analysis = simulator.transient(step_time=50e-12, end_time=80e-9)
