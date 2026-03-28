# .chn Format Specification v1.0

> **Purpose:** This document is the complete reference needed to implement .chn, .chn_prim, and .chn_testbench parsers, writers, and LLM integrations.

---

## 0. Design Philosophy

**.chn is to xschem what TOON is to JSON:** same circuit data model, different encoding, optimized for LLM consumption instead of GUI rendering.

Core axioms:

1. **Zero geometry in connectivity.** Coordinates are rendering concerns, banished to a low-priority `drawing:` section.
2. **Explicit named nets.** No implicit "wires touching = connected." Every connection is a declared `net -> inst.pin` statement.
3. **Schema-once, rows-stream.** Instance lists are tabular (TOON-style): field names appear once in a header, device rows are positional.
4. **`[N]` guardrails everywhere.** Every list declares its length. LLMs (and validators) can detect truncation, duplication, and drift.
5. **Lossless round-trip.** `.chn ←→ xschem .sch ←→ SPICE netlist`. No information is invented or destroyed.
6. **Annotations are inline and timestamped.** Simulation results live _in_ the file with a freshness status, not in a sidecar.

---

## 1. File Types

| Extension        | Has SYMBOL | Has SCHEMATIC | Purpose                          |
| ---------------- | ---------- | ------------- | -------------------------------- |
| `.chn`           | Yes        | Yes           | Reusable component (subcircuit)  |
| `.chn_prim`      | Yes        | No            | Leaf device backed by SPICE .lib |
| `.chn_testbench` | No         | Yes           | Top-level stimulus & measurement |

---

## 2. Syntax Fundamentals

| Rule            | Detail                                                                                   |
| --------------- | ---------------------------------------------------------------------------------------- |
| Encoding        | UTF-8                                                                                    |
| Comments        | `#` to end of line                                                                       |
| Indentation     | 2 spaces per level (significant, like YAML/TOON)                                         |
| Strings         | Unquoted unless containing `: , -> { } [ ] " #` or leading/trailing whitespace           |
| Expressions     | `{expr}` — e.g. `{wp*2}`, `{vdd/2}`                                                      |
| Net arrow       | `->` separates net name from pin list                                                    |
| Pin reference   | `instance.pin` — dot notation                                                            |
| File header     | First line: `chn 1.0`, `chn_prim 1.0`, or `chn_testbench 1.0`                            |
| Section markers | ALL-CAPS keywords: `SYMBOL`, `SCHEMATIC`, `TESTBENCH`                                    |
| List headers    | `section_name [N]:` — N = item count guardrail                                           |
| Tabular headers | `section_name [N]{col1, col2, ...}:` — TOON-style                                        |
| Delimiter       | Default `,` within tabular rows. Override per-section: `[N\t]` for tab, `[N\|]` for pipe |

---

## 3. SYMBOL Section

Declares the external interface. Present in `.chn` and `.chn_prim`. Absent in `.chn_testbench`.

```
SYMBOL <name>
  desc: <one-line description>

  pins [N]:
    <name>  <direction>  # optional comment
    ...

  params [N]:
    <name> = <default_value>
    ...

  spice_prefix: <letter>   # M, R, C, X, etc.
```

### Pin Directions

| Direction | Meaning       | Examples              |
| --------- | ------------- | --------------------- |
| `in`      | Input-only    | Gate, clock, enable   |
| `out`     | Output-driven | Amplifier output      |
| `inout`   | Bidirectional | Drain, source, supply |

### Example

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

---

## 4. SCHEMATIC Section

Declares the internal implementation. Present in `.chn` and `.chn_testbench`.

### 4.1 Instances

Instances are listed in **type-grouped tabular blocks** for maximum token efficiency. Each device class gets its own table with class-specific columns.

```
SCHEMATIC

  # Type-grouped tabular blocks (TOON-style: schema once, rows stream)
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

  # Non-uniform or single instances use key-value form
  instances [1]:
    XBUF  chn/buffer  strength=4  fanout=8
```

**Rules:**

- The type-group name (`nmos`, `pmos`, `capacitors`) maps to a `.chn_prim` file by convention. The full path can be declared once at file level or inferred from a library search path.
- `[N]` in each header is the row count guardrail.
- `{fields}` declares column names exactly once.
- Rows are whitespace-delimited (spaces or tabs). Within a row, values are positional per the header.
- For mixed/non-uniform instances, use the `instances [N]:` list form with `key=value` pairs.

### 4.2 Nets

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

**Rules:**

- Net name is everything before `->`.
- Pin list is comma-separated `instance.pin` references after `->`.
- `[7]` guardrail = exactly 7 net declarations must follow.
- A pin not appearing in any net declaration is **floating** — a DRC error unless intentional.
- For hierarchical probing, use dot-path: `DUT.OPAMP.stage1_out` (TOON key-folding principle, matches SPICE `XDUT.XOPAMP` convention).

### 4.3 Buses and Generate Loops

**Decision: use generate loops, not bus-expansion notation.**

Why: LLMs handle code-generation patterns (for loops, range expressions) far better than they handle array-indexing notation with implicit expansion. Research shows LLMs trained on billions of lines of code have strong priors for `for i in range(N)` patterns but weak priors for hardware-specific `[7:0]` slice semantics. A generate block is also more explicit about what it produces — the LLM (and the validator) can verify the expansion.

```
  generate bit in 0..7:
    nmos [1]{name, w, l, nf, model}:
      MDRV_{bit}  1u  100n  1  nch
    nets:
      data_{bit}  -> MDRV_{bit}.d, DFF.q_{bit}
      word_line   -> MDRV_{bit}.g
      bit_{bit}   -> MDRV_{bit}.s
```

**Rules:**

- `generate <var> in <start>..<end>:` — inclusive range, integer only.
- `{var}` in names/references is substituted. `MDRV_{bit}` expands to `MDRV_0`, `MDRV_1`, ... `MDRV_7`.
- Nested generates are allowed: `generate row in 0..3:` inside `generate col in 0..3:`.
- The generate block is syntactic sugar — a validator or netlister expands it before processing, producing exactly the same flat instance/net lists.
- The LLM can reason about the _pattern_ without enumerating 256 instances.

### 4.4 Annotations (Inline, Timestamped)

Simulation results, operating points, and design notes are embedded directly in the file — not in a sidecar. Each annotation carries a **freshness status**.

```
  annotations:
    status: stale              # stale | fresh
    timestamp: 2026-03-20T14:22:00Z
    sim_tool: ngspice 43
    corner: tt

    node_voltages:
      VDD:     1.800
      out_p:   1.023
      out_n:   0.777
      tail:    0.412

    op_points [4]{inst, vgs, vds, id, gm, gds, vth}:
      M0   0.612  0.611  52.3u  312u  4.1u  0.385
      M1   0.588  0.365  47.7u  298u  3.8u  0.390
      M4  -0.777 -0.777  52.3u  287u  3.2u  0.401
      M5  -0.777 -1.023  47.7u  279u  3.1u  0.398

    measures:
      dc_gain:  42.3 dB
      ugbw:     85.2 MHz
      pm:       62.1 deg

    notes:
      - "M0/M1 mismatch causing 4.6mV offset — consider increasing L"
      - "Phase margin marginal at ff corner, check CC sizing"
```

**Status semantics:**

- `fresh` — annotations were generated from the current schematic. The LLM can trust these values.
- `stale` — the schematic has been modified since the last simulation. The LLM should note that values may be outdated and suggest re-simulation if the task requires accurate numbers.

**Rules:**

- `annotations:` section can appear inside `SCHEMATIC` (component-level) or at top level in `.chn_testbench` (testbench results).
- The `status` field is mandatory. `timestamp`, `sim_tool`, `corner` are strongly recommended.
- Tabular format used for `op_points` (TOON principle: many similar rows → schema once).
- `notes:` is a free-form list for human/AI design observations.
- When an LLM modifies the schematic (adds instances, changes params, rewires nets), it must set `status: stale`. The timestamp remains unchanged — it records _when the sim ran_, not when the file was edited.

---

## 5. `.chn_prim` — Primitive Devices

A `.chn_prim` file declares a leaf-level device with no internal schematic. Its behavior is defined by a SPICE model library.

### 5.1 Structure

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

### 5.2 How Primitives Map to SPICE

The `spice_format` is a template string. At netlist time:

1. `@name` → instance name (e.g., `M0`)
2. `@d`, `@g`, `@s`, `@b` → resolved net names from parent schematic's `nets:` section, in the order pins are declared
3. `@model` → value of the `model` parameter, which names a `.MODEL` or `.SUBCKT` in the `.lib` file
4. `@w`, `@l`, etc. → parameter values (from defaults or overridden by parent)

**Generated SPICE line:**

```
M0 OUT_N IN_N TAIL VSS nch_lvt w=2u l=100n nf=1 m=1
```

The `spice_lib` field tells the netlister to emit:

```
.lib "$PDK/models/nmos.lib" tt
```

**For built-in SPICE primitives** (R, C, L), `spice_lib` is omitted:

```
chn_prim 1.0

SYMBOL resistor
  desc: Ideal resistor

  pins [2]:
    p  inout
    n  inout

  params [2]:
    r = 1k
    m = 1

  spice_prefix: R
  spice_format: "@name @p @n @r m=@m"
```

### 5.3 Drawing Section (Low Priority, For Rendering)

```
  drawing:
    # Shapes on drawing layer
    lines:
      (0,-30) (0,-20)
      (0,20) (0,30)
    rect: (-10,-20) (10,20)
    circle: (0,0) r=5
    arc: (0,0) r=8 start=45 sweep=270
    text: (15,0) "@name"
    text: (15,-10) "@w/@l"

    # Pin positions (must match pin names from SYMBOL)
    pin_positions:
      d: (0,-30)
      g: (-20,0)
      s: (0,30)
      b: (20,0)
```

**Rules:**

- `drawing:` is optional. If absent, a tool auto-generates a bounding box with pin stubs.
- Coordinates are relative to the symbol origin (0,0), in abstract units.
- The LLM should **ignore** this section for circuit reasoning. It exists solely for GUI renderers.
- Shapes: `lines`, `rect`, `circle`, `arc`, `polygon`, `text`.
- `pin_positions` maps each pin name to its visual anchor point on the symbol.

---

## 6. `.chn_testbench` — Top-Level Testbenches

No SYMBOL (nothing instantiates a testbench). Contains stimulus, DUT instantiation, analysis commands, and measurement definitions.

```
chn_testbench 1.0

TESTBENCH tb_opamp_ac
  desc: Open-loop AC response of two-stage op-amp

  includes [1]:
    "$PDK/models/all.lib" section=tt

  instances [5]:
    DUT   chn/two_stage_opamp  wp_in=10u  ln_in=500n  cc=2p
    VDD   chn_prim/vsource     dc=1.8
    VCM   chn_prim/vsource     dc=0.9
    VAC   chn_prim/vsource     dc=0  ac=1
    CL    chn_prim/capacitor   c=5p

  nets [6]:
    vdd      -> DUT.VDD, VDD.p
    gnd      -> DUT.VSS, VDD.n, VCM.n
    vcm      -> VCM.p, VAC.n
    inp      -> VAC.p, DUT.INP
    inn      -> DUT.INN, DUT.OUT          # unity-gain feedback
    out      -> DUT.OUT, CL.p, CL.n->gnd  # CL between out and gnd

  analyses [3]:
    op:
    ac:    start=1  stop=10G  points_per_dec=20
    noise: output=V(out)  input=VAC

  measures [3]:
    dc_gain:      find dB(V(out)/V(inp)) at freq=1
    ugbw:         find freq when dB(V(out)/V(inp))=0
    phase_margin: find 180+phase(V(out)/V(inp)) at freq={ugbw}

  annotations:
    status: fresh
    timestamp: 2026-03-20T15:30:00Z
    sim_tool: ngspice 43
    corner: tt

    measures:
      dc_gain:      62.3 dB
      ugbw:         127.4 MHz
      phase_margin: 58.2 deg

    notes:
      - "Phase margin below 60 deg target — increase CC to 2.5p"
```

---

## 7. `.chn` — Full Component Example

A complete Miller-compensated two-stage op-amp:

```
chn 1.0

SYMBOL two_stage_opamp
  desc: Miller-compensated two-stage CMOS op-amp

  pins [6]:
    INP    in
    INN    in
    OUT    out
    VDD    inout
    VSS    inout
    VBIAS  in

  params [10]:
    wp_in   = 10u
    ln_in   = 500n
    wp_load = 5u
    lp_load = 500n
    wn_tail = 5u
    ln_tail = 1u
    wn_drv  = 40u
    ln_drv  = 500n
    wp_cas  = 20u
    cc      = 2p

  spice_prefix: X

SCHEMATIC

  nmos [4]{name, w, l, nf, model}:
    M1      {wp_in}    {ln_in}    1  nch
    M2      {wp_in}    {ln_in}    1  nch
    MTAIL1  {wn_tail}  {ln_tail}  1  nch
    M5      {wn_drv}   {ln_drv}   1  nch

  pmos [3]{name, w, l, nf, model}:
    M3      {wp_load}  {lp_load}  1  pch
    M4      {wp_load}  {lp_load}  1  pch
    M6      {wp_cas}   {lp_load}  1  pch

  capacitors [1]{name, c}:
    CC      {cc}

  nets [9]:
    INP      -> M1.g
    INN      -> M2.g
    tail1    -> M1.s, M2.s, MTAIL1.d
    stage1p  -> M1.d, M3.d, M3.g, M4.g
    stage1n  -> M2.d, M4.d, M5.g, CC.p
    OUT      -> M5.d, M6.d, CC.n
    VBIAS    -> MTAIL1.g
    VDD      -> M3.s, M3.b, M4.s, M4.b, M6.s, M6.b
    VSS      -> MTAIL1.s, MTAIL1.b, M1.b, M2.b, M5.s, M5.b

  annotations:
    status: stale
    timestamp: 2026-03-19T10:00:00Z
    sim_tool: ngspice 43
    corner: tt

    op_points [7]{inst, vgs, vds, id, gm, gds}:
      M1      0.612  0.611  52.3u  312u  4.1u
      M2      0.588  0.365  47.7u  298u  3.8u
      M3     -0.777 -0.777  52.3u  287u  3.2u
      M4     -0.777 -1.023  47.7u  279u  3.1u
      MTAIL1  0.400  0.412  100u   156u  2.8u
      M5      0.611  1.012  198u   1.2m  12u
      M6     -0.788 -0.788  198u   0.9m  8.5u

    notes:
      - "Params changed since last sim — re-run needed"

  drawing:
    # Schematic-level drawing hints for layout
    # Low priority: LLM ignores, GUI tool consumes
    canvas: 1200 800
    placements:
      M1: (300, 400) rot=0
      M2: (500, 400) rot=0
      M3: (300, 200) rot=0
      M4: (500, 200) rot=0
      MTAIL1: (400, 600) rot=0
      M5: (800, 400) rot=0
      M6: (800, 200) rot=0
      CC: (650, 300) rot=0
```

---

## 8. Netlisting Rules

### 8.1 .chn → SPICE

For each `.chn` component with `spice_prefix: X`:

1. Emit `.subckt <name> <pin_names_in_order>`
2. For each primitive instance, look up its `.chn_prim`, apply `spice_format` template with resolved net names and param values
3. For each subcircuit instance, emit `X<name> <net_names> <subckt_name> <params>`
4. Emit `.ends`

**For the opamp above, the generated SPICE:**

```
.subckt two_stage_opamp INP INN OUT VDD VSS VBIAS
M1 stage1p INP tail1 VSS nch w=10u l=500n nf=1
M2 stage1n INN tail1 VSS nch w=10u l=500n nf=1
MTAIL1 tail1 VBIAS VSS VSS nch w=5u l=1u nf=1
M3 stage1p stage1p VDD VDD pch w=5u l=500n nf=1
M4 stage1n stage1p VDD VDD pch w=5u l=500n nf=1
M5 OUT stage1n VSS VSS nch w=40u l=500n nf=1
M6 OUT OUT VDD VDD pch w=20u l=500n nf=1
CC stage1n OUT 2p
.ends
```

### 8.2 .chn_testbench → SPICE

1. Emit each `includes:` line as `.lib`
2. Flatten all instances (recursively expand `.chn` subcircuits or emit `X` calls)
3. Emit `.dc`, `.tran`, `.ac`, `.noise` from `analyses:`
4. Emit `.meas` from `measures:`

---

## 9. Validation & DRC Rules

A `.chn` validator checks:

| Check                | Rule                                                                        |
| -------------------- | --------------------------------------------------------------------------- |
| `[N]` match          | Declared count matches actual row count in every section                    |
| Floating pins        | Every pin of every instance appears in at least one `nets:` entry           |
| Duplicate nets       | No pin appears in more than one net (short-circuit)                         |
| Pin existence        | Every `inst.pin` reference resolves to a real pin on that instance's symbol |
| Param coverage       | Every param in `spice_format` has a value (from default or override)        |
| Supply consistency   | All NMOS bulk pins connect to VSS (or explicit body bias net)               |
| Annotation freshness | Warn if `status: stale` and task requires simulation data                   |
| Generate expansion   | After expansion, all `[N]` guardrails must still pass                       |

---

## 10. LLM Interaction Contract

### What the LLM reads (high priority → low priority):

1. **`SYMBOL` section** — interface: pin names, directions, params. Always read first.
2. **`nets:` section** — connectivity graph. This is the circuit's topology.
3. **Instance tables** — what devices exist and their sizing.
4. **`annotations:`** — simulation results. Check `status:` before trusting values.
5. **`drawing:` section** — **SKIP.** The LLM should never reason about coordinates.

### What the LLM writes:

When modifying a `.chn` file, the LLM:

1. Adds/removes rows in instance tables. Updates `[N]` guardrail.
2. Adds/removes pin references in `nets:` lines. Updates `[N]` guardrail.
3. Adds/removes pins in `SYMBOL.pins:` if the interface changes. Updates `[N]`.
4. Sets `annotations.status: stale` if any schematic change was made.
5. **Never touches `drawing:`.** Layout is recomputed by a tool.

### Token budget estimate:

| Circuit complexity      | Approx tokens (no annotations) | With annotations |
| ----------------------- | ------------------------------ | ---------------- |
| Simple inverter         | ~80                            | ~130             |
| Diff pair               | ~150                           | ~250             |
| Two-stage opamp         | ~300                           | ~500             |
| Full PLL (~200 devices) | ~2,500                         | ~4,000           |

Compare: the same two-stage opamp in xschem `.sch` format ≈ 900 tokens (60% geometry waste).

---

## 11. File Extension Summary

| File             | What it is | SYMBOL   | SCHEMATIC           | spice_format                | drawing  |
| ---------------- | ---------- | -------- | ------------------- | --------------------------- | -------- |
| `.chn`           | Component  | Required | Required            | No (uses `spice_prefix: X`) | Optional |
| `.chn_prim`      | Primitive  | Required | Absent              | Required                    | Optional |
| `.chn_testbench` | Testbench  | Absent   | Required (implicit) | Absent                      | Absent   |

---

## 12. Standard Primitive Library (Tool-Provided)

A standard library of `.chn_prim` files ships with the toolchain and is updated via tool commands. The LLM can assume these exist:

`chn_prim/nmos`, `chn_prim/pmos`, `chn_prim/resistor`, `chn_prim/capacitor`, `chn_prim/inductor`, `chn_prim/diode`, `chn_prim/npn`, `chn_prim/pnp`, `chn_prim/vsource`, `chn_prim/isource`, `chn_prim/vcvs`, `chn_prim/vccs`, `chn_prim/ccvs`, `chn_prim/cccs`

PDK-specific primitives (e.g., `sky130_prim/nfet_01v8`) are installed separately and reference PDK `.lib` files.

---

## Appendix A: TOON Principles Applied

| TOON Principle                      | .chn Application                                     |
| ----------------------------------- | ---------------------------------------------------- |
| Schema once, rows stream            | Type-grouped tabular instance blocks                 |
| Eliminate structural noise          | No geometry, no braces, no coordinate tokens         |
| `[N]` guardrails                    | Every list section declares its count                |
| Same data model, different encoding | Lossless round-trip to xschem and SPICE              |
| Delimiter scoping                   | Per-section tab/pipe override for bus-heavy designs  |
| Key folding                         | `DUT.OPAMP.stage1_out` hierarchical dot-paths        |
| Type-grouped tables (our extension) | Separate table per device class for mixed schematics |

## Appendix B: Annotation Status State Machine

```
[file created] --> status: (absent, no annotations yet)
      |
      v
[simulation run] --> status: fresh, timestamp: now
      |
      v
[LLM edits schematic] --> status: stale (timestamp unchanged)
      |
      v
[simulation re-run] --> status: fresh, timestamp: now
```

The LLM checks `status:` before citing any annotation values. If `stale`, it should say so and recommend re-simulation.

---

## Appendix C: LLM Tool API — Circuit Interaction Functions

The LLM should **never** edit `.chn` files as raw text for structural changes (adding devices, rewiring nets). Instead, it calls tool functions that handle the bookkeeping: updating `[N]` guardrails, checking pin validity, marking annotations stale, and keeping `drawing:` in sync. The LLM's job is intent and reasoning; the tools handle execution.

This design follows the SPICEAssistant and AnalogCoder pattern from EDA research: the LLM is the reasoning engine, tools are the hands. SPICEAssistant showed a 38% improvement over standalone GPT-4o by giving the LLM structured tool access to simulation results instead of raw waveform data.

### C.1 Schema Manipulation Tools

These tools modify the .chn file structure. Every mutation auto-updates `[N]` guardrails and sets `annotations.status: stale`.

#### `add_instance`

```
add_instance(
  file:    "opamp.chn",
  name:    "M7",
  type:    "chn_prim/nmos",
  params:  {w: "4u", l: "100n", nf: 1, model: "nch"}
)
→ {ok: true, instance_count: 9, unconnected_pins: ["M7.d", "M7.g", "M7.s", "M7.b"]}
```

**Why this exists:** The LLM says _what_ device it wants. The tool handles inserting it into the correct type-grouped table, incrementing `[N]`, and reporting which pins now need wiring. The LLM never thinks about table formatting.

#### `remove_instance`

```
remove_instance(file: "opamp.chn", name: "M7")
→ {ok: true, instance_count: 8, orphaned_nets: ["bias2"]}
```

Returns which nets lost all their connections (became orphaned) so the LLM can clean up.

#### `set_param`

```
set_param(file: "opamp.chn", instance: "M1", param: "w", value: "12u")
→ {ok: true, old_value: "10u", new_value: "12u"}
```

#### `add_pin` / `remove_pin`

```
add_pin(file: "opamp.chn", name: "EN", direction: "in")
→ {ok: true, pin_count: 7}
```

For modifying the SYMBOL interface. Rare — only when the component's external contract changes.

### C.2 Connectivity Tools

These are the core tools. They abstract away all geometry and let the LLM think purely in terms of named nets and named pins.

#### `connect`

```
connect(
  file: "opamp.chn",
  net:  "bias2",
  pins: ["M7.g", "MTAIL2.g"]
)
→ {ok: true, net_count: 10, net_members: ["M7.g", "MTAIL2.g"]}
```

Creates a new net or extends an existing one. If the net already exists, the pins are added to it (union operation).

#### `disconnect`

```
disconnect(file: "opamp.chn", net: "VDD", pins: ["M6.b"])
→ {ok: true, net_members: ["M3.s", "M3.b", "M4.s", "M4.b", "M6.s"]}
```

Removes specific pins from a net. If the net becomes empty, it's deleted.

#### `move_pin`

```
move_pin(file: "opamp.chn", pin: "M7.d", from_net: "out", to_net: "stage2_int")
→ {ok: true}
```

Atomic move: disconnect from one net + connect to another in a single operation. Prevents dangling states.

### C.3 Query Tools (Read-Only)

These let the LLM _understand_ the circuit without parsing the file. They return structured data the LLM can reason about directly.

#### `get_net`

```
get_net(file: "opamp.chn", net: "stage1n")
→ {
    net: "stage1n",
    pins: ["M2.d", "M4.d", "M5.g", "CC.p"],
    pin_details: [
      {inst: "M2", pin: "d", device: "nmos", role: "drain"},
      {inst: "M4", pin: "d", device: "pmos", role: "drain"},
      {inst: "M5", pin: "g", device: "nmos", role: "gate"},
      {inst: "CC", pin: "p", device: "capacitor", role: "positive"}
    ]
  }
```

**Why this matters:** This is the union-find query. The LLM asks "what's on this net?" and gets back a complete, structured answer without tracing wires or parsing coordinates. The `role` field maps pin names to human-readable functions.

#### `get_instance`

```
get_instance(file: "opamp.chn", name: "M1")
→ {
    name: "M1", type: "chn_prim/nmos",
    params: {w: "10u", l: "500n", nf: 1, model: "nch"},
    connections: {d: "stage1p", g: "INP", s: "tail1", b: "VSS"},
    op_point: {vgs: 0.612, vds: 0.611, id: "52.3u", gm: "312u"},  # if annotations fresh
    op_status: "stale"
  }
```

Returns everything about one device: params, what net each pin connects to, and operating point data with freshness.

#### `get_floating_pins`

```
get_floating_pins(file: "opamp.chn")
→ {floating: ["M7.d", "M7.s"], count: 2}
```

DRC check: which pins aren't connected to anything.

#### `get_topology_summary`

```
get_topology_summary(file: "opamp.chn")
→ {
    instances: {nmos: 4, pmos: 3, capacitor: 1, total: 8},
    nets: 9,
    pins: {in: ["INP", "INN", "VBIAS"], out: ["OUT"], inout: ["VDD", "VSS"]},
    floating_pins: 0,
    annotation_status: "stale",
    signal_path: "INP → M1.g → M1.d(stage1p) → M3/M4(mirror) → M4.d(stage1n) → M5.g → M5.d(OUT)"
  }
```

High-level structural overview. The `signal_path` is the tool's best-effort trace of the main signal flow — extremely useful for the LLM to verify topology correctness.

### C.4 Simulation Tools

#### `run_sim`

```
run_sim(
  file:     "tb_opamp.chn_testbench",
  analyses: ["op", "ac"],
  corner:   "tt"
)
→ {
    status: "success",
    runtime: "2.3s",
    measures: {dc_gain: "62.3 dB", ugbw: "127.4 MHz", phase_margin: "58.2 deg"},
    warnings: ["M5 in triode region at DC operating point"],
    annotations_updated: true   # annotations.status is now "fresh"
  }
```

Runs the simulation, extracts measures, and **automatically writes results back into the file's `annotations:` section** with `status: fresh` and a new timestamp. The LLM never manually parses waveform data.

#### `measure`

```
measure(file: "tb_opamp.chn_testbench", expr: "V(out) at freq=1k")
→ {value: "1.194 V", phase: "-0.3 deg"}
```

Quick single-point measurement without re-running the full sim (uses cached results if `status: fresh`).

#### `sweep`

```
sweep(
  file:  "tb_opamp.chn_testbench",
  param: "M1.w",
  range: {start: "2u", stop: "20u", step: "2u"},
  measure: "ugbw"
)
→ {
    results: [
      {w: "2u",  ugbw: "45.1 MHz"},
      {w: "4u",  ugbw: "72.3 MHz"},
      {w: "6u",  ugbw: "91.0 MHz"},
      ...
      {w: "20u", ugbw: "152.8 MHz"}
    ]
  }
```

Parametric sweep. Returns a table the LLM can reason about to find optimal sizing.

### C.5 Validation & DRC Tools

#### `validate`

```
validate(file: "opamp.chn")
→ {
    valid: false,
    errors: [
      {type: "floating_pin", inst: "M7", pin: "b", severity: "error"},
      {type: "guardrail_mismatch", section: "nets", declared: 9, actual: 10, severity: "error"}
    ],
    warnings: [
      {type: "annotation_stale", message: "Schematic changed since last sim"}
    ]
  }
```

#### `check_shorts`

```
check_shorts(file: "opamp.chn")
→ {shorts: [], ok: true}
```

Checks if VDD and VSS (or any supply nets) are accidentally shorted through a shared pin.

### C.6 File Management Tools

#### `list_library`

```
list_library(path: "chn_prim/")
→ ["nmos", "pmos", "resistor", "capacitor", "inductor", "diode", "vsource", "isource", ...]
```

#### `get_symbol`

```
get_symbol(file: "chn/diff_pair.chn")
→ {
    name: "diff_pair",
    pins: [{name: "INP", dir: "in"}, {name: "INN", dir: "in"}, ...],
    params: [{name: "w_in", default: "10u"}, ...],
    desc: "NMOS differential pair with tail current source"
  }
```

Returns just the interface contract — everything the LLM needs to _use_ this component without looking inside.

#### `export_spice`

```
export_spice(file: "opamp.chn", output: "opamp.spice")
→ {ok: true, lines: 24, subcircuits: ["two_stage_opamp"]}
```

### C.7 Tool Design Principles

These tools follow patterns validated by EDA research:

| Principle                                           | Rationale                                                                                                                 | Source                                   |
| --------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------- |
| **Structured returns, not raw text**                | SPICEAssistant showed LLMs can't reliably parse waveform data; structured extraction improved solve rates by 38%          | SPICEAssistant (2025)                    |
| **Auto-update side effects**                        | Every mutation updates `[N]` guards and sets `status: stale` — the LLM never forgets bookkeeping                          | TOON guardrail principle                 |
| **Report unconnected/orphaned state**               | After every add/remove, tell the LLM what's now dangling — prevents accumulating DRC errors                               | AnalogCoder feedback loop                |
| **Concise tool descriptions**                       | Tool definitions consume context tokens on every call. Keep descriptions short but precise                                | Prompt Engineering Guide (2025)          |
| **Prefer specific tools over generic file editing** | `connect(net, pins)` is a single intent; raw text editing requires the LLM to handle formatting, `[N]` update, validation | ChatEDA / function-calling best practice |
| **Simulation results write back to file**           | Closes the feedback loop: sim runs → annotations update → LLM reads fresh data → decides next action                      | SPICEAssistant iterative loop            |

### C.8 Example Agent Workflow

**Task:** "Increase the phase margin of this op-amp to above 60 degrees."

```
1. LLM calls: get_topology_summary("opamp.chn")
   → Reads: 8 devices, 9 nets, annotation_status: stale

2. LLM calls: run_sim("tb_opamp.chn_testbench", ["ac"], "tt")
   → Reads: phase_margin: 58.2 deg (below target)

3. LLM reasons: "PM is 58.2°. The Miller cap CC is 2p. Increasing CC
   should improve PM at the cost of bandwidth. Let me try 2.5p."

4. LLM calls: set_param("opamp.chn", "CC", "c", "2.5p")
   → annotations.status automatically set to "stale"

5. LLM calls: run_sim("tb_opamp.chn_testbench", ["ac"], "tt")
   → Reads: phase_margin: 63.1 deg, ugbw: 108.2 MHz

6. LLM responds: "Increased CC from 2p to 2.5p. Phase margin is now
   63.1° (above 60° target). UGB decreased from 127.4 MHz to 108.2 MHz.
   The tradeoff is acceptable."
```

The LLM never touched a coordinate, never parsed a waveform, never manually updated an `[N]` guardrail, and never forgot to mark annotations stale. The tools handled all of it.
