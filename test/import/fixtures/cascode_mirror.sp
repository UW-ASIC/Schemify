* Cascode Current Mirror — GF180MCU PDK
.subckt cascode_mirror iref iout vdd vss
* Bottom pair — basic mirror
M1 net1 net1 vss vss gf180mcu_fd_pr__nfet_03v3 W=5u L=1u
M2 net2 net1 vss vss gf180mcu_fd_pr__nfet_03v3 W=5u L=1u

* Top pair — cascode devices
M3 iref net3 net1 vss gf180mcu_fd_pr__nfet_03v3 W=5u L=1u
M4 iout net3 net2 vss gf180mcu_fd_pr__nfet_03v3 W=5u L=1u

* Cascode bias (diode-connected)
R1 vdd net3 10k
.ends cascode_mirror
.end
