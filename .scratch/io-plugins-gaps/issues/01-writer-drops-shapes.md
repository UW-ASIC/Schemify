---
id: io/01
title: Writer drops drawing shapes (roundtrip loss)
status: ready-for-agent
priority: medium
labels: [io, roundtrip]
---

# Writer drops drawing shapes (roundtrip loss)

## Problem

`Schematic` has 6 drawing shape types but `write_drawing()` only emits 4. `Text` and `Polygon` are lost on save/load roundtrip.

## Current state

**Writer** (`crates/io/src/writer.rs:224–255`):
- Emits: `lines`, `rects`, `circles`, `arcs`
- Missing: `texts`, `polygons`

**Reader** (`crates/io/src/reader.rs:497–551`):
- Parses: `line`, `rect`, `circle`, `arc`
- Missing: `text`, `polygon`

**Core types exist** (`crates/core/src/schematic.rs`):
- `Text` struct (x, y, content: Sym, font_size, color, rotation)
- `Polygon` struct (points: Vec<[i32; 2]>, fill, stroke, thickness)
- Both fields present on `Schematic`

## Acceptance criteria

- [ ] Reader parses `text` and `polygon` drawing entries
- [ ] Writer emits `text` and `polygon` drawing entries
- [ ] Roundtrip test: schematic with text/polygon shapes survives save → load → save
- [ ] `has_any` check in writer includes texts and polygons

## Files

- `crates/io/src/writer.rs` — `write_drawing()`
- `crates/io/src/reader.rs` — `parse_drawing()`
- `crates/core/src/schematic.rs` — Text, Polygon structs
