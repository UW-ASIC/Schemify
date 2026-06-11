#!/usr/bin/env python3
"""RC integrator with pulse input — demonstrates transient analysis."""
from pyspice_rs import Circuit

circuit = Circuit('RC Integrator')

# Pulse source: 0V to 1V, 1us rise, 1us fall, 5us on, 20us period
circuit.PulseVoltageSource(name='in', positive='vin', negative=circuit.gnd,
                           initial_value=0, pulsed_value=1,
                           rise_time=1e-6, fall_time=1e-6,
                           pulse_width=5e-6, period=20e-6)
circuit.R(name='1', positive='vin', negative='vout', value=10e3)
circuit.C(name='1', positive='vout', negative=circuit.gnd, value=1e-9)  # 1 nF

print(circuit)
