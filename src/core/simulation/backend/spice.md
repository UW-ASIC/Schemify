# Comprehensive Guide: Converting ngspice & Xyce Netlists to VACASK

> **VACASK** (Verilog-A Circuit AnalysiS Kernel) is a FOSS analog circuit simulator with
> Spectre-like netlist syntax, developed by Árpád Bűrmen at the University of Ljubljana.
>
> Repository: <https://codeberg.org/arpadbuermen/VACASK>

---

## Table of Contents

1. [Fundamental Philosophy Differences](#1-fundamental-philosophy-differences)
2. [General Syntax Rules](#2-general-syntax-rules)
3. [Comments and Title Lines](#3-comments-and-title-lines)
4. [Parameters and Expressions](#4-parameters-and-expressions)
5. [Include, Load, and Library Files](#5-include-load-and-library-files)
6. [Model Declarations](#6-model-declarations)
7. [Passive Components](#7-passive-components)
8. [Independent Sources](#8-independent-sources)
9. [Dependent / Controlled Sources](#9-dependent--controlled-sources)
10. [Semiconductor Devices](#10-semiconductor-devices)
11. [Subcircuits](#11-subcircuits)
12. [Global Nodes](#12-global-nodes)
13. [Initial Conditions and Nodesets](#13-initial-conditions-and-nodesets)
14. [Analyses](#14-analyses)
15. [Sweeps](#15-sweeps)
16. [Output / Print / Save](#16-output--print--save)
17. [Options / Simulator Settings](#17-options--simulator-settings)
18. [Control Blocks](#18-control-blocks)
19. [Elaborate and Topology Changes](#19-elaborate-and-topology-changes)
20. [Postprocessing and Embedded Scripts](#20-postprocessing-and-embedded-scripts)
21. [Harmonic Balance (Xyce / VACASK)](#21-harmonic-balance)
22. [Scale Factors and Units](#22-scale-factors-and-units)
23. [Mutual Inductance / Coupling](#23-mutual-inductance--coupling)
24. [Behavioral Sources / B-Sources](#24-behavioral-sources--b-sources)
25. [Unsupported / Not-Yet-Available Features](#25-unsupported--not-yet-available-features)
26. [Complete Conversion Examples](#26-complete-conversion-examples)
27. [Quick-Reference Cheat Sheet](#27-quick-reference-cheat-sheet)

---

## 1. Fundamental Philosophy Differences

### SPICE (ngspice / Xyce)

- Line-oriented, positional syntax inherited from 1970s punch-card era.
- Device type determined by the **first letter** of the instance name (R=resistor, C=capacitor, M=MOSFET, etc.).
- Directives begin with a **dot** (`.tran`, `.model`, `.subckt`).
- Case-**insensitive** for most things.
- Title line is always the first line and is treated as a comment.
- Continuation lines begin with `+`.
- The netlist **order matters** in some contexts (the title must be first; `.end` must be last).

### VACASK

- **Spectre-like** syntax: structured, keyword-driven, parenthesized node lists.
- Device type determined by a **model name or type keyword**, not by the instance name prefix.
- Directives are **plain keywords** (no dots): `model`, `subckt`, `include`, `load`, `analysis`, etc.
- Case-**sensitive** everywhere — instance names, node names, model names, parameters.
- **No title line** requirement; no `.end` terminator.
- Line continuation uses `\` at the end of a line (not `+`).
- **Order of definitions does not matter** — the netlist is fully parsed before elaboration.
- All circuit topology lives outside of `control ... endc`; analysis setup lives inside.
- The toplevel circuit is treated as just another subcircuit.

---

## 2. General Syntax Rules

### Instance Statement Structure

**ngspice / Xyce:**

```
<TypeLetter><Name> <node1> <node2> ... <value_or_model> [params]
```

**VACASK:**

```
<name> (<node1> <node2> ...) <model_or_type> [param=value ...]
```

The key structural change: nodes go in **parentheses** after the instance name, and the model/type follows the parenthesized node list.

### Line Continuation

| Feature        | ngspice / Xyce            | VACASK                     |
| -------------- | ------------------------- | -------------------------- |
| Continuation   | `+` at start of next line | `\` at end of current line |
| Inline comment | `$` (ngspice), `;` (Xyce) | `//` (C++-style)           |
| Line comment   | `*` at start of line      | `//` at start of line      |
| Block comment  | Not supported             | `/* ... */`                |

### Quoting

VACASK uses double quotes for string values: `type="pulse"`, `include "file.inc"`.

---

## 3. Comments and Title Lines

**ngspice / Xyce:**

```spice
My Circuit Title                    * First line is always a comment/title
* This is a comment
R1 n1 n2 1k                        $ inline comment (ngspice)
R1 n1 n2 1k                        ; inline comment (Xyce)
```

**VACASK:**

```
// My Circuit Title (optional, just a comment)
// This is a comment
r1 (n1 n2) resistor r=1k           // inline comment
/* This is a
   block comment */
```

**Key difference:** VACASK has no concept of a mandatory title line. The first line is parsed like any other. Comments use C/C++ style `//` and `/* */`.

---

## 4. Parameters and Expressions

### Parameter Declaration

**ngspice:**

```spice
.param vdd_val = 1.2
.param gm = {2*ids/vov}
```

**Xyce:**

```spice
.PARAM vdd_val = 1.2
.GLOBAL_PARAM gm = {2*ids/vov}
```

**VACASK:**

```
parameters vdd_val=1.2
parameters gm=2*ids/vov
```

Notes:

- VACASK uses `parameters` (plural) keyword.
- No curly braces needed around expressions.
- All Spectre built-in constants and functions are supported.
- Expressions are stored as RPN and evaluated with a stack-based VM.
- Parameter types supported: integer, real, string.
- Compound types: vector (all same type, comma-separated in brackets), list (mixed types, semicolon-separated).

### Expression Syntax Differences

| Feature         | ngspice / Xyce   | VACASK             |
| --------------- | ---------------- | ------------------ |
| Braces required | `{expression}`   | No braces needed   |
| Power operator  | `**`             | `**` or `pow(x,y)` |
| Ternary         | `{cond ? a : b}` | `cond ? a : b`     |
| String params   | Limited          | Full support       |

---

## 5. Include, Load, and Library Files

### Include

**ngspice / Xyce:**

```spice
.include "models.inc"
.inc "models.inc"
.INCLUDE "models.inc"
```

**VACASK:**

```
include "models.inc"
```

VACASK searches: (1) directory of the including netlist, (2) current working directory, (3) the include path set via `SIM_INCLUDE_PATH`.

### Loading Compiled Device Models (.osdi)

**ngspice:**

```spice
.control
pre_osdi bsim4.osdi
.endc
```

or (newer ngspice):

```spice
.osdi bsim4.osdi
```

**Xyce:** Does not use OSDI; uses built-in or ADMS-compiled models.

**VACASK:**

```
load "bsim4.osdi"
```

VACASK can also compile Verilog-A files on the fly:

```
load "mydevice.va"
```

The search order for `load` is: (1) directory of the netlist, (2) CWD, (3) `SIM_MODULE_PATH` (default: `<vacask_lib>/mod`).

### Library Sections

**ngspice / Xyce:**

```spice
.lib "models.lib" tt
* or
.lib "models.lib" section=tt
```

Inside the library file:

```spice
.lib tt
  .model nmos nmos ...
.endl tt
```

**VACASK:**

```
library "models.lib" section="tt"
```

Inside the library file:

```
section tt
  model nmos bsimbulk ...
endsection
```

---

## 6. Model Declarations

### Basic Model Statement

**ngspice:**

```spice
.model mydiode d (is=1e-14 n=1.05 rs=10)
.model nch nmos level=14 version=4.8.2 tnom=27 ...
```

**Xyce:**

```spice
.MODEL mydiode D (IS=1E-14 N=1.05 RS=10)
.MODEL nch NMOS LEVEL=14 VERSION=4.8.2 TNOM=27 ...
```

**VACASK:**

```
model mydiode diode is=1e-14 n=1.05 rs=10
model nch bsim4 tnom=27 ...
```

**Key differences:**

- No parentheses around parameters.
- No dot prefix.
- The device type uses the actual Verilog-A module name or built-in name (e.g., `diode`, `bsim4`, `bsimbulk`, `bsimcmg`, `psp103`, `hicum`, `vbic`), not a generic type letter or level number.
- There is no `level=` parameter — the model type itself determines the equations.
- Legacy SPICE3 devices (MOSFET L1-3, L6, L9, BSIM3, BSIM4, BJT Gummel-Poon, JFET, MESFET, diode) are available as converted Verilog-A models in VACASK's `devices/spice/` directory.

### Model Type Mapping

| ngspice/Xyce Type | Level   | VACASK Model Type (Verilog-A module) |
| ----------------- | ------- | ------------------------------------ |
| `d` (diode)       | 1       | `diode` or `diode_l1`                |
| `d` (diode)       | 3       | `diode_l3`                           |
| `nmos` / `pmos`   | 1       | `mos1`                               |
| `nmos` / `pmos`   | 2       | `mos2`                               |
| `nmos` / `pmos`   | 3       | `mos3`                               |
| `nmos` / `pmos`   | 6       | `mos6`                               |
| `nmos` / `pmos`   | 9       | `mos9`                               |
| `nmos` / `pmos`   | 8 / 49  | `bsim3`                              |
| `nmos` / `pmos`   | 14 / 54 | `bsim4`                              |
| `nmos` / `pmos`   | 72      | `bsimbulk`                           |
| `nmos` / `pmos`   | 73      | `bsimcmg` (FinFET)                   |
| `nmos` / `pmos`   | 74      | `bsimimg`                            |
| `nmos` / `pmos`   | 102/103 | `psp102` / `psp103`                  |
| `npn` / `pnp`     | 1       | `bjt` (Gummel-Poon)                  |
| `npn` / `pnp`     | (VBIC)  | `vbic`                               |
| `npn` / `pnp`     | (HICUM) | `hicuml2`                            |
| `njf` / `pjf`     | 1-2     | `jfet1` / `jfet2`                    |
| `nmf` / `pmf`     | 1       | `mesfet1`                            |
| R (resistor)      | —       | `resistor`                           |
| C (capacitor)     | —       | `capacitor`                          |
| L (inductor)      | —       | `inductor`                           |

### Model Variants

VACASK supports model "variants" from the Verilog-A Distiller. These include a default variant, an `sn` (simplified noise) variant, and a `full` variant. If a device doesn't have a particular variant, it defaults to the standard one.

---

## 7. Passive Components

### Resistor

**ngspice / Xyce:**

```spice
R1 net1 net2 1k
R2 a b r=10k tc1=0.01 tc2=0.001
Rvar a b {1k * scale_factor}
```

**VACASK:**

```
r1 (net1 net2) resistor r=1k
r2 (a b) resistor r=10k tc1=0.01 tc2=0.001
rvar (a b) resistor r=1k*scale_factor
```

**Note:** In VACASK, even simple passive values require `param=value` syntax. You cannot just write `r1 (n1 n2) resistor 1k` — it must be `r=1k`.

### Capacitor

**ngspice / Xyce:**

```spice
C1 net1 net2 10p
C2 a b 1n ic=0.5
```

**VACASK:**

```
c1 (net1 net2) capacitor c=10p
c2 (a b) capacitor c=1n ic=0.5
```

### Inductor

**ngspice / Xyce:**

```spice
L1 net1 net2 10u
L2 a b 1m ic=0.1
```

**VACASK:**

```
l1 (net1 net2) inductor l=10u
l2 (a b) inductor l=1m ic=0.1
```

---

## 8. Independent Sources

VACASK independent sources are **built-in devices**. You must declare their model type before use.

### Model Declarations for Sources

**VACASK** (put near top of netlist):

```
model vsrc vsource
model isrc isource
```

These are declared once and reused for all voltage/current source instances.

### DC Voltage Source

**ngspice / Xyce:**

```spice
Vdd vdd 0 1.2
V1 n1 n2 dc 3.3
```

**VACASK:**

```
vdd (vdd 0) vsrc dc=1.2
v1 (n1 n2) vsrc dc=3.3
```

### DC Current Source

**ngspice / Xyce:**

```spice
I1 n1 n2 1m
Ibias 0 n1 dc 100u
```

**VACASK:**

```
i1 (n1 n2) isrc dc=1m
ibias (0 n1) isrc dc=100u
```

### AC Source

**ngspice / Xyce:**

```spice
Vac in 0 dc 0 ac 1
Vac2 in 0 dc 0.6 ac 1 0          * ac mag=1, phase=0
```

**VACASK:**

```
vac (in 0) vsrc dc=0 ac=1
vac2 (in 0) vsrc dc=0.6 ac=1 acphase=0
```

### Pulse Source

**ngspice / Xyce:**

```spice
Vpulse in 0 pulse(0 1.2 1n 0.1n 0.1n 5n 10n)
*                   V1 V2 TD  TR    TF    PW  PER
```

**VACASK:**

```
vpulse (in 0) vsrc type="pulse" v0=0 v1=1.2 delay=1n rise=0.1n fall=0.1n width=5n period=10n
```

### Sinusoidal Source

**ngspice / Xyce:**

```spice
Vsin in 0 sin(0 1 1Meg 0 0)
*            VO VA  FREQ  TD THETA
```

**VACASK:**

```
vsin (in 0) vsrc type="sine" dc=0 ampl=1 freq=1Meg
```

or with the `sinephase` parameter for specifying all sine parameters:

```
vsin (in 0) vsrc dc=0 sinephase=(0, 1, 1Meg)
```

### PWL (Piecewise Linear) Source

**ngspice / Xyce:**

```spice
Vpwl in 0 pwl(0 0 1n 0 1.1n 1.2 5n 1.2 5.1n 0 10n 0)
```

**VACASK:**

```
vpwl (in 0) vsrc type="pwl" wave=[0, 0, 1n, 0, 1.1n, 1.2, 5n, 1.2, 5.1n, 0, 10n, 0]
```

### Exponential Source

**ngspice / Xyce:**

```spice
Vexp out 0 exp(0 1 1n 2n 3n 4n)
```

**VACASK:**

```
vexp (out 0) vsrc type="exp" v0=0 v1=1 td1=1n tau1=2n td2=3n tau2=4n
```

### Summary: Source Type Parameter Mapping

| ngspice/Xyce       | VACASK `type=`             | Key Parameter Renames                                  |
| ------------------ | -------------------------- | ------------------------------------------------------ |
| `pulse(...)`       | `"pulse"`                  | `v0`, `v1`, `delay`, `rise`, `fall`, `width`, `period` |
| `sin(...)`         | `"sine"`                   | `dc`, `ampl`, `freq` (or use `sinephase=()`)           |
| `pwl(...)`         | `"pwl"`                    | `wave=[t0,v0, t1,v1, ...]`                             |
| `exp(...)`         | `"exp"`                    | `v0`, `v1`, `td1`, `tau1`, `td2`, `tau2`               |
| `dc <val>`         | `dc=<val>`                 | —                                                      |
| `ac <mag> [phase]` | `ac=<mag> acphase=<phase>` | —                                                      |

---

## 9. Dependent / Controlled Sources

VACASK implements linear controlled sources as **built-in devices**.

### VCVS (Voltage-Controlled Voltage Source)

**ngspice / Xyce:**

```spice
E1 out 0 inp inm 100
* E<name> <n+> <n-> <nc+> <nc-> <gain>
```

**VACASK:**

```
model vcvs_type vcvs
e1 (out 0 inp inm) vcvs_type gain=100
```

### VCCS (Voltage-Controlled Current Source)

**ngspice / Xyce:**

```spice
G1 out 0 inp inm 1m
```

**VACASK:**

```
model vccs_type vccs
g1 (out 0 inp inm) vccs_type gain=1m
```

### CCVS (Current-Controlled Voltage Source)

**ngspice / Xyce:**

```spice
Vsense n1 n2 0
H1 out 0 Vsense 100
```

**VACASK:**
In VACASK, current-controlled sources use a sensing branch. The exact syntax depends on the builtin implementation. This maps to:

```
model ccvs_type ccvs
h1 (out 0 n1 n2) ccvs_type gain=100
```

### CCCS (Current-Controlled Current Source)

**ngspice / Xyce:**

```spice
Vsense n1 n2 0
F1 out 0 Vsense 5
```

**VACASK:**

```
model cccs_type cccs
f1 (out 0 n1 n2) cccs_type gain=5
```

**Note:** VACASK's controlled source builtins take the sensing nodes directly in the node list (4 terminals: output+, output−, sense+, sense−) instead of referencing a voltage source name as in SPICE.

---

## 10. Semiconductor Devices

### MOSFET

**ngspice:**

```spice
M1 drain gate source bulk nch w=10u l=0.18u ad=5p as=5p pd=22u ps=22u
```

**Xyce:**

```spice
M1 drain gate source bulk nch W=10U L=0.18U AD=5P AS=5P PD=22U PS=22U
```

**VACASK:**

```
m1 (drain gate source bulk) nch w=10u l=0.18u ad=5p as=5p pd=22u ps=22u
```

**Notes:**

- Node order is identical: drain, gate, source, bulk.
- The model name `nch` must match a previously declared `model nch bsim4 ...` or equivalent.
- VACASK is case-sensitive, so `nch` ≠ `NCH` ≠ `Nch`.
- The `$mfactor` parameter (Verilog-A multiplier) is automatically added by OpenVAF. VACASK allows `$` in parameter names; ngspice replaces `$` with `_`.

### Diode

**ngspice / Xyce:**

```spice
D1 anode cathode mydiode
D2 anode cathode mydiode area=2
```

**VACASK:**

```
d1 (anode cathode) mydiode
d2 (anode cathode) mydiode area=2
```

### BJT (Bipolar Junction Transistor)

**ngspice / Xyce:**

```spice
Q1 collector base emitter npnmod
Q2 collector base emitter substrate npnmod area=2
```

**VACASK:**

```
q1 (collector base emitter) npnmod
q2 (collector base emitter substrate) npnmod area=2
```

### JFET

**ngspice / Xyce:**

```spice
J1 drain gate source jmod
```

**VACASK:**

```
j1 (drain gate source) jmod
```

### MESFET

**ngspice / Xyce:**

```spice
Z1 drain gate source mesmod
```

**VACASK:**

```
z1 (drain gate source) mesmod
```

---

## 11. Subcircuits

### Definition

**ngspice / Xyce:**

```spice
.subckt inv in out vdd vss
.param w=10u l=0.2u fac=2
Mp out in vdd vdd pch w={w*fac} l=l
Mn out in vss vss nch w=w l=l
.ends inv
```

**VACASK:**

```
subckt inv(in out vdd vss)
  parameters w=10u l=0.2u fac=2
  mp (out in vdd vdd) pch w=w*fac l=l
  mn (out in vss vss) nch w=w l=l
ends
```

**Key differences:**

- Nodes go in **parentheses** after the subcircuit name.
- `parameters` replaces `.param`.
- `ends` replaces `.ends` (no subcircuit name needed after `ends`, though it can be added).
- No dot prefix on `subckt` or `ends`.

### Instantiation

**ngspice / Xyce:**

```spice
X1 in out vdd vss inv w=20u l=0.1u
```

**VACASK:**

```
x1 (in out vdd vss) inv w=20u l=0.1u
```

**Note:** The `X` prefix is conventional but not required in VACASK — the instance name can be anything since the device type is determined by the model/subcircuit name, not the prefix letter.

### Nested Subcircuits

Both ngspice/Xyce and VACASK support nested subcircuit definitions. The syntax follows the same pattern as above — just nest `subckt ... ends` blocks.

---

## 12. Global Nodes

**ngspice / Xyce:**

```spice
.global vdd vss
.GLOBAL VDD VSS
```

**VACASK:**

```
global vdd vss
```

**Note:** In VACASK, `0` is typically the ground reference node, same as in SPICE.

---

## 13. Initial Conditions and Nodesets

### Initial Conditions

**ngspice / Xyce:**

```spice
.ic v(out)=0.6 v(n1)=1.2
```

**VACASK** (Spectre style):

```
ic out=0.6 n1=1.2
```

Or (legacy SPICE3 style also supported):

```
ic v(out)=0.6 v(n1)=1.2
```

### Nodesets

**ngspice / Xyce:**

```spice
.nodeset v(out)=0.6
```

**VACASK:**

```
nodeset out=0.6
```

### Instance-Level IC

**ngspice / Xyce:**

```spice
C1 n1 0 1p ic=0.5
```

**VACASK:**

```
c1 (n1 0) capacitor c=1p ic=0.5
```

---

## 14. Analyses

VACASK analyses are **named instances** and live inside `control ... endc` blocks. This is fundamentally different from SPICE where analyses are dot-commands at the top level.

### Operating Point

**ngspice / Xyce:**

```spice
.op
```

**VACASK:**

```
control
  analysis op1 op
endc
```

### DC Sweep

**ngspice:**

```spice
.dc Vin 0 5 0.1
.dc Vin 0 5 0.1 Vdd 1.0 3.3 0.1    * nested sweep
```

**Xyce:**

```spice
.DC Vin 0 5 0.1
.DC Vin 0 5 0.1 Vdd 1.0 3.3 0.1
```

**VACASK:**

```
control
  sweep vinsweep instance="vin" parameter="dc" from=0 to=5 mode="lin" points=51
    analysis dc1 op
endc
```

Nested sweep:

```
control
  sweep vddsweep instance="vdd" parameter="dc" from=1.0 to=3.3 mode="lin" points=24
    sweep vinsweep instance="vin" parameter="dc" from=0 to=5 mode="lin" points=51
      analysis dc1 op
endc
```

**Note:** In VACASK, a DC sweep is actually a **sweep** of a parameter (like a source's DC value) with an **op** analysis at each point. There is no separate "dc" analysis type — it's a sweep wrapping an operating point.

### Parameter Sweep (not just sources)

VACASK can sweep **any** parameter, not just source values:

```
control
  sweep wsweep instance="m1" parameter="w" from=1u to=100u mode="lin" points=100
    analysis op1 op
endc
```

### Transient Analysis

**ngspice:**

```spice
.tran 1n 100n
.tran 1n 100n uic
.tran 0.1n 100n 0 0.1n
*      step  stop start maxstep
```

**Xyce:**

```spice
.TRAN 1n 100n
```

**VACASK:**

```
control
  analysis tran1 tran stop=100n
  analysis tran1 tran step=1n stop=100n
  analysis tran1 tran step=0.1n stop=100n maxstep=0.1n
endc
```

Transient with UIC (use initial conditions):

```
control
  analysis tran1 tran stop=100n uic=1
endc
```

### AC Analysis

**ngspice:**

```spice
.ac dec 100 1 1G
.ac lin 1000 1k 10k
.ac oct 10 1k 16k
```

**Xyce:**

```spice
.AC DEC 100 1 1G
```

**VACASK:**

```
control
  analysis ac1 ac start=1 stop=1G dec=100
  analysis ac1 ac start=1k stop=10k lin=1000
  analysis ac1 ac start=1k stop=16k oct=10
endc
```

### Noise Analysis

**ngspice:**

```spice
.noise v(out) Vin dec 100 1 1G
```

**Xyce:**

```spice
.NOISE V(out) Vin DEC 100 1 1G
```

**VACASK:**

```
control
  analysis noise1 noise output="out" source="vin" start=1 stop=1G dec=100
endc
```

### Transfer Function (TF)

**ngspice / Xyce:**

```spice
.tf v(out) Vin
```

**VACASK:**

```
control
  analysis xf1 xf output="out" source="vin" start=1 stop=1G dec=100
endc
```

(The transfer function in VACASK is computed as part of a frequency-domain analysis.)

---

## 15. Sweeps

VACASK has a powerful, unified sweep mechanism that can wrap any analysis. Sweeps can be nested to any depth.

### Sweep Syntax

```
sweep <sweep_name> instance="<inst>" parameter="<param>" \
    from=<start> to=<stop> mode="lin"|"log" points=<N>
  <analysis or nested sweep>
```

### Temperature Sweep

**ngspice:**

```spice
.temp 0 25 50 75 100
* or in .control block:
foreach temp_val 0 25 50 75 100
  set temp = $temp_val
  ...
end
```

**Xyce:**

```spice
.STEP TEMP LIST 0 25 50 75 100
```

**VACASK:**

```
control
  sweep tempsweep parameter="temp" values=[0, 25, 50, 75, 100]
    analysis op1 op
endc
```

Or for a linear temperature sweep:

```
control
  sweep tempsweep parameter="temp" from=-40 to=125 mode="lin" points=34
    analysis op1 op
endc
```

### Component Parameter Sweep

**Xyce:**

```spice
.STEP R1:R 1k 10k 1k
```

**VACASK:**

```
control
  sweep rsweep instance="r1" parameter="r" from=1k to=10k mode="lin" points=10
    analysis op1 op
endc
```

---

## 16. Output / Print / Save

### Saving and Printing Results

**ngspice:**

```spice
.save v(out) i(Vdd)
.print tran v(out) v(inp) v(inm)
.control
  run
  plot v(out) vs v(inp)
  wrdata output.csv v(out) v(inp)
.endc
```

**Xyce:**

```spice
.PRINT TRAN v(out) i(Vdd)
.PRINT DC v(out) {v(inp)-v(inm)}
```

**VACASK:**

```
control
  analysis tran1 tran stop=100n
  // Results are automatically saved to .raw files
  // Use postprocessing for custom output
  postprocess(PYTHON, "plot.py")
endc
```

VACASK writes simulation results to **binary `.raw` files** by default. Python scripts using the supplied `rawread` module can load and plot them.

### Print Command

VACASK has a `print` command for outputting specific values:

```
control
  analysis op1 op
  print op1 "out" "inp"
endc
```

---

## 17. Options / Simulator Settings

### Solver Options

**ngspice:**

```spice
.options reltol=1e-3 abstol=1e-12 vntol=1e-6 gmin=1e-12
.options method=gear maxord=2
.options itl1=200 itl2=100 itl4=50
```

**Xyce:**

```spice
.OPTIONS DEVICE GMIN=1E-12
.OPTIONS TIMEINT RELTOL=1E-3 ABSTOL=1E-12
.OPTIONS NONLIN MAXSTEP=200
```

**VACASK:**
VACASK options are set within the `control` block or as analysis parameters:

```
control
  options reltol=1e-3 abstol=1e-12 vntol=1e-6 gmin=1e-12
  options method="trap"    // "trap", "euler", "gear2"
endc
```

### Integration Method Mapping

| ngspice/Xyce                | VACASK                                |
| --------------------------- | ------------------------------------- |
| `method=trap` / Trapezoidal | `method="trap"`                       |
| `method=gear`               | `method="gear2"` (or `"gear3"`, etc.) |
| Backward Euler              | `method="euler"`                      |

### Homotopy / Convergence Aids

**ngspice:**

```spice
.options gminstepping=1
.options srcstepping=1
```

**Xyce:**

```spice
.OPTIONS NONLIN CONTINUATION=GMIN
.OPTIONS NONLIN CONTINUATION=SOURCE
```

**VACASK:**
VACASK supports homotopy algorithms including gmin stepping and source stepping. These are configured via options in the control block:

```
control
  options homotopy="gmin"    // or "source"
endc
```

---

## 18. Control Blocks

VACASK uses `control ... endc` blocks to separate simulation setup from circuit definition. This is conceptually similar to ngspice's `.control ... .endc` but structurally different.

**ngspice:**

```spice
* Circuit definition ...
.control
  run
  plot v(out)
  meas tran trise find v(out) when v(out)=0.6 rise=1
.endc
.end
```

**VACASK:**

```
// Circuit definition ...

control
  elaborate circuit("mytop")
  analysis op1 op
  analysis tran1 tran stop=100n
  postprocess(PYTHON, "analyze.py")
endc
```

**Key differences:**

- `elaborate` replaces the implicit circuit instantiation in SPICE.
- No `run` command — analyses are executed in the order they appear.
- No `.end` terminator.
- `postprocess` replaces `.meas` and plot commands by calling external scripts.

---

## 19. Elaborate and Topology Changes

This is a unique VACASK feature with no direct SPICE equivalent.

### Basic Elaboration

The toplevel circuit is treated as a subcircuit in VACASK. You must explicitly elaborate it:

```
subckt mytop()
  vdd (vdd 0) vsrc dc=1.2
  m1 (out in vdd vdd) pch w=10u l=0.2u
  m2 (out in 0 0) nch w=5u l=0.2u
ends

control
  elaborate circuit("mytop")
  analysis op1 op
endc
```

### Multiple Topologies in One Run

VACASK can re-elaborate with different subcircuits between analyses:

```
subckt ring()
  x1 (1 2 vdd 0) inv
  x2 (2 3 vdd 0) inv
  x3 (3 1 vdd 0) inv
ends

subckt start()
  ipulse (0 1) isrc type="pulse" v0=0 v1=1u delay=1n rise=1n fall=1n width=1n
ends

control
  elaborate circuit("ring", "start")     // ring oscillator WITH startup pulse
  analysis tran1 tran step=0.05n stop=1u

  elaborate circuit("ring")              // ring oscillator WITHOUT startup pulse
  analysis tran2 tran step=0.05n stop=1u
endc
```

### Altering Parameters Without Re-elaboration

```
control
  elaborate circuit("mytop")
  analysis op1 op

  alter instance="vdd" parameter="dc" value=3.3
  analysis op2 op
endc
```

---

## 20. Postprocessing and Embedded Scripts

### Postprocessing

**ngspice** uses built-in commands (`plot`, `meas`, `wrdata`, `let`, etc.) inside `.control` blocks.

**Xyce** uses `.MEASURE` statements and outputs to files.

**VACASK** delegates postprocessing to **Python** scripts:

```
control
  analysis tran1 tran stop=100n
  postprocess(PYTHON, "plot_results.py")
endc
```

### Embedded Scripts

VACASK can embed scripts directly in the netlist file:

```
control
  analysis tran1 tran stop=1u
  postprocess(PYTHON, "runme.py")
endc

embed "runme.py" <<<FILE
from rawfile import rawread
import numpy as np
import matplotlib.pyplot as plt

data = rawread('tran1.raw').get()
t = data["time"]
vout = data["out"]

plt.plot(t * 1e9, vout)
plt.xlabel("Time [ns]")
plt.ylabel("V(out)")
plt.show()
>>>FILE
```

The `rawread` module is supplied with VACASK and can load the binary `.raw` output files. It depends on NumPy.

### Environment Variables for Python

VACASK supplements `PYTHONPATH` with its own Python scripts directory. The Python interpreter path can be set via the `SIM_PYTHON` environment variable.

---

## 21. Harmonic Balance

### Xyce

```spice
.HB 1MHz 10MHz
.OPTIONS HBINT NUMFREQ=3
.PRINT HB_FD V(out) I(R1)
```

### VACASK

VACASK supports multi-tone harmonic balance analysis:

```
control
  elaborate circuit("mixer")
  analysis hb1 hb freq=[50k, 1.01k] sidebands=3
endc
```

This is a unique strength of VACASK — harmonic balance for RF circuits like mixers and demodulators is a first-class feature.

**ngspice** does not natively support harmonic balance analysis.

---

## 22. Scale Factors and Units

VACASK uses **SI scale factors** (like Spectre), which differ from SPICE in one critical way:

| Factor     | SI (VACASK/Spectre) | SPICE (ngspice/Xyce) |
| ---------- | ------------------- | -------------------- |
| `T`        | 10^12               | 10^12                |
| `G`        | 10^9                | 10^9                 |
| `M`        | **10^6** (Mega)     | **10^-3** (milli!)   |
| `K` or `k` | 10^3                | 10^3                 |
| `m`        | 10^-3               | 10^-3                |
| `u`        | 10^-6               | 10^-6                |
| `n`        | 10^-9               | 10^-9                |
| `p`        | 10^-12              | 10^-12               |
| `f`        | 10^-15              | 10^-15               |
| `a`        | 10^-18              | 10^-18               |
| `MEG`      | —                   | 10^6                 |

**Critical:** In SPICE, both `m` and `M` mean 10^-3 (milli), and `MEG` means 10^6.
In VACASK/Spectre, `M` means 10^6 (Mega) and `m` means 10^-3 (milli).

**When converting:** Any SPICE value using `M` as milli must be changed to `m`. Any SPICE value using `MEG` must be changed to `M`.

Examples:

- ngspice `1MEG` → VACASK `1M`
- ngspice `10M` (meaning 10 milli) → VACASK `10m`
- ngspice `2.2M` (meaning 2.2 milli) → VACASK `2.2m`

---

## 23. Mutual Inductance / Coupling

### Transformer / Coupled Inductors

**ngspice / Xyce:**

```spice
L1 n1 n2 10u
L2 n3 n4 10u
K1 L1 L2 0.99
```

**VACASK:**
VACASK implements inductive coupling as a builtin device:

```
model coupling_type mutual_inductor
l1 (n1 n2) inductor l=10u
l2 (n3 n4) inductor l=10u
k1 coupling_type ind1="l1" ind2="l2" k=0.99
```

(The exact syntax may vary — consult the VACASK documentation for the current implementation of the `mutual_inductor` builtin.)

---

## 24. Behavioral Sources / B-Sources

### ngspice B-source

**ngspice:**

```spice
B1 out 0 V = v(inp) * 2 + 0.5
B2 out 0 I = v(ctrl) * 1m
```

**Xyce:**

```spice
B1 out 0 V = {V(inp) * 2 + 0.5}
```

### VACASK Equivalent

VACASK does not have a built-in behavioral source equivalent to SPICE's B-source. The recommended approach is to:

1. **Write a Verilog-A module** that implements the desired behavior.
2. **Compile it** with OpenVAF.
3. **Load it** with `load "mybehavioral.osdi"`.

Example Verilog-A for a simple voltage-mode behavioral source:

```verilog
`include "disciplines.vams"
module mybsource(out, ref, inp, inm);
  inout out, ref, inp, inm;
  electrical out, ref, inp, inm;
  analog begin
    V(out, ref) <+ V(inp, inm) * 2 + 0.5;
  end
endmodule
```

This is more verbose but gives you full control and optimized compiled code.

---

## 25. Unsupported / Not-Yet-Available Features

The following ngspice/Xyce features do not have direct VACASK equivalents as of 2026:

| Feature                    | ngspice/Xyce                | VACASK Status             |
| -------------------------- | --------------------------- | ------------------------- |
| `.measure` / `.meas`       | Built-in measurement        | Use Python postprocessing |
| B-source (behavioral)      | `.bsource` / `B` element    | Write Verilog-A module    |
| Digital simulation         | XSPICE code models          | Not supported             |
| `.four` (Fourier)          | Built-in FFT                | Use Python (NumPy FFT)    |
| `.sens` (sensitivity)      | Built-in                    | Not yet implemented       |
| `.pz` (pole-zero)          | Built-in                    | Not yet implemented       |
| `.disto` (distortion)      | Built-in                    | Not yet implemented       |
| S-parameter analysis       | Xyce `.LIN`                 | Planned (roadmap)         |
| Monte Carlo                | `.mc` / `.step` with random | Use Python scripting      |
| BSIMSOI models             | Built-in                    | TODO (conversion planned) |
| Transmission lines (TLINE) | `T`, `U` elements           | Not yet available         |
| XSPICE models              | `A` element + code models   | Not supported             |
| Subcircuit multiplier `m=` | Automatic                   | Use `$mfactor` parameter  |
| `.save` / `.probe`         | Save specific signals       | All signals saved to .raw |

---

## 26. Complete Conversion Examples

### Example 1: Simple CMOS Inverter

**ngspice:**

```spice
CMOS Inverter
.include "models.inc"

.param vdd_val=1.2

Vdd vdd 0 dc {vdd_val}
Vin in 0 pulse(0 {vdd_val} 1n 0.1n 0.1n 5n 10n)

M1 out in vdd vdd pch w=20u l=0.18u
M2 out in 0 0 nch w=10u l=0.18u
Cl out 0 100f

.tran 0.01n 20n

.control
  run
  plot v(out) v(in)
.endc
.end
```

**VACASK:**

```
// CMOS Inverter
include "models.inc"

model vsrc vsource

parameters vdd_val=1.2

vdd (vdd 0) vsrc dc=vdd_val
vin (in 0) vsrc type="pulse" v0=0 v1=vdd_val delay=1n rise=0.1n fall=0.1n width=5n period=10n

subckt inverter()
  m1 (out in vdd vdd) pch w=20u l=0.18u
  m2 (out in 0 0) nch w=10u l=0.18u
  cl (out 0) capacitor c=100f
ends

control
  elaborate circuit("inverter")
  analysis tran1 tran step=0.01n stop=20n
  postprocess(PYTHON, "plot_inv.py")
endc

embed "plot_inv.py" <<<FILE
from rawfile import rawread
import matplotlib.pyplot as plt

data = rawread('tran1.raw').get()
t = data["time"]
plt.plot(t*1e9, data["out"], label="V(out)")
plt.plot(t*1e9, data["in"], label="V(in)")
plt.xlabel("Time [ns]")
plt.legend()
plt.show()
>>>FILE
```

### Example 2: 5-Transistor OTA with DC Sweep

**ngspice:**

```spice
5-Transistor OTA
.include "cmos_models.inc"

.param ibias=10u

Vdd vdd 0 dc 1.8
Vss vss 0 dc -1.8
Vip inp 0 dc 0 ac 1
Vim inm 0 dc 0 ac -1
Ibias vdd nbias dc {ibias}

M1 out1 inp ntail vss nch w=10u l=1u
M2 out2 inm ntail vss nch w=10u l=1u
M3 out1 out1 vdd vdd pch w=20u l=1u
M4 out2 out1 vdd vdd pch w=20u l=1u
M5 ntail nbias vss vss nch w=10u l=1u

.dc Vip -0.5 0.5 0.01
.ac dec 100 1 1G

.control
  run
.endc
.end
```

**VACASK:**

```
// 5-Transistor OTA
include "cmos_models.inc"

model vsrc vsource
model isrc isource

parameters ibias=10u

vdd (vdd 0) vsrc dc=1.8
vss (vss 0) vsrc dc=-1.8
vip (inp 0) vsrc dc=0 ac=1
vim (inm 0) vsrc dc=0 ac=-1
ibias_src (vdd nbias) isrc dc=ibias

subckt ota()
  m1 (out1 inp ntail vss) nch w=10u l=1u
  m2 (out2 inm ntail vss) nch w=10u l=1u
  m3 (out1 out1 vdd vdd) pch w=20u l=1u
  m4 (out2 out1 vdd vdd) pch w=20u l=1u
  m5 (ntail nbias vss vss) nch w=10u l=1u
ends

control
  elaborate circuit("ota")

  // DC sweep
  sweep vipsweep instance="vip" parameter="dc" from=-0.5 to=0.5 mode="lin" points=101
    analysis dc1 op

  // AC analysis
  analysis ac1 ac start=1 stop=1G dec=100
endc
```

### Example 3: Ring Oscillator (from VACASK MIDEM 2025)

**ngspice:**

```spice
Ring Oscillator
.osdi psp103v4.osdi
.include "cmos_models.inc"

.subckt inv in out vdd vss
.param w=10u l=0.2u fac=2
Mp out in vdd vdd pmos w='w*fac' l=l
Mn out in vss vss nmos w=w l=l
.ends

Vdd vdd 0 dc 1.2
Ipulse 0 1 pulse(0 1u 1n 1n 1n 1n 10n)
X1 1 2 vdd 0 inv
X2 2 3 vdd 0 inv
X3 3 1 vdd 0 inv

.tran 0.05n 1u

.control
  run
  plot v(1)
.endc
.end
```

**VACASK:**

```
load "psp103v4.osdi"
include "cmos_models.inc"

model isrc isource
model vsrc vsource

subckt inv(in out vdd vss)
  parameters w=10u l=0.2u fac=2
  mp (out in vdd vdd) pmos w=w*fac l=l
  mn (out in vss vss) nmos w=w l=l
ends

vdd (vdd 0) vsrc dc=1.2

subckt ring()
  x1 (1 2 vdd 0) inv
  x2 (2 3 vdd 0) inv
  x3 (3 1 vdd 0) inv
ends

subckt start()
  ipulse (0 1) isrc type="pulse" v0=0 v1=1u delay=1n rise=1n fall=1n width=1n
ends

control
  elaborate circuit("ring", "start")
  analysis tran1 tran step=0.05n stop=1u maxstep=0.05n
endc
```

---

## 27. Quick-Reference Cheat Sheet

| ngspice / Xyce       | VACASK                                                                       | Notes                      |
| -------------------- | ---------------------------------------------------------------------------- | -------------------------- |
| `* comment`          | `// comment`                                                                 | Also supports `/* */`      |
| `+ continuation`     | `\ ` (backslash at EOL)                                                      |                            |
| `.param x=1`         | `parameters x=1`                                                             |                            |
| `.include "f"`       | `include "f"`                                                                |                            |
| `.lib "f" sec`       | `library "f" section="sec"`                                                  |                            |
| `.osdi model.osdi`   | `load "model.osdi"`                                                          | Also accepts `.va` files   |
| `.model n nmos ...`  | `model n bsim4 ...`                                                          | Use actual VA module name  |
| `.subckt n a b`      | `subckt n(a b)`                                                              | Nodes in parens            |
| `.ends n`            | `ends`                                                                       | Name optional              |
| `.global vdd`        | `global vdd`                                                                 |                            |
| `.ic v(n)=1`         | `ic n=1`                                                                     |                            |
| `.nodeset v(n)=1`    | `nodeset n=1`                                                                |                            |
| `R1 a b 1k`          | `r1 (a b) resistor r=1k`                                                     |                            |
| `C1 a b 1p`          | `c1 (a b) capacitor c=1p`                                                    |                            |
| `L1 a b 1u`          | `l1 (a b) inductor l=1u`                                                     |                            |
| `V1 a b dc 1.2`      | `v1 (a b) vsrc dc=1.2`                                                       | Needs `model vsrc vsource` |
| `I1 a b 1m`          | `i1 (a b) isrc dc=1m`                                                        | Needs `model isrc isource` |
| `M1 d g s b mod ...` | `m1 (d g s b) mod ...`                                                       |                            |
| `D1 a k mod`         | `d1 (a k) mod`                                                               |                            |
| `Q1 c b e mod`       | `q1 (c b e) mod`                                                             |                            |
| `X1 a b sub`         | `x1 (a b) sub`                                                               |                            |
| `E1 o r i+ i- g`     | `e1 (o r i+ i-) vcvs_t gain=g`                                               | Needs model declaration    |
| `.op`                | `analysis op1 op`                                                            | Inside `control ... endc`  |
| `.tran ts tstop`     | `analysis t1 tran stop=tstop`                                                | Inside `control ... endc`  |
| `.ac dec N f1 f2`    | `analysis a1 ac start=f1 stop=f2 dec=N`                                      | Inside `control ... endc`  |
| `.dc V 0 5 0.1`      | `sweep s instance="v" parameter="dc" from=0 to=5 ...` then `analysis op1 op` |                            |
| `.noise v(o) V ...`  | `analysis n1 noise output="o" source="v" ...`                                | Inside `control ... endc`  |
| `.meas`              | Python postprocessing                                                        |                            |
| `.end`               | (not needed)                                                                 |                            |
| `M` = 10^-3          | `M` = 10^6                                                                   | **Critical difference!**   |
| `MEG` = 10^6         | `M` = 10^6                                                                   |                            |

---

## Notes and Caveats

1. **VACASK is under active development.** Some features described here may change. Always check the latest documentation and demo files at the Codeberg repository.

2. **Xschem integration** is being developed with a dedicated Spectre/VACASK netlist backend. If you use xschem for schematic entry, this will eventually automate much of the conversion.

3. **The IHP SG13G2 open PDK** has VACASK support. See `demo/ihp-sg13g2/` in the VACASK repository.

4. **Verilog-A Distiller** (VADistiller) can convert SPICE3 device model C code into Verilog-A code. This is how legacy device models were ported to VACASK. It is a separate tool at <https://codeberg.org/arpadbuermen/VADistiller>.

5. **OpenVAF-reloaded** is the required Verilog-A compiler. Get the latest OSDI 0.4 version from <https://fides.fe.uni-lj.si/openvaf/download/> or build from source at <https://github.com/arpadbuermen/OpenVAF>.

6. **Binary `.raw` file output** can be read with the Python `rawfile` module supplied with VACASK. It depends on NumPy.

7. **No `.end` needed.** Unlike SPICE, VACASK does not require a terminating directive.

8. **Case sensitivity matters.** `VDD` and `vdd` are different nodes in VACASK. Be consistent.

---

_This guide was compiled from VACASK repository documentation, the MIDEM 2025 presentation, the FSiC 2024 paper, the xschem Discussion #370 (StefanSchippers/xschem), and the FOSDEM 2025 talk materials. For the latest and most authoritative information, always refer to the VACASK repository and its demo files._
