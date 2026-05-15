# Cadence Virtuoso -> Schemify Component Mapping

Reference document for building a gold-class Cadence schematic import system.
Based on Cadence Virtuoso IC6/IC23, Spectre simulator, and common foundry PDKs.

## Status

- Total Cadence analogLib components catalogued: 72
- Mapped to Schemify DeviceKind: 49 (1:1 exact or near-exact)
- Approximate: 12 (needs adaptation or property translation)
- Unmapped: 11 (no Schemify equivalent -- need new DeviceKind or subckt fallback)
- PDK-specific patterns documented: 3 foundries (TSMC, GlobalFoundries, Cadence GPDK)

---

## Cadence Hierarchy Model

### Library / Cell / View (LCV)

Cadence organizes designs as a three-level hierarchy:

```
Library (e.g. analogLib, myDesignLib, tsmcN65)
  +-- Cell (e.g. nmos4, res, inv_x1)
       +-- View (e.g. schematic, symbol, layout, extracted, spectre, veriloga)
```

- **Library**: A directory registered in `cds.lib`. Contains cells. Examples: `analogLib` (Cadence builtins), `basic` (wire labels, pins), PDK libs (`tsmcN65`, `gpdk045`), user design libs.
- **Cell**: A single component/block. Has multiple views.
- **View**: A representation. `symbol` = schematic symbol graphics + pins. `schematic` = internal netlist. `spectre` = Spectre netlist view. `veriloga` = Verilog-A behavioral.

### Mapping to Schemify's Flat Model

Schemify uses a flat `symbol` string (e.g. `"nmos4"`) plus a `DeviceKind` enum. The mapping is:

| Cadence LCV | Schemify |
|---|---|
| `analogLib/nmos4/symbol` | `symbol = "nmos4"`, `kind = .nmos4` |
| `analogLib/res/symbol` | `symbol = "res"`, `kind = .resistor` |
| `tsmcN65/nch/symbol` | `symbol = "nch"`, `kind = .nmos4` (via PDK remap) |
| `myLib/opamp/symbol` | `symbol = "opamp"`, `kind = .subckt` |

**Key rule**: The cell name is the primary lookup key. The library name is used only for disambiguation and PDK-specific remapping. The view is discarded (Schemify has its own symbol/schematic duality).

### cds.lib Detection

The existing `cadence/mod.zig` stub already detects Cadence projects by the presence of `cds.lib` in the project root. This file contains `DEFINE` statements mapping library names to filesystem paths:

```
DEFINE analogLib /tools/cadence/IC23/tools/dfII/etc/cdslib/artist/analogLib
DEFINE basic /tools/cadence/IC23/tools/dfII/etc/cdslib/basic
DEFINE myDesign ./myDesign
```

---

## analogLib -- Core Analog Library

This is the primary Cadence-provided library. All cells below use the Spectre simulator primitive syntax.

### Spectre Terminal Naming Convention

Cadence Spectre uses uppercase single-letter or short terminal names:

| Component Class | Spectre Terminals | Order |
|---|---|---|
| 2-terminal passive | PLUS, MINUS | + first |
| 3-terminal passive (diffused) | PLUS, MINUS, B | + first, bulk last |
| MOSFET 4-terminal | D, G, S, B | Drain, Gate, Source, Bulk |
| MOSFET 3-terminal | D, G, S | Bulk implicit (gnd/vdd) |
| BJT 3-terminal | C, B, E | Collector, Base, Emitter |
| BJT 4-terminal | C, B, E, S | + Substrate |
| Diode | PLUS, MINUS | Anode, Cathode |
| Source 2-terminal | PLUS, MINUS | + first |
| Controlled source 4-terminal | inp, inn, outp, outn | Input pair, output pair |
| Port | PLUS, MINUS | + first |
| Iprobe | in, out | Current flows in->out |

---

## StaticStringMap Candidates

### Exact 1:1 Mappings (analogLib cell -> DeviceKind)

These are safe for a comptime `StaticStringMap(DeviceKind)`:

| Cadence Cell (lib/cell) | Schemify DeviceKind | Pins (Cadence -> Schemify) | Key Properties | Notes |
|---|---|---|---|---|
| `analogLib/res` | `.resistor` | PLUS,MINUS -> p,n (2-pin) | `r` (resistance), `tc1`, `tc2` | Ideal 2-terminal resistor |
| `analogLib/cap` | `.capacitor` | PLUS,MINUS -> p,n (2-pin) | `c` (capacitance), `vc1`, `vc2` | Ideal capacitor |
| `analogLib/ind` | `.inductor` | PLUS,MINUS -> p,n (2-pin) | `l` (inductance), `r` (series R) | Ideal inductor |
| `analogLib/nmos4` | `.nmos4` | D,G,S,B -> drain,gate,source,body | `w`, `l`, `m`, `nf`, `model` | 4-terminal NMOS |
| `analogLib/pmos4` | `.pmos4` | D,G,S,B -> drain,gate,source,body | `w`, `l`, `m`, `nf`, `model` | 4-terminal PMOS |
| `analogLib/nmos` | `.nmos3` | D,G,S -> drain,gate,source | `w`, `l`, `m`, `model` | 3-terminal NMOS (bulk implicit) |
| `analogLib/pmos` | `.pmos3` | D,G,S -> drain,gate,source | `w`, `l`, `m`, `model` | 3-terminal PMOS (bulk implicit) |
| `analogLib/npn` | `.npn` | C,B,E -> collector,base,emitter | `area`, `m`, `model` | NPN BJT (3-pin) |
| `analogLib/npn4` | `.npn` | C,B,E,S -> collector,base,emitter,sub | `area`, `m`, `model` | NPN BJT (4-pin, substrate) |
| `analogLib/pnp` | `.pnp` | C,B,E -> collector,base,emitter | `area`, `m`, `model` | PNP BJT (3-pin) |
| `analogLib/pnp4` | `.pnp` | C,B,E,S -> collector,base,emitter,sub | `area`, `m`, `model` | PNP BJT (4-pin, substrate) |
| `analogLib/njfet` | `.njfet` | D,G,S -> drain,gate,source | `w`, `l`, `model` | N-channel JFET |
| `analogLib/pjfet` | `.pjfet` | D,G,S -> drain,gate,source | `w`, `l`, `model` | P-channel JFET |
| `analogLib/diode` | `.diode` | PLUS,MINUS -> anode,cathode | `area`, `pj`, `m`, `model` | PN junction diode |
| `analogLib/vdc` | `.vsource` | PLUS,MINUS -> p,n | `vdc` (DC voltage), `mag` | DC voltage source |
| `analogLib/vsin` | `.vsource` | PLUS,MINUS -> p,n | `vdc`, `va` (amplitude), `freq` | Sinusoidal voltage source |
| `analogLib/vpulse` | `.vsource` | PLUS,MINUS -> p,n | `val0`, `val1`, `period`, `rise`, `fall`, `width` | Pulse voltage source |
| `analogLib/vpwl` | `.vsource` | PLUS,MINUS -> p,n | `fileName` or inline time/value pairs | PWL voltage source |
| `analogLib/vexp` | `.vsource` | PLUS,MINUS -> p,n | `val0`, `val1`, `td1`, `tau1`, `td2`, `tau2` | Exponential voltage source |
| `analogLib/vsource` | `.vsource` | PLUS,MINUS -> p,n | `type`, `dc`, `mag`, many more | Universal voltage source |
| `analogLib/idc` | `.isource` | PLUS,MINUS -> p,n | `idc` (DC current), `mag` | DC current source |
| `analogLib/isin` | `.isource` | PLUS,MINUS -> p,n | `idc`, `ia` (amplitude), `freq` | Sinusoidal current source |
| `analogLib/ipulse` | `.isource` | PLUS,MINUS -> p,n | `ival0`, `ival1`, `period`, `rise`, `fall`, `width` | Pulse current source |
| `analogLib/ipwl` | `.isource` | PLUS,MINUS -> p,n | `fileName` or inline time/value pairs | PWL current source |
| `analogLib/iexp` | `.isource` | PLUS,MINUS -> p,n | `ival0`, `ival1`, `td1`, `tau1` | Exponential current source |
| `analogLib/isource` | `.isource` | PLUS,MINUS -> p,n | `type`, `dc`, `mag`, many more | Universal current source |
| `analogLib/vcvs` | `.vcvs` | inp,inn,outp,outn -> inp,inn,outp,outn | `egain` (voltage gain) | Voltage-controlled voltage source |
| `analogLib/vccs` | `.vccs` | inp,inn,outp,outn -> inp,inn,outp,outn | `ggain` (transconductance) | Voltage-controlled current source |
| `analogLib/ccvs` | `.ccvs` | inp,inn,outp,outn -> inp,inn,outp,outn | `hgain` (transresistance) | Current-controlled voltage source |
| `analogLib/cccs` | `.cccs` | inp,inn,outp,outn -> inp,inn,outp,outn | `fgain` (current gain) | Current-controlled current source |
| `analogLib/vcvs4` | `.vcvs` | inp,inn,outp,outn -> inp,inn,outp,outn | `egain` | 4-pin variant (same mapping) |
| `analogLib/vccs4` | `.vccs` | inp,inn,outp,outn -> inp,inn,outp,outn | `ggain` | 4-pin variant |
| `analogLib/ccvs4` | `.ccvs` | inp,inn,outp,outn -> inp,inn,outp,outn | `hgain` | 4-pin variant |
| `analogLib/cccs4` | `.cccs` | inp,inn,outp,outn -> inp,inn,outp,outn | `fgain` | 4-pin variant |
| `analogLib/iprobe` | `.ammeter` | in,out -> p,n | (none) | Zero-voltage current probe |
| `analogLib/gnd` | `.gnd` | gnd! -> gnd | (none) | Ground symbol |
| `analogLib/switch` | `.vswitch` | A,B -> p,n | `vth` (threshold), `ron`, `roff` | Voltage-controlled switch |
| `analogLib/relay` | `.iswitch` | inp,inn,outp,outn | `ith` (threshold), `ron`, `roff` | Current-controlled switch/relay |
| `analogLib/port` | `.probe` | PLUS,MINUS -> p,n | `r` (impedance), `num`, `type` | S-parameter port |
| `basic/noConn` | `.noconn` | (1 pin) | (none) | No-connection marker |

### Cells Mapping to `.vsource` (All Voltage Source Variants)

All of the following map to `DeviceKind.vsource` since Schemify's model is source-type-agnostic:

```
vdc, vsin, vpulse, vpwl, vpwlf, vexp, vsource, vac
```

### Cells Mapping to `.isource` (All Current Source Variants)

```
idc, isin, ipulse, ipwl, ipwlf, iexp, isource, iac
```

---

## Pin Name Translation

### Cadence -> Schemify Pin Mapping Table

| Cadence Pin | Schemify Pin | Component Types | Notes |
|---|---|---|---|
| `D` | `drain` | MOSFET (nmos, pmos, nmos4, pmos4) | Always uppercase in Cadence |
| `G` | `gate` | MOSFET | |
| `S` | `source` | MOSFET | |
| `B` | `body` | MOSFET 4-term, diffused resistor, BJT substrate | Bulk/body/substrate |
| `C` | `collector` | BJT (npn, pnp) | |
| `B` | `base` | BJT | Overloaded with MOSFET bulk -- context-dependent |
| `E` | `emitter` | BJT | |
| `S` | `sub` | BJT 4-term substrate | Overloaded with MOSFET source -- context-dependent |
| `PLUS` | `p` | Resistor, capacitor, inductor, diode, source | Positive terminal |
| `MINUS` | `n` | Resistor, capacitor, inductor, diode, source | Negative terminal |
| `in` | `p` | iprobe | Current measurement input |
| `out` | `n` | iprobe | Current measurement output |
| `inp` | `inp` | Controlled sources (vcvs, vccs, ccvs, cccs) | Positive sensing input |
| `inn` | `inn` | Controlled sources | Negative sensing input |
| `outp` | `outp` | Controlled sources | Positive output |
| `outn` | `outn` | Controlled sources | Negative output |
| `d` | `d` | Controlled sources (Spectre 2-port) | Differential pair alternate |
| `gnd!` | (global net) | Ground | Global net convention |
| `vdd!` | (global net) | Power supply | Global net convention |

### Pin Name Normalization Function

A comptime `StaticStringMap` for pin translation:

```
"D" -> "drain"
"G" -> "gate"
"S" -> "source"  (context: MOSFET)
"B" -> "body"    (context: MOSFET)
"C" -> "collector"
"B" -> "base"    (context: BJT)
"E" -> "emitter"
"S" -> "sub"     (context: BJT 4-term)
"PLUS" -> "p"
"MINUS" -> "n"
"in" -> "p"
"out" -> "n"
"inp" -> "inp"
"inn" -> "inn"
"outp" -> "outp"
"outn" -> "outn"
```

**Important**: `B` and `S` are overloaded between MOSFET and BJT contexts.
The DeviceKind determines which translation to apply.

---

## Approximate Mappings

These require adaptation or property translation during import:

| Cadence Cell | Closest DeviceKind | Issue | Resolution |
|---|---|---|---|
| `analogLib/bsource` | `.behavioral` | Generic B-source with arbitrary expressions | Map to behavioral; preserve `v=` / `i=` expression in props |
| `analogLib/nmos4` with `nf>1` | `.nmos4` | Multi-finger parameter not in Schemify core | Preserve `nf` as instance property; `w_eff = w * nf` |
| `analogLib/pmos4` with `nf>1` | `.pmos4` | Same as above | Same resolution |
| `analogLib/tline` | `.tline` | Cadence has multiple tline variants | Map all tline variants to `.tline`; preserve params |
| `analogLib/mind` | `.coupling` | Mutual inductor uses `k` coupling coefficient | Map to `.coupling`; preserve `k`, `ind1`, `ind2` refs |
| `analogLib/mutual_ind` | `.coupling` | Same as mind | Same resolution |
| `analogLib/ideal_balun` | `.generic` | No direct Schemify equivalent | Map to `.generic` with `type=ideal_balun` in props |
| `analogLib/xfmr` | `.generic` | Transformer -- no direct equivalent | Map to `.generic` with `type=transformer` in props |
| `analogLib/delay` | `.generic` | Ideal delay element | Map to `.generic`; preserve `td` property |
| `analogLib/pvcvs` | `.vcvs` | Polynomial VCVS | Map to `.vcvs`; preserve polynomial coefficients |
| `analogLib/pvccs` | `.vccs` | Polynomial VCCS | Map to `.vccs`; preserve polynomial coefficients |
| `analogLib/pccvs` | `.ccvs` | Polynomial CCVS | Map to `.ccvs`; preserve polynomial coefficients |
| `analogLib/pcccs` | `.cccs` | Polynomial CCCS | Map to `.cccs`; preserve polynomial coefficients |

---

## Unmapped (No Schemify Equivalent)

| Cadence Cell | Description | Suggested DeviceKind |
|---|---|---|
| `analogLib/n1port` | 1-port noise source | `.behavioral` or new `.nport` |
| `analogLib/n2port` | 2-port noise source | `.behavioral` or new `.nport` |
| `analogLib/n3port` | 3-port network | `.subckt` (generic fallback) |
| `analogLib/n4port` | 4-port network | `.subckt` (generic fallback) |
| `analogLib/nbsim` | BSIM3 behavioral NMOS | `.nmos4` (approximate) |
| `analogLib/nbsim4` | BSIM4 behavioral NMOS | `.nmos4` (approximate) |
| `analogLib/pbsim` | BSIM3 behavioral PMOS | `.pmos4` (approximate) |
| `analogLib/pbsim4` | BSIM4 behavioral PMOS | `.pmos4` (approximate) |
| `analogLib/winding` | Transformer winding | `.generic` or new `.winding` |
| `analogLib/zener` | Zener diode (rare in analogLib, more common in PDKs) | `.zener` |
| `analogLib/mesfet` | GaAs MESFET | `.mesfet` |

---

## basic Library

The `basic` library contains non-electrical symbols and connectivity helpers:

| Cell | DeviceKind | Description | Notes |
|---|---|---|---|
| `basic/gnd` | `.gnd` | Ground symbol | Same as analogLib/gnd |
| `basic/vdd` | `.vdd` | Power supply symbol | |
| `basic/noConn` | `.noconn` | No-connection marker | Suppresses DRC warnings on floating pins |
| `basic/iopin` | `.inout_pin` | Bidirectional I/O pin | Used in hierarchical port definitions |
| `basic/ipin` | `.input_pin` | Input pin | |
| `basic/opin` | `.output_pin` | Output pin | |

### Global Net Convention

Cadence uses the `!` suffix for global nets (visible at all hierarchy levels):
- `gnd!` -- global ground
- `vdd!` -- global VDD
- `vss!` -- global VSS (equivalent to gnd in many designs)

Schemify should strip the `!` suffix and register these as global nets via `addGlobal()`.

---

## ahdlLib -- Verilog-A Behavioral Models

The `ahdlLib` library contains Verilog-A behavioral models. Common cells:

| Cell | Closest DeviceKind | Description |
|---|---|---|
| `ahdlLib/pll` | `.subckt` | PLL behavioral model |
| `ahdlLib/vco` | `.subckt` | Voltage-controlled oscillator |
| `ahdlLib/phase_detector` | `.subckt` | Phase detector |
| `ahdlLib/lpf_1storder` | `.subckt` | First-order low-pass filter |
| `ahdlLib/adc` | `.subckt` | ADC behavioral model |
| `ahdlLib/dac` | `.subckt` | DAC behavioral model |

**Mapping rule**: All ahdlLib cells map to `.subckt` since they are behavioral subcircuits. Preserve the Verilog-A source as an `hdl_source` property if available.

---

## functional Library

The `functional` library contains behavioral/abstract models:

| Cell Pattern | Closest DeviceKind | Description |
|---|---|---|
| `functional/*` | `.subckt` | All functional library cells are behavioral subcircuits |

**Mapping rule**: Same as ahdlLib -- all map to `.subckt`.

---

## PDK-Specific Mappings

### Property Names to Preserve vs Strip

**Universally preserved** (needed for simulation):
- `w` -- channel width
- `l` -- channel length
- `m` -- multiplier
- `model` -- SPICE model name
- `r`, `c`, `l` -- passive values

**PDK-specific to strip** (layout-only, not needed in schematic):
- `sa`, `sb`, `sd` -- source/drain diffusion lengths
- `nf` -- number of fingers (preserve as property but not in kind)
- `nrd`, `nrs` -- drain/source diffusion squares
- `mult` -- alternative multiplier name
- `area`, `perim` -- junction area/perimeter
- `topography` -- layout orientation hint

### TSMC

TSMC PDKs use library names like `tsmcN65`, `tsmcN28`, `tsmcN16` etc. Transistor cells:

| Cell Pattern | DeviceKind | Pin Mapping | Properties | Notes |
|---|---|---|---|---|
| `nch` | `.nmos4` | D,G,S,B -> drain,gate,source,body | `w`, `l`, `m`, `nf` | Standard Vt NMOS |
| `pch` | `.pmos4` | D,G,S,B -> drain,gate,source,body | `w`, `l`, `m`, `nf` | Standard Vt PMOS |
| `nch_lvt` | `.nmos4` | D,G,S,B -> drain,gate,source,body | `w`, `l`, `m`, `nf` | Low Vt NMOS |
| `pch_lvt` | `.pmos4` | D,G,S,B -> drain,gate,source,body | `w`, `l`, `m`, `nf` | Low Vt PMOS |
| `nch_hvt` | `.nmos4` | D,G,S,B -> drain,gate,source,body | `w`, `l`, `m`, `nf` | High Vt NMOS |
| `pch_hvt` | `.pmos4` | D,G,S,B -> drain,gate,source,body | `w`, `l`, `m`, `nf` | High Vt PMOS |
| `nch_svt` | `.nmos4` | D,G,S,B -> drain,gate,source,body | `w`, `l`, `m`, `nf` | Super Vt NMOS |
| `pch_svt` | `.pmos4` | D,G,S,B -> drain,gate,source,body | `w`, `l`, `m`, `nf` | Super Vt PMOS |
| `nch_na` / `nch_native` | `.nmos4` | D,G,S,B -> drain,gate,source,body | `w`, `l`, `m` | Native (zero-Vt) NMOS |
| `nch_25` | `.nmos4` | D,G,S,B -> drain,gate,source,body | `w`, `l`, `m`, `nf` | 2.5V NMOS |
| `pch_25` | `.pmos4` | D,G,S,B -> drain,gate,source,body | `w`, `l`, `m`, `nf` | 2.5V PMOS |
| `nch_25_dnw` | `.nmos4` | D,G,S,B -> drain,gate,source,body | `w`, `l`, `m`, `nf` | 2.5V NMOS in deep N-well |
| `nch_mac` | `.nmos4` | D,G,S,B -> drain,gate,source,body | `w`, `l`, `m`, `nf` | Mismatch-aware NMOS |
| `pch_mac` | `.pmos4` | D,G,S,B -> drain,gate,source,body | `w`, `l`, `m`, `nf` | Mismatch-aware PMOS |
| `nch_io` | `.nmos4` | D,G,S,B -> drain,gate,source,body | `w`, `l`, `m`, `nf` | I/O NMOS (thick oxide) |
| `pch_io` | `.pmos4` | D,G,S,B -> drain,gate,source,body | `w`, `l`, `m`, `nf` | I/O PMOS (thick oxide) |

**TSMC pattern rule**: Any cell matching `^[np]ch(_.*)?$` is a MOSFET.
- Starts with `n` -> `.nmos4`
- Starts with `p` -> `.pmos4`
- Suffix indicates Vt flavor / voltage domain, preserved as a property

**TSMC properties to strip for generic display** (keep for netlisting):
`sa`, `sb`, `sd`, `nrd`, `nrs`, `topography`

### GlobalFoundries (GF180MCU)

GF180MCU is an open-source PDK. Cell naming uses `nfet`/`pfet` prefix + voltage + variant:

| Cell Pattern | DeviceKind | Pin Mapping | Properties | Notes |
|---|---|---|---|---|
| `nfet_03v3` | `.nmos4` | D,G,S,B -> drain,gate,source,body | `w`, `l`, `m`, `nf` | 3.3V NMOS |
| `pfet_03v3` | `.pmos4` | D,G,S,B -> drain,gate,source,body | `w`, `l`, `m`, `nf` | 3.3V PMOS |
| `nfet_06v0` | `.nmos4` | D,G,S,B -> drain,gate,source,body | `w`, `l`, `m`, `nf` | 6V NMOS |
| `pfet_06v0` | `.pmos4` | D,G,S,B -> drain,gate,source,body | `w`, `l`, `m`, `nf` | 6V PMOS |
| `nfet_05v0` | `.nmos4` | D,G,S,B -> drain,gate,source,body | `w`, `l`, `m`, `nf` | 5V NMOS |
| `pfet_05v0` | `.pmos4` | D,G,S,B -> drain,gate,source,body | `w`, `l`, `m`, `nf` | 5V PMOS |
| `nfet_06v0_nvt` | `.nmos4` | D,G,S,B -> drain,gate,source,body | `w`, `l`, `m` | 6V Native NMOS |
| `nfet_10v0_asym` | `.nmos4` | D,G,S,B -> drain,gate,source,body | `w`, `l`, `m` | 10V LD-NMOS (asymmetric) |
| `pfet_10v0_asym` | `.pmos4` | D,G,S,B -> drain,gate,source,body | `w`, `l`, `m` | 10V LD-PMOS (asymmetric) |
| `nfet_*_dss` | `.nmos4` | D,G,S,B -> drain,gate,source,body | `w`, `l`, `m` | ESD/SAB NMOS variants |
| `pfet_*_dss` | `.pmos4` | D,G,S,B -> drain,gate,source,body | `w`, `l`, `m` | ESD/SAB PMOS variants |
| `nfet_*_dn` | `.nmos4` | D,G,S,B -> drain,gate,source,body | `w`, `l`, `m`, `nf` | Inside deep N-well variants |
| `pfet_*_dn` | `.pmos4` | D,G,S,B -> drain,gate,source,body | `w`, `l`, `m`, `nf` | Inside deep N-well variants |
| `npn_*` | `.npn` | C,B,E -> collector,base,emitter | `m` | NPN BJT (suffix = emitter size) |
| `pnp_*` | `.pnp` | C,B,E -> collector,base,emitter | `m` | PNP BJT (suffix = emitter size) |
| `diode_nd2ps_*` | `.diode` | PLUS,MINUS -> anode,cathode | `area`, `perim`, `m` | N+/LVPWELL diode |
| `diode_pd2nw_*` | `.diode` | PLUS,MINUS -> anode,cathode | `area`, `perim`, `m` | P+/Nwell diode |
| `diode_nw2ps_*` | `.diode` | PLUS,MINUS -> anode,cathode | `area`, `perim`, `m` | Nwell/Psub diode |
| `diode_pw2dw_*` | `.diode` | PLUS,MINUS -> anode,cathode | `area`, `perim`, `m` | LVPWELL/DNWELL diode |
| `diode_dw2ps_*` | `.diode` | PLUS,MINUS -> anode,cathode | `area`, `perim`, `m` | DNWELL/Psub diode |
| `sc_diode` | `.diode` | PLUS,MINUS -> anode,cathode | `area`, `m` | Schottky diode |
| `nplus_u`, `pplus_u` | `.resistor` | PLUS,MINUS,B -> p,n,body | `l`, `w`, `m` | Unsalicided diffusion resistor |
| `nplus_s`, `pplus_s` | `.resistor` | PLUS,MINUS,B -> p,n,body | `l`, `w`, `m` | Salicided diffusion resistor |
| `npolyf_u`, `ppolyf_u` | `.resistor` | PLUS,MINUS,B -> p,n,body | `l`, `w`, `m` | Unsalicided poly resistor |
| `npolyf_s`, `ppolyf_s` | `.resistor` | PLUS,MINUS,B -> p,n,body | `l`, `w`, `m` | Salicided poly resistor |
| `ppolyf_u_1k` | `.resistor` | PLUS,MINUS,B -> p,n,body | `l`, `w`, `m` | High-Rs poly resistor (1k) |
| `ppolyf_u_2k` | `.resistor` | PLUS,MINUS,B -> p,n,body | `l`, `w`, `m` | High-Rs poly resistor (2k) |
| `ppolyf_u_3k` | `.resistor` | PLUS,MINUS,B -> p,n,body | `l`, `w`, `m` | High-Rs poly resistor (3k) |
| `nwell`, `pwell` | `.resistor` | PLUS,MINUS,B -> p,n,body | `l`, `w`, `m` | Well resistor |
| `rm1`..`rm3` | `.resistor` | PLUS,MINUS -> p,n | `l`, `w`, `m` | Metal resistor (2-pin) |
| `tm6k`..`tm30k` | `.resistor` | PLUS,MINUS -> p,n | `l`, `w`, `m` | Top metal resistor (2-pin) |
| `cap_mim_*` | `.capacitor` | PLUS,MINUS -> p,n | `l`, `w`, `m` | MIM capacitor |
| `cap_nmos_*` | `.capacitor` | PLUS,MINUS -> p,n | `l`, `w`, `m` | MOS varactor (NMOS) |
| `cap_pmos_*` | `.capacitor` | PLUS,MINUS -> p,n | `l`, `w`, `m` | MOS varactor (PMOS) |
| `efuse` | `.generic` | PLUS,MINUS -> p,n | `l`, `w` | Programmable fuse |

**GF180MCU pattern rules**:
- `^nfet_` -> `.nmos4`
- `^pfet_` -> `.pmos4`
- `^npn_` -> `.npn`
- `^pnp_` -> `.pnp`
- `^diode_` -> `.diode`
- `^sc_diode` -> `.diode`
- `^(nplus|pplus|npolyf|ppolyf|nwell|pwell|rm\d|tm\d)` -> `.resistor`
- `^cap_` -> `.capacitor`

### Cadence GPDK (Generic PDK -- gpdk045, gpdk090)

Cadence's educational/reference PDKs:

| Cell Pattern | DeviceKind | Pin Mapping | Notes |
|---|---|---|---|
| `nmos1v` | `.nmos4` | D,G,S,B | 1.0V nominal Vt NMOS |
| `nmos1v_hvt` | `.nmos4` | D,G,S,B | High Vt variant |
| `nmos1v_lvt` | `.nmos4` | D,G,S,B | Low Vt variant |
| `nmos1v_nat` | `.nmos4` | D,G,S,B | Native (near-zero Vt) |
| `nmos2v` | `.nmos4` | D,G,S,B | 2.5V nominal Vt |
| `nmos2v_nat` | `.nmos4` | D,G,S,B | 2.5V native |
| `pmos1v` | `.pmos4` | D,G,S,B | 1.0V nominal Vt PMOS |
| `pmos1v_hvt` | `.pmos4` | D,G,S,B | High Vt variant |
| `pmos1v_lvt` | `.pmos4` | D,G,S,B | Low Vt variant |
| `pmos2v` | `.pmos4` | D,G,S,B | 2.5V nominal Vt |
| `npn2`, `npn5`, `npn10` | `.npn` | C,B,E | Vertical NPN (emitter 2x2, 5x5, 10x10) |
| `vpnp2`, `vpnp5`, `vpnp10` | `.pnp` | C,B,E | Vertical substrate PNP |
| `ndio`, `ndio_hvt`, `ndio_lvt` | `.diode` | PLUS,MINUS | N+/P-substrate diode |
| `pdio`, `pdio_hvt`, `pdio_lvt` | `.diode` | PLUS,MINUS | P+/N-well diode |
| `ndio_2v`, `pdio_2v` | `.diode` | PLUS,MINUS | 1.8V diode variants |
| `ressndiff`, `resspdiff` | `.resistor` | PLUS,MINUS,B | Salicided diffusion resistor |
| `resnsndiff`, `resnspdiff` | `.resistor` | PLUS,MINUS,B | Non-salicided diffusion resistor |
| `ressnpoly`, `ressppoly` | `.resistor` | PLUS,MINUS,B | Salicided poly resistor |
| `resnsnpoly`, `resnsppoly` | `.resistor` | PLUS,MINUS,B | Non-salicided poly resistor |
| `resnwsti`, `resnwoxide` | `.resistor` | PLUS,MINUS,B | N-well resistor |
| `resm1`..`resm11` | `.resistor` | PLUS,MINUS | Metal resistor |
| `mimcap` | `.capacitor` | PLUS,MINUS,B | Metal-insulator-metal cap |
| `nmoscap1v`, `pmoscap1v` | `.capacitor` | PLUS,MINUS | MOS varactor |
| `nmoscap2v`, `pmoscap2v` | `.capacitor` | PLUS,MINUS | 1.8V MOS varactor |
| `ind_a` | `.inductor` | PLUS,MINUS,B | Asymmetric inductor |
| `ind_s` | `.inductor` | PLUS,MINUS,B | Symmetric inductor |

**GPDK pattern rule**: Match by prefix `nmos` -> `.nmos4`, `pmos` -> `.pmos4`, `npn` or `vpnp` -> `.npn`/`.pnp`, `ndio` or `pdio` -> `.diode`, `res` -> `.resistor`, `cap` or `mim` -> `.capacitor`, `ind` -> `.inductor`.

---

## Universal PDK Prefix Matching

For any unknown foundry PDK, these prefix-based heuristics should work as a fallback:

| Prefix Pattern (regex) | DeviceKind | Confidence |
|---|---|---|
| `^n(ch\|mos\|fet)` | `.nmos4` | High |
| `^p(ch\|mos\|fet)` | `.pmos4` | High |
| `^npn` | `.npn` | High |
| `^pnp` | `.pnp` | High |
| `^vpnp` | `.pnp` | High -- vertical substrate PNP |
| `^diode` | `.diode` | High |
| `^(res\|poly\|nwell\|pwell\|rm\|tm)` | `.resistor` | Medium |
| `^cap` | `.capacitor` | Medium |
| `^ind` | `.inductor` | Medium |
| `^mim` | `.capacitor` | Medium -- MIM cap |

---

## CDL/Netlist Format Notes

### CDL vs Standard SPICE

CDL (Circuit Design Language) is Cadence's netlist format for LVS. Key differences from standard SPICE:

| Feature | Standard SPICE | Cadence CDL |
|---|---|---|
| Instance prefix | `M1` (MOSFET), `R1`, `C1`, etc. | Same, but MOSFETs always use `M` (never `X`) for LVS |
| Subcircuit instances | `X` prefix | `X` prefix (same) |
| MOSFET pin order | D, G, S, B (or Sub) | D, G, S, B (same) |
| BJT pin order | C, B, E [, S] | C, B, E [, S] (same) |
| Diode pin order | Anode, Cathode | Anode, Cathode (same) |
| Global nets | `.GLOBAL gnd vdd` | `.GLOBAL gnd! vdd!` (uses `!` suffix) |
| Comments | `*` at line start | `*` at line start, `$` inline |
| Substrate connection | Pin in instance line | `$SUB=<net>` alternate syntax |
| Case sensitivity | Case-insensitive (traditional) | Case-sensitive after `*.CASE` directive |
| Scale factors | `M` = milli | `M` = Mega only with `*.MEGA` + `*.SCALE` directives |
| Pin names | `$PINS` directive optional | `$PINS <name> <name>...` lists pin names |
| Continuation | `+` at line start | `+` at line start (same) |
| Include | `.INCLUDE` / `.LIB` | `.INCLUDE` / `.LIB` (same) |

### Spectre Netlist Format

Spectre uses a different netlist format from SPICE:

```spectre
// Spectre format (not SPICE)
M0 (net1 net2 net3 net4) nmos4 w=1u l=100n m=1
R0 (net5 net6) resistor r=1K
C0 (net7 0) capacitor c=1p
V0 (vin 0) vsource dc=1.2 type=dc
```

Key differences from SPICE:
- Instance name comes first (no letter prefix required)
- Terminals are in parentheses
- Component type follows the parenthesized terminals
- Parameters use `name=value` syntax (same as SPICE)
- Comments use `//` (not `*`)

### Import Strategy

When importing Cadence designs, the importer should:

1. **Parse `cds.lib`** to build a library path map
2. **Read OA database** or **parse exported CDL/Spectre netlists**
3. **Resolve instances** via LCV lookup: `library/cell/symbol` view for pin info
4. **Map cell names** using the StaticStringMap tables above
5. **Translate pin names** using the context-aware pin translation table
6. **Strip PDK properties** per the strip list, preserving `w`, `l`, `m`, `model`
7. **Handle global nets** by stripping `!` suffix and calling `addGlobal()`

### Property Name Translation (Cadence -> Schemify)

| Cadence Property | Schemify Property | Component Types | Notes |
|---|---|---|---|
| `w` | `w` | MOSFET | Channel width (keep as-is) |
| `l` | `l` | MOSFET | Channel length (keep as-is) |
| `m` | `m` | All | Multiplier (keep as-is) |
| `nf` | `nf` | MOSFET | Number of fingers (keep as-is) |
| `model` | `model` | All active | SPICE model name (keep) |
| `r` | `value` | Resistor | Resistance value |
| `c` | `value` | Capacitor | Capacitance value |
| `l` (inductor) | `value` | Inductor | Inductance value (note: same key as MOSFET length) |
| `vdc` | `dc` | Voltage source | DC voltage |
| `idc` | `dc` | Current source | DC current |
| `egain` | `gain` | VCVS | Voltage gain |
| `ggain` | `gain` | VCCS | Transconductance |
| `hgain` | `gain` | CCVS | Transresistance |
| `fgain` | `gain` | CCCS | Current gain |

---

## Complete analogLib Cell Inventory

For completeness, here is every known analogLib cell organized by category:

### Passives (5 cells)
`res`, `cap`, `ind`, `mind` (mutual inductor), `xfmr` (transformer)

### Active Devices (14 cells)
`nmos`, `pmos`, `nmos4`, `pmos4`, `npn`, `npn4`, `pnp`, `pnp4`, `njfet`, `pjfet`, `diode`, `mesfet`, `nbsim`, `nbsim4`, `pbsim`, `pbsim4`

### Independent Voltage Sources (8 cells)
`vdc`, `vsin`, `vpulse`, `vpwl`, `vpwlf`, `vexp`, `vsource`, `vac`

### Independent Current Sources (8 cells)
`idc`, `isin`, `ipulse`, `ipwl`, `ipwlf`, `iexp`, `isource`, `iac`

### Controlled Sources (12 cells)
`vcvs`, `vccs`, `ccvs`, `cccs`, `vcvs4`, `vccs4`, `ccvs4`, `cccs4`, `pvcvs`, `pvccs`, `pccvs`, `pcccs`

### Behavioral (1 cell)
`bsource`

### Ideal Blocks (4 cells)
`switch`, `relay`, `ideal_balun`, `delay`

### Probes & Ports (2 cells)
`iprobe`, `port`

### Transmission Lines (2 cells)
`tline`, `tline4`

### Multi-Port Networks (4 cells)
`n1port`, `n2port`, `n3port`, `n4port`

### Power/Ground (1 cell)
`gnd`

### Parasitics (5 cells)
`pcap`, `pind`, `presistor`, `pdiode`, `pdc`

### Misc Sources (4 cells)
`pdc`, `ppulse`, `ppwl`, `psin`, `pexp`

**Total: ~72 cells** (exact count varies by Cadence version; newer versions add more)

---

## Implementation Recommendations

### StaticStringMap Construction (Zig)

```
// Suggested structure for cadence/remap.zig:
//
// const cadence_cell_map = std.StaticStringMap(core.DeviceKind).initComptime(.{
//     // analogLib exact matches
//     .{ "res", .resistor },
//     .{ "cap", .capacitor },
//     .{ "ind", .inductor },
//     .{ "nmos", .nmos3 },
//     .{ "pmos", .pmos3 },
//     .{ "nmos4", .nmos4 },
//     .{ "pmos4", .pmos4 },
//     .{ "npn", .npn },
//     .{ "npn4", .npn },
//     .{ "pnp", .pnp },
//     .{ "pnp4", .pnp },
//     .{ "njfet", .njfet },
//     .{ "pjfet", .pjfet },
//     .{ "diode", .diode },
//     .{ "mesfet", .mesfet },
//     .{ "vdc", .vsource },
//     .{ "vsin", .vsource },
//     .{ "vpulse", .vsource },
//     .{ "vpwl", .vsource },
//     .{ "vpwlf", .vsource },
//     .{ "vexp", .vsource },
//     .{ "vsource", .vsource },
//     .{ "vac", .vsource },
//     .{ "idc", .isource },
//     .{ "isin", .isource },
//     .{ "ipulse", .isource },
//     .{ "ipwl", .isource },
//     .{ "ipwlf", .isource },
//     .{ "iexp", .isource },
//     .{ "isource", .isource },
//     .{ "iac", .isource },
//     .{ "vcvs", .vcvs },
//     .{ "vccs", .vccs },
//     .{ "ccvs", .ccvs },
//     .{ "cccs", .cccs },
//     .{ "vcvs4", .vcvs },
//     .{ "vccs4", .vccs },
//     .{ "ccvs4", .ccvs },
//     .{ "cccs4", .cccs },
//     .{ "pvcvs", .vcvs },
//     .{ "pvccs", .vccs },
//     .{ "pccvs", .ccvs },
//     .{ "pcccs", .cccs },
//     .{ "bsource", .behavioral },
//     .{ "iprobe", .ammeter },
//     .{ "port", .probe },
//     .{ "switch", .vswitch },
//     .{ "relay", .iswitch },
//     .{ "gnd", .gnd },
//     .{ "tline", .tline },
//     .{ "tline4", .tline },
//     .{ "mind", .coupling },
//     .{ "mutual_ind", .coupling },
//     .{ "ideal_balun", .generic },
//     .{ "xfmr", .generic },
//     .{ "delay", .generic },
//     .{ "noConn", .noconn },
//     .{ "noconn", .noconn },
//     .{ "iopin", .inout_pin },
//     .{ "ipin", .input_pin },
//     .{ "opin", .output_pin },
//     .{ "vdd", .vdd },
//     // GPDK cells
//     .{ "nmos1v", .nmos4 },
//     .{ "nmos1v_hvt", .nmos4 },
//     .{ "nmos1v_lvt", .nmos4 },
//     .{ "nmos1v_nat", .nmos4 },
//     .{ "nmos2v", .nmos4 },
//     .{ "nmos2v_nat", .nmos4 },
//     .{ "pmos1v", .pmos4 },
//     .{ "pmos1v_hvt", .pmos4 },
//     .{ "pmos1v_lvt", .pmos4 },
//     .{ "pmos2v", .pmos4 },
//     // TSMC cells (common names)
//     .{ "nch", .nmos4 },
//     .{ "pch", .pmos4 },
//     .{ "nch_lvt", .nmos4 },
//     .{ "pch_lvt", .pmos4 },
//     .{ "nch_hvt", .nmos4 },
//     .{ "pch_hvt", .pmos4 },
//     .{ "nch_svt", .nmos4 },
//     .{ "pch_svt", .pmos4 },
//     .{ "nch_na", .nmos4 },
//     .{ "nch_native", .nmos4 },
//     .{ "nch_25", .nmos4 },
//     .{ "pch_25", .pmos4 },
//     .{ "nch_mac", .nmos4 },
//     .{ "pch_mac", .pmos4 },
//     .{ "nch_io", .nmos4 },
//     .{ "pch_io", .pmos4 },
// });
```

### Prefix-Based Fallback (for unknown PDK cells)

After the StaticStringMap lookup fails, apply prefix matching:

```
// fn matchCadencePdkPrefix(cell: []const u8) ?core.DeviceKind
// Ordered by specificity (longest prefix first):
// "nfet_" -> .nmos4
// "pfet_" -> .pmos4
// "nmos"  -> .nmos4   (catches nmos1v, nmos2v, etc.)
// "pmos"  -> .pmos4
// "nch_"  -> .nmos4   (TSMC variants)
// "pch_"  -> .pmos4
// "npn"   -> .npn
// "pnp"   -> .pnp
// "vpnp"  -> .pnp
// "diode_" -> .diode
// "ndio"  -> .diode
// "pdio"  -> .diode
// "res"   -> .resistor (catches resm1, ressndiff, etc.)
// "cap_"  -> .capacitor
// "mim"   -> .capacitor
// "ind_"  -> .inductor
```

### Pin Translation Strategy

Pin translation must be DeviceKind-aware due to the B/S overload:

```
// For MOSFETs: D->drain, G->gate, S->source, B->body
// For BJTs:    C->collector, B->base, E->emitter, S->sub
// For passives/sources: PLUS->p, MINUS->n
// For controlled sources: inp->inp, inn->inn, outp->outp, outn->outn
// For iprobe: in->p, out->n
```

---

## References

- Cadence Analog Library Reference Guide, Product Version 5.1.41 (June 2004)
- Cadence GPDK045 PDK Reference Manual, Revision 6.0
- Cadence GPDK090 PDK Reference Manual, Revision 4.0
- GlobalFoundries GF180MCU PDK Documentation (gf180mcu-pdk.readthedocs.io)
- Cadence Virtuoso Spectre Circuit Simulator User Guide
- Cadence Community Forums (community.cadence.com)
- TSMC PDK documentation (under NDA -- cell names derived from public tutorials)
