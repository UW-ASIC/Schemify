* Five-Transistor OTA
.subckt ota inp inn out vdd vss
M1 net1 inp net3 vss sky130_fd_pr__nfet_01v8 W=2u L=0.5u
M2 out inn net3 vss sky130_fd_pr__nfet_01v8 W=2u L=0.5u
M3 net1 net1 vdd vdd sky130_fd_pr__pfet_01v8 W=4u L=0.5u
M4 out net1 vdd vdd sky130_fd_pr__pfet_01v8 W=4u L=0.5u
M5 net3 vbias vss vss sky130_fd_pr__nfet_01v8 W=4u L=1u
.ends ota
.end
