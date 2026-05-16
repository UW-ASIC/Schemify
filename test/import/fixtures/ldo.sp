* Low Dropout Regulator
.global VDD VSS

.subckt ldo vin vout vss
* Error amplifier — differential pair
M1 net1 vref net3 vss sky130_fd_pr__nfet_01v8 W=2u L=0.5u
M2 net2 fb net3 vss sky130_fd_pr__nfet_01v8 W=2u L=0.5u

* Error amplifier — PMOS mirror load
M3 net1 net1 vin vin sky130_fd_pr__pfet_01v8 W=4u L=0.5u
M4 net2 net1 vin vin sky130_fd_pr__pfet_01v8 W=4u L=0.5u

* Error amplifier — tail current source
M5 net3 nbias vss vss sky130_fd_pr__nfet_01v8 W=2u L=1u

* Pass transistor (large PMOS)
M6 vout net2 vin vin sky130_fd_pr__pfet_01v8 W=100u L=0.18u

* Feedback resistor divider
R1 vout fb 90k
R2 fb vss 10k

* Compensation capacitor
C1 net2 vout 5p

* Reference voltage source
V1 vref vss 0.6
.ends ldo
.end
