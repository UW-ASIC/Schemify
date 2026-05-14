# schematic

Foundational domain model. Owns all types representing a schematic: instances, wires, pins, properties, geometry, nets, connectivity.

## Functionality

- Canonical data types (Instance, Wire, Pin, Property, Net, Conn, geometry primitives)
- Schemify struct: SoA collections holding a complete schematic document
- Device catalog and primitive symbol definitions (parsed from embedded data)
- File I/O: read/write `.chn` format, TOML project config
- Pure geometric transforms (rotation, flip, bounds computation)

Removed in cleanup: digital/ (2,468 LOC — HdlParser, YosysJson, Synthesis). Digital simulation handled via PySpice netlist embedding instead.

## Public API

| Symbol | Purpose |
|--------|---------|
| `types.*` | Instance, Wire, Pin, Property, Net, Conn, DeviceKind, SymData, etc. |
| `Schemify` | Main schematic struct: addComponent, addWire, resolveNets, emitSpice |
| `helpers.*` | applyRotFlip, findProp, isStructuralProp, Bounds |
| `fileio.Reader` | Parse `.chn` files into Schemify |
| `fileio.Writer` | Serialize Schemify to `.chn` format |
| `fileio.Toml` | Parse TOML project config |
| `devices.Devices` | Device catalog: prefix lookup, pin info, SPICE mapping |
| `devices.primitives` | Embedded primitive symbol definitions |

## Internal Structure

| File | Purpose |
|------|---------|
| `lib.zig` | Module entry, re-exports |
| `types.zig` | All canonical data types |
| `Schemify.zig` | Main schematic struct (SoA MultiArrayList) |
| `helpers.zig` | Bounds, rotation, property lookup |
| `devices/Devices.zig` | Device catalog and SPICE component mapping |
| `devices/primitives.zig` | Embedded primitive symbol definitions |
| `fileio/Reader.zig` | `.chn` file parser |
| `fileio/Writer.zig` | `.chn` file serializer |
| `fileio/Toml.zig` | TOML project config parser |

## Dependencies

- `utility` — Logger, platform helpers
