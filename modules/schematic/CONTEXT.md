# schematic

Domain model for a schematic editor. Owns every type that represents a schematic document: instances, wires, pins, properties, nets, connectivity, geometry, device catalog, and file serialization.

All collections use `std.MultiArrayList` (SoA) for hot-path iteration. Strings are always `[]const u8` duped into a caller-supplied allocator; the `Schemify` struct owns all duped memory and frees it in `deinit`.

## Public API

### lib.zig (module root, `@import("schematic")`)

| Symbol | Kind | Purpose |
|--------|------|---------|
| `Schemify` | struct | Main document. SoA collections of all schematic elements. |
| `types` | namespace | All canonical data types (see below). |
| `helpers` | namespace | Pure utility functions (see below). |
| `fileio` | namespace | CHN reader/writer, TOML project config. |
| `devices` | namespace | Device catalog, PDK library, embedded primitives. |

### types.zig

| Symbol | Kind | Purpose |
|--------|------|---------|
| `SchematicType` | `enum(u2)` | `schematic`, `symbol`, `testbench`, `primitive`. |
| `PinDir` | `enum(u8)` | Pin direction: `input`, `output`, `inout`, `power`, `ground`. Has `fromStr`/`toStr`. |
| `GeomKind` | `enum(u8)` | `line`, `rect`, `circle`, `arc`, `text`, `polygon`. |
| `DeviceKind` | `enum(u8)` | 50+ device kinds (resistor..subckt). Methods: `isNonElectrical`, `isLabel`, `isPower`, `fromStr`. |
| `ConnKind` | `enum(u8)` | `instance_pin`, `wire_endpoint`, `label`. Has `toTag`/`fromTag`. |
| `InstanceFlags` | `packed struct(u8)` | `rot: u2`, `flip: bool`, `bus: bool`. |
| `Instance` | struct | Name, symbol, position, kind, flags, prop/conn slice indices. |
| `Wire` | struct | Two endpoints + optional net name + bus flag. |
| `Pin` | struct | Name, position, direction, width, optional number. |
| `Property` | struct | Key-value pair (`[]const u8` each). |
| `Conn` | struct | Pin-to-net binding (pin name, net name). |
| `Net` | struct | Named net (just a name field). |
| `NetConn` | struct | Net membership record: net_id, ref coords, kind, optional label. |
| `Line`, `Rect`, `Circle`, `Arc`, `Text` | structs | Geometry primitives with coordinates and layer. |
| `PinRef` | struct | Resolved pin with name, position, direction, propagation flag. |
| `SymData` | struct | Per-instance symbol data: pins, props, format strings. |
| `PrimCacheEntry` | struct | Cached pin positions + optional injected net for a primitive. |
| `NetMap` | struct | Union-find point-to-net lookup. Methods: `deinit`, `pointKey`, `getNetName`. |
| `PluginBlock` | struct | Round-trip-preserved plugin data block (name + key-value entries). |
| `FileType` | enum | `.chn`, `.chn_prim`, `.chn_tb`, `.xschem_sch`, `.unknown`. Has `fromPath`. |

### Schemify.zig

| Method | Signature (abbreviated) | Purpose |
|--------|------------------------|---------|
| `deinit` | `(*Schemify, Allocator) void` | Free all owned memory. |
| `readFile` | `([]const u8, Allocator, logger) Schemify` | Parse CHN data into a new Schemify. |
| `writeFile` | `(*Schemify, Allocator, logger) ?[]u8` | Serialize to CHN format. Returns owned slice. |
| `emitSpice` | `(*const Schemify, Allocator, pdk) ![]u8` | Delegate to `simulation.Netlist.emitSpice`. |
| `drawLine/Rect/Circle/Arc/Text/Pin` | `(*Schemify, Allocator, T) !void` | Append geometry element (dupes strings). |
| `addWire` | `(*Schemify, Allocator, x0,y0,x1,y1) !usize` | Append wire, return index. |
| `addWireFull` | `(*Schemify, Allocator, Wire) !usize` | Append wire with all fields. |
| `addInstance` | `(*Schemify, Allocator, name, symbol, x, y) !usize` | Append instance, infer kind from symbol name. |
| `addInstanceWithKind` | `(*Schemify, Allocator, name, symbol, x, y, DeviceKind) !usize` | Append instance with explicit kind. |
| `addComponent` | `(*Schemify, Allocator, ComponentDesc) !usize` | Batch-add instance with props, conns, sym_data. |
| `symToKind` | `(sym: []const u8) DeviceKind` | Map symbol string to DeviceKind (static aliases + enum parse). |
| `setName` | `(*Schemify, Allocator, []const u8) void` | Set schematic name (frees old). |
| `addSymProp` | `(*Schemify, Allocator, key, val) !void` | Append symbol-level property. |
| `addGlobal` | `(*Schemify, Allocator, name) !void` | Add global net (dedup). |
| `addPluginBlock` | `(*Schemify, Allocator, name, entries) !void` | Add plugin data block. |
| `appendSymData` | `(*Schemify, Allocator, SymData) !void` | Deep-copy and append symbol data. |
| `removeInstance/Wire/Line/Rect/Circle/Arc/Text/Pin` | `(*Schemify, Allocator, idx) void` | SwapRemove element at index. |
| `moveInstance` | `(*Schemify, idx, dx, dy) void` | Translate instance by delta. |
| `setInstancePos` | `(*Schemify, idx, x, y) void` | Set absolute position. |
| `setInstanceTransform` | `(*Schemify, idx, rot, flip) void` | Set rotation/flip. |
| `setPinWidth` | `(*Schemify, idx, width) void` | Set bus width (clamp to 1). |
| `resolveNets` | `(*Schemify, Allocator) void` | Union-find net resolution from wires + pin positions. |
| `rebuildPrimCache` | `(*Schemify, Allocator) void` | Allocate prim cache array (population deferred). |
| `rebuildSymData` | `(*Schemify, Allocator) void` | Fill empty sym_data from prim cache. |
| `bounds` | `(*const Schemify, inst_pad) Bounds` | Compute axis-aligned bounding box of all elements. |
| `ComponentDesc` | struct | Builder-style config for `addComponent`. |

### helpers.zig

| Symbol | Kind | Purpose |
|--------|------|---------|
| `applyRotFlip` | fn | Transform point by rotation (0-3) and flip around origin. |
| `findProp` | fn | Linear search for property value by key. |
| `isStructuralProp` | fn | True for keys already encoded as Instance fields (name, x, y, rot...). |
| `isSymPropMetadata` | fn | True for symbol-level metadata keys (description, spice_format, ann.*, analysis.*...). |
| `Bounds` | struct | Incremental AABB. Method: `bump(x, y)`. |

### devices/Devices.zig

| Symbol | Kind | Purpose |
|--------|------|---------|
| `Device` | struct | Runtime-resolved device with kind, prefix, pin_order, model, params. |
| `Device.fromBuiltin` | fn | Look up device from comptime LUT. Returns null for non-electrical. |
| `Device.fromPdk` | fn | Resolve from PDK, fall back to builtin. |
| `Device.emitSpice` | fn | Emit SPICE line for this device. |
| `Device.toSpiceComponent` | fn | Convert to `SpiceComponent` union (covers R/C/L/D/M/Q/J/E/F/G/H/B/X). |
| `Pdk` | struct | PDK cell library. Binary-search name index over prims/comps/tbs. |
| `Pdk.find` | fn | Look up cell by name. Returns `CellRef`. |
| `Pdk.classify` | fn | Return `CellTier` for a cell name. |
| `Pdk.resolve` | fn | Resolve cell to `Device`, falling back to builtin. |
| `Pdk.addPrimitive/Component/Testbench` | fn | Register entries. |
| `Pdk.emitPreamble` | fn | Generate `.lib`/`.include` lines for used cells. |
| `Pdk.collectLibIncludes` | fn | Deduplicated lib includes for a set of cells. |
| `Pdk.libsForCell` | fn | Lib includes for a single cell. |
| `global_pdk` | var | Mutable global singleton. |
| `prefix_lut`, `pins_lut`, `model_keyword_lut`, `non_electrical_lut`, `injected_net_lut` | `[N]T` | Comptime LUTs indexed by `@intFromEnum(DeviceKind)`. |
| `Value`, `SpiceComponent`, `ParamOverride`, `emitComponent` | re-export | From `simulation.SpiceIF`. |

### devices/primitives.zig

| Symbol | Kind | Purpose |
|--------|------|---------|
| `PrimEntry` | struct | Comptime-parsed primitive: kind, prefix, pins, params, drawing geometry, pin positions. |
| `parsed_prims` | `[36]PrimEntry` | Comptime table of all 36 embedded `.chn_prim` files. |
| `prim_count` | `usize` | 36 (number of embedded primitives). |
| `findByName` | fn (comptime) | Comptime lookup by kind name. |
| `findByNameRuntime` | fn | Runtime lookup by kind name (linear scan). |
| `DrawSeg`, `DrawCircle`, `DrawArc`, `DrawRect`, `PinPos`, `ParamPair` | structs | Drawing data types for primitives. |

### fileio/Reader.zig

| Symbol | Kind | Purpose |
|--------|------|---------|
| `readCHN` | fn | `([]const u8, Allocator) Schemify` -- Parse CHN text into a Schemify struct. Post-processes bus pin collapse and port instance synthesis. |

### fileio/Writer.zig

| Symbol | Kind | Purpose |
|--------|------|---------|
| `writeCHN` | fn | `(Allocator, *const Schemify) ?[]u8` -- Serialize Schemify to CHN text. Returns owned slice or null on failure. |

### fileio/Toml.zig

| Symbol | Kind | Purpose |
|--------|------|---------|
| `ProjectConfig` | struct | Parsed `Config.toml`: name, pdk, paths, simulation opts, plugin specs. |
| `ProjectConfig.parseFromPath` | fn | Parse from project directory (reads `Config.toml`, expands globs). |
| `ProjectConfig.parseFromString` | fn | Parse from string content. |
| `ProjectConfig.parseFromFile` | fn | Parse from explicit file path. |
| `ProjectConfig.firstSchematicPath` | fn | First `.chn` or `.chn_tb` path. |
| `ProjectConfig.allFiles` | fn | All registered file paths. |
| `ParseError` | error set | `InvalidFormat`, `OutOfMemory`. |

## Internal Structure

| File | LOC (approx) | Purpose |
|------|-------------|---------|
| `lib.zig` | 13 | Module root. Re-exports types, helpers, Schemify, fileio, devices. |
| `types.zig` | 271 | All domain types. No logic beyond enum conversions. |
| `helpers.zig` | 65 | Pure functions: rotation, property lookup, bounding box. |
| `Schemify.zig` | 791 | Central document struct. SoA storage, CRUD, net resolution (union-find), bounds. |
| `devices/lib.zig` | 9 | Devices sub-module root. |
| `devices/Devices.zig` | 445 | Device catalog, PDK cell library, SPICE mapping, comptime LUTs. |
| `devices/primitives.zig` | 394 | Comptime `.chn_prim` parser. 36 embedded symbol definitions. |
| `devices/primitives/*.chn_prim` | 36 files | Source symbol definitions (geometry + metadata). |
| `fileio/lib.zig` | 11 | File I/O sub-module root. |
| `fileio/Reader.zig` | 947 | CHN parser. State machine, type tables, generate blocks, bus collapse, port synthesis. |
| `fileio/Writer.zig` | 356 | CHN serializer. Section writers for all schematic elements. |
| `fileio/Toml.zig` | 358 | Config.toml parser. Glob expansion, plugin spec builder. |

## Dependencies

| Dependency | Used by | What for |
|------------|---------|----------|
| `simulation` | `Schemify.emitSpice`, `Devices.zig` | `Netlist.emitSpice`, `SpiceIF.Value/SpiceComponent/emitComponent` |
| `utility` | `Toml.zig` | `utility.platform.fs` for file I/O and directory walking |
| `dvui` | build dep only | Listed in build.zig but no runtime import found in schematic source |

Note: `schematic` and `simulation` have a circular dependency. `schematic` imports `simulation` for SPICE emission; `simulation` imports `schematic` for the domain types. This is handled by listing both as build deps of each other.

## Gaps

### Missing Features

These are capabilities a complete EDA schematic module would need but are absent here:

| Feature | Impact |
|---------|--------|
| **Hierarchical design** | No sheet hierarchy, no cross-sheet references, no hierarchical net propagation. Subcircuit instances exist but there is no tree of Schemify documents. |
| **Net classes / net rules** | No concept of differential pairs, matched nets, impedance targets, or net groups. |
| **Bus types** | Bus flag exists on Wire and InstanceFlags but there is no bus definition type, no bus-to-signal expansion, no bus naming convention enforcement. |
| **Design constraints** | No way to attach electrical constraints (voltage domains, current limits, matching groups) to nets or instances. |
| **Schematic variants** | No variant/configuration management. One document = one variant. |
| **Cross-probing data** | No source location tracking (file + line) on elements. No mapping from schematic element to layout element. |
| **Annotation / back-annotation** | Annotations are stored as flat key-value sym_props with `ann.*` prefix. No structured annotation type, no back-annotation from simulation results or layout. |
| **Electrical rule checks (ERC)** | No connectivity validation, no floating-net detection, no power-domain checking. |
| **Parameterized cells (PCells)** | No parametric geometry generation. Primitives are static embedded files. |
| **Undo/redo at model level** | Undo is handled externally. Schemify has no snapshot/diff/command-pattern support. |
| **Net aliases / net merging** | `resolveNets` builds nets from scratch each time. No persistent net identity across edits. |
| **Text/label geometry** | `Text` struct exists but is not used for net labels or pin labels -- those are inferred from instance properties. No rich text. |
| **Polygon geometry** | `GeomKind` has `.polygon` but there is no `Polygon` struct and no polygon drawing/storage. |
| **Multi-page schematics** | Single flat page only. No page/sheet abstraction. |

### API Issues

| Issue | Location | Detail |
|-------|----------|--------|
| **Circular dependency** | `Schemify.zig` <-> `simulation` | `emitSpice` forces schematic to import simulation. Should be a caller-side composition, not a method on Schemify. |
| **`global_pdk` mutable global** | `Devices.zig:425` | A `var` singleton defeats the "no hidden state" principle. Should be passed explicitly. |
| **`readFile`/`writeFile` take unused `logger` param** | `Schemify.zig:148,153` | Parameter is accepted as `anytype` and immediately discarded (`_ = logger`). Dead parameter. |
| **Error swallowing** | Reader.zig, Schemify.zig | Pervasive `catch {}` on append operations silently drops OOM. Callers cannot distinguish partial parse from success. |
| **`removeInstance` uses swapRemove** | `Schemify.zig:362` | SwapRemove invalidates the last element's index. `prop_start`/`conn_start` of the swapped element are not updated, leaving stale indices. |
| **`resolveNets` clears and rebuilds** | `Schemify.zig:442` | Full rebuild on every call. No incremental update, no dirty tracking for nets (only `prim_cache_dirty` exists). |
| **Instance props use flat shared array** | `Schemify.zig` | `prop_start`/`prop_count` index into a single `props` list. Deleting an instance does not free or compact its props slice, leaking entries until `deinit`. |
| **`symToKind` duplicated** | `Schemify.zig:233` and `Reader.zig:889` | Two copies of the symbol-to-kind mapping (`symToKind` and `typeGroupToKind`) with the same static map. |
| **`Pdk` does not free string content** | `Devices.zig:180` | `Pdk.deinit` frees MAL storage but the strings (cell_name, file, etc.) inside are borrowed, not owned -- ownership contract is undocumented. |
| **`page_allocator` in hot path** | `Devices.zig:94` | `Device.toSpiceComponent` for vsource uses `std.heap.page_allocator` for a format string. Should use the caller's allocator. |
| **No `init` constructor for Schemify** | `Schemify.zig` | Default initialization via `var s: Schemify = .{}` works but violates the "constructors validate invariants" principle. |
| **`ComponentDesc` has no builder** | `Schemify.zig:254` | 10-field struct with defaults, but no chained builder or validation. |
| **`Bounds` uses `f32` despite `i32` coordinates** | `helpers.zig:49` | Lossy conversion from `i32` to `f32` for large coordinates. Should stay `i32` or use `f64`. |
| **Writer loses `power`/`ground` pin direction** | `Writer.zig:304` | `pinDirStr` maps both `.power` and `.ground` to `"inout"`, losing the original direction on round-trip. |
| **No Polygon storage** | `types.zig:33` | `GeomKind.polygon` exists but there is no corresponding struct or storage in Schemify. |
