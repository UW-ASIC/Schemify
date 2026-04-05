# Schemify — Developer Guide

## Build Commands
```bash
zig build              # Native build (raylib)
zig build run          # Build + run native GUI
zig build -Dbackend=web   # Web build (WASM)
zig build run_local -Dbackend=web  # Serve at http://localhost:8080
zig build test         # Run all tests
```

## Module Structure Rules

Every module MUST be a folder (no single-file modules). Required structure:

```
src/<module>/
├── lib.zig        # Public API, re-exports from types.zig, bulk of tests
├── types.zig      # All public types (private to external except for function signatures)
├── SomeStruct.zig # Named after its ONE pub struct; uses types from types.zig
└── ...
```

- **One pub struct per file** (except types.zig which holds shared/simple data types)
- Private/helper structs go in `types.zig`, referenced from there
- `lib.zig` re-exports only what external consumers need:
  ```zig
  pub const TypeName = @import("types.zig").TypeName;
  ```
- All structs must follow **data-oriented design**: minimize padding, order fields by alignment, prefer SoA over AoS, avoid unnecessary indirection

## Source Layout

```
src/
├── main.zig          # Entry point (not a module)
├── commands/         # Command dispatch, undo/redo, all editor commands
├── core/             # Schematic data model, netlist, HDL parsing, SPICE, TOML
├── cli/              # CLI argument parsing and headless mode
├── gui/              # GUI rendering (see GUI section below)
├── plugins/          # Plugin runtime, installer
├── pluginif/         # Plugin ABI v6 protocol (Reader, Writer, Descriptor, Tags)
├── state/            # AppState, Document, Viewport, Selection, Tool, GuiState
├── utility/          # Logger, Platform, Simd, UnionFind, Vfs
└── web/              # JS files for WASM host (not a Zig module)
```

## GUI Architecture

### Dual Backend
- **Native**: raylib + dvui immediate-mode GUI
- **Web**: WASM + dvui web backend + canvas

Both share the same Zig GUI code. The `build.zig` `-Dbackend=native|web` flag switches the dvui backend.

### Frame Rendering Order (gui/lib.zig)

The GUI renders in strict z-order each frame:

```
1. INPUT HANDLING (handleInput)
   └── dvui.events() → keybind dispatch → state changes / commands queued

2. LAYOUT & RENDERING (frame)
   ├── ToolBar.draw()           — Menu bar (File, Edit, View, Draw...)
   ├── TabBar.draw()            — Document tabs + Sch/Sym toggle
   ├── MIDDLE REGION (horizontal box):
   │   ├── Left Sidebar         — Plugin panels
   │   ├── Center               — Renderer (canvas) + Bottom Bar Panels
   │   └── Right Sidebar        — Plugin panels
   ├── CommandBar.draw()        — Status line + vim command input
   ├── Overlay plugin panels
   ├── FileExplorer / LibraryBrowser / Marketplace
   ├── ContextMenu
   └── Dialogs (Props, Find, Keybinds)
```

### Key GUI Files

| File | Purpose | Complexity |
|------|---------|-----------|
| `gui/lib.zig` | Orchestration, frame order, input handling | Medium |
| `gui/Renderer.zig` | Canvas rendering, viewport, primitives, interaction | High (~1200 LOC) |
| `gui/Actions.zig` | Command dispatch, vim-style parsing | Medium |
| `gui/Keybinds.zig` | Static keybind table (binary search) | Low-Medium |
| `gui/PluginPanels.zig` | Plugin widget rendering from ParsedWidget[] | Medium |
| `gui/Theme.zig` | Color palette + JSON overrides | Low-Medium |
| `gui/Bars/ToolBar.zig` | Menu items | Low-Medium |
| `gui/Bars/TabBar.zig` | Tabs + view toggle | Low |
| `gui/Bars/CommandBar.zig` | Status line + command mode | Low |
| `gui/Dialogs/` | PropsDialog, FindDialog, KeybindsDialog | Low |
| `gui/Components/` | FloatingWindow, HorizontalBar | Low |
| `gui/FileExplorer.zig` | File browser dialog | Low |
| `gui/LibraryBrowser.zig` | Component library browser | Low |
| `gui/Marketplace.zig` | Plugin marketplace UI | Low |
| `gui/ContextMenu.zig` | Right-click context menus | Low |

### Data Flow

1. **Input** → dvui events → keybind dispatch → GUI state changes / commands queued
2. **Command Processing** (main.zig appFrame) → command.dispatch() → state mutations
3. **Plugin Tick** → runtime.tick() → emit UI widget updates
4. **Rendering** → gui.frame() → layout + all sub-module draws
5. **Canvas Interaction** → Renderer.draw() emits CanvasEvent → gui.lib processes

### DVUI Widget Patterns

```zig
// Layout
var box = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
defer box.deinit();

// Widgets
if (dvui.button(@src(), label, .{}, .{})) { /* handle click */ }
if (dvui.slider(@src(), .{ .fraction = &val }, .{})) { /* handle change */ }
if (dvui.checkbox(@src(), &checked, label, .{})) { /* handle toggle */ }
dvui.labelNoFmt(@src(), text, .{}, .{});
dvui.separator(@src(), .{});

// Floating window
var fw = dvui.floatingWindow(@src(), .{ .open_flag = &visible }, .{});
defer fw.deinit();
```

### Command Dispatch

```zig
// Undoable command (goes through queue + undo/redo)
actions.enqueue(app, .{ .undoable = .delete_selected }, "Delete");

// Immediate command (no undo)
actions.enqueue(app, .{ .immediate = .zoom_in }, "Zoom in");

// GUI-only command (direct state mutation, no queue)
actions.runGuiCommand(app, .view_schematic);
```

### Plugin Panel Rendering

Plugins emit `ParsedWidget` arrays via ABI v6. `PluginPanels.drawPanelBody()` renders them:
```zig
const rt: *Runtime = @ptrCast(@alignCast(app.plugin_runtime_ptr.?));
const wl = rt.getPanelWidgetList(panel.panel_id);
// Iterate widget tags, strings, values → render via dvui
// Dispatch events: rt.dispatchButtonClicked(), rt.dispatchSliderChanged()
```

### GUI Rules

- **Preserve frame z-order** — rendering order in lib.zig matters
- **Queue commands for undoable ops** — don't mutate state directly
- **Use Theme.zig palette** — never hardcode colors
- **Don't break plugin panel contract** — ParsedWidget rendering must stay stable
- **Test both backends** — `zig build run` (native) and `zig build -Dbackend=web`
- **dvui text entry is not yet stable** — some dialogs have TODOs around this

### Common GUI Tasks

**Add a menu item**: Edit `Bars/ToolBar.zig` → add entry to menu table → reference action
**Add a dialog**: Create `Dialogs/MyDialog.zig` with `.open` flag + `draw(app)` → call from lib.zig
**Add a keybind**: Edit `Keybinds.zig` static table → add key/modifier/action entry
**Modify canvas rendering**: Edit `Renderer.zig` → adjust primitives in `draw()` method
**Customize theme**: Edit `Theme.zig` → modify palette or add override fields

## Plugin System (ABI v6)

Single entry point: `schemify_process(in_ptr, in_len, out_ptr, out_cap) usize`
- Wire format: `[u8 tag][u16 payload_sz LE][payload bytes]`
- No VTable, identical for native and WASM
- See `pluginif/` for protocol details

## Lint Rules

- No `std.fs.*` or `std.posix.getenv` outside `utility/` and `cli/` — use Vfs/Platform instead
- Enforced at build time via shell lint step in build.zig

<!-- GSD:project-start source:PROJECT.md -->
## Project

**Schemify GUI Redesign**

Schemify is a Zig-based EDA schematic editor with dual native (raylib) and web (WASM) backends, an ABI v6 plugin system, and a command-queue architecture. The GUI is currently mostly broken — it renders a visual shell but most interactions don't work. This project rebuilds the entire `gui/` module with a clean component architecture, minimal toolbar, and full editor functionality across both backends.

**Core Value:** A functional schematic editor where users can place components, draw wires, edit properties, run simulations, and manage files — all through a clean, minimal GUI that works identically on native and web.

### Constraints

- **Tech stack**: Zig 0.15.x + dvui 0.4.0-dev + raylib (native) / WASM canvas (web). No new dependencies.
- **Module rules**: Must follow CLAUDE.md module structure (lib.zig, types.zig, one pub struct per file)
- **Dual backend**: All GUI code must work on both native and web. No platform-specific GUI code.
- **Plugin contract**: ParsedWidget rendering must stay stable — plugins depend on the ABI v6 protocol
- **Frame z-order**: Rendering order in gui/lib.zig matters — must preserve strict layering
- **Lint rules**: No std.fs.* or std.posix.getenv outside utility/ and cli/
<!-- GSD:project-end -->

<!-- GSD:stack-start source:codebase/STACK.md -->
## Technology Stack

## Languages
- Zig 0.15.x (minimum 0.15.0, installed 0.15.2) - All application code, build system, plugin ABI, test harness
- JavaScript (ES2020+) - WASM host bridge, VFS worker, boot loader (`web/`, `src/web/`)
- C - NGSpice bindings via `@cImport` of `sharedspice.h` (`deps/ngspice.zig`)
- C++ - Xyce bindings via C shim `xyce_c_api.cpp` (`deps/xyce.zig`, `deps/Xyce/xyce_c_api.cpp`)
- Zig - `src/plugins/lib.zig` (Reader/Writer/Framework)
- C/C++ - `tools/sdk/schemify_plugin.h` (header-only C99 SDK)
- Rust - `tools/sdk/bindings/rust/schemify-plugin/` (crate with `Plugin` trait + `export_plugin!` macro)
- TinyGo/Go - `tools/sdk/bindings/tinygo/schemify/plugin.go`
- Python - `tools/sdk/bindings/python/schemify/__init__.py` (runs via SchemifyPython embedder)
## Runtime
- Native: Linux/macOS/Windows host OS, linked against system libc
- Web: wasm32-freestanding target, runs in browser via WebAssembly
- Zig Build System (built-in, `build.zig` + `build.zig.zon`)
- Lockfile: `build.zig.zon` contains dependency hashes (acts as lockfile)
- No npm/cargo/pip for the main project (only for plugin SDK bindings)
## Frameworks
- dvui 0.4.0-dev - Immediate-mode GUI toolkit (fetched from GitHub `david-vanderson/dvui`)
- raylib - Native windowing, OpenGL rendering, input handling (pulled transitively via dvui)
- HTML5 Canvas - Web rendering target via dvui web backend
- Zig built-in test framework (`std.testing`)
- Custom test runner: `test/test_runner.zig` (prints pass/fail/skip/leak per test)
- Custom size runner: `test/size_runner.zig` (prints `@sizeOf` for structs)
- Zig Build System - `build.zig` orchestrates everything
- Python 3 `http.server` - Local web dev server (`zig build run_local -Dbackend=web`)
- Shell lint step - Bans `std.fs.*` / `std.posix.getenv` outside `utility/` and `cli/`
## Key Dependencies
- dvui 0.4.0-dev - The entire GUI layer; both native and web rendering depend on it
- raylib (transitive via dvui) - Native window creation, OpenGL context, input
- libngspice - SPICE circuit simulation (optional, linked dynamically via `deps/ngspice.zig`)
- libxyce + Trilinos - Xyce circuit simulation (optional, linked dynamically via `deps/xyce.zig`)
## Module Graph
## Configuration
- `HOME` env var - Used to locate plugin directory (`~/.config/Schemify/`)
- No `.env` files; no secrets required for the application itself
- Build-time options passed via `-D` flags to `zig build`
- `-Dbackend=native|web` - Selects GUI backend (default: `native`)
- `-Doptimize=Debug|ReleaseSafe|ReleaseFast|ReleaseSmall` - Standard Zig optimize
- `-Dtarget=...` - Cross-compilation target (native default)
- `Config.toml` in project root - Parsed by `src/core/Toml.zig`
- Sections: `name`, `[paths]`, `[legacy_paths]`, `[simulation]`, `[plugins]`
- Supports glob patterns in path arrays (e.g., `chn = ["examples/*"]`)
- `build.zig` - Main build script
- `build.zig.zon` - Dependency manifest (dvui)
- `tools/build_dep.zig` - SPICE backend build helper (ngspice + Xyce paths)
- `tools/sdk/build_plugin_helper.zig` - Plugin SDK build helper for external repos
## Platform Requirements
- Zig >= 0.15.0 (tested with 0.15.2)
- Linux: X11 display backend (hardcoded in `build.zig`: `.linux_display_backend = .X11`)
- Optional: ngspice source tree at `deps/ngspice/` (for SPICE simulation)
- Optional: Xyce + Trilinos at `deps/Xyce/` (for Xyce simulation)
- Optional: Python 3 (for `zig build run_local` web dev server)
- Linux: libraylib (linked), X11 libraries
- macOS: raylib framework
- Windows: raylib.dll
- Modern browser with WebAssembly support
- OPFS (Origin Private File System) for persistent VFS storage
- Web Worker support (for VFS persistence worker)
- Static file hosting (no server-side logic needed)
## File Formats
- `.chn` - Schematic files
- `.chn_tb` - Testbench files
- `.chn_prim` - Primitive/symbol files
- `Config.toml` - Project configuration
- Verilog/VHDL - HDL parsing (`src/core/HdlParser.zig`)
- Yosys JSON - Synthesis results (`src/core/YosysJson.zig`)
- SVG - Export via CLI (`src/cli.zig` `--export-svg`)
- SPICE netlist - Generation via CLI (`src/cli.zig` `--netlist`)
- `.so` / `.dylib` / `.dll` - Native plugin shared libraries
- `.wasm` - WebAssembly plugin modules
- `plugins.json` - Web plugin registry
<!-- GSD:stack-end -->

<!-- GSD:conventions-start source:CONVENTIONS.md -->
## Conventions

## Module Structure
- `src/core/lib.zig` -- canonical example of re-export + comptime test pull-in
- `src/utility/lib.zig` -- minimal module root
- `src/commands/lib.zig` -- uses `refAllDecls(@This())` for exhaustive test pull
- `src/plugins/lib.zig` -- ABI protocol re-exports + widget types
- `src/state/lib.zig` -- state re-exports + global singleton
## Naming Patterns
- `PascalCase.zig` for files containing one pub struct: `Schemify.zig`, `AppState.zig`, `Document.zig`, `CommandQueue.zig`, `Logger.zig`
- `lib.zig` and `types.zig` are always lowercase (module infrastructure)
- `helpers.zig` for shared private utility functions within a module (`src/commands/helpers.zig`)
- Exception: `primitives.zig` in `src/core/devices/` (data file, not a struct)
- `PascalCase` for all structs, enums, unions: `Schemify`, `AppState`, `PinDir`, `DeviceKind`
- Abbreviations stay uppercase within PascalCase: `MAL` (MultiArrayList alias), `CHN` (file format)
- `camelCase` for all public and private functions: `readCHN`, `writeFile`, `zoomIn`, `handleImmediate`
- `init` / `deinit` for lifecycle (never `new`/`destroy`/`create`/`free`)
- `fromStr` / `toStr` for enum serialization round-trips
- `snake_case` for all local variables, struct fields, and function parameters
- Abbreviations lowercased in fields: `panel_id`, `widget_id`, `abi_version`
- `SCREAMING_SNAKE_CASE` for global/pub constants: `ABI_VERSION`, `RING_CAP`, `MSG_CAP`, `HEADER_SZ`, `MAX_OUT_BUF`
- `snake_case` for comptime local constants within blocks
## Data-Oriented Design
- `src/state/types.zig`: `CommandFlags = packed struct` (bitfield flags)
- `src/core/types.zig`: `CellRef = packed struct(u32)` (index + tier in 32 bits)
- `src/plugins/types.zig`: `Descriptor = extern struct` (ABI-stable layout)
- `src/utility/types.zig`: `Entry = extern struct` (C-compatible log record)
## Code Style
- Use `zig fmt` (the standard Zig formatter). No custom formatting config.
- 4-space indentation (Zig default).
- Build-time lint step in `build.zig` bans `std.fs.*` and `std.posix.getenv` outside `src/utility/` and `src/cli/`.
- Use `utility.Vfs` for filesystem access and `utility.platform` for environment access.
## Import Organization
- `@import("core")` -- schematic data model
- `@import("state")` -- application state
- `@import("utility")` -- logger, vfs, platform, simd
- `@import("commands")` -- command types and dispatch
- `@import("plugins")` -- plugin runtime and ABI
- `@import("dvui")` -- GUI framework
## Error Handling
- `try` for propagation: `try self.documents.append(a, doc);`
- `catch return` for silent fallback: `alloc.dupe(u8, path) catch return;`
- `catch continue` in loops: `sch.instances.append(sa, copy) catch continue;`
- `catch |err| switch` for specific error handling:
- `errdefer` for cleanup on error path: `errdefer allocator.free(buf);`
- `orelse return` for optional unwrapping: `const fio = state.active() orelse return;`
## Logging
## Comments
## Function Design
## Module Exports
## SIMD and Performance
## Platform Abstraction
## Command System
<!-- GSD:conventions-end -->

<!-- GSD:architecture-start source:ARCHITECTURE.md -->
## Architecture

## Pattern Overview
- **Command-queue pattern**: All schematic mutations flow through a `CommandQueue` drained once per frame in `src/main.zig`. Undoable commands record inverse snapshots in a `History` ring buffer.
- **Immediate-mode rendering**: The GUI is rebuilt every frame via dvui. No persistent widget tree -- layout and draw happen in a single pass with strict z-order.
- **Module-based layering**: `build.zig` defines six named modules (`utility`, `core`, `commands`, `state`, `plugins`, `theme_config`) with explicit import graphs. Circular dependencies between `commands` and `state` are resolved by the two-pass module creation in `build.zig`.
- **Data-oriented design**: Core schematic types use `MultiArrayList` (SoA). Structs are field-ordered by alignment to minimize padding.
- **Comptime-driven dispatch**: Keybind tables, vim command maps, and plugin command whitelists are built at comptime using `StaticStringMap` and sorted arrays with binary search.
## Layers
- Purpose: Platform-agnostic primitives shared by all other layers
- Location: `src/utility/`
- Contains: `Vfs` (virtual filesystem), `Platform` (OS abstraction for HTTP/URLs/env/processes), `Logger` (ring-buffer logger), `Simd` (SIMD text scanning), `UnionFind` (net connectivity)
- Depends on: Nothing (leaf module)
- Used by: Every other module
- Purpose: Schematic data model, file I/O, netlist generation, HDL parsing, device library
- Location: `src/core/`
- Contains: `Schemify` (central data model with MultiArrayList storage for instances/wires/pins/etc.), `Reader`/`Writer` (.chn file format), `Netlist` (SPICE emission), `Devices` (PDK cell library), `HdlParser`, `YosysJson`, `Synthesis`, `SpiceIF` (simulator interface), `Toml` (config parser)
- Depends on: `utility`
- Used by: `state`, `commands`, `plugins`, `gui` (via `state`)
- Purpose: Top-level application state aggregation -- the single source of truth
- Location: `src/state/`
- Contains: `AppState` (god object aggregating documents, selection, viewport, tool state, GUI state, command queue, history, plugin pointer), `Document` (single open schematic), shared types (`Viewport`, `Selection`, `Clipboard`, `Tool`, `GuiState`, `PluginPanel`, etc.)
- Depends on: `utility`, `commands` (for `CommandQueue`, `History`), `core` (for `Schemify`, type aliases)
- Used by: `commands` (handlers receive `*AppState`), `plugins`, `gui`
- Purpose: Every schematic mutation expressed as a typed `Command` union, dispatched to handler groups
- Location: `src/commands/`
- Contains: `Dispatch` (central router), `CommandQueue` (per-frame drain queue), `types` (Command/Immediate/Undoable unions), handler files: `Edit`, `View`, `Selection`, `Clipboard`, `Wire`, `File`, `Hierarchy`, `Netlist`, `Sim`, `Undo`
- Depends on: `state`, `core`, `utility`, `dvui`
- Used by: `main.zig` (drains queue), `gui` (enqueues commands)
- Purpose: ABI v6 plugin runtime, binary wire protocol, plugin installation
- Location: `src/plugins/`
- Contains: `Runtime` (load/tick/unload lifecycle via dlopen), `Reader`/`Writer` (wire-format codec), `Framework` (plugin-side helpers), `types` (Tag enum, InMsg, ParsedWidget, Descriptor), `installer` (URL-based plugin install)
- Depends on: `utility`, `state`, `theme_config`, `commands`
- Used by: `main.zig` (tick), `gui/PluginPanels.zig` (render widgets, dispatch events)
- Purpose: Immediate-mode GUI shell, input handling, canvas rendering
- Location: `src/gui/`
- Contains: `lib.zig` (frame orchestrator), `Renderer.zig` (canvas/viewport), `Actions.zig` (command enqueue + vim dispatch), `Keybinds.zig` (static keybind table), `Theme.zig` (color palette), bars (`ToolBar`, `TabBar`, `CommandBar`), dialogs (`PropsDialog`, `FindDialog`, `KeybindsDialog`), panels (`PluginPanels`, `FileExplorer`, `LibraryBrowser`, `Marketplace`, `ContextMenu`), components (`FloatingWindow`, `HorizontalBar`)
- Depends on: `dvui`, `state`, `commands`, `core`, `plugins`, `utility`, `theme_config`
- Used by: `main.zig` (calls `gui.frame()`)
- Purpose: Headless CLI subcommands (plugin management, SVG export, netlist generation)
- Location: `src/cli.zig`
- Contains: Argument parsing, plugin install/list/remove, SVG export, netlist generation
- Depends on: `state`, `plugins`, `utility`
- Used by: `main.zig` (only on native builds, skipped on WASM)
## Data Flow
- Single mutable `AppState` instance in `main.zig` (stack-allocated)
- `AppState` owns a `GeneralPurposeAllocator` used for all dynamic allocations
- Documents stored in `ArrayListUnmanaged(Document)`, indexed by `active_idx`
- Each `Document` owns a `core.Schemify` which holds all schematic data in MultiArrayLists
- Selection is `DynamicBitSetUnmanaged` parallel to instance/wire arrays
- Plugin runtime accessed via `app.plugin_runtime_ptr: ?*anyopaque` cast to `*Runtime`
## Key Abstractions
- Purpose: Central schematic storage -- instances, wires, pins, lines, rects, arcs, circles, texts, props, conns, nets
- Location: `src/core/Schemify.zig`
- Pattern: Structure-of-Arrays via `std.MultiArrayList` for cache-friendly iteration. Each element type (Instance, Wire, Pin, etc.) has its own MAL. Properties and connections use flat arrays with `prop_start`/`prop_count` index ranges on Instance.
- Purpose: Every user action that modifies state is a typed union
- Location: `src/commands/types.zig`
- Pattern: Two-level discriminated union: `Command = union(enum) { immediate: Immediate, undoable: Undoable }`. Immediate commands never enter history (zoom, toggle, tab switch). Undoable commands record inverses.
- Purpose: Language-agnostic plugin communication
- Location: `src/plugins/types.zig`, `src/plugins/Reader.zig`, `src/plugins/Writer.zig`
- Pattern: Single C-callable entry point `schemify_process(in_ptr, in_len, out_ptr, out_cap) -> usize`. Messages are `[u8 tag][u16 LE payload_sz][payload]`. Tags 0x01-0x12 are host-to-plugin, 0x80-0xAB are plugin-to-host. No vtable, no host imports (except WASM VFS).
- Purpose: Filesystem operations that compile to either `std.fs` (native) or `extern "host"` WASM imports
- Location: `src/utility/Vfs.zig`
- Pattern: Comptime backend selection. All file I/O outside `utility/` and `cli/` must use Vfs (enforced by build-time lint step in `build.zig`).
## Entry Points
- Location: `src/main.zig`
- Triggers: `zig build run` or direct execution
- Responsibilities: Exports `dvui_app` descriptor with `config`, `initFn`, `deinitFn`, `frameFn`. dvui calls `appInit` (creates AppState, loads config, inits logger, loads plugins), then loops calling `appFrame` (drain queue, tick plugins, render GUI). CLI dispatch happens in `getConfig` before GUI starts -- if a CLI command matches, `std.process.exit(0)` prevents GUI launch.
- Location: Same `src/main.zig`, compiled with `-Dbackend=web`
- Triggers: Browser loads `schemify.wasm` via `boot.js`
- Responsibilities: Same dvui_app pattern but dvui uses its web backend. CLI is compiled out (`cli = struct {}`). WASM host JS files (`web/boot.js`, `web/vfs.js`, `src/web/schemify_host.js`) provide VFS and platform imports.
- Location: `src/cli.zig`
- Triggers: `schemify --plugin-install <url>`, `--plugin-list`, `--plugin-remove <name>`, `--export-svg <file>`, `--netlist [--xyce] <file>`, `--help`
- Responsibilities: Parse argv via `StaticStringMap`, dispatch to handler, print results, exit. No GUI started.
- Location: `build.zig`
- Triggers: `zig build [run|test|-Dbackend=web|run_local|get_size]`
- Responsibilities: Two-pass module graph creation (create all modules, then wire imports to resolve circular deps). Backend selection (native=raylib, web=WASM). Lint step banning `std.fs`/`std.posix.getenv` outside allowed paths. Test suite registration. Web asset installation. Size reporting.
## Error Handling
- Each command handler file exports a specific `Error` type (e.g., `Edit.Error = error{OutOfMemory}`, `file.Error = error{OutOfMemory, WriteFailed}`)
- `Dispatch.zig` merges all handler errors into `DispatchError` using error set union (`||`)
- `main.zig:processQueuedCommands()` catches dispatch errors, sets status message, and logs -- never crashes the frame loop
- Plugin runtime catches `OutOfMemory` and `PluginOutputTooLarge` from `callPluginProcess`, silently skips failed plugins
- Vfs operations use `IoError` named error set (`FileNotFound`, `ReadError`, `WriteError`, etc.)
- Status bar is the primary error surface for users (`app.setStatusErr("...")`)
## Cross-Cutting Concerns
<!-- GSD:architecture-end -->

<!-- GSD:workflow-start source:GSD defaults -->
## GSD Workflow Enforcement

Before using Edit, Write, or other file-changing tools, start work through a GSD command so planning artifacts and execution context stay in sync.

Use these entry points:
- `/gsd:quick` for small fixes, doc updates, and ad-hoc tasks
- `/gsd:debug` for investigation and bug fixing
- `/gsd:execute-phase` for planned phase work

Do not make direct repo edits outside a GSD workflow unless the user explicitly asks to bypass it.
<!-- GSD:workflow-end -->

<!-- GSD:profile-start -->
## Developer Profile

> Profile not yet configured. Run `/gsd:profile-user` to generate your developer profile.
> This section is managed by `generate-claude-profile` -- do not edit manually.
<!-- GSD:profile-end -->
