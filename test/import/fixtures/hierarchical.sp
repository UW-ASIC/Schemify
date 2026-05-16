* Hierarchical Netlist — NAND2 from Inverters
.subckt inv in out vdd vss
M1 out in vdd vdd sky130_fd_pr__pfet_01v8 W=1u L=0.18u
M2 out in vss vss sky130_fd_pr__nfet_01v8 W=0.5u L=0.18u
.ends inv

.subckt nand2 a b y vdd vss
* Pull-up network
M1 y a vdd vdd sky130_fd_pr__pfet_01v8 W=2u L=0.18u
M2 y b vdd vdd sky130_fd_pr__pfet_01v8 W=2u L=0.18u

* Pull-down stack
M3 y a mid vss sky130_fd_pr__nfet_01v8 W=1u L=0.18u
M4 mid b vss vss sky130_fd_pr__nfet_01v8 W=1u L=0.18u
.ends nand2

.subckt nand2_buf a b y vdd vss
X1 a b nand_out vdd vss nand2
X2 nand_out y vdd vss inv
.ends nand2_buf

* Top-level testbench
V1 vdd 0 1.8
V2 a 0 PULSE(0 1.8 0 1n 1n 5n 10n)
V3 b 0 PULSE(0 1.8 0 1n 1n 10n 20n)
X1 a b y vdd 0 nand2_buf
.end
