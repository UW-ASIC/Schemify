# Writing PySpice / SPICE for Schemify Import

This document defines the conventions for writing PySpice (or raw SPICE) files that import cleanly into Schemify as components, primitives, or testbenches.

## Core Rule

**Every reusable component must be a `.subckt`.**

Schemify's import pipeline treats each `.subckt` as one schematic. Hierarchy is resolved by name — if subckt `OTA` instantiates `current_mirror`, Schemify links them by matching the instance's symbol name to the `current_mirror.chn` file.

---

## File Categories

### Component (reusable block with ports)

A `.subckt` with ports and internal devices. Becomes a `.chn` with `stype = schematic`.

```python
from pyspice_rs import Circuit

ckt = Circuit("current_mirror")
ckt.subcircuit_begin("current_mirror", "iref", "iout", "vdd", "vss")
ckt.M("1", "gate", "gate", "vdd", "vdd", model="sky130_fd_pr__pfet_01v8", W="2u", L="0.5u")
ckt.M("2", "iout", "gate", "vdd", "vdd", model="sky130_fd_pr__pfet_01v8", W="2u", L="0.5u")
ckt.R("bias", "iref", "gate", "0")  # diode-connect
ckt.subcircuit_end()

print(ckt)
```

Equivalent raw SPICE:
```spice
.subckt current_mirror iref iout vdd vss
M1 gate gate vdd vdd sky130_fd_pr__pfet_01v8 W=2u L=0.5u
M2 iout gate vdd vdd sky130_fd_pr__pfet_01v8 W=2u L=0.5u
Rbias iref gate 0
.ends current_mirror
```

### Primitive (leaf device, no internal hierarchy)

A `.subckt` whose internals are a single behavioral model or PDK device. Becomes a `.chn` with `stype = primitive`.

Mark it with a comment on the `.subckt` line:

```spice
* schemify:primitive
.subckt my_ideal_opamp inp inn out
Eamp out 0 inp inn 100000
.ends my_ideal_opamp
```

In PySpice, add a comment parameter:

```python
ckt.subcircuit_begin("my_ideal_opamp", "inp", "inn", "out", comment="schemify:primitive")
```

If no marker is present, import defaults to component. The CLI `--import file.py primitive` flag overrides for all subcircuits in that file.

### Testbench (top-level with stimulus + analysis)

A file whose top-level (outside any `.subckt`) contains:
- Source stimuli (`V`, `I`, `PULSE`, `SIN`, etc.)
- Analysis commands (`.tran`, `.ac`, `.dc`, `.op`)
- `.subckt` instantiations via `X` lines

Becomes a `.chn` with `stype = testbench`.

```python
from pyspice_rs import Circuit

ckt = Circuit("tb_ota")

# Instantiate the DUT (resolved by name → ota.chn)
ckt.X("dut", "ota", "inp", "inn", "out", "vdd", "vss")

# Stimulus
ckt.V("dd", "vdd", "0", "1.8")
ckt.V("ss", "vss", "0", "0")
ckt.V("cm", "inp", "0", "DC 0.9 AC 1")
ckt.V("cm2", "inn", "0", "DC 0.9")

# Analysis
ckt.ac("dec", 20, "1", "1G")

print(ckt)
```

Detection rule: if the SPICE output has analysis commands (`.tran`, `.ac`, `.dc`, `.op`) at the top level, it's a testbench.

---

## Hierarchy Resolution

After import, Schemify resolves hierarchy by **name matching**:

```
tb_ota.chn          (testbench)
  └─ Xdut → symbol "ota"  →  ota.chn (component)
       └─ Xmirror → symbol "current_mirror"  →  current_mirror.chn (component)
```

Rules:
1. Instance `X<name> <subckt_name> ...` → Schemify looks for `<subckt_name>.chn` in the project
2. If not found → unresolved reference (shown as placeholder box in GUI)
3. Name matching is case-sensitive, matches the `.subckt` name exactly

---

## Batch Import Convention

When importing a directory with multiple `.py` files:

```
project/
├── current_mirror.py    → defines .subckt current_mirror → component
├── ota.py               → defines .subckt ota (uses Xcm current_mirror) → component
├── tb_gain.py           → top-level with .ac analysis, Xdut ota → testbench
└── tb_transient.py      → top-level with .tran analysis, Xdut ota → testbench
```

Import pipeline:
1. Run every `.py` file that has PySpice imports
2. Collect all SPICE output
3. Each `.subckt` → one component (deduplicated by name)
4. Each file with top-level analysis → one testbench
5. Write all `.chn` files to output directory

Deduplication: if multiple files produce the same `.subckt` name with identical content, keep one. If content differs → error (ambiguous definition).

---

## Parameter Passing

Subcircuit parameters become schematic properties, editable in the GUI:

```spice
.subckt resistor_ladder in out vss R1=10k R2=10k
R1 in mid {R1}
R2 mid out {R2}
.ends resistor_ladder
```

In PySpice:
```python
ckt.subcircuit_begin("resistor_ladder", "in", "out", "vss", params={"R1": "10k", "R2": "10k"})
```

These appear as editable properties on the component instance in Schemify.

---

## .include / .lib References

For PDK models, use `.include` or `.lib` at the top level:

```spice
.lib /path/to/sky130.lib.spice tt
```

Schemify preserves these as metadata on the testbench. They are not imported as components — they're passed through to simulation.

---

## Summary Table

| SPICE construct | Schemify type | Detection |
|---|---|---|
| `.subckt X ...` / `.ends X` | component | Any subcircuit block |
| `.subckt X ...` with `schemify:primitive` | primitive | Comment marker |
| Top-level with `.tran`/`.ac`/`.dc`/`.op` | testbench | Analysis at top level |
| `.include` / `.lib` | metadata | Preserved, not imported |
| Top-level devices without analysis | component (flat) | No subckt wrapper, no analysis |

---

## Quick Reference: Minimal Valid Files

**Minimal component:**
```python
from pyspice_rs import Circuit
ckt = Circuit("my_block")
ckt.subcircuit_begin("my_block", "in", "out", "vdd", "vss")
# ... devices ...
ckt.subcircuit_end()
print(ckt)
```

**Minimal testbench:**
```python
from pyspice_rs import Circuit
ckt = Circuit("tb_my_block")
ckt.X("dut", "my_block", "in", "out", "vdd", "vss")
ckt.V("dd", "vdd", "0", "1.8")
ckt.V("in", "in", "0", "PULSE(0 1.8 0 1n 1n 5u 10u)")
ckt.tran("1n", "20u")
print(ckt)
```
