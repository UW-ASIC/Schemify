#!/usr/bin/env python3
"""3 op-amp instrumentation amplifier — high CMRR differential measurement."""
from pyspice_rs import Circuit

circuit = Circuit('Instrumentation Amplifier')

circuit.V(name='cc', positive='vcc', negative=circuit.gnd, value=15)
circuit.V(name='ee', positive='vee', negative=circuit.gnd, value=-15)

# Differential input with common-mode
circuit.V(name='cm', positive='vcm', negative=circuit.gnd, value=2.5)
circuit.V(name='dp', positive='inp', negative='vcm', value=5e-3)    # +5 mV differential
circuit.V(name='dn', positive='vcm', negative='inn', value=5e-3)    # -5 mV differential

# First stage: two non-inverting buffers with shared gain resistor
# Op-amp A1 (top)
circuit.E(name='a1', positive='out_a1', negative=circuit.gnd,
          control_positive='inp', control_negative='fb_a1', voltage_gain=1e6)
circuit.R(name='g1', positive='fb_a1', negative='mid', value=10e3)  # Rg/2
circuit.R(name='1a', positive='fb_a1', negative='out_a1', value=24.7e3)

# Op-amp A2 (bottom)
circuit.E(name='a2', positive='out_a2', negative=circuit.gnd,
          control_positive='inn', control_negative='fb_a2', voltage_gain=1e6)
circuit.R(name='g2', positive='mid', negative='fb_a2', value=10e3)  # Rg/2
circuit.R(name='2a', positive='fb_a2', negative='out_a2', value=24.7e3)

# Second stage: difference amplifier
circuit.R(name='3', positive='out_a1', negative='diff_m', value=10e3)
circuit.R(name='4', positive='diff_m', negative='vout', value=10e3)
circuit.R(name='5', positive='out_a2', negative='diff_p', value=10e3)
circuit.R(name='6', positive='diff_p', negative=circuit.gnd, value=10e3)

# Op-amp A3 (diff stage)
circuit.E(name='a3', positive='vout', negative=circuit.gnd,
          control_positive='diff_p', control_negative='diff_m', voltage_gain=1e6)

print(circuit)

simulator = circuit.simulator()
analysis = simulator.operating_point()
