from pyspice_rs import Circuit

circuit = Circuit('Inverter')
circuit.V('dd', 'vdd', circuit.gnd, 1.8)
circuit.X('1', 'inv', 'in', 'out', 'vdd', circuit.gnd)
print(circuit)
