#!/usr/bin/env python3
"""Op-amp differentiator. Vout = -RC * d(Vin)/dt."""
from pyspice_rs import Circuit

circuit = Circuit('Op-Amp Differentiator')

circuit.V(name='cc', positive='vcc', negative=circuit.gnd, value=15)
circuit.V(name='ee', positive='vee', negative=circuit.gnd, value=-15)

# Sine wave input
circuit.SinusoidalVoltageSource(name='in', positive='vin', negative=circuit.gnd,
                                 dc_offset=0, offset=0,
                                 amplitude=1, frequency=1e3)

# Input capacitor (differentiation)
circuit.C(name='in', positive='vin', negative='vminus', value=10e-9)

# Series resistor for stability
circuit.R(name='s', positive='vin', negative='n1', value=100)

# Feedback resistor
circuit.R(name='f', positive='vminus', negative='vout', value=10e3)

# Feedback cap for HF rolloff
circuit.C(name='f', positive='vminus', negative='vout', value=100e-12)

# Op-amp (behavioral VCVS: E element)
circuit.E(name='amp', positive='vout', negative=circuit.gnd,
          control_positive=circuit.gnd, control_negative='vminus', voltage_gain=1e6)

print(circuit)
