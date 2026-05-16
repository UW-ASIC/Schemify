* CMOS Inverter
.subckt inv in out vdd vss
M1 out in vdd vdd sky130_fd_pr__pfet_01v8 W=1u L=0.18u
M2 out in vss vss sky130_fd_pr__nfet_01v8 W=0.5u L=0.18u
.ends inv

V1 vdd 0 1.8
V2 in 0 PULSE(0 1.8 0 1n 1n 5n 10n)
X1 in out vdd 0 inv
.end
