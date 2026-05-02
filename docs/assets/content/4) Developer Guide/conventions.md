# Code Conventions

## Module Rules

1. **`lib.zig` is the public surface.** Each directory that forms a logical module exposes exactly one `lib.zig`. Internal files are not imported directly by outside code.

2. **`types.zig` holds shared types.** Types shared within a module live in `types.zig`. Cross-module types live in the nearest common ancestor's `types.zig`.

3. **One primary struct per file.** A file named `Foo.zig` exports exactly one primary `pub const Foo = struct { ... }`. Helper types used only by `Foo` may be private.

4. **No `std.fs` outside `utility/` and `cli/`.** File system access is banned in core logic and GUI code. Only `utility/Vfs.zig` and CLI entry points may touch the filesystem. This keeps the WASM backend working.

5. **No mutations in GUI code.** GUI code pushes `Command` values to the command queue. It does not mutate `AppState` or `Document` directly.

6. **No allocations in render functions.** Frame functions must be allocation-free to avoid per-frame GC pressure. Pre-allocate in init; use scratch buffers for temporaries.

## Naming

| Thing | Convention | Example |
|-------|-----------|---------|
| Types / structs | PascalCase | `Schematic`, `PlaceInstanceCmd` |
| Functions | camelCase | `emitSpice`, `renderCanvas` |
| Variables / fields | camelCase | `activeTab`, `wireCount` |
| Comptime constants | SCREAMING_SNAKE | `ABI_VERSION` |
| Unused parameters | `_` prefix | `fn foo(_unused: u32)` |
| File names (types) | PascalCase | `FileIO.zig`, `AppState.zig` |
| File names (modules) | lowercase | `state.zig`, `lib.zig` |

## Data-Oriented Design

Prefer Structure-of-Arrays over Array-of-Structs for hot data:

```zig
// Avoid: strides through full struct to reach x coordinates
var instances: ArrayList(Instance) = .{};
for (instances.items) |inst| { _ = inst.x; }

// Prefer: contiguous x array, cache-friendly
var instances: MultiArrayList(Instance) = .{};
const xs = instances.items(.x);
for (xs) |x| { _ = x; }
```

Separate hot (per-frame) and cold (property editor) data:

```zig
// Hot: rendered every frame
const InstanceHot = struct { x: i32, y: i32, kind: DeviceKind, rot: u2, flip: bool };

// Cold: accessed only in property dialog
const InstanceCold = struct { name: []const u8, description: []const u8 };
```

## Error Handling

```zig
// Good: explicit error union, caller knows what failed
pub fn readSchematic(path: []const u8) !Schematic { ... }

// Bad: optional doesn't explain failure
pub fn readSchematic(path: []const u8) ?Schematic { ... }

// Good: propagate with try
const data = try Vfs.readAlloc(alloc, path);

// Bad: swallow errors silently
const data = Vfs.readAlloc(alloc, path) catch return .{};
```

- Never `catch unreachable` in production paths
- Catch only at true boundary points (user input, file I/O, plugin calls)
- Allocator errors are always propagated, never swallowed

## Allocator Discipline

```zig
// Pass allocator as parameter — never store globally
pub fn parseChN(allocator: Allocator, input: []const u8) !Schematic { ... }

// Free immediately after use
const data = try Vfs.readAlloc(alloc, path);
defer alloc.free(data);

// Arena for scratch work within a function
var arena = ArenaAllocator.init(alloc);
defer arena.deinit();
const scratch = arena.allocator();
```

## Adding a Command

**1.** Add to `UndoableAction` in `commands/lib.zig`:
```zig
pub const MyCmd = struct { target_idx: u32, new_val: []const u8 };
pub const UndoableAction = union(enum) {
    // ...existing...
    my_command: MyCmd,
};
```

**2.** Write handler in `commands/handlers/MyCommand.zig`:
```zig
pub fn handle(cmd: MyCmd, doc: *Document) !void { ... }
pub fn undo(cmd: MyCmd, doc: *Document) !void { ... }
```

**3.** Register in `commands/Dispatch.zig`:
```zig
.my_command => |cmd| try MyCommand.handle(cmd, doc),
```

**4.** Trigger from GUI:
```zig
actions.enqueue(app, .{ .undoable = .{ .my_command = .{
    .target_idx = idx,
    .new_val    = "value",
} } }, "My command description");
```

## Adding a Plugin Message

**1.** Add tag to `PluginIF.Tag` enum — host→plugin tags `0x01–0x7F`, plugin→host `0x80–0xFF`.

**2.** Add variant to `InMsg` or `OutMsg` union.

**3.** Update `Reader.next()` to decode the new tag.

**4.** Add `Writer` method to encode the new message.

**5.** Handle in `plugins/Runtime.zig`.

**6.** Bump `ABI_VERSION` only if change is breaking (removed/reordered tags). Adding new tags is backward compatible — unknown tags are skipped by the reader.

## GUI Frame Rules

```zig
// Good: read state, emit draw calls + commands
fn renderToolbar(state: *const AppState, q: *CommandQueue) void {
    if (dvui.button("Place Wire")) {
        q.push(.{ .undoable = .{ .begin_wire = .{} } });
    }
}

// Bad: mutate state directly in render function
fn renderToolbar(state: *AppState) void {
    if (dvui.button("Place Wire")) {
        state.active_doc.tool = .wire;  // never do this
    }
}
```

Render functions must be idempotent: calling twice with the same state produces identical output.
