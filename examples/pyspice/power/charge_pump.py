#!/usr/bin/env python3
"""Dickson charge pump — voltage doubler using switched capacitors."""
from pyspice_rs import Circuit

circuit = Circuit('Dickson Charge Pump')

circuit.model('diode_1v8', 'D', **{'is': 1e-14}, n=1.05)

circuit.V(name='dd', positive='vdd', negative=circuit.gnd, value=1.8)

# Clock phases (non-overlapping)
circuit.PulseVoltageSource(name='clk1', positive='phi1', negative=circuit.gnd,
                           initial_value=0, pulsed_value=1.8,
                           rise_time=100e-12, fall_time=100e-12,
                           pulse_width=5e-9, period=10e-9)
circuit.PulseVoltageSource(name='clk2', positive='phi2', negative=circuit.gnd,
                           initial_value=0, pulsed_value=1.8,
                           rise_time=100e-12, fall_time=100e-12,
                           pulse_width=5e-9, period=10e-9)

# Stage 1: Diode + pump cap
circuit.D(name='1', anode='vdd', cathode='n1', model='diode_1v8')
circuit.C(name='p1', positive='n1', negative='phi1', value=10e-12)

# Stage 2
circuit.D(name='2', anode='n1', cathode='n2', model='diode_1v8')
circuit.C(name='p2', positive='n2', negative='phi2', value=10e-12)

# Stage 3
circuit.D(name='3', anode='n2', cathode='n3', model='diode_1v8')
circuit.C(name='p3', positive='n3', negative='phi1', value=10e-12)

# Output diode + filter cap
circuit.D(name='4', anode='n3', cathode='vout', model='diode_1v8')
circuit.C(name='out', positive='vout', negative=circuit.gnd, value=50e-12)

# Load
circuit.R(name='load', positive='vout', negative=circuit.gnd, value=100e3)

print(circuit)

simulator = circuit.simulator()
analysis = simulator.transient(step_time=100e-12, end_time=100e-9)
