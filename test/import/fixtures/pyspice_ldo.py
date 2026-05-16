from pyspice_rs import Circuit
from pyspice_rs.unit import u_V, u_Ohm, u_uF, u_u

circuit = Circuit('LDO Regulator')

# Pass transistor and error amp
circuit.M('pass', 'vout', 'gate', 'vin', 'vin', model='sky130_fd_pr__pfet_01v8', w=100e-6, l=0.18e-6)
circuit.M('1', 'n1', 'vref', 'tail', 'vss', model='sky130_fd_pr__nfet_01v8', w=2e-6, l=0.5e-6)
circuit.M('2', 'gate', 'fb', 'tail', 'vss', model='sky130_fd_pr__nfet_01v8', w=2e-6, l=0.5e-6)
circuit.M('3', 'n1', 'n1', 'vin', 'vin', model='sky130_fd_pr__pfet_01v8', w=4e-6, l=0.5e-6)
circuit.M('4', 'gate', 'n1', 'vin', 'vin', model='sky130_fd_pr__pfet_01v8', w=4e-6, l=0.5e-6)

# Feedback divider
circuit.R('1', 'vout', 'fb', 90e3 @ u_Ohm)
circuit.R('2', 'fb', circuit.gnd, 10e3 @ u_Ohm)

# Compensation
circuit.C('1', 'gate', 'vout', 5e-12 @ u_uF)

print(circuit)

# Analysis
simulator = circuit.simulator()
analysis = simulator.dc(Vvin=slice(1.0, 3.3, 0.01))
