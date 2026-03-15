# Built-in SPICE Components Reference

> Complete list of devices built into the NGSpice and Xyce simulator engines.
> These require **no** `.include` or `.lib` — they are part of the simulator binary itself.

---

## 1. Value-Only Components (No `.model` Needed)

These work with just a name, nodes, and a value.

### Resistor — `R`

```spice
R<name> <n+> <n-> <value> [m=<mult>] [tc1=<coeff> tc2=<coeff>]
```

```spice
R1 in out 10k
R2 a b 4.7k m=2          * 2 resistors in parallel → effective 2.35k
R3 a b {Rval}             * parameterized
R4 a b R='1k * (1 + V(ctrl))'   * behavioral (ngspice)
```

| Feature | NGSpice | Xyce |
|---------|---------|------|
| Basic resistance | ✅ | ✅ |
| Multiplier `m` | ✅ | ✅ (R, L, C only) |
| Temp coefficients `tc1`/`tc2` | ✅ | ✅ |
| Semiconductor model | ✅ (`.model R`) | ✅ (Level 1, 2, Thermal) |
| Behavioral `R=expr` | ✅ | ✅ |

---

### Capacitor — `C`

```spice
C<name> <n+> <n-> <value> [ic=<initial_voltage>] [m=<mult>]
```

```spice
C1 out 0 1p
C2 a b 100n ic=0
CL out GND 5p m=1
```

| Feature | NGSpice | Xyce |
|---------|---------|------|
| Basic capacitance | ✅ | ✅ |
| Initial condition `ic` | ✅ | ✅ |
| Semiconductor model | ✅ | ✅ (+ age-aware) |
| Behavioral `C=f(V)` | ✅ | ✅ |

---

### Inductor — `L`

```spice
L<name> <n+> <n-> <value> [ic=<initial_current>]
```

```spice
L1 in out 10u
L2 a b 1m ic=0
```

| Feature | NGSpice | Xyce |
|---------|---------|------|
| Basic inductance | ✅ | ✅ |
| Initial condition `ic` | ✅ | ✅ |
| Nonlinear mutual | ✅ | ✅ |

---

### Mutual Inductor (Coupling) — `K`

```spice
K<name> <L1> <L2> <coupling_coefficient>
```

```spice
L1 a 0 10u
L2 b 0 10u
K1 L1 L2 0.99               * transformer with k=0.99
```

---

### Voltage Source — `V`

```spice
V<name> <n+> <n-> [DC <val>] [AC <mag> [<phase>]] [<waveform>]
```

```spice
V1 vdd 0 DC 1.8
V2 in  0 AC 1                                        * AC stimulus
V3 clk 0 PULSE(0 1.8 0 100p 100p 500n 1u)            * clock
V4 sig 0 SIN(0.9 0.5 1MEG)                           * sine wave
V5 ramp 0 PWL(0 0 1u 1.8 2u 0)                       * ramp
V_meas a b 0                                          * 0V probe for current
```

> [!TIP]
> A 0V source is the standard way to **measure current** through a branch.
> Access the current as `I(V_meas)` in `.print`, `.meas`, or `.control`.

**Available Waveforms:** `DC`, `AC`, `PULSE`, `SIN`, `PWL`, `EXP`, `SFFM`, `PAT`

See [spice.docs.md → §3](file:///home/omare/Documents/UWASIC/Schemify/docs/spice.docs.md) for waveform parameter details.

---

### Current Source — `I`

```spice
I<name> <n+> <n-> [DC <val>] [AC <mag> [<phase>]] [<waveform>]
```

```spice
I0 vdd bias DC 10u
I1 0 in PULSE(0 1m 0 1n 1n 500n 1u)
```

Same waveforms as voltage sources.

---

### Behavioral Source — `B`

Arbitrary voltage or current defined by an expression:

```spice
B<name> <n+> <n-> V={<expression>}     * voltage
B<name> <n+> <n-> I={<expression>}     * current
```

```spice
B1 out 0 V={if(V(in) > 0.9, 1.8, 0)}        * comparator
B2 out 0 I={V(ctrl) * 1m}                     * voltage-controlled current
B3 out 0 V={V(a) * V(b)}                      * multiplier
B4 out 0 V={table(V(in), 0, 0, 0.5, 1, 1, 1.8)}  * lookup table
```

| Feature | NGSpice | Xyce |
|---------|---------|------|
| `V={}` | ✅ | ✅ |
| `I={}` | ✅ | ✅ |
| `table()` | ✅ | ✅ |
| `if()` → `ternary_fcn` / `IF` | ✅ | ✅ |
| Time-dependent `V={sin(2*pi*1e6*TIME)}` | ✅ | ✅ |

---

### Dependent Sources — `E`, `F`, `G`, `H`

Linear controlled sources — no `.model` needed:

| Prefix | Type | Syntax | Control |
|--------|------|--------|---------|
| `E` | VCVS | `E1 out 0 ctrl+ ctrl- <gain>` | Voltage → Voltage |
| `F` | CCCS | `F1 out 0 Vsense <gain>` | Current → Current |
| `G` | VCCS | `G1 out 0 ctrl+ ctrl- <gm>` | Voltage → Current |
| `H` | CCVS | `H1 out 0 Vsense <rm>` | Current → Voltage |

```spice
E_amp out 0 in 0 100              * ×100 voltage amplifier
G_gm  out 0 in 0 1m               * 1mS transconductance
F_mirror out 0 V_sense 1           * current mirror (1:1)
H_tia out 0 V_sense 10k            * transimpedance amp
```

> [!NOTE]
> `F` and `H` sources measure current through a **voltage source** (the `Vsense` argument).
> You must place a 0V source in the branch you want to sense.

Xyce also supports PSpice-style `VALUE={}` extensions on E and G sources.

---

### Transmission Lines — `T`, `O`

```spice
* Lossless
T1 port1+ port1- port2+ port2- Z0=50 TD=1n

* Lossy (LTRA)  — requires .model
O1 port1+ port1- port2+ port2- ltra_model
.model ltra_model LTRA R=0.1 L=0.25u C=100p LEN=1
```

| Feature | NGSpice | Xyce |
|---------|---------|------|
| Lossless `T` | ✅ | ✅ |
| Lossy `O` (LTRA) | ✅ | ✅ |

---

## 2. Devices Requiring `.model` (But No `.include`)

These need a `.model` card to define their behavior, but the **equation engine is built into the simulator**. You write the `.model` yourself — no external file needed.

### Diode — `D`

```spice
D<name> <anode> <cathode> <model_name> [area=<val>] [m=<mult>]
.model <model_name> D [parameters...]
```

```spice
D1 anode cathode MyDiode
.model MyDiode D IS=1e-14 N=1.05 BV=100 RS=10
```

| Parameter | Description | Default |
|-----------|-------------|---------|
| `IS` | Saturation current | 1e-14 A |
| `N` | Emission coefficient | 1 |
| `RS` | Series resistance | 0 Ω |
| `BV` | Reverse breakdown voltage | ∞ |
| `CJ0` | Zero-bias junction capacitance | 0 F |
| `TT` | Transit time | 0 s |
| `VJ` | Junction potential | 1 V |
| `M` | Grading coefficient | 0.5 |

| Level | NGSpice | Xyce |
|-------|---------|------|
| Level 1 (Junction) | ✅ | ✅ |
| Level 2 | ❌ | ✅ |
| Level 3 (Tunnel) | ✅ | ❌ |

---

### BJT — `Q`

```spice
Q<name> <collector> <base> <emitter> [substrate] <model_name> [area=<val>] [m=<mult>]
.model <model_name> NPN|PNP [parameters...]
```

```spice
Q1 out in 0 NPN_basic
.model NPN_basic NPN IS=1e-15 BF=200 VAF=100 TF=0.3n CJE=20f
```

| Parameter | Description | Default |
|-----------|-------------|---------|
| `IS` | Saturation current | 1e-16 A |
| `BF` | Forward current gain (β) | 100 |
| `BR` | Reverse current gain | 1 |
| `VAF` | Forward Early voltage | ∞ |
| `TF` | Forward transit time | 0 s |
| `CJE` | B-E junction capacitance | 0 F |
| `CJC` | B-C junction capacitance | 0 F |
| `RB` | Base resistance | 0 Ω |

| Level / Model | NGSpice | Xyce |
|---------------|---------|------|
| Level 1 (Ebers-Moll) | ✅ | ✅ |
| Level 2 (Gummel-Poon) | ✅ | ✅ |
| VBIC (Level 4) | ✅ | ✅ (1.2 + 1.3) |
| HICUM (Level 8) | ✅ | ❌ |
| FBH HBT | ❌ | ✅ |
| MEXTRAM 504 | ❌ | ✅ |

---

### MOSFET — `M`

```spice
M<name> <drain> <gate> <source> <bulk> <model_name> [W=] [L=] [M=] [AD=] [AS=] [PD=] [PS=]
.model <model_name> NMOS|PMOS LEVEL=<n> [parameters...]
```

```spice
M1 out in 0 0 NMOS1 W=10u L=1u
.model NMOS1 NMOS LEVEL=1 VTO=0.7 KP=110u LAMBDA=0.04 GAMMA=0.4 PHI=0.65
```

**Level 1 (Shichman-Hodges) Key Parameters:**

| Parameter | Description | Default |
|-----------|-------------|---------|
| `VTO` | Threshold voltage | 0 V |
| `KP` | Transconductance parameter | 2e-5 A/V² |
| `LAMBDA` | Channel-length modulation | 0 V⁻¹ |
| `GAMMA` | Body-effect parameter | 0 V^0.5 |
| `PHI` | Surface potential | 0.6 V |
| `TOX` | Oxide thickness | ∞ (use default KP) |

**All Built-in MOSFET Levels:**

| Level | Model Name | NGSpice | Xyce | Typical Use |
|-------|-----------|---------|------|-------------|
| 1 | Shichman-Hodges | ✅ | ✅ | Educational, quick sims |
| 2 | Grove-Frohman | ✅ | ✅ | Short-channel (legacy) |
| 3 | Empirical | ✅ | ✅ | Semi-empirical |
| 4 | BSIM1 | ✅ | ❌ | Legacy |
| 5 | BSIM2 | ✅ | ❌ | Legacy |
| 6 | MOS6 | ✅ | ✅ | Simple analog |
| 8, 49 | BSIM3v3 | ✅ | ✅ | ≥0.25µm processes |
| 14, 54 | **BSIM4** | ✅ | ✅ | **Sub-0.25µm / modern PDKs** |
| 44 | EKV | ✅ | ❌ | Low-power analog |
| — | BSIM6 | ✅ | ✅ | Next-gen compact model |
| — | **PSP** | ✅ | ✅ | Advanced surface-potential |
| — | BSIM-SOI | ✅ | ✅ | Silicon-on-insulator |
| — | BSIM-CMG | ✅ (via OSDI) | ❌ | FinFET (multi-gate) |
| — | HiSIM2 | ✅ | ❌ | Japanese foundries |
| — | HiSIM_HV | ✅ | ❌ | High-voltage LDMOS |
| — | **VDMOS** | ❌ | ✅ | Power MOSFETs |

> [!IMPORTANT]
> **BSIM4 (Level 14/54)** is the model used by Sky130 and most modern PDKs.
> The `.model` card with ~300 extracted parameters comes from the **foundry PDK** via `.lib` —
> the equation engine that evaluates those parameters is built into the simulator.

---

### JFET — `J`

```spice
J<name> <drain> <gate> <source> <model_name> [area=<val>]
.model <model_name> NJF|PJF [parameters...]
```

```spice
J1 out in 0 MyJFET
.model MyJFET NJF VTO=-2 BETA=1e-3 LAMBDA=0.01 IS=1e-14
```

| Level | NGSpice | Xyce |
|-------|---------|------|
| Level 1 (Shichman-Hodges) | ✅ | ✅ |
| Level 2 (Parker-Skellern) | ✅ | ✅ |

---

### MESFET — `Z`

```spice
Z<name> <drain> <gate> <source> <model_name> [area=<val>]
.model <model_name> NMF|PMF [parameters...]
```

| Level | NGSpice | Xyce |
|-------|---------|------|
| Level 1 (Statz/Curtice) | ✅ | ✅ |
| Level 2 (TOM2/Ytterdal) | ✅ | ✅ |
| Level 6 (HFET) | ✅ | ✅ |

---

### Switches — `S`, `W`

```spice
* Voltage-controlled switch
S<name> <n+> <n-> <ctrl+> <ctrl-> <model_name>
.model <model_name> SW VT=<threshold> VH=<hysteresis> RON=<val> ROFF=<val>

* Current-controlled switch
W<name> <n+> <n-> <V_sense> <model_name>
.model <model_name> CSW IT=<threshold> IH=<hysteresis> RON=<val> ROFF=<val>
```

```spice
S1 out 0 ctrl 0 MySwitch
.model MySwitch SW VT=0.9 VH=0.1 RON=1 ROFF=1MEG
```

---

## 3. Xyce-Only Special Devices

| Device | Prefix/Type | Description |
|--------|-------------|-------------|
| Linear (S-param) | `YLIN` | Load S-parameters from Touchstone file |
| External coupled | `YGENEXT` | Co-simulation with external software |
| Digital gates | `YAND`, `YOR`, `YNAND`, etc. | Behavioral digital with truth tables, threshold/delay |
| Neuron | Various N devices | Hodgkin-Huxley, integrate-and-fire models |
| Reaction network | — | Chemical reaction modeling |

---

## 4. Quick Reference — Prefix Table

| Prefix | Device | Needs `.model`? | Needs `.include`? |
|--------|--------|:-:|:-:|
| `R` | Resistor | ❌ | ❌ |
| `C` | Capacitor | ❌ | ❌ |
| `L` | Inductor | ❌ | ❌ |
| `K` | Mutual Inductor | ❌ | ❌ |
| `V` | Voltage Source | ❌ | ❌ |
| `I` | Current Source | ❌ | ❌ |
| `B` | Behavioral Source | ❌ | ❌ |
| `E` | VCVS | ❌ | ❌ |
| `F` | CCCS | ❌ | ❌ |
| `G` | VCCS | ❌ | ❌ |
| `H` | CCVS | ❌ | ❌ |
| `T` | Lossless TLine | ❌ | ❌ |
| `O` | Lossy TLine | ✅ (LTRA) | ❌ |
| `D` | Diode | ✅ | ❌ |
| `Q` | BJT | ✅ | ❌ |
| `M` | MOSFET | ✅ | ❌* |
| `J` | JFET | ✅ | ❌ |
| `Z` | MESFET | ✅ | ❌ |
| `S` | V-Switch | ✅ (SW) | ❌ |
| `W` | I-Switch | ✅ (CSW) | ❌ |
| `X` | Subcircuit | — | ✅** |

> \* MOSFETs need `.include`/`.lib` only for **PDK models** (e.g. sky130 BSIM4 parameters).
> Simple Level 1 MOSFETs work with a hand-written `.model` and no includes.
>
> \*\* Subcircuits need `.include` only if defined in an external file.
> They can also be defined inline in the same netlist.
