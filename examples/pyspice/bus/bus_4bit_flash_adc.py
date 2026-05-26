#!/usr/bin/env python3
"""4-bit flash ADC with bus outputs: dout[3:0].

Uses a resistor ladder to generate reference voltages,
comparators at each tap, and thermometer-to-binary encoder.
Bus notation on outputs for Schemify bus rendering.
"""
from pyspice_rs import Circuit

circuit = Circuit('4-bit Flash ADC')

circuit.V(name='dd', positive='vdd', negative=circuit.gnd, value=1.8)
circuit.V(name='ref', positive='vref', negative=circuit.gnd, value=1.8)

# Analog input
circuit.V(name='in', positive='vin', negative=circuit.gnd, value=1.0)

# Reference ladder: 15 taps for 4-bit (2^4 - 1 comparators)
R_UNIT = 1e3
for i in range(16):
    if i == 0:
        circuit.R(name=f'lad{i}', positive=circuit.gnd, negative=f'tap[{i}]', value=R_UNIT)
    else:
        circuit.R(name=f'lad{i}', positive=f'tap[{i-1}]', negative=f'tap[{i}]', value=R_UNIT)

# Top of ladder to Vref
circuit.R(name='lad_top', positive='tap[15]', negative='vref', value=R_UNIT)

# 15 comparators (behavioral: E element with high gain)
for i in range(15):
    circuit.E(name=f'cmp{i}', positive=f'comp[{i}]', negative=circuit.gnd,
              control_positive='vin', control_negative=f'tap[{i}]', voltage_gain=1e4)

# Thermometer-to-binary priority encoder (simplified behavioral)
# Output bus: dout[3:0]
circuit.R(name='d0', positive='comp[0]', negative='dout[0]', value=10e3)
circuit.R(name='d1', positive='comp[1]', negative='dout[1]', value=10e3)
circuit.R(name='d2', positive='comp[3]', negative='dout[2]', value=10e3)
circuit.R(name='d3', positive='comp[7]', negative='dout[3]', value=10e3)

# Pull-downs on outputs
for i in range(4):
    circuit.R(name=f'pd{i}', positive=f'dout[{i}]', negative=circuit.gnd, value=100e3)

print(circuit)

simulator = circuit.simulator()
analysis = simulator.dc(Vin=slice(0, 1.8, 0.01))
