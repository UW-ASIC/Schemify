* Bandgap Reference with Current Mirrors and Cascodes
.subckt bandgap vref vdd vss

* PMOS current mirror (load)
M1 net1 net1 vdd vdd sky130_fd_pr__pfet_01v8 W=4u L=1u
M2 net2 net1 vdd vdd sky130_fd_pr__pfet_01v8 W=4u L=1u
M3 vref net1 vdd vdd sky130_fd_pr__pfet_01v8 W=4u L=1u

* NMOS cascode pair
M4 net1 nbias1 net3 vss sky130_fd_pr__nfet_01v8 W=2u L=0.5u
M5 net2 nbias1 net4 vss sky130_fd_pr__nfet_01v8 W=2u L=0.5u
M6 net3 nbias2 vss vss sky130_fd_pr__nfet_01v8 W=2u L=1u
M7 net4 nbias2 vss vss sky130_fd_pr__nfet_01v8 W=2u L=1u

* BJT pair
Q1 net3 net3 vss vss sky130_fd_pr__npn_05v5_W0p68L0p68 m=1
Q2 net4 net4 r1out vss sky130_fd_pr__npn_05v5_W0p68L0p68 m=8

* Resistors
R1 r1out vss 10k
R2 vref vss 20k

.ends bandgap
.end
