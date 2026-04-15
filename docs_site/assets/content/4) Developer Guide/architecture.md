# Architecture

## Module Map

```
src/
├── main.zig              application entry point (4 dvui callbacks)
├── cli.zig               CLI subcommands (--cli mode)
├── PluginIF.zig          stable plugin ABI definition
├── core/
│   ├── Schemify.zig      netlist generation, hierarchy
│   ├── types.zig         Wire, Instance, Pin, Net, Prop, Conn
│   ├── fileio/
│   │   ├── Reader.zig    CHN parser
│   │   ├── Writer.zig    CHN serializer
│   │   ├── Toml.zig      Config.toml parser
│   │   └── utils.zig     file I/O helpers
│   ├── devices/
│   │   └── Devices.zig   DeviceKind enum, primitives, PDK models
│   └── simulation/
│       ├── SpiceIF.zig   simulator interface, Value, SpiceComponent
│       ├── Netlist.zig   SPICE IR, validation, emission
│       └── backend/      ngspice + Xyce runners
├── gui/
│   ├── lib.zig           frame dispatcher (render order)
│   ├── Input.zig         keyboard/mouse handling
│   ├── Actions.zig       keybind → Action enum
│   ├── Canvas/
│   │   ├── lib.zig
│   │   ├── SymbolRenderer.zig
│   │   ├── WireRenderer.zig
│   │   ├── Interaction.zig    hit-test, drag, rubber-band
│   │   ├── SelectionOverlay.zig
│   │   └── TbOverlay.zig     testbench pill button + ghost wires
│   ├── Bars/             toolbar, tabbar, command bar
│   ├── Panels/           file browser, library, marketplace
│   ├── Dialogs/          properties, keybinds, find, spice code
│   ├── Keybinds/         keymap definitions
│   └── state/
│       ├── AppState.zig  global app state (plugins, config, open tabs)
│       ├── Document.zig  per-tab schematic + selection + tool state
│       └── types.zig
├── commands/
│   ├── lib.zig
│   ├── CommandQueue.zig  undo/redo ring buffer
│   ├── Dispatch.zig      Action → handler router
│   ├── handlers/         one file per command (AddWire, Move, Delete…)
│   └── utils/            move, copy, delete helpers
├── plugins/
│   ├── PluginIF.zig      message protocol, ABI v6
│   ├── Runtime.zig       load/tick/unload lifecycle
│   ├── Framework.zig     helper abstractions for plugin authors
│   └── installer/        plugin install/remove
├── utility/
│   ├── Vfs.zig           virtual filesystem (native + WASM)
│   ├── Logger.zig        structured logging
│   └── Platform.zig      OS abstraction
└── web/                  WASM-specific shell (IndexedDB VFS, boot.js)
```

## Data Model

### AppState vs Document

`AppState` (global, process-lifetime):
```zig
pub const AppState = struct {
    config:       Config,
    open_tabs:    ArrayList(Document),
    active_tab:   usize,
    plugins:      PluginHost,
    theme:        Theme,
};
```

`Document` (per-tab, schematic-lifetime):
```zig
pub const Document = struct {
    schematic:  Schematic,
    selection:  SelectionSet,
    tool_state: ToolState,   // wire mode, placement mode, etc.
    undo_queue: CommandQueue,
    file_path:  ?[]const u8,
    dirty:      bool,
};
```

This split means undo/redo is per-tab, plugins are global.

### Schematic Data (DOD)

Schemify uses `std.MultiArrayList` (Structure-of-Arrays) for all schematic data.

```zig
pub const Schematic = struct {
    instances: MultiArrayList(Instance),
    wires:     MultiArrayList(Wire),
    nets:      MultiArrayList(Net),
    labels:    MultiArrayList(Text),
};

// Fast: iterating all X coords is contiguous memory
const xs = schematic.instances.items(.x);
const ys = schematic.instances.items(.y);
```

### Core Types

```zig
pub const Wire = struct {
    x0, y0, x1, y1: i32,
    net_name: ?[]const u8,
    bus: bool,
};

pub const Instance = struct {
    name:        []const u8,   // "R1", "M2", "Xamp"
    symbol:      []const u8,   // reference to .chn_prim or .chn
    x, y:        i32,
    rot:         u2,           // 0=0°, 1=90°, 2=180°, 3=270°
    flip:        bool,
    kind:        DeviceKind,
    prop_start:  u32,          // index into flat property array
    prop_count:  u16,
    conn_start:  u32,          // index into flat connection array
    conn_count:  u16,
};

pub const Prop = struct { key, val: []const u8 };
pub const Conn = struct { pin, net: []const u8 };
```

Net connectivity uses union-find (`NetMap`): wires are merged into nets by scanning endpoints.

## Command Queue and Undo

All mutations go through the `Command` union in `commands/`:

```zig
pub const UndoableAction = union(enum) {
    add_wire:            WireAddCmd,
    delete_selection:    DeleteCmd,
    move_instances:      MoveCmd,
    copy_paste:          PasteCmd,
    rotate_cw, rotate_ccw,
    flip_h, flip_v,
    set_instance_prop:   PropCmd,
    // ...
};
```

`CommandQueue` is a ring buffer — push appends, undo pops and inverts, redo re-applies.

```zig
// Trigger from GUI
actions.enqueue(app, .{ .undoable = .{ .add_wire = .{
    .start = p0,
    .end   = p1,
} } }, "Add wire");
```

Handlers in `commands/handlers/` implement `handle()` and `undo()` for each action.

## VFS — Virtual Filesystem

All file I/O goes through `utility/Vfs.zig`. Calling `std.fs` directly outside `utility/` and `cli/` is banned (enforced by lint).

**Why:** WASM has no native filesystem. VFS maps to:
- **Native:** `std.fs`
- **Web:** IndexedDB via JS interop

```zig
// In plugin or core code:
const data = try Vfs.readAlloc(allocator, "config.toml");
defer allocator.free(data);

try Vfs.writeAll("output.spice", netlist_text);
try Vfs.makePath("cache/pdk");
```

## Rendering Pipeline

Frame order (back → front):

1. Grid
2. Wires (`WireRenderer`)
3. Instance bodies (`SymbolRenderer`)
4. Instance pins
5. Net labels
6. Selection highlights (`SelectionOverlay`)
7. Rubber-band rectangle
8. Testbench ghost overlay (`TbOverlay`) — only when hovering TB pill
9. Plugin overlays (floating panels)
10. UI chrome (topbar, sidebar, toolbar, statusbar)

## Testbench Overlay

When a `.chn` schematic is open and a matching `.chn_tb` exists in the same project:

- Pill button appears in top-right of canvas: `▶ test.chn_tb`
- **Hover** → ghost-draws testbench wires on top of the DUT schematic (shows port connections)
- **Click** → switch active tab to the testbench
- **Shift+Click** → open testbench in a new tab

Implemented in `gui/Canvas/TbOverlay.zig`.

## Dual Backend

```bash
zig build                    # native (SDL3 + Raylib, OpenGL)
zig build -Dbackend=web      # WASM (HTML5 Canvas via dvui wasm32 backend)
```

Same source. Platform-specific code isolated to `web/` and the dvui backend selection in `build.zig`. VFS, plugin runtime, and all core logic are backend-agnostic.

## CLI Mode

Schemify has a headless CLI mode — no display, no dvui:

```bash
zig build run -- --cli help
zig build run -- --cli netlist output.spice schematic.chn
zig build run -- --cli export-svg render.svg schematic.chn
zig build run -- --cli plugin-install ./libMyPlugin.so
```

Implemented in `src/cli.zig`. CLI mode compiles out the GUI entirely — no Xvfb needed in CI.
