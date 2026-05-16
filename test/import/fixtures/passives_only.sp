* Passive Network with Coupled Inductors
.subckt passive_net in out gnd
R1 in mid1 1k
R2 mid1 mid2 2.2k
R3 mid2 out 4.7k
C1 mid1 gnd 100p
C2 mid2 gnd 47p
C3 out gnd 10p
L1 in mid3 10u
L2 mid3 out 22u
K1 L1 L2 0.8
.ends passive_net
.end
