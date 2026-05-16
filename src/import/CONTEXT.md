# import

Reads foreign EDA formats and produces native Schematics. Pure function entry point: `importProject(alloc, source) -> ConvertResultList`.

## Language

**Import**:
The process of reading a foreign EDA format and producing a native Schematic. Encompasses parsing, device-type mapping, PDK remapping, layout generation, wire routing, and label placement.
_Avoid_: conversion (too generic), translation, migration

**Building Block**:
A recognized circuit pattern (differential pair, current mirror, cascode stack) that influences placement. Matched by connectivity, not by name.

**Zone**:
Vertical region of the schematic: PMOS top, NMOS bottom, passives/sources middle.

## Relationships

- An **Import** consumes files in a foreign format and produces one or more Schematics (defined in the schematic module)
- An **Import** maps foreign device types to the native Device catalog via **PdkMap**
- An **Import** from SPICE/PySpice/Virtuoso generates placement (**Layout**), wiring (**Router**), and label positions (**LabelPlacer**)
- An **Import** from XSchem preserves original geometry (no layout generation)
- **PySpice** import runs a Python subprocess and captures SPICE output

## Backends

| Backend | Geometry source | Uses shared layout? |
|---------|----------------|-------------------|
| XSchem | `.sch` files | No (own geometry) |
| Virtuoso | CDL/Spectre parse | Yes (via Layout+Router) |
| SPICE | Netlist parse | Yes (via Layout+Router) |
| PySpice | Python stdout → SPICE parse | Yes (via Layout+Router) |

## Shared pipeline (SPICE/PySpice/Virtuoso)

```
Parser → PdkMap → Layout → Router → LabelPlacer → ConvertResult
```

## File layout

| File | Purpose |
|------|---------|
| `lib.zig` | `importProject()` entry point, `ImportSource` union |
| `types.zig` | `ConvertResult`, `ConvertResultList` |
| `PdkMap.zig` | Unified device mapping (Sky130, GF180, IHP, analogLib, TSMC, GPDK) |
| `Layout.zig` | Placement engine: building blocks, zones, grid snap, symmetry |
| `Router.zig` | Manhattan wire routing with obstacle avoidance |
| `LabelPlacer.zig` | Greedy no-overlap text positioning |
| `XSchem/` | XSchem parser, converter, exporter, xschemrc, TCL evaluator |
| `Virtuoso/` | Cadence CDL/Spectre parser, OA types |
| `spice/` | SPICE parser + conversion pipeline (uses shared Layout/Router/LabelPlacer) |
| `PySpice/` | Python subprocess runner + SPICE capture |

## Flagged ambiguities

- `XSchem/exporter.zig` (`mapSchemifyToXSchem`) is an **Export**, not an Import. Lives here for practical reasons.
