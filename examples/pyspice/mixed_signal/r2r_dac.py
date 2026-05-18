#!/usr/bin/env python3
"""4-bit R-2R ladder DAC."""
from pyspice_rs import Circuit

circuit = Circuit('R-2R DAC 4-bit')

# Digital inputs (example: 0b1010 = 10 -> Vout ~ 10/16 * Vref)
circuit.V(name='ref', positive='vref', negative=circuit.gnd, value=3.3)
circuit.V(name='b3', positive='b3', negative=circuit.gnd, value=3.3)   # MSB = 1
circuit.V(name='b2', positive='b2', negative=circuit.gnd, value=0)      # 0
circuit.V(name='b1', positive='b1', negative=circuit.gnd, value=3.3)    # 1
circuit.V(name='b0', positive='b0', negative=circuit.gnd, value=0)      # LSB = 0

R = 10e3

# R-2R ladder from LSB to MSB
# Bit 0 (LSB)
circuit.R(name='2r0', positive='b0', negative='n0', value=2 * R)
circuit.R(name='r0', positive='n0', negative='n1', value=R)

# Bit 1
circuit.R(name='2r1', positive='b1', negative='n1', value=2 * R)
circuit.R(name='r1', positive='n1', negative='n2', value=R)

# Bit 2
circuit.R(name='2r2', positive='b2', negative='n2', value=2 * R)
circuit.R(name='r2', positive='n2', negative='n3', value=R)

# Bit 3 (MSB)
circuit.R(name='2r3', positive='b3', negative='n3', value=2 * R)

# Termination
circuit.R(name='term', positive='n0', negative=circuit.gnd, value=2 * R)

# Output buffer (unity-gain op-amp via E element)
circuit.E(name='buf', positive='vout', negative=circuit.gnd,
          control_positive='n3', control_negative=circuit.gnd, voltage_gain=1e6)
circuit.R(name='fb', positive='vout', negative='n3', value=1)  # Feedback

print(circuit)

simulator = circuit.simulator()
analysis = simulator.operating_point()
