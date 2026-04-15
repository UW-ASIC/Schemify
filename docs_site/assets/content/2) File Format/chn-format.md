# CHN Format Specification

## SYMBOL Section

Declares the external interface. Present in `.chn` and `.chn_prim`. Absent in `.chn_testbench`.

```
SYMBOL inverter
  desc: CMOS inverter

  pins [4]:
    IN   in
    OUT  out
    VDD  inout
    VSS  inout

  params [4]:
    wp = 2u
    wn = 1u
    lp = 100n
    ln = 100n

  spice_prefix: X
```

### Pin Directions

| Direction | Meaning | Examples |
|-----------|---------|---------|
| `in` | Input-only | Gate, clock, enable |
| `out` | Output-driven | Amplifier output |
| `inout` | Bidirectional | Drain, source, supply |

## SCHEMATIC Section

### Instance Tables (TOON-style)

Instances are listed in **type-grouped tabular blocks**. Each device class gets its own table:

```
SCHEMATIC

  nmos [4]{name, w, l, nf, model}:
    M0   2u    100n  1  nch
    M1   2u    100n  1  nch
    M2   4u    100n  2  nch
    M3   4u    100n  2  nch

  pmos [2]{name, w, l, nf, model}:
    M4   4u    100n  1  pch
    M5   4u    100n  1  pch

  capacitors [1]{name, c}:
    CC   2p
```

- `[N]` is the row count guardrail — validators check this matches actual rows
- `{fields}` declares column names once; rows are positional
- Mixed/single instances use key-value form: `instances [1]: XBUF  chn/buffer  strength=4`

### Nets

Named connectivity declarations. Each line is a union operation: "these pins all belong to this net."

```
  nets [7]:
    INP      -> M0.g
    INN      -> M1.g
    tail     -> M0.s, M1.s, M3.d
    out_p    -> M0.d, M4.d, M4.g, M5.g
    out_n    -> M1.d, M5.d, CC.p
    VDD      -> M4.s, M4.b, M5.s, M5.b
    VSS      -> M3.s, M3.b, M0.b, M1.b
```

A pin not appearing in any net declaration is **floating** — a DRC error unless intentional.

### Generate Loops

For repeated structures, use generate loops instead of bus notation:

```
  generate bit in 0..7:
    nmos [1]{name, w, l, nf, model}:
      MDRV_{bit}  1u  100n  1  nch
    nets:
      data_{bit}  -> MDRV_{bit}.d, DFF.q_{bit}
      word_line   -> MDRV_{bit}.g
      bit_{bit}   -> MDRV_{bit}.s
```

### Annotations

Simulation results embedded inline with freshness tracking:

```
  annotations:
    status: fresh         # fresh | stale
    timestamp: 2026-03-20T14:22:00Z
    sim_tool: ngspice 43
    corner: tt

    op_points [4]{inst, vgs, vds, id, gm, gds, vth}:
      M0   0.612  0.611  52.3u  312u  4.1u  0.385
      M1   0.588  0.365  47.7u  298u  3.8u  0.390

    measures:
      dc_gain:  42.3 dB
      ugbw:     85.2 MHz

    notes:
      - "M0/M1 mismatch causing 4.6mV offset"
```

**Annotation status state machine:**
- `fresh` — annotations match the current schematic; trust these values
- `stale` — schematic modified since last simulation; re-run before citing values

Any schematic modification must set `status: stale`.

## Primitive Files (.chn_prim)

A `.chn_prim` declares a leaf device with no internal schematic — its behavior is a SPICE model:

```
chn_prim 1.0

SYMBOL nmos
  desc: N-channel MOSFET

  pins [4]:
    d  inout
    g  in
    s  inout
    b  inout

  params [5]:
    w     = 1u
    l     = 100n
    nf    = 1
    m     = 1
    model = nch_lvt

  spice_prefix: M
  spice_format: "@name @d @g @s @b @model w=@w l=@l nf=@nf m=@m"
  spice_lib: "$PDK/models/nmos.lib" section=tt
```

Generated SPICE line:
```
M0 OUT_N IN_N TAIL VSS nch_lvt w=2u l=100n nf=1 m=1
```

## Testbench Files (.chn_testbench)

No SYMBOL (testbenches are not instantiated). Contains stimulus, DUT, analyses, and measures:

```
chn_testbench 1.0

TESTBENCH tb_opamp_ac
  desc: Open-loop AC response

  includes [1]:
    "$PDK/models/all.lib" section=tt

  instances [3]:
    DUT   chn/opamp    wp_in=10u  cc=2p
    VDD   chn_prim/vsource  dc=1.8
    VAC   chn_prim/vsource  dc=0  ac=1

  nets [4]:
    vdd -> DUT.VDD, VDD.p
    gnd -> DUT.VSS, VDD.n
    inp -> VAC.p, DUT.INP
    out -> DUT.OUT

  analyses [2]:
    op:
    ac: start=1  stop=10G  points_per_dec=20

  measures [2]:
    dc_gain:  find dB(V(out)/V(inp)) at freq=1
    ugbw:     find freq when dB(V(out)/V(inp))=0
```

## Validation Rules

| Check | Rule |
|-------|------|
| `[N]` match | Declared count matches actual row count in every section |
| Floating pins | Every pin of every instance appears in at least one `nets:` entry |
| Duplicate nets | No pin appears in more than one net (short-circuit) |
| Pin existence | Every `inst.pin` reference resolves to a real pin |
| Param coverage | Every param in `spice_format` has a value |
| Supply consistency | All NMOS bulk pins connect to VSS (or explicit body bias net) |
| Annotation freshness | Warn if `status: stale` and task requires simulation data |
