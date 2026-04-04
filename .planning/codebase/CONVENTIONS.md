# Coding Conventions

**Analysis Date:** 2026-04-04

## Module Structure

**Mandatory folder-based modules.** Every module is a directory, never a single file. Required structure:

```
src/<module>/
  lib.zig        # Public API surface, re-exports from types.zig, module-level tests
  types.zig      # All shared/simple data types (module-internal by default)
  SomeStruct.zig # Named after its ONE pub struct
```

**One pub struct per file** (except `types.zig` which holds multiple shared types).

**lib.zig re-exports pattern:**
```zig
// src/core/lib.zig
const types = @import("types.zig");
pub const PinDir = types.PinDir;
pub const Line = types.Line;
// ...
pub const Schemify = @import("Schemify.zig").Schemify;
```

**comptime import block** at bottom of `lib.zig` pulls in all sub-file tests:
```zig
comptime {
    _ = @import("types.zig");
    _ = @import("Devices.zig");
    _ = @import("Reader.zig");
    // ...
}
```

**Reference files:**
- `src/core/lib.zig` -- canonical example of re-export + comptime test pull-in
- `src/utility/lib.zig` -- minimal module root
- `src/commands/lib.zig` -- uses `refAllDecls(@This())` for exhaustive test pull
- `src/plugins/lib.zig` -- ABI protocol re-exports + widget types
- `src/state/lib.zig` -- state re-exports + global singleton

## Naming Patterns

**Files:**
- `PascalCase.zig` for files containing one pub struct: `Schemify.zig`, `AppState.zig`, `Document.zig`, `CommandQueue.zig`, `Logger.zig`
- `lib.zig` and `types.zig` are always lowercase (module infrastructure)
- `helpers.zig` for shared private utility functions within a module (`src/commands/helpers.zig`)
- Exception: `primitives.zig` in `src/core/devices/` (data file, not a struct)

**Types:**
- `PascalCase` for all structs, enums, unions: `Schemify`, `AppState`, `PinDir`, `DeviceKind`
- Abbreviations stay uppercase within PascalCase: `MAL` (MultiArrayList alias), `CHN` (file format)

**Functions:**
- `camelCase` for all public and private functions: `readCHN`, `writeFile`, `zoomIn`, `handleImmediate`
- `init` / `deinit` for lifecycle (never `new`/`destroy`/`create`/`free`)
- `fromStr` / `toStr` for enum serialization round-trips

**Variables:**
- `snake_case` for all local variables, struct fields, and function parameters
- Abbreviations lowercased in fields: `panel_id`, `widget_id`, `abi_version`

**Constants:**
- `SCREAMING_SNAKE_CASE` for global/pub constants: `ABI_VERSION`, `RING_CAP`, `MSG_CAP`, `HEADER_SZ`, `MAX_OUT_BUF`
- `snake_case` for comptime local constants within blocks

**Aliases at file top:**
```zig
const std = @import("std");
const Allocator = std.mem.Allocator;
const MAL = std.MultiArrayList;
const List = std.ArrayListUnmanaged;
```

## Data-Oriented Design

**Mandatory.** All structs must follow data-oriented design principles.

**Field ordering by alignment** -- largest alignment first, smallest last. Every struct has a comment documenting the ordering rationale:
```zig
pub const Instance = struct {
    // slices (8-byte) first, then u32, then i32, then u16, then u2/bool/enum
    name: []const u8,
    symbol: []const u8,
    spice_line: ?[]const u8 = null,
    prop_start: u32 = 0,
    conn_start: u32 = 0,
    x: i32,
    y: i32,
    prop_count: u16 = 0,
    conn_count: u16 = 0,
    kind: DeviceKind = .unknown,
    rot: u2 = 0,
    flip: bool = false,
};
```

**Prefer SoA over AoS.** Core data uses `std.MultiArrayList` (aliased as `MAL`):
```zig
// src/core/Schemify.zig
lines: MAL(Line) = .{},
rects: MAL(Rect) = .{},
wires: MAL(Wire) = .{},
instances: MAL(Instance) = .{},
```

Access individual fields via `.items(.field)`:
```zig
const xs = sch.instances.items(.x);
const ys = sch.instances.items(.y);
```

**"Expose struct size" tests** guard against padding bloat:
```zig
test "Expose struct size for Command" {
    const print = @import("std").debug.print;
    print("Command:      {d}B\n", .{@sizeOf(Command)});
}
```

The `zig build get_size` step collects all such tests and prints a sorted size report.

**Use `packed struct` for bitfields**, `extern struct` for C ABI compatibility:
- `src/state/types.zig`: `CommandFlags = packed struct` (bitfield flags)
- `src/core/types.zig`: `CellRef = packed struct(u32)` (index + tier in 32 bits)
- `src/plugins/types.zig`: `Descriptor = extern struct` (ABI-stable layout)
- `src/utility/types.zig`: `Entry = extern struct` (C-compatible log record)

## Code Style

**Formatting:**
- Use `zig fmt` (the standard Zig formatter). No custom formatting config.
- 4-space indentation (Zig default).

**Linting:**
- Build-time lint step in `build.zig` bans `std.fs.*` and `std.posix.getenv` outside `src/utility/` and `src/cli/`.
- Use `utility.Vfs` for filesystem access and `utility.platform` for environment access.

**Line length:** No hard limit, but prefer lines under ~120 characters. Long struct initializers and switch arms may exceed this.

## Import Organization

**Order:**
1. `std` and `builtin` imports
2. Build-system module imports (`@import("core")`, `@import("state")`, `@import("utility")`)
3. Intra-module file imports (`@import("types.zig")`, `@import("Schemify.zig")`)
4. Type aliases from imports

**Path aliases:** Build-system modules only (no `@` path aliases):
- `@import("core")` -- schematic data model
- `@import("state")` -- application state
- `@import("utility")` -- logger, vfs, platform, simd
- `@import("commands")` -- command types and dispatch
- `@import("plugins")` -- plugin runtime and ABI
- `@import("dvui")` -- GUI framework

**Typical file header:**
```zig
const std = @import("std");
const Allocator = std.mem.Allocator;

const core = @import("core");
const utility = @import("utility");
const types = @import("types.zig");

const PinDir = types.PinDir;
const Instance = types.Instance;
```

## Error Handling

**Named error sets.** Never use `anyerror`. Every command handler module exports a specific `Error` type:
```zig
// src/commands/Edit.zig
pub const Error = error{OutOfMemory};

// src/commands/File.zig
pub const Error = error{ OutOfMemory, FileNotFound, ReadError, WriteError, Overflow, WriteFailed };

// src/commands/View.zig
pub const Error = error{};  // infallible
```

**Error set union for dispatch.** The central dispatcher merges all handler errors:
```zig
// src/commands/Dispatch.zig
pub const DispatchError =
    view.Error ||
    selection.Error ||
    clipboard.Error ||
    edit.Error ||
    wire.Error ||
    file.Error ||
    hierarchy.Error ||
    netlist.Error ||
    sim.Error ||
    undo.Error;
```

**Error handling patterns:**
- `try` for propagation: `try self.documents.append(a, doc);`
- `catch return` for silent fallback: `alloc.dupe(u8, path) catch return;`
- `catch continue` in loops: `sch.instances.append(sa, copy) catch continue;`
- `catch |err| switch` for specific error handling:
  ```zig
  self.config = ProjectConfig.parseFromPath(...) catch |err| switch (err) {
      error.FileNotFound => return,
      else => return err,
  };
  ```
- `errdefer` for cleanup on error path: `errdefer allocator.free(buf);`
- `orelse return` for optional unwrapping: `const fio = state.active() orelse return;`

**Status messages for user-facing errors:**
```zig
state.setStatusErr("SVG export failed");
state.setStatus("Save the schematic first");
```

## Logging

**Framework:** Custom ring-buffer logger in `src/utility/Logger.zig`. Zero-allocation after init.

**Patterns:**
```zig
// Initialize with minimum level
self.log = utility.Logger.init(.info);

// Level-specific convenience methods (prefer these over .log())
app.log.info("CMD", "plugin command: {s}", .{p.tag});
app.log.err("CMD", "dispatch {s} failed: {}", .{@tagName(c), err});
app.log.warn("SRC", "message: {}", .{value});

// Source tag is a short string (max 32 chars) identifying the subsystem
// Format string is comptime, args is anytype
```

**Log levels:** `trace`, `debug`, `info`, `warn`, `err`, `fatal` (defined in `src/utility/types.zig`).

## Comments

**File-level doc comments (`//!`)** at the top of every file describing its purpose and contents:
```zig
//! Schemify.zig -- The core schematic data model.
//!
//! This file serves double duty:
//!   1. Contains the `Schemify` pub struct (one pub struct per file rule).
//!   2. Acts as the build.zig module root...
```

**Doc comments (`///`)** on public functions and complex private functions:
```zig
/// Load a complete file so parsers get a contiguous slice to work from.
pub fn readAlloc(allocator: Allocator, path: []const u8) ![]u8 {
```

**Section separators** using decorated comment lines:
```zig
// ── Re-exports ──────────────────────────────────────────────────────────────
// ── Lifecycle ────────────────────────────────────────────────────────────────
// ── Private helpers ──────────────────────────────────────────────────────────
```

**Alignment comment** in struct fields:
```zig
// 8-byte aligned (pointers / slices / fat structs)
// 4-byte aligned
// 1-byte
```

## Function Design

**`state: anytype` pattern for command handlers.** All command handler functions accept `state: anytype` to decouple from AppState's concrete type, enabling testability:
```zig
// src/commands/View.zig
pub fn handle(imm: Immediate, state: anytype) Error!void {
    switch (imm) {
        .zoom_in => state.view.zoomIn(),
        // ...
    }
}
```

**`@This()` pattern for single-struct files.** Files containing one pub struct use `const Self = @This()` or `const TypeName = @This()`:
```zig
// src/state/AppState.zig
const AppState = @This();
// src/state/Document.zig
const Document = @This();
```

**Comptime generics** for type-erased wrappers (plugin framework):
```zig
fn wrapHandler(comptime S: type, comptime h: fn (*S) void) *const fn (*anyopaque) void {
    return &struct {
        fn call(p: *anyopaque) void {
            h(@alignCast(@ptrCast(p)));
        }
    }.call;
}
```

**Comptime string parameters** for toggle/flag helpers:
```zig
fn toggleFlag(state: anytype, comptime field: []const u8, comptime label: []const u8) void {
    const ptr = &@field(state.cmd_flags, field);
    ptr.* = !ptr.*;
    state.setStatus(if (ptr.*) label ++ " on" else label ++ " off");
}
```

**Comptime lookup tables** for performance:
```zig
// src/plugins/types.zig -- tag direction lookup
pub const host_to_plugin_tag = blk: {
    var table = [_]bool{false} ** 256;
    // ... populate at comptime
    break :blk table;
};

// src/utility/types.zig -- level symbol table
const sym_table: [6][3]u8 = blk: {
    // ... generate at comptime from enum field names
    break :blk t;
};
```

**Static keybind table** sorted at comptime for O(log n) binary search:
```zig
// src/gui/Keybinds.zig
pub const static_keybinds = blk: {
    var sorted = table;
    std.sort.insertion(Keybind, &sorted, {}, lessThan);
    break :blk sorted;
};
```

## Module Exports

**Explicit re-exports only.** `lib.zig` re-exports exactly what external consumers need. Internal types stay in `types.zig`:
```zig
// Public (re-exported in lib.zig)
pub const PinDir = types.PinDir;

// Internal (NOT re-exported -- used only within module)
pub const ParamDefault = struct { ... };
pub const DeviceEntry = struct { ... };
```

**No barrel file wildcards.** Every re-export is an explicit `pub const X = ...` line.

## SIMD and Performance

**SIMD primitives** in `src/utility/Simd.zig` for text scanning:
```zig
pub fn findByte(haystack: []const u8, needle: u8) ?usize {
    const splat_n: Vec = @splat(needle);
    // 16-byte vector chunks with scalar tail fallback
}
```

**Vector math** for coordinate transforms:
```zig
// src/commands/Edit.zig
const fpos: @Vector(2, f32) = .{ @floatFromInt(xs[i]), @floatFromInt(ys[i]) };
const sv: @Vector(2, f32) = @splat(snap);
const rounded = @round(fpos / sv) * sv;
```

## Platform Abstraction

**Comptime backend selection** via `builtin.cpu.arch`:
```zig
const is_wasm = builtin.cpu.arch == .wasm32 or builtin.cpu.arch == .wasm64;

pub fn readAlloc(allocator: Allocator, path: []const u8) ![]u8 {
    if (comptime is_wasm) {
        // WASM host import path
    }
    return std.fs.cwd().readFileAlloc(...);
}
```

**Never use `std.fs.*` or `std.posix.getenv` outside `src/utility/` and `src/cli/`.** This is enforced at build time by a lint step in `build.zig`.

## Command System

**Two-tier command discriminant:**
```zig
pub const Command = union(enum) {
    immediate: Immediate,  // view/UI commands, never enter history
    undoable: Undoable,    // schematic mutations, enter undo/redo ring
};
```

**Enqueue, never mutate directly.** Use the command queue for all state mutations:
```zig
actions.enqueue(app, .{ .undoable = .delete_selected }, "Delete");
actions.enqueue(app, .{ .immediate = .zoom_in }, "Zoom in");
```

---

*Convention analysis: 2026-04-04*
