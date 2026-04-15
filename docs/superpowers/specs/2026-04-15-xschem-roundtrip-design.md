# XSchem Roundtrip & SPICE Comparison Test Design

## Status

Approved 2026-04-15. Implementation pending.

---

## Overview

Two automated tests for the EasyImport XSchem plugin:

1. **Roundtrip test** — XSchem → Schemify → XSchem: verify bidirectional geometric fidelity
2. **SPICE comparison test** — XSchem → Schemify netlist vs XSchem native SPICE: verify netlist correctness

Tests run against the full xschem_library fixture set.

---

## Fixture Management

### Source

xschem_library as a git submodule at `plugins/EasyImport/test/fixtures/xschem_library/`, pinned to a specific commit hash.

### CI Setup

Before tests run: `git submodule update --init`.

### Fixture Directory Structure

```
plugins/EasyImport/test/fixtures/xschem_library/
  devices/       ← 127 primitive .sym files (leaves)
  ngspice/      ← paired .sch + .sym
  logic/        ← paired .sch + .sym
  examples/     ← paired .sch + .sym
  generators/   ← paired .sch + .sym
```

---

## Test 1: Roundtrip (`testRoundtrip`)

### Workflow

For each fixture in topological (dependency) order:

1. Parse original `.sch` or `.sym` via `fileio::reader::parse`
2. Convert XSchemFiles → Schemify via `convert::mapXSchemToSchemify`
3. Convert Schemify → XSchemFiles via `convert::mapSchemifyToXSchem`
4. Serialize to string via `fileio::writer::serialize`
5. Re-parse the serialized string
6. Compare element counts per geometric type

### What Is Compared

Per fixture, compare element counts for:
- `lines`
- `rects`
- `arcs`
- `circles`
- `wires`
- `texts`
- `pins`
- `instances`

### Failure Reporting

Structured JSON report per failing fixture:

```json
{
  "fixture": "ngspice/inv_ngspice",
  "test": "roundtrip",
  "scenario": "paired",
  "expected": { "lines": 4, "rects": 2, "arcs": 0, "circles": 0, "wires": 3, "texts": 1, "pins": 2, "instances": 0 },
  "actual": { "lines": 4, "rects": 1, "arcs": 0, "circles": 0, "wires": 3, "texts": 1, "pins": 2, "instances": 0 },
  "missing": ["rect at layer 5 (pin)"],
  "lossy_props": ["dir"]  // only reported if props differ
}
```

If all counts match: no output (pass silent).

---

## Test 2: SPICE Comparison (`testSpice`)

### Preconditions

- `xschem` binary must be on PATH
- Only runs on **paired** fixtures (`.sch` + `.sym` exist for same stem)

### Workflow

For each paired fixture in topological order:

1. Parse `.sch` + resolve referenced `.sym` files via pre-populated resolver
2. Convert XSchemFiles → Schemify (full, with symbol resolution)
3. Generate SPICE netlist via `Schemify.toSpice()`
4. Parse original `.sch` and generate SPICE via `xschem` (reference binary)
5. Normalize both netlists
6. Compare token-by-token

### Normalization

Minimal — only:
- Strip blank lines
- Strip `*` comment lines

Preserve statement order and floating-point values. Floating-point differences cause test failure — these indicate real precision bugs.

### Failure Reporting

```json
{
  "fixture": "ngspice/inv_ngspice",
  "test": "spice",
  "expected_snippet": "...Xinv_1 net1 net2 vss inv_ngspice...",
  "actual_snippet": "...Xinv_1 net1 vss vss inv_ngspice...",
  "diff_line": 12,
  "detail": "Pin 2 swapped: expected net2, got vss"
}
```

---

## Symbol Resolution

### Pre-populated Resolver

Before running tests:

1. Scan all fixtures, build `stem → XSchemFiles` map from all `.sym` files
2. Convert all `.sym` files in dependency order, register each in resolver
3. When converting `.sch`, resolver already contains all child symbols

### Dependency Graph

**Pass 1 — Build graph:**
```
sch_path → { referenced_sym_stems: Set(string) }
sym_path → { implemented_by_sch: Option(string) }
```

**Pass 2 — Kahn's topological sort:**
- in_degree of `.sch` = count of referenced `.sym` stems (not `.sch`)
- Leaves (in_degree 0) = primitives from `devices/`
- Sort emits children first, parents last

### Scenario Classification

For each fixture:
- `.sym` only → Scenario 1 (roundtrip only, no SPICE)
- `.sch` + `.sym` → Scenario 2 (roundtrip + SPICE)
- `.sch` only → skip with warning

---

## Lost Information Tracking

After each roundtrip, compare all instance props of re-parsed vs original.

Flag property keys where the roundtrip path is lossy for non-geometric data. Only report keys known to be lossy through the XSchem → Schemify → XSchem path, e.g.:
- Props with TCL-expr values that evaluate differently after roundtrip
- Floating-point precision loss in computed values

Report format: list of `lossy_props` per fixture.

---

## Test Organization

```
plugins/EasyImport/test/
  xschem_roundtrip.zig   ← main test runner
  xschem_roundtrip.md     ← this doc
  fixtures/
    .gitmodules          ← submodule pointing to xschem_library
```

### Entry Point: `testRoundtrip` and `testSpice`

Both functions iterate over the pre-computed topological order. `testSpice` skips non-paired fixtures silently.

---

## Implementation Notes

### Submodule Setup

In `plugins/EasyImport/build.zig`, add:

```zig
const xschem_lib = b.dependency("xschem_library", .{
    .path = "test/fixtures/xschem_library",
});
test_step.dependOn(&xschem_lib.test_step);
```

### xschem Binary Detection

In `testSpice`, check if `xschem` is on PATH at test startup. If not, skip all SPICE tests with a single warning message. Do not fail the test run.

### Memory

Each fixture is processed with a fresh backing allocator. `XSchemFiles` and `Schemify` instances are deallocated before moving to the next fixture.

### Floating-Point Geometry

Coordinates are f64 in XSchemFiles, converted to i32 via `f2i` (round-to-nearest). Roundtrip geometry comparisons should be exact after this conversion.

---

## Electrical Information We Track

The following fields are preserved through roundtrip:

| Element | Fields Tracked |
|---------|---------------|
| Line | layer, x0, y0, x1, y1 |
| Rect | layer, x0, y0, x1, y1 |
| Arc | layer, cx, cy, radius, start_angle, sweep_angle |
| Circle | layer, cx, cy, radius |
| Wire | x0, y0, x1, y1, net_name (lab=), bus flag |
| Text | content, x, y, layer, size, rotation |
| Pin | name, x, y, direction, number |
| Instance | name, symbol, x, y, rot, flip, props |
| K-block | type, format, template, extra, global, spice_sym_def |
| S-block | raw spice body |

Known potentially lossy:
- TCL-evaluated format strings that produce different prop values on re-evaluation
- Pin direction string → enum roundtrip (via ordinal cast — should be lossless)
