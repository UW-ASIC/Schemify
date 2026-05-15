# XSchem -> Schemify Component Mapping

Comprehensive reference for mapping XSchem built-in symbols (from `xschem_library/devices/`)
and PDK-specific symbols to Schemify's `DeviceKind` enum.

Based on XSchem master branch (v3.4.5+), Schemify convert.zig `mapXSchemStem()` and
`mapXSchemKType()`, and upstream .sym file analysis.

## Status

- Total XSchem built-in symbols (.sym files): 116
- Electrical primitives: 72
- Non-electrical / annotation / HDL: 44
- **Mapped (1:1 exact)**: 58
- **Approximate (needs adaptation)**: 10
- **Unmapped (no Schemify equivalent)**: 4
- **Non-electrical mapped**: 30
- **Non-electrical unmapped / HDL-only**: 14

---

## Existing convert.zig Coverage

Schemify already has two mapping layers:

1. **`mapXSchemKType()`** -- maps the XSchem `type=` attribute (e.g. `type=nmos`, `type=vcvs`)
2. **`mapXSchemStem()`** -- maps the symbol filename stem (e.g. `res`, `capa`, `nmos4`)
3. **`matchFetPrefix()`** -- prefix match for PDK-flavored FET stems (`nfet_*`, `pfet_*`, `nfet3_*`, `pfet3_*`)

The stem map currently has **82 entries**; the ktype map has **37 entries**.

---

## StaticStringMap Candidates -- Exact 1:1 Mappings

These have exact 1:1 mappings and are already present or can go directly into a comptime
StaticStringMap in `mapXSchemStem()`:

### Passives

| XSchem Stem | Schemify DeviceKind | Pins | Pin Names | SPICE Prefix | In convert.zig? | Notes |
|---|---|---|---|---|---|---|
| `res` | `resistor` | 2 | P, M | R | YES | Standard 2-terminal resistor |
| `res_ac` | `resistor` | 2 | P, M | R | YES | Resistor with AC value parameter |
| `res_noisy` | `resistor` | 2 | P, M | R | NO -- add | Resistor with noisy= parameter (ngspice) |
| `res3` | `resistor3` | 3 | P, M, B | R (subckt) | YES | 3-terminal poly resistor |
| `var_res` | `var_resistor` | 3 | C, M, P | R | YES | Variable (potentiometer) resistor |
| `connect` | `resistor` | 2 | p, m | R | YES | Zero-ohm connect (0.01 ohm) |
| `capa` | `capacitor` | 2 | p, m | C | YES | Standard capacitor |
| `capa-2` | `capacitor` | 2 | p, m | C | YES | Polarized capacitor symbol |
| `parax_cap` | `capacitor` | 1 | p | C | YES | Parasitic cap (1 pin + gnd ref) |
| `crystal` | `capacitor` | 2 | P, M | X | YES | Crystal oscillator (subcircuit) |
| `ind` | `inductor` | 2 | p, m | L | YES | Standard inductor |

### Diodes

| XSchem Stem | Schemify DeviceKind | Pins | Pin Names | SPICE Prefix | In convert.zig? | Notes |
|---|---|---|---|---|---|---|
| `diode` | `diode` | 2 | p, m | D | YES | Standard diode |
| `led` | `diode` | 2 | p, m | D (or X) | YES | LED (same pinout as diode) |
| `zener` | `zener` | 2 | p, m | D (or X) | YES | Zener diode |

### MOSFETs

| XSchem Stem | Schemify DeviceKind | Pins | Pin Names | SPICE Prefix | In convert.zig? | Notes |
|---|---|---|---|---|---|---|
| `nmos4` | `nmos4` | 4 | d, g, s, b | M | YES | 4-terminal NMOS |
| `pmos4` | `pmos4` | 4 | d, g, s, b | M | YES | 4-terminal PMOS |
| `nmos3` | `nmos3` | 3 | d, g, s | M (or X) | implicit | 3-terminal NMOS (type=nmos, 3 pins) |
| `pmos3` | `pmos3` | 3 | d, g, s | M (or X) | implicit | 3-terminal PMOS (type=pmos, 3 pins) |
| `nmos4_depl` | `nmos4_depl` | 4 | d, g, s, b | M | YES | Depletion-mode NMOS |
| `rnmos4` | `rnmos4` | 4 | d, g, s, b | M | YES | Round-gate NMOS |
| `nmos-sub` | `nmos_sub` | 3 | d, g, s | M | YES | NMOS with implicit substrate |
| `pmos-sub` | `pmos_sub` | 3 | d, g, s | M | YES | PMOS with implicit substrate |
| `pmoshv4` | `pmoshv4` | 4 | d, g, s, b | M (or X) | YES | High-voltage PMOS |
| `pmosnat` | `pmos4` | 3 | d, g, s | M | NO -- add | Native PMOS (3-pin, type=pmos) |

Note: `nmos` and `pmos` (bare stems) exist as 3-terminal symbols with `type=nmos`/`type=pmos`.
`mapXSchemKType()` handles these by checking pin_count: >=4 -> nmos4/pmos4, else nmos3/pmos3.

### BJTs

| XSchem Stem | Schemify DeviceKind | Pins | Pin Names | SPICE Prefix | In convert.zig? | Notes |
|---|---|---|---|---|---|---|
| `npn` | `npn` | 3 | C, B, E | Q | YES | NPN BJT |
| `pnp` | `pnp` | 3 | B, E, C | Q | YES | PNP BJT (note pin order: B, E, C) |

### JFETs

| XSchem Stem | Schemify DeviceKind | Pins | Pin Names | SPICE Prefix | In convert.zig? | Notes |
|---|---|---|---|---|---|---|
| `njfet` | `njfet` | 3 | d, g, s | J | YES | N-channel JFET |
| `pjfet` | `pjfet` | 3 | d, g, s | J | YES | P-channel JFET |

### Independent Sources

| XSchem Stem | Schemify DeviceKind | Pins | Pin Names | SPICE Prefix | In convert.zig? | Notes |
|---|---|---|---|---|---|---|
| `vsource` | `vsource` | 2 | p, m | V | YES | DC/AC/TRAN voltage source |
| `vsource_arith` | `vsource` | 2 | p, m | V | YES | Arithmetic expression voltage source |
| `isource` | `isource` | 2 | p, m | I | YES | DC/AC/TRAN current source |
| `isource_arith` | `isource` | 2 | p, m | I | YES | Arithmetic expression current source |
| `isource_table` | `isource` | 2 | p, m | I | YES | Table-based current source |
| `sqwsource` | `sqwsource` | 2 | p, m | V | YES | Square-wave source (type=vsource internally) |
| `ammeter` | `ammeter` | 2 | plus, minus | V | YES | Zero-volt ammeter (V src for current meas.) |

### Controlled Sources

| XSchem Stem | Schemify DeviceKind | Pins | Pin Names | SPICE Prefix | In convert.zig? | Notes |
|---|---|---|---|---|---|---|
| `vcvs` | `vcvs` | 4 | p, m, cp, cm | E | YES | Voltage-controlled voltage source |
| `vccs` | `vccs` | 4 | p, m, cp, cm | G | YES | Voltage-controlled current source |
| `ccvs` | `ccvs` | 2 | p, m | H | YES | Current-controlled voltage source |
| `cccs` | `cccs` | 2 | p, m | F | YES | Current-controlled current source |
| `bsource` | `behavioral` | 2 | p, m | B | YES | Behavioral source (B-element) |
| `asrc` | `behavioral` | 2 | p, m | B | YES | Alternate behavioral source name |

### Switches

| XSchem Stem | Schemify DeviceKind | Pins | Pin Names | SPICE Prefix | In convert.zig? | Notes |
|---|---|---|---|---|---|---|
| `switch_ngspice` | `vswitch` | 4 | CP, P, M, CM | S | YES | Voltage-controlled switch (ngspice) |
| `switch` | `vswitch` | 4 | CP, P, M, CM | S (or G) | via ktype | Generic switch (type=switch in ktype map) |
| `switch_v_xyce` | `vswitch` | 4 | CP, P, M, CM | S | NO -- add | Xyce voltage-controlled switch |

### Transmission Lines / Coupling

| XSchem Stem | Schemify DeviceKind | Pins | Pin Names | SPICE Prefix | In convert.zig? | Notes |
|---|---|---|---|---|---|---|
| `k` | `coupling` | 0 | (refs L1, L2) | K | YES | Mutual inductance coupling |

### Labels / Pins / Power

| XSchem Stem | Schemify DeviceKind | Pins | Pin Names | SPICE Prefix | In convert.zig? | Notes |
|---|---|---|---|---|---|---|
| `lab_pin` | `lab_pin` | 1 | p (in) | -- | YES | Net label (type=label) |
| `lab_wire` | `lab_pin` | 1 | p (in) | -- | YES | Wire label variant |
| `lab_show` | `lab_pin` | 1 | p (none) | -- | YES | Display-only label (type=show_label) |
| `lab_generic` | `lab_pin` | 1 | p (in) | -- | NO -- add | Generic label with value field |
| `ipin` | `input_pin` | 1 | p (out) | -- | YES | Hierarchical input port |
| `opin` | `output_pin` | 1 | p (in) | -- | YES | Hierarchical output port |
| `iopin` | `inout_pin` | 1 | p (inout) | -- | YES | Hierarchical bidirectional port |
| `gnd` | `gnd` | 1 | p (inout) | -- | YES | Ground symbol (type=label, lab=0) |
| `vdd` | `vdd` | 1 | p (inout) | -- | YES | VDD power rail (type=label, lab=VDD) |
| `bus_connect` | `lab_pin` | 1 | p (inout) | -- | YES | Bus connection label |
| `bus_connect_nolab` | `lab_pin` | 1 | x (inout) | -- | YES | Bus connection (no label display) |
| `bus_tap` | `lab_pin` | 2 | tap, bus | -- | YES | Bus bit extraction |

### Simulation / Probes

| XSchem Stem | Schemify DeviceKind | Pins | Pin Names | SPICE Prefix | In convert.zig? | Notes |
|---|---|---|---|---|---|---|
| `spice_probe` | `probe` | 1 | p | -- | YES | Voltage probe (save directive) |
| `spice_probe_vdiff` | `probe_diff` | 2 | p, m | -- | YES | Differential voltage probe |
| `ngspice_probe` | `probe` | 1 | p | -- | YES | ngspice-specific probe |
| `ngspice_get_value` | `probe` | 0 | (none) | -- | YES | ngspice OP annotation (devicename ref) |
| `ngspice_get_expr` | `probe` | 0 | (none) | -- | YES | ngspice expression annotation |
| `device_param_probe` | `probe` | 0 | (none) | -- | YES | Device parameter probe |
| `scope` | `probe` | 1 | p (in) | -- | NO -- add | Scope marker (1-pin) |
| `scope2` | `probe_diff` | 2 | p, m (in) | -- | NO -- add | Scope marker (2-pin differential) |
| `scope_ammeter` | `ammeter` | 0 | (none) | -- | NO -- add | Scope current measurement marker |

### Non-Electrical / Annotation

| XSchem Stem | Schemify DeviceKind | Pins | Pin Names | SPICE Prefix | In convert.zig? | Notes |
|---|---|---|---|---|---|---|
| `title` | `title` | 0 | (none) | -- | YES | Title block (type=logo) |
| `title-2` | `title` | 0 | (none) | -- | YES | Title block variant 2 |
| `title-3` | `title` | 0 | (none) | -- | YES | Title block variant 3 |
| `launcher` | `launcher` | 0 | (none) | -- | YES | URL/script launcher |
| `noconn` | `noconn` | 1 | p (inout) | -- | YES | No-connection marker |
| `code` | `code` | 0 | (none) | -- | YES | SPICE code block (type=netlist_commands) |
| `code_shown` | `code` | 0 | (none) | -- | YES | SPICE code block (displayed) |
| `simulator_commands` | `code` | 0 | (none) | -- | YES | Simulator-specific code block |
| `simulator_commands_shown` | `code` | 0 | (none) | -- | YES | Simulator-specific code (displayed) |
| `netlist_options` | `code` | 0 | (none) | -- | YES | Netlist generation options |
| `arch_declarations` | `code` | 0 | (none) | -- | YES | VHDL architecture declarations |
| `architecture` | `code` | 0 | (none) | -- | YES | VHDL architecture body |
| `package_not_shown` | `annotation` | 0 | (none) | -- | YES | VHDL package (hidden) |
| `short` | `generic` | 2 | (two pins) | -- | YES | Short circuit / wire jumper |
| `param` | `param` | 0 | (none) | -- | via ktype | .param block (type=spice_parameters) |
| `param_agauss` | `param` | 0 | (none) | -- | NO -- add | .param with agauss() mismatch |

---

## Approximate Mappings

These need property translation, pin reordering, or semantic adaptation:

| XSchem Stem | Closest DeviceKind | Issue | Resolution |
|---|---|---|---|
| `vsource_pwl` | `vsource` | 4 pins (p, m, cp, cm) -- PWL lookup uses control pins | Map to `vsource`. Extra cp/cm pins are for piecewise-linear lookup table control; strip cp/cm in pure SPICE mode. Currently mapped as `vsource` in convert.zig but pin count differs from standard vsource. |
| `isource_pwl` | `isource` | 4 pins (p, m, cp, cm); type=isource_only_for_hspice | Map to `isource`. The ktype `isource_only_for_hspice` is already handled. Extra pins are HSPICE PWL control. |
| `vcr` | `resistor` | 4 pins (p, m, cp, cm); voltage-controlled resistor | Currently mapped to `resistor` in ktype map. Really a 4-pin dependent element. Could be `behavioral` instead. |
| `vcvs_limit` | `vcvs` | 4 pins (P, M, CP, CM); type=xline (XSPICE a-device) | Behavioral limiter version of VCVS. Map to `vcvs` or `behavioral`. |
| `vccs_limit` | `vccs` | 4 pins (P, M, CP, CM); type=xline (XSPICE a-device) | Behavioral limiter version of VCCS. Map to `vccs` or `behavioral`. |
| `filesource` | `vsource` | 2 pins; type=vsource but reads from file | Map to `vsource`. Properties include `file=`, `amploffset=`, `amplscale=`. |
| `flash_cell` | `nmos4` | 4 pins (D, G, S, B); type=flash | Flash memory cell, functionally a modified MOSFET. Map to `generic` (current) or add `flash` DeviceKind. |
| `single2cm` | `subckt` | 5 pins (vin, VSS, vp, vcm, vn); type=primitive | Single-ended to common-mode converter. Map to `subckt`. |
| `single2dm` | `subckt` | 5 pins (vin, VSS, vp, vcm, vn); type=primitive | Single-ended to differential converter. Map to `subckt`. |
| `rgb_led` | `rgb_led` | 6 pins (b, g, r, gr, gg, gb); type=diode | RGB LED component. DeviceKind `rgb_led` exists but currently unmapped in convert.zig. Add mapping. |

---

## Unmapped -- No Schemify Equivalent Exists

| XSchem Stem | XSchem type= | Description | Pins | Suggested DeviceKind |
|---|---|---|---|---|
| `delay_line` | `transmission_line` | Ideal transmission line (z0, td) | 4: nap, nam, nbp, nbm | `tline` |
| `adc_bridge` | `delay` | XSPICE A/D bridge (analog-to-digital) | 2: s (in), d (out) | `generic` or new `adc_bridge` |
| `dac_bridge` | `delay` | XSPICE D/A bridge (digital-to-analog) | 2: s (in), d (out) | `generic` or new `dac_bridge` |
| `ngspice_analog_delay` | `analog_delay` | XSPICE analog delay element | 3: in, out, cntrl | `generic` |
| `stop` | `stop` | Simulation stop condition | 1: node (in) | `annotation` |
| `connector` | `connector` | PCB connector element | 1+: conn_N (inout) | `annotation` |
| `conn_NxM` variants | `connector` | Multi-pin PCB connectors (3x1, 4x1, 6x1, 8x1, 10x2, 14x1) | N*M pins | `annotation` |
| `ic` | `ic` | Initial condition (.IC) | 1: p (in) | `annotation` or `param` |
| `assign` | `delay` | Verilog assign (digital buffer/delay) | 2: d (out), s (in) | `generic` |
| `use` | `use` | VHDL use/library declaration | 0 | `code` |
| `package` | `package` | VHDL package declaration | 0 | `code` |
| `generic_pin` | `generic` | VHDL generic parameter | 0 | `annotation` |
| `verilog_preprocessor` | `verilog_preprocessor` | Verilog `include/`define | 0 | `code` |
| `verilog_timescale` | `timescale` | Verilog `timescale | 0 | `code` |
| `verilog_delay` | `subcircuit` | Verilog delay sub-circuit | 2: d, s | `code` or `generic` |
| `port_attributes` | (annotation) | VHDL port attribute text | 0 | `annotation` |
| `attributes` | (annotation) | VHDL attribute text | 0 | `annotation` |
| `netlist` | `netlist_commands` | Raw netlist text block | 0 | `code` |
| `netlist_at_end` | `netlist_commands` | Raw netlist appended at end | 0 | `code` |
| `netlist_not_shown` | `netlist_commands` | Hidden raw netlist block | 0 | `code` |
| `netlist_not_shown_at_end` | `netlist_commands` | Hidden raw netlist appended at end | 0 | `code` |
| `bindkeys_cheatsheet` | (logo) | Keyboard shortcut reference image | 0 | `annotation` |
| `intuitive_interface_cheatsheet` | (logo) | Interface cheat sheet image | 0 | `annotation` |
| `crystal-2` | `crystal` | Crystal variant (same as crystal) | 2 | `capacitor` (same as crystal) |

---

## Recommended Additions to mapXSchemStem()

New entries to add (not yet in convert.zig):

```
.{ "res_noisy", .resistor },
.{ "pmosnat", .pmos3 },           // 3-pin native PMOS (type=pmos)
.{ "lab_generic", .lab_pin },
.{ "scope", .probe },             // NOTE: already in ktype map, add to stem map too
.{ "scope2", .probe_diff },
.{ "scope_ammeter", .ammeter },
.{ "switch_v_xyce", .vswitch },
.{ "param_agauss", .param },
.{ "filesource", .vsource },
.{ "rgb_led", .rgb_led },
.{ "crystal-2", .capacitor },
.{ "delay_line", .tline },
.{ "netlist", .code },
.{ "netlist_at_end", .code },
.{ "netlist_not_shown", .code },
.{ "netlist_not_shown_at_end", .code },
.{ "use", .code },
.{ "package", .code },
.{ "verilog_preprocessor", .code },
.{ "verilog_timescale", .code },
.{ "port_attributes", .annotation },
.{ "attributes", .annotation },
.{ "generic_pin", .annotation },
.{ "stop", .annotation },
.{ "connector", .annotation },
.{ "ic", .annotation },
.{ "bindkeys_cheatsheet", .annotation },
.{ "intuitive_interface_cheatsheet", .annotation },
```

---

## Recommended Additions to mapXSchemKType()

New entries to add to the ktype map:

```
.{ "transmission_line", .tline },
.{ "xline", .behavioral },        // XSPICE analog behavioral (vcvs_limit, vccs_limit)
.{ "spice_parameters", .param },  // Already handled by param stem but ktype backup
.{ "polarized_capacitor", .capacitor },  // Already present
.{ "analog_delay", .generic },    // Already present
.{ "crystal", .capacitor },       // type=crystal on crystal.sym
.{ "delay", .generic },           // Already present
.{ "flash", .generic },           // Already present
.{ "ic", .annotation },           // .IC initial condition
.{ "use", .code },                // VHDL use declaration
.{ "package", .code },            // VHDL package
```

---

## PDK-Specific Mappings

### Sky130 (sky130_fd_pr__*)

Handled by `pdk_remap.zig` prefix matching. All sky130_fd_pr symbols use 4-pin MOSFET
convention (d, g, s, b) for FETs.

| Symbol Pattern | Pins | DeviceKind | Properties to Preserve | Properties to Strip |
|---|---|---|---|---|
| `sky130_fd_pr__nfet_01v8` | 4: d,g,s,b | `nmos4` | w, l, m | sa, sb, sd, nf, mult, VPWR, VGND, VPB, VNB, topography, area, perim |
| `sky130_fd_pr__nfet_01v8_lvt` | 4 | `nmos4` | w, l, m | (same) |
| `sky130_fd_pr__nfet_01v8_esd` | 4 | `nmos4` | w, l, m | (same) |
| `sky130_fd_pr__nfet_03v3_nvt` | 4 | `nmos4` | w, l, m | (same) |
| `sky130_fd_pr__nfet_05v0_nvt` | 4 | `nmos4` | w, l, m | (same) |
| `sky130_fd_pr__nfet_20v0` | 4 | `nmos4` | w, l, m | (same) |
| `sky130_fd_pr__nfet_20v0_iso` | 4 | `nmos4` | w, l, m | (same) |
| `sky130_fd_pr__nfet_20v0_nvt` | 4 | `nmos4` | w, l, m | (same) |
| `sky130_fd_pr__nfet_20v0_zvt` | 4 | `nmos4` | w, l, m | (same) |
| `sky130_fd_pr__nfet_g5v0d10v5` | 4 | `nmos4` | w, l, m | (same) |
| `sky130_fd_pr__nfet_g5v0d16v0` | 4 | `nmos4` | w, l, m | (same) |
| `sky130_fd_pr__pfet_01v8` | 4: d,g,s,b | `pmos4` | w, l, m | (same) |
| `sky130_fd_pr__pfet_01v8_hvt` | 4 | `pmos4` | w, l, m | (same) |
| `sky130_fd_pr__pfet_01v8_lvt` | 4 | `pmos4` | w, l, m | (same) |
| `sky130_fd_pr__pfet_20v0` | 4 | `pmos4` | w, l, m | (same) |
| `sky130_fd_pr__pfet_g5v0d10v5` | 4 | `pmos4` | w, l, m | (same) |
| `sky130_fd_pr__pfet_g5v0d16v0` | 4 | `pmos4` | w, l, m | (same) |
| `sky130_fd_pr__res_generic_*` | 2-3 | `resistor` | R, W, L, m | (same) |
| `sky130_fd_pr__res_high_po*` | 2-3 | `resistor` | R, W, L, m | (same) |
| `sky130_fd_pr__res_xhigh_po*` | 2-3 | `resistor` | R, W, L, m | (same) |
| `sky130_fd_pr__res_iso_pw` | 2-3 | `resistor` | R, W, L, m | (same) |
| `sky130_fd_pr__cap_mim_m3_1` | 2 | `capacitor` | C, W, L, m | (same) |
| `sky130_fd_pr__cap_mim_m3_2` | 2 | `capacitor` | C, W, L, m | (same) |
| `sky130_fd_pr__cap_var_hvt` | 2 | `capacitor` | C, W, L, m | (same) |
| `sky130_fd_pr__cap_var_lvt` | 2 | `capacitor` | C, W, L, m | (same) |
| `sky130_fd_pr__diode` | 2 | `diode` | area, perim, m | (same) |
| `sky130_fd_pr__lvsdiode` | 2 | `diode` | area, perim, m | (same) |
| `sky130_fd_pr__photodiode` | 2 | `diode` | area, m | (same) |

**3-pin FET variants** (nfet3_*, pfet3_*): These use the `matchFetPrefix()` function
in convert.zig, mapping to `nmos3` and `pmos3` respectively. Examples:
- `nfet3_01v8`, `nfet3_01v8_lvt`, `nfet3_03v3_nvt`, `nfet3_05v0_nvt`, `nfet3_20v0`,
  `nfet3_g5v0d10v5`, `nfet3_g5v0d16v0`
- `pfet3_01v8`, `pfet3_01v8_hvt`, `pfet3_01v8_lvt`, `pfet3_20v0`,
  `pfet3_g5v0d10v5`, `pfet3_g5v0d16v0`

**_nf suffix variants**: Some FETs have `_nf` suffix (nfet_01v8_nf, pfet_01v8_nf, etc.)
indicating a multi-finger layout parameter. Same DeviceKind mapping, the `nf` property
controls fingers.

**BJTs**:
- `npn_05v5` -> `npn`
- `pnp_05v5` -> `pnp`

**Special**:
- `reram` -> `generic` (no Schemify equivalent)
- `vpp_cap` -> `capacitor` (vertical parallel plate cap)
- `annotate_fet_params` -> `annotation` (display only)
- `corner` -> `code` (process corner include)

**Standard cells** (sky130_fd_sc_hd__*, sky130_fd_sc_*): Handled by `pdk_remap.zig`
`remapStdCell()` with gate pattern matching (inv, buf, nand2-4, nor2-4, and2-4, or2-4,
xor2, xnor2, mux2, mux4, dfxtp, dfrtp, dlrtp, conb, tap). All map to `digital_instance`.

### GF180MCU (gf180mcu_fd_pr__*)

The GF180MCU PDK uses a naming convention similar to Sky130 but with different voltage
ratings and device variants.

| Symbol Pattern | Pins | DeviceKind | Notes |
|---|---|---|---|
| `gf180mcu_fd_pr__nfet_03v3` (nmos_3p3) | 4: d,g,s,b | `nmos4` | 3.3V NMOS |
| `gf180mcu_fd_pr__nfet_06v0` (nmos_6p0) | 4 | `nmos4` | 6V NMOS |
| `gf180mcu_fd_pr__nfet_06v0_nvt` (nmos_6p0_nat) | 4 | `nmos4` | 6V native-Vt NMOS |
| `gf180mcu_fd_pr__nfet_03v3_dss` (nmos_3p3_sab) | 4 | `nmos4` | 3.3V SAB NMOS |
| `gf180mcu_fd_pr__nfet_06v0_dss` | 4 | `nmos4` | 6V DSS NMOS |
| `gf180mcu_fd_pr__nfet_10v0_asym` | 4 | `nmos4` | 10V asymmetric NMOS |
| `gf180mcu_fd_pr__pfet_03v3` (pmos_3p3) | 4: d,g,s,b | `pmos4` | 3.3V PMOS |
| `gf180mcu_fd_pr__pfet_06v0` (pmos_6p0) | 4 | `pmos4` | 6V PMOS |
| `gf180mcu_fd_pr__pfet_03v3_dss` (pmos_3p3_sab) | 4 | `pmos4` | 3.3V SAB PMOS |
| `gf180mcu_fd_pr__pfet_06v0_dss` | 4 | `pmos4` | 6V DSS PMOS |
| `gf180mcu_fd_pr__pfet_10v0_asym` | 4 | `pmos4` | 10V asymmetric PMOS |
| `gf180mcu_fd_pr__cap_nmos_03v3` (nmoscap_3p3) | 2 | `capacitor` | 3.3V NMOS cap |
| `gf180mcu_fd_pr__cap_nmos_06v0` (nmoscap_6p0) | 2 | `capacitor` | 6V NMOS cap |
| `gf180mcu_fd_pr__cap_pmos_03v3` (pmoscap_3p3) | 2 | `capacitor` | 3.3V PMOS cap |
| `gf180mcu_fd_pr__cap_pmos_06v0` (pmoscap_6p0) | 2 | `capacitor` | 6V PMOS cap |
| `gf180mcu_fd_pr__cap_mim_2p0fF` (mim_2p0fF) | 2 | `capacitor` | MIM capacitor |
| `gf180mcu_fd_pr__res_nwell` (nwell) | 2 | `resistor` | N-well resistor |
| `gf180mcu_fd_pr__res_ppolyf_u` (ppolyf_u) | 2-3 | `resistor` | Unsilicided P+ poly |
| `gf180mcu_fd_pr__res_npolyf_u` (npolyf_u) | 2-3 | `resistor` | Unsilicided N+ poly |
| `gf180mcu_fd_pr__res_pplus_u` (pplus_u) | 2 | `resistor` | Unsilicided P+ diffusion |
| `gf180mcu_fd_pr__res_nplus_u` (nplus_u) | 2 | `resistor` | Unsilicided N+ diffusion |
| `gf180mcu_fd_pr__res_rm1` (rm1) | 2 | `resistor` | Metal-1 resistor |
| `gf180mcu_fd_pr__res_rm2` | 2 | `resistor` | Metal-2 resistor |
| `gf180mcu_fd_pr__res_rm3` | 2 | `resistor` | Metal-3 resistor |
| `gf180mcu_fd_pr__diode_np_03v3` (np_3p3) | 2 | `diode` | 3.3V N+/P-well diode |
| `gf180mcu_fd_pr__diode_dnwpw` (dnwpw) | 2 | `diode` | Deep N-well/P-well diode |
| `gf180mcu_fd_pr__vnpn_10x10` (vnpn_10x10) | 3 | `npn` | Vertical NPN 10x10 |
| `gf180mcu_fd_pr__vpnp_10x10` (vpnp_10x10) | 3 | `pnp` | Vertical PNP 10x10 |

**Properties to strip**: sa, sb, sd, nf, mult (same as Sky130 set, plus GF-specific
layout params like `dw`, `dl`).

**Prefix matching recommendation**: Add to `matchFetPrefix()` or a new `matchGF180Prefix()`:
```
.{ "gf180mcu_fd_pr__nfet", .nmos4 },
.{ "gf180mcu_fd_pr__pfet", .pmos4 },
.{ "gf180mcu_fd_pr__res",  .resistor },
.{ "gf180mcu_fd_pr__cap",  .capacitor },
.{ "gf180mcu_fd_pr__diode", .diode },
.{ "gf180mcu_fd_pr__vnpn", .npn },
.{ "gf180mcu_fd_pr__vpnp", .pnp },
```

### IHP SG13G2 (sg13_* / sg13g2_*)

The IHP SG13G2 is a 130nm BiCMOS process with SiGe HBTs.

| Symbol Pattern | Pins | DeviceKind | Notes |
|---|---|---|---|
| `sg13_lv_nmos` | 4: d,g,s,b | `nmos4` | Low-voltage (1.2V) NMOS |
| `sg13_hv_nmos` | 4: d,g,s,b | `nmos4` | High-voltage (3.3V) NMOS |
| `sg13_lv_pmos` | 4: d,g,s,b | `pmos4` | Low-voltage (1.2V) PMOS |
| `sg13_hv_pmos` | 4: d,g,s,b | `pmos4` | High-voltage (3.3V) PMOS |
| `npn13g2` | 3: C,B,E | `npn` | SiGe HBT NPN (high-speed) |
| `npn13g2l` | 3: C,B,E | `npn` | SiGe HBT NPN (low-noise) |
| `npn13g2v` | 3: C,B,E | `npn` | SiGe HBT NPN (high-voltage) |
| `pnpMPA` | 3: C,B,E | `pnp` | PNP transistor |
| `rsil` | 2 | `resistor` | Silicided poly resistor |
| `rppd` | 2-3 | `resistor` | P+ poly resistor |
| `rhigh` | 2-3 | `resistor` | High-sheet-resistance poly |
| `ntap1` | 2 | `resistor` | N-tap resistor |
| `ptap1` | 2 | `resistor` | P-tap resistor |
| `cap_cmim` | 2 | `capacitor` | MIM capacitor |
| `cap_cpara` | 2 | `capacitor` | Parasitic capacitor |
| `cap_rfcmim` | 2 | `capacitor` | RF MIM capacitor |
| `dantenna` | 2 | `diode` | Antenna diode |
| `dpantenna` | 2 | `diode` | P-type antenna diode |

**Prefix matching recommendation**: Add to a new `matchSG13Prefix()`:
```
.{ "sg13_lv_nmos", .nmos4 },
.{ "sg13_hv_nmos", .nmos4 },
.{ "sg13_lv_pmos", .pmos4 },
.{ "sg13_hv_pmos", .pmos4 },
.{ "npn13g2",      .npn },
.{ "pnpMPA",       .pnp },
```

Or more generally with prefix matching:
```
.{ "sg13_",   detect nmos/pmos from name },
.{ "npn13",   .npn },
.{ "pnpMPA",  .pnp },
```

**Properties to strip**: `Absvar`, `AREAfactor`, `STI` (IHP-specific layout params).

---

## XSchem type= Attribute Reference

Complete list of `type=` values encountered in xschem_library/devices/ and their
Schemify mapping via `mapXSchemKType()`:

| XSchem type= | Schemify DeviceKind | In ktype map? | Notes |
|---|---|---|---|
| `nmos` | `nmos3` or `nmos4` | YES (special) | Pin-count dependent (>=4 -> nmos4) |
| `pmos` | `pmos3` or `pmos4` | YES (special) | Pin-count dependent (>=4 -> pmos4) |
| `resistor` | (from stem) | NO | Handled by stem map (res, var_res, connect) |
| `capacitor` | (from stem) | NO | Handled by stem map |
| `inductor` | (from stem) | NO | Handled by stem map |
| `diode` | (from stem) | NO | Handled by stem map |
| `npn` | (from stem) | NO | Handled by stem map |
| `pnp` | (from stem) | NO | Handled by stem map |
| `njfet` | (from stem) | NO | Handled by stem map |
| `pjfet` | (from stem) | NO | Handled by stem map |
| `vsource` | (from stem) | NO | Handled by stem map |
| `isource` | (from stem) | NO | Handled by stem map |
| `vcvs` | `vcvs` | YES | In ktype map |
| `vccs` | `vccs` | YES | In ktype map |
| `ccvs` | (from stem) | NO | Handled by stem map |
| `cccs` | (from stem) | NO | Handled by stem map |
| `source` | `behavioral` | YES | B-source / behavioral (bsource, asrc) |
| `subcircuit` | `subckt` | YES | Hierarchical subcircuit |
| `primitive` | `subckt` | YES | XSPICE or behavioral primitive |
| `label` | `lab_pin` | YES | Net label (lab_pin, lab_wire, gnd, vdd) |
| `show_label` | `lab_pin` | YES | Display-only net label |
| `ipin` | `input_pin` | YES | Hierarchical input port |
| `opin` | `output_pin` | YES | Hierarchical output port |
| `iopin` | `inout_pin` | YES | Hierarchical bidirectional port |
| `bus_tap` | `lab_pin` | YES | Bus bit extraction |
| `netlist_commands` | `code` | YES | Inline SPICE/simulator commands |
| `netlist_options` | `code` | YES | Netlist options block |
| `architecture` | `code` | YES | VHDL architecture |
| `timescale` | `code` | YES | Verilog timescale |
| `verilog_preprocessor` | `code` | YES | Verilog preprocessor directive |
| `logo` | `title` | YES | Title/logo block |
| `launcher` | `launcher` | YES | URL/script launcher |
| `noconn` | `noconn` | YES | No-connection marker |
| `probe` | `probe` | YES | Voltage/parameter probe |
| `scope` | `probe` | YES | Oscilloscope marker |
| `stop` | `annotation` | YES | Simulation stop condition |
| `connector` | `annotation` | YES | PCB connector |
| `short` | `generic` | YES | Short circuit element |
| `coupler` | `coupling` | YES | Mutual inductance |
| `switch` | `vswitch` | YES | Voltage-controlled switch |
| `vcr` | `resistor` | YES | Voltage-controlled resistor |
| `isource_only_for_hspice` | `isource` | YES | HSPICE-only current source |
| `polarized_capacitor` | `capacitor` | YES | Polarized capacitor |
| `poly_resistor` | `resistor` | YES | Poly resistor (res3 with body pin) |
| `parax_cap` | `capacitor` | YES | Parasitic capacitor |
| `crystal` | `capacitor` | YES | Crystal oscillator |
| `delay` | `generic` | YES | Digital delay / A-D bridge |
| `delay_eldo` | `generic` | YES | Eldo analog delay |
| `analog_delay` | `generic` | YES | XSPICE analog delay |
| `flash` | `generic` | YES | Flash memory cell |
| `ic` | `generic` | YES | Initial condition |
| `jumper` | `generic` | YES | PCB jumper |
| `transmission_line` | -- | NO -- add | Ideal transmission line |
| `xline` | -- | NO -- add | XSPICE behavioral line (limiter) |
| `spice_parameters` | -- | NO -- add | .param block |
| `ammeter` | -- | NO | Handled by stem map |
| `use` | -- | NO -- add | VHDL use declaration |
| `package` | -- | NO -- add | VHDL package |
| `arch_declarations` | -- | NO | Handled by stem map |
| `generic` | -- | NO | VHDL generic parameter |

---

## Pin Convention Summary

XSchem uses consistent pin naming across most symbols:

| Category | Pin Names | Pin Order (SPICE @pinlist) |
|---|---|---|
| 2-terminal passive | p (plus), m (minus) | p m |
| 2-terminal source | p (plus), m (minus) | p m |
| 3-terminal MOSFET | d, g, s | d g s |
| 4-terminal MOSFET | d, g, s, b | d g s b |
| 3-terminal BJT NPN | C, B, E | C B E |
| 3-terminal BJT PNP | B, E, C (or C,B,E) | varies -- check format= |
| 3-terminal JFET | d, g, s | d g s |
| 4-terminal controlled src | p, m, cp, cm | p m cp cm (or @@P @@M @@CP @@CM) |
| 2-terminal controlled src | p, m | p m (+ vnam= property for CC) |
| Label/pin | p | p |
| Bus tap | tap, bus | tap bus |

Important: PNP pin order varies between XSchem versions. The `format=` attribute in the
.sym file is authoritative for SPICE netlist pin ordering.

---

## SPICE Prefix Reference

| SPICE Prefix | Device Type | XSchem Stems |
|---|---|---|
| R | Resistor | res, res_ac, res_noisy, connect, var_res, vcr |
| C | Capacitor | capa, capa-2, parax_cap |
| L | Inductor | ind |
| D | Diode | diode, zener, led |
| M | MOSFET | nmos*, pmos*, nfet_*, pfet_* |
| Q | BJT | npn, pnp |
| J | JFET | njfet, pjfet |
| V | Voltage source | vsource*, ammeter, sqwsource |
| I | Current source | isource* |
| E | VCVS | vcvs, vcvs_limit |
| G | VCCS | vccs, vccs_limit |
| H | CCVS | ccvs |
| F | CCCS | cccs |
| B | Behavioral | bsource, asrc |
| S | V-switch | switch_ngspice, switch_v_xyce |
| K | Coupling | k |
| T | Transmission line | delay_line |
| X | Subcircuit | (any with spiceprefix=X) |
| A | XSPICE | adc_bridge, dac_bridge, ngspice_analog_delay |

Note: Many symbols use `@spiceprefix` in their format string, which defaults to empty
but can be overridden to `X` to wrap the device in a subcircuit call.
