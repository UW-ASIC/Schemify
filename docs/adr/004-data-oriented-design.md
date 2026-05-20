# ADR-004: Data-Oriented Design Choices

**Status:** Accepted
**Date:** 2026-05-19

## Context

Porting from Zig (which uses MultiArrayList, StringPool, fixed buffers) to Rust. Goal: make types as small as possible, data-oriented where access patterns warrant it.

## Decisions

### String Interning (`lasso`)

**Problem:** Repeated strings (net names, symbol names, property keys) cause heap allocation per-copy. 500 instances × 24-byte String = 12KB just for symbol name fields.

**Solution:** `lasso::Spur` (4-byte handle) stored in hot types. A `Rodeo` interner in AppState resolves `Sym → &str`.

- `Sym` (alias for `lasso::Spur`) used in: `Wire.net_name`, `Instance.name/symbol/spice_line`, `Property.key/value`, `Pin.name`, `Text.content`
- `String` used in: `Schematic` metadata (one per doc), `CellInfo` (loaded once), `Command` args (handler interns on receipt), `SimResult` fields
- Rule: Sym for types with many instances where strings repeat. String for one-offs.

### Property Pool

**Problem:** `Vec<Property>` per instance = 24 bytes + allocation per instance.

**Solution:** Shared `Schematic.properties: Vec<Property>` pool. Instance stores `prop_start: u32, prop_count: u16` (6 bytes). Property itself is 8 bytes (two Sym handles).

### Struct of Arrays (Wire, Instance)

**Problem:** Renderer iterates all wires/instances every frame, often only reading positions.

**Solution:** `soa_derive::StructOfArray` on `Wire` and `Instance`. Generates `WireVec`/`InstanceVec` with per-field Vecs. Iterating just positions avoids pulling color/thickness/bus into cache.

**Not SoA:** Shapes (Line, Rect, etc.) — fewer objects, accessed individually. Pin — moderate count, all fields read together. Property — always read as key+value pair.

**Rule:** SoA when bulk-iterated with partial field access. AoS when accessed individually or all fields together. Decided per-type based on dominant access pattern.

### Compact Enums

All small enums use `#[repr(u8)]`: `DeviceKind`, `SchematicType`, `PinDirection`, `Tool`, `SpiceBackend`, `SimStatus`, etc. Saves 3 bytes per enum value vs default repr.

### Packed Flags

`InstanceFlags` packed into single `u8`: bits [0:1] rotation, bit 2 flip, bit 3 bus. Accessor methods for ergonomic reads.

### Color Sentinel

`Color::NONE` (alpha=0) replaces `Option<Color>`. Saves 1+ bytes padding per color field. `is_none()` checks alpha. Meaning: "not overridden, use theme default."

## Sizes After Optimization

| Type | Before | After | Notes |
|---|---|---|---|
| Wire | ~50 bytes (with String) | 26 bytes | Sym + Color sentinel |
| Instance | ~100+ bytes (with Strings, Vec) | 36 bytes | Sym + prop pool |
| Property | ~48+ bytes (two Strings) | 8 bytes | Two Sym handles |
| DeviceKind | 4 bytes | 1 byte | repr(u8) |
| InstanceFlags | 3+ bytes | 1 byte | Packed u8 |

## Consequences

- `lasso` and `soa_derive` added as core dependencies
- Handler must manage the interner lifecycle
- Display resolves `Sym → &str` through handler accessors
- Commands use `String` (boundary type), handler interns on receipt
