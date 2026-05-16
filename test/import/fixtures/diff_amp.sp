* Differential Amplifier with Current Mirror Load
.param W_diff=2u L_diff=0.5u W_mir=4u L_mir=0.5u W_tail=4u L_tail=1u

.subckt diff_amp inp inn out vdd vss
* Differential pair
M1 net1 inp tail vss sky130_fd_pr__nfet_01v8 W=W_diff L=L_diff
M2 net2 inn tail vss sky130_fd_pr__nfet_01v8 W=W_diff L=L_diff

* PMOS current mirror load
M3 net1 net1 vdd vdd sky130_fd_pr__pfet_01v8 W=W_mir L=L_mir
M4 net2 net1 vdd vdd sky130_fd_pr__pfet_01v8 W=W_mir L=L_mir

* Tail current source
M5 tail vbias vss vss sky130_fd_pr__nfet_01v8 W=W_tail L=L_tail
.ends diff_amp

* Testbench
V1 vdd 0 1.8
V2 vbias 0 0.6
V3 inp 0 0.9
V4 inn 0 0.9
X1 inp inn out vdd 0 diff_amp
.end
