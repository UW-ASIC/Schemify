* Parameter and Model Test
.param vdd_val=1.8 vth_n=0.4
.param gm_target='50u' $ target transconductance
.model NMOD nmos
+ LEVEL=1 VTO=0.7 KP=110u
+ GAMMA=0.4 PHI=0.65
.model PMOD pmos
+ LEVEL=1 VTO=-0.7 KP=50u
+ GAMMA=0.57 PHI=0.65

.subckt amp_stage in out vdd vss
M1 out in net1 vss NMOD W=10u L=1u $ input transistor
M2 out out vdd vdd PMOD W=20u L=1u ; diode load
R1 net1 vss 500
.ends amp_stage

V1 vdd 0 vdd_val
V2 in 0 AC=1 DC=0.9
X1 in out vdd 0 amp_stage
.end
