from pyspice_rs import Circuit
from pyspice_rs.unit import u_V, u_uA

circuit = Circuit('OTA Testbench')
circuit.V('dd', 'vdd', circuit.gnd, 1.8 @ u_V)
circuit.V('bias', 'vbias', circuit.gnd, 0.6 @ u_V)
circuit.V('inp', 'inp', circuit.gnd, 0.9 @ u_V)
circuit.V('inn', 'inn', circuit.gnd, 0.9 @ u_V)
circuit.X('1', 'ota', 'inp', 'inn', 'out', 'vdd', circuit.gnd)

# Analysis (passes through, not imported as geometry)
simulator = circuit.simulator()
analysis = simulator.dc(Vinp=slice(0, 1.8, 0.01))

print(circuit)
