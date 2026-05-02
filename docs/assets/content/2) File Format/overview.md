# CHN File Format

CHN is Schemify's native schematic interchange format. It is designed to be human-readable, LLM-optimized, and round-trip lossless with xschem's `.sch`/`.sym` format and SPICE netlists.

> **Design philosophy:** `.chn` is to xschem what TOON is to JSON — same circuit data model, different encoding, optimized for LLM consumption instead of GUI rendering.

## File Types

| Extension | Has SYMBOL | Has SCHEMATIC | Use |
|-----------|-----------|---------------|-----|
| `.chn` | Yes | Yes | Reusable component (subcircuit) |
| `.chn_prim` | Yes | No | Leaf device backed by SPICE `.lib` |
| `.chn_testbench` | No | Yes | Top-level simulation harness |

The type is enforced by the file extension and the parser — a testbench cannot be instantiated as a component by accident.

## Core Axioms

1. **Zero geometry in connectivity.** Coordinates are rendering concerns, banished to a low-priority `drawing:` section.
2. **Explicit named nets.** No implicit "wires touching = connected." Every connection is a declared `net -> inst.pin` statement.
3. **Schema-once, rows-stream.** Instance lists are tabular (TOON-style): field names appear once in a header, device rows are positional.
4. **`[N]` guardrails everywhere.** Every list declares its length. Validators detect truncation, duplication, and drift.
5. **Lossless round-trip.** `.chn ↔ xschem .sch ↔ SPICE netlist`. No information is invented or destroyed.
6. **Annotations are inline and timestamped.** Simulation results live in the file with a freshness status, not in a sidecar.

## File Structure

```
<header>

SYMBOL <name>
  desc: <description>
  pins [N]:
    ...
  params [N]:
    ...
  spice_prefix: <letter>

SCHEMATIC
  nmos [N]{name, w, l, nf, model}:
    ...
  nets [N]:
    ...
  annotations:
    status: fresh|stale
    ...
```

## Token Efficiency

| Circuit | Approx tokens (no annotations) | vs xschem `.sch` |
|---------|-------------------------------|-----------------|
| Simple inverter | ~80 | 5× smaller |
| Diff pair | ~150 | 4× smaller |
| Two-stage opamp | ~300 | 3× smaller |
| Full PLL (~200 devices) | ~2,500 | 3× smaller |

The same two-stage opamp in xschem `.sch` format ≈ 900 tokens (60% geometry waste).

## Syntax Rules

| Rule | Detail |
|------|--------|
| Encoding | UTF-8 |
| Comments | `#` to end of line |
| Indentation | 2 spaces per level |
| Strings | Unquoted unless containing special chars |
| Expressions | `{expr}` — e.g. `{wp*2}`, `{vdd/2}` |
| Net arrow | `->` separates net name from pin list |
| Pin reference | `instance.pin` — dot notation |
| File header | First line: `chn 1.0`, `chn_prim 1.0`, or `chn_testbench 1.0` |
| List headers | `section_name [N]:` — N = item count guardrail |
| Tabular headers | `section_name [N]{col1, col2, ...}:` — TOON-style |
