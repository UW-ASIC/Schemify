# Codebase Structure

**Analysis Date:** 2026-04-04

## Directory Layout

```
Schemify/
├── src/                    # All Zig source code
│   ├── main.zig            # Entry point (dvui app descriptor, frame loop)
│   ├── cli.zig             # CLI subcommands (not a module folder)
│   ├── commands/           # Command dispatch and handler modules
│   ├── core/               # Schematic data model, file I/O, netlist, HDL
│   │   └── devices/        # Built-in primitive device tables
│   ├── gui/                # Immediate-mode GUI shell
│   │   ├── Bars/           # ToolBar, TabBar, CommandBar
│   │   ├── Components/     # FloatingWindow, HorizontalBar
│   │   └── Dialogs/        # PropsDialog, FindDialog, KeybindsDialog
│   ├── plugins/            # Plugin runtime, ABI v6 protocol, installer
│   ├── state/              # AppState, Document, shared GUI/tool types
│   ├── utility/            # Logger, Vfs, Platform, Simd, UnionFind
│   └── web/                # JS host imports for WASM builds
├── web/                    # Web shell (index.html, boot.js, vfs.js)
├── build.zig               # Build configuration and module graph
├── build.zig.zon           # Zig package manifest (dvui dependency)
├── deps/                   # SPICE simulator bindings
│   ├── lib.zig             # Spice module root
│   ├── ngspice.zig         # ngspice FFI
│   └── xyce.zig            # Xyce FFI
├── tools/                  # Build helpers and plugin SDKs
│   ├── build_dep.zig       # SpiceConfig for build.zig
│   ├── scripts/            # Development scripts
│   └── sdk/                # Plugin SDK (C header, Rust/Go/Python bindings)
├── test/                   # Test infrastructure
│   ├── core/               # Core module integration tests
│   ├── test_runner.zig     # Custom test runner
│   └── size_runner.zig     # Struct size reporting runner
├── examples/               # Example .chn schematic files
├── plugins/                # External plugin source code (not compiled by main build)
├── Config.toml             # Default project configuration
└── CLAUDE.md               # Developer guide
```

## Directory Purposes

**`src/commands/`:**
- Purpose: Every schematic mutation expressed as a typed Command, with dispatch routing and handler implementations
- Contains: Command types, central dispatcher, per-domain handler files, undo/redo history
- Key files:
  - `src/commands/lib.zig` -- Module root, re-exports public API
  - `src/commands/types.zig` -- `Command`, `Immediate`, `Undoable` unions and payload structs (`PlaceDevice`, `MoveDevice`, `AddWire`, etc.)
  - `src/commands/Dispatch.zig` -- Central router: `dispatch(cmd, state)` switches on command tag, delegates to handler modules
  - `src/commands/CommandQueue.zig` -- Fixed-capacity queue drained once per frame (`max_capacity = 64`)
  - `src/commands/Edit.zig` -- Place, delete, move, nudge, rotate, flip, duplicate handlers
  - `src/commands/View.zig` -- Zoom, fullscreen, toggle, snap handlers
  - `src/commands/Selection.zig` -- Select all/none, highlight nets, find/select
  - `src/commands/Clipboard.zig` -- Copy, cut, paste
  - `src/commands/Wire.zig` -- Wire placement, routing toggles
  - `src/commands/File.zig` -- Tab management, save/load, reload
  - `src/commands/Hierarchy.zig` -- Descend/ascend, edit-in-new-tab
  - `src/commands/Netlist.zig` -- Netlist generation triggers
  - `src/commands/Sim.zig` -- Simulation launch
  - `src/commands/Undo.zig` -- History ring buffer, inverse command types, undo handler
  - `src/commands/helpers.zig` -- Shared selection query helpers (`selInst`, `selWire`)

**`src/core/`:**
- Purpose: Schematic data model, serialization, netlist emission, HDL parsing, device library, synthesis
- Contains: Core data structures in SoA layout, file format reader/writer, SPICE backends
- Key files:
  - `src/core/lib.zig` -- Module root with re-exports and tests
  - `src/core/types.zig` -- All shared types: `Line`, `Rect`, `Circle`, `Arc`, `Wire`, `Text`, `Pin`, `Instance`, `Prop`, `Conn`, `Net`, `NetConn`, `NetMap`, `SymData`, `DeviceKind`, `ComponentDesc`, etc.
  - `src/core/Schemify.zig` -- Central data model struct with MultiArrayList storage; `readFile()`, `writeFile()`, `emitSpice()`, `addComponent()`, `removeSelected()`, HDL sync
  - `src/core/Devices.zig` -- Device cell library, PDK management, `DeviceKind` enum, primitive lookup tables (940 LOC)
  - `src/core/devices/primitives.zig` -- Built-in primitive device definitions (731 LOC)
  - `src/core/Reader.zig` -- `.chn` file format parser (1259 LOC)
  - `src/core/Writer.zig` -- `.chn` file format writer (800 LOC)
  - `src/core/Netlist.zig` -- SPICE netlist generation, hierarchical/flat/top-only modes (1651 LOC, largest file)
  - `src/core/SpiceIF.zig` -- Simulator backend abstraction, ngspice/Xyce interface (1391 LOC)
  - `src/core/HdlParser.zig` -- Verilog/VHDL/XSPICE parser (1282 LOC)
  - `src/core/YosysJson.zig` -- Yosys JSON netlist parser (744 LOC)
  - `src/core/Synthesis.zig` -- Yosys synthesis invocation (437 LOC)
  - `src/core/Toml.zig` -- Config.toml parser, `ProjectConfig` (346 LOC)

**`src/state/`:**
- Purpose: Top-level application state, document model, shared types for GUI and tool state
- Contains: AppState god object, Document, all shared enums and small structs
- Key files:
  - `src/state/lib.zig` -- Module root, re-exports, tests
  - `src/state/types.zig` -- `Viewport`, `Selection`, `Clipboard`, `ClosedTabs`, `Tool`, `CommandFlags`, `ToolState`, `GuiViewMode`, `PluginPanel`, `PluginPanelLayout`, `CtxMenu`, `GuiState`, `MarketplaceEntry`, `MarketplaceState`
  - `src/state/AppState.zig` -- God object: owns GPA allocator, document list, selection, viewport, tool state, GUI state, command queue, history, clipboard, logger, plugin pointer. Lifecycle: `init()`, `deinit()`, `loadConfig()`, `initLogger()`. Document ops: `active()`, `newFile()`, `openPath()`, `saveActiveTo()`. Plugin helpers: `registerPluginPanelEx()`, `registerPluginCommand()`, `clearPluginCommands()`
  - `src/state/Document.zig` -- Single open schematic: owns `core.Schemify`, file origin, dirty flag. Methods: `open()`, `deinit()`, `createNetlist()`, `runSpiceSim()`, `placeSymbol()`, `deleteInstanceAt()`, `moveInstanceBy()`, `addWireSeg()`, `deleteWireAt()`, `saveAsChn()`

**`src/gui/`:**
- Purpose: Immediate-mode GUI rendering, input handling, canvas interaction
- Contains: Frame orchestrator, renderer, action dispatch, keybinds, theme, toolbar/tabbar/commandbar, dialogs, browser panels
- Key files:
  - `src/gui/lib.zig` -- Frame orchestrator: `frame(app)` renders in strict z-order. Input handling: keybind dispatch, command mode, canvas events (349 LOC)
  - `src/gui/Renderer.zig` -- Canvas rendering: viewport transform, grid, wires, instances, pins, subcircuit symbol cache, selection highlight, interaction events (1152 LOC)
  - `src/gui/Actions.zig` -- `enqueue()` (push command + status msg), `runGuiCommand()` (direct GUI mutations), `runVimCommand()` (colon-command parser with `StaticStringMap`)
  - `src/gui/Keybinds.zig` -- Static keybind table sorted at comptime, O(log n) binary search `lookup()`
  - `src/gui/Theme.zig` -- Color palette struct + JSON theme override support
  - `src/gui/PluginPanels.zig` -- Renders `ParsedWidget` lists from plugin runtime, dispatches UI events back
  - `src/gui/Bars/ToolBar.zig` -- Menu bar (File, Edit, View, Draw, Sim, Plugins menus)
  - `src/gui/Bars/TabBar.zig` -- Document tabs + schematic/symbol view toggle
  - `src/gui/Bars/CommandBar.zig` -- Status line + vim-style `:command` input
  - `src/gui/Dialogs/PropsDialog.zig` -- Instance property editor dialog
  - `src/gui/Dialogs/FindDialog.zig` -- Find/select dialog
  - `src/gui/Dialogs/KeybindsDialog.zig` -- Keybind reference dialog
  - `src/gui/FileExplorer.zig` -- File browser dialog (381 LOC)
  - `src/gui/LibraryBrowser.zig` -- Component library browser
  - `src/gui/Marketplace.zig` -- Plugin marketplace UI
  - `src/gui/ContextMenu.zig` -- Right-click context menus
  - `src/gui/Components/FloatingWindow.zig` -- Reusable floating window widget
  - `src/gui/Components/HorizontalBar.zig` -- Reusable horizontal bar widget

**`src/plugins/`:**
- Purpose: Plugin ABI v6 protocol, native plugin runtime, plugin installation
- Contains: Wire protocol types, binary reader/writer, runtime lifecycle, installer
- Key files:
  - `src/plugins/lib.zig` -- Module root, re-exports Runtime, Reader, Writer, Framework, types
  - `src/plugins/types.zig` -- ABI constants (`ABI_VERSION=6`, `HEADER_SZ=3`), `Tag` enum (host-to-plugin 0x01-0x12, plugin-to-host 0x80-0xAB), `InMsg` tagged union, `Descriptor` extern struct, `ProcessFn` type, `ParsedWidget`, `WidgetTag`
  - `src/plugins/runtime.zig` -- `Runtime` struct: `scanAndLoad()` (dlopen from `~/.config/Schemify/`), `tick()` (compose input batch, call process, parse output), `callProcessDrawPanel()`, widget parsing, command whitelist (681 LOC)
  - `src/plugins/Reader.zig` -- Wire-format reader: iterates `[tag][u16 sz][payload]` frames, returns `InMsg`
  - `src/plugins/Writer.zig` -- Wire-format writer: `registerPanel()`, `setStatus()`, `label()`, `button()`, `slider()`, `checkbox()`, etc.
  - `src/plugins/Framework.zig` -- Plugin-side convenience: tick loop, panel registration helpers
  - `src/plugins/installer.zig` -- URL-based plugin installer (GitHub release resolution, download, place in config dir)

**`src/utility/`:**
- Purpose: Shared platform-agnostic primitives used by all layers
- Contains: Filesystem abstraction, OS platform abstraction, logging, SIMD text ops, union-find
- Key files:
  - `src/utility/lib.zig` -- Module root, re-exports
  - `src/utility/types.zig` -- `Level` enum, `Entry` log record, `DirList`, error sets (`IoError`, `UrlError`, `HttpError`, `EnvError`, `ProcessError`)
  - `src/utility/Vfs.zig` -- `readAlloc()`, `writeAll()`, `exists()`, `makePath()`, `isDir()`, `listDir()`. Native: `std.fs` wrappers. WASM: `extern "host"` imports
  - `src/utility/Platform.zig` -- `openUrl()`, `httpGetSync()`, `AsyncGet` (WASM polling), `getEnvVar()`, `spawnProcess()`. Native: std library. WASM: host imports
  - `src/utility/Logger.zig` -- Ring-buffer logger with `Level` gating, `Entry` records
  - `src/utility/Simd.zig` -- SIMD-accelerated `findByte()`, `LineIterator`
  - `src/utility/UnionFind.zig` -- Union-find data structure for net connectivity analysis

**`src/web/`:**
- Purpose: JavaScript host-side imports for WASM builds
- Contains: Single JS file providing VFS and platform host functions
- Key files:
  - `src/web/schemify_host.js` -- Implements `host.vfs_*` and `host.platform_*` extern imports for the WASM module

**`web/`:**
- Purpose: Web shell for WASM deployment
- Contains: HTML entry point, boot loader, VFS worker
- Key files:
  - `web/index.html` -- HTML shell page
  - `web/boot.js` -- WASM module loader
  - `web/vfs.js` -- Client-side VFS bridge (IndexedDB/OPFS)
  - `web/vfs-worker.js` -- Service worker for VFS persistence

## Key File Locations

**Entry Points:**
- `src/main.zig`: Application entry, dvui app descriptor, frame loop
- `src/cli.zig`: CLI dispatch (headless mode)
- `build.zig`: Build system, module graph, backend selection

**Configuration:**
- `build.zig`: Module definitions, dependency wiring, build options
- `build.zig.zon`: Zig package dependencies (dvui)
- `Config.toml`: Default project configuration
- `tools/build_dep.zig`: SPICE simulator config for build.zig

**Core Logic:**
- `src/core/Schemify.zig`: Central data model (1169 LOC)
- `src/core/Netlist.zig`: SPICE netlist generation (1651 LOC)
- `src/commands/Dispatch.zig`: Command routing (134 LOC)
- `src/plugins/runtime.zig`: Plugin lifecycle (681 LOC)
- `src/gui/lib.zig`: GUI frame orchestrator (349 LOC)
- `src/gui/Renderer.zig`: Canvas rendering (1152 LOC)

**Testing:**
- `test/core/test_core.zig`: Core module integration tests
- `test/test_runner.zig`: Custom test runner
- `test/size_runner.zig`: Struct size reporting
- Tests also live inline in `lib.zig` of each module

## Naming Conventions

**Files:**
- `PascalCase.zig` for files containing one pub struct (e.g., `Schemify.zig`, `AppState.zig`, `Renderer.zig`, `CommandQueue.zig`)
- `lowercase.zig` for files without a primary pub struct (e.g., `lib.zig`, `types.zig`, `helpers.zig`, `runtime.zig`, `installer.zig`)

**Directories:**
- `lowercase/` for module folders: `commands/`, `core/`, `gui/`, `plugins/`, `state/`, `utility/`
- `PascalCase/` for GUI sub-groupings: `Bars/`, `Components/`, `Dialogs/`

**Module Structure:**
- Every module is a folder (no single-file modules)
- `lib.zig` is the module root, re-exports from `types.zig`
- `types.zig` holds all shared/simple data types
- One pub struct per file (except `types.zig`)

## Where to Add New Code

**New Command:**
1. Add payload struct to `src/commands/types.zig` if needed
2. Add variant to `Immediate` or `Undoable` union in `src/commands/types.zig`
3. Add switch arm in `src/commands/Dispatch.zig` routing to the appropriate handler
4. Implement handler in the relevant file (e.g., `src/commands/Edit.zig` for edit ops)
5. If undoable, add inverse type to `src/commands/Undo.zig:CommandInverse`
6. Add keybind in `src/gui/Keybinds.zig` (maintain sort order)
7. Add vim command in `src/gui/Actions.zig` `vim_noarg_entries` or `vim_arg_handlers`

**New GUI Panel/Dialog:**
1. Create `src/gui/Dialogs/MyDialog.zig` with an `open` flag and `draw(app)` function
2. Call `draw(app)` from `src/gui/lib.zig:frame()` at the appropriate z-order position
3. Add open trigger (menu item in `src/gui/Bars/ToolBar.zig`, keybind, or command)
4. If dialog needs state, add fields to `src/state/types.zig:GuiState`

**New Core Data Type:**
1. Define struct in `src/core/types.zig` (order fields by alignment)
2. Re-export from `src/core/lib.zig` if needed externally
3. Add MultiArrayList storage in `src/core/Schemify.zig` if it's a schematic element
4. Update `src/core/Reader.zig` and `src/core/Writer.zig` for .chn serialization

**New Utility:**
1. Create `src/utility/MyUtil.zig` with one pub struct
2. Re-export from `src/utility/lib.zig`
3. Add tests in the file and reference via `comptime { _ = @import("MyUtil.zig"); }` in `lib.zig`

**New Plugin ABI Message:**
1. Add tag value to `src/plugins/types.zig:Tag` enum
2. Add payload to `InMsg` union if host-to-plugin
3. Add parse case in `src/plugins/types.zig:parsePayload()` if host-to-plugin
4. Add write method to `src/plugins/Writer.zig` if plugin-to-host
5. Add handler in `src/plugins/runtime.zig:handleOutMsg()` if plugin-to-host
6. Update `host_to_plugin_tag` comptime table if host-to-plugin

**New Menu Item:**
1. Edit `src/gui/Bars/ToolBar.zig` -- add entry to the relevant menu table
2. Reference an existing action or create a new one

**New Test:**
1. Module tests: add `test` blocks in the relevant `lib.zig` or struct file
2. Integration tests: add to `test/core/test_core.zig` or create a new `test/<module>/` directory
3. Register in `build.zig` `test_defs` array if a new top-level test suite

## Special Directories

**`plugins/` (project root):**
- Purpose: External plugin source trees (Circuit Visionary, GmID Visualizer, Optimizer, PDKLoader, SchemifyPython, examples)
- Generated: No (source code)
- Committed: Yes
- Note: These are separate build targets, not compiled by the main `build.zig`. Each has its own build system.

**`deps/`:**
- Purpose: SPICE simulator FFI bindings (ngspice, Xyce)
- Generated: No
- Committed: Yes
- Note: Only linked on native builds when enabled. WASM builds skip these entirely.

**`tools/sdk/`:**
- Purpose: Plugin SDK for external developers (C header, Rust/Go/Python bindings, build helpers)
- Generated: No
- Committed: Yes
- Note: `build_plugin_helper.zig` is re-exported from `build.zig` so plugin repos can `@import("schemify_sdk")`

**`zig-out/`:**
- Purpose: Build output directory
- Generated: Yes
- Committed: No

**`test/`:**
- Purpose: Test infrastructure and integration tests
- Generated: No
- Committed: Yes
- Note: Custom `test_runner.zig` and `size_runner.zig` for specialized test execution

**`.planning/`:**
- Purpose: GSD planning documents
- Generated: Yes (by tooling)
- Committed: Varies

---

*Structure analysis: 2026-04-04*
