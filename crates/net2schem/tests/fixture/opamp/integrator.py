#!/usr/bin/env python3
"""Op-amp integrator. Vout = -(1/RC) * integral(Vin) dt."""
from pyspice_rs import Circuit

circuit = Circuit('Op-Amp Integrator')

circuit.V(name='cc', positive='vcc', negative=circuit.gnd, value=15)
circuit.V(name='ee', positive='vee', negative=circuit.gnd, value=-15)

# Square wave input
circuit.PulseVoltageSource(name='in', positive='vin', negative=circuit.gnd,
                           initial_value=-0.5, pulsed_value=0.5,
                           rise_time=1e-6, fall_time=1e-6,
                           pulse_width=500e-6, period=1e-3)

# Input resistor
circuit.R(name='in', positive='vin', negative='vminus', value=10e3)

# Feedback capacitor (integration)
circuit.C(name='f', positive='vminus', negative='vout', value=10e-9)

# Reset resistor (prevents DC drift)
circuit.R(name='f', positive='vminus', negative='vout', value=1e6)

# Op-amp (behavioral VCVS: E element)
circuit.E(name='amp', positive='vout', negative=circuit.gnd,
          control_positive=circuit.gnd, control_negative='vminus', voltage_gain=1e6)

print(circuit)
