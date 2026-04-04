# Architecture

**Analysis Date:** 2026-04-04

## Pattern Overview

**Overall:** Layered architecture with command-queue dispatch, immediate-mode GUI, and a binary ABI plugin system. Dual-backend (native raylib / WASM web canvas) sharing identical Zig GUI code via dvui abstraction.

**Key Characteristics:**
- **Command-queue pattern**: All schematic mutations flow through a `CommandQueue` drained once per frame in `src/main.zig`. Undoable commands record inverse snapshots in a `History` ring buffer.
- **Immediate-mode rendering**: The GUI is rebuilt every frame via dvui. No persistent widget tree -- layout and draw happen in a single pass with strict z-order.
- **Module-based layering**: `build.zig` defines six named modules (`utility`, `core`, `commands`, `state`, `plugins`, `theme_config`) with explicit import graphs. Circular dependencies between `commands` and `state` are resolved by the two-pass module creation in `build.zig`.
- **Data-oriented design**: Core schematic types use `MultiArrayList` (SoA). Structs are field-ordered by alignment to minimize padding.
- **Comptime-driven dispatch**: Keybind tables, vim command maps, and plugin command whitelists are built at comptime using `StaticStringMap` and sorted arrays with binary search.

## Layers

**Utility Layer (`utility`):**
- Purpose: Platform-agnostic primitives shared by all other layers
- Location: `src/utility/`
- Contains: `Vfs` (virtual filesystem), `Platform` (OS abstraction for HTTP/URLs/env/processes), `Logger` (ring-buffer logger), `Simd` (SIMD text scanning), `UnionFind` (net connectivity)
- Depends on: Nothing (leaf module)
- Used by: Every other module

**Core Layer (`core`):**
- Purpose: Schematic data model, file I/O, netlist generation, HDL parsing, device library
- Location: `src/core/`
- Contains: `Schemify` (central data model with MultiArrayList storage for instances/wires/pins/etc.), `Reader`/`Writer` (.chn file format), `Netlist` (SPICE emission), `Devices` (PDK cell library), `HdlParser`, `YosysJson`, `Synthesis`, `SpiceIF` (simulator interface), `Toml` (config parser)
- Depends on: `utility`
- Used by: `state`, `commands`, `plugins`, `gui` (via `state`)

**State Layer (`state`):**
- Purpose: Top-level application state aggregation -- the single source of truth
- Location: `src/state/`
- Contains: `AppState` (god object aggregating documents, selection, viewport, tool state, GUI state, command queue, history, plugin pointer), `Document` (single open schematic), shared types (`Viewport`, `Selection`, `Clipboard`, `Tool`, `GuiState`, `PluginPanel`, etc.)
- Depends on: `utility`, `commands` (for `CommandQueue`, `History`), `core` (for `Schemify`, type aliases)
- Used by: `commands` (handlers receive `*AppState`), `plugins`, `gui`

**Commands Layer (`commands`):**
- Purpose: Every schematic mutation expressed as a typed `Command` union, dispatched to handler groups
- Location: `src/commands/`
- Contains: `Dispatch` (central router), `CommandQueue` (per-frame drain queue), `types` (Command/Immediate/Undoable unions), handler files: `Edit`, `View`, `Selection`, `Clipboard`, `Wire`, `File`, `Hierarchy`, `Netlist`, `Sim`, `Undo`
- Depends on: `state`, `core`, `utility`, `dvui`
- Used by: `main.zig` (drains queue), `gui` (enqueues commands)

**Plugins Layer (`plugins`):**
- Purpose: ABI v6 plugin runtime, binary wire protocol, plugin installation
- Location: `src/plugins/`
- Contains: `Runtime` (load/tick/unload lifecycle via dlopen), `Reader`/`Writer` (wire-format codec), `Framework` (plugin-side helpers), `types` (Tag enum, InMsg, ParsedWidget, Descriptor), `installer` (URL-based plugin install)
- Depends on: `utility`, `state`, `theme_config`, `commands`
- Used by: `main.zig` (tick), `gui/PluginPanels.zig` (render widgets, dispatch events)

**GUI Layer (not a named module -- compiled into exe):**
- Purpose: Immediate-mode GUI shell, input handling, canvas rendering
- Location: `src/gui/`
- Contains: `lib.zig` (frame orchestrator), `Renderer.zig` (canvas/viewport), `Actions.zig` (command enqueue + vim dispatch), `Keybinds.zig` (static keybind table), `Theme.zig` (color palette), bars (`ToolBar`, `TabBar`, `CommandBar`), dialogs (`PropsDialog`, `FindDialog`, `KeybindsDialog`), panels (`PluginPanels`, `FileExplorer`, `LibraryBrowser`, `Marketplace`, `ContextMenu`), components (`FloatingWindow`, `HorizontalBar`)
- Depends on: `dvui`, `state`, `commands`, `core`, `plugins`, `utility`, `theme_config`
- Used by: `main.zig` (calls `gui.frame()`)

**CLI Layer (not a named module -- conditional import):**
- Purpose: Headless CLI subcommands (plugin management, SVG export, netlist generation)
- Location: `src/cli.zig`
- Contains: Argument parsing, plugin install/list/remove, SVG export, netlist generation
- Depends on: `state`, `plugins`, `utility`
- Used by: `main.zig` (only on native builds, skipped on WASM)

## Data Flow

**Frame Loop (main.zig `appFrame`):**

1. `processQueuedCommands()` -- drain `app.queue`, call `command.dispatch(cmd, &app)` for each
2. `tickPlugins()` -- call `plugins.tick(&app, dt)` which sends tick + pending events to each loaded plugin, parses output messages
3. `gui.frame(&app)` -- handle input, layout, render all GUI elements

**Command Dispatch Flow:**

1. GUI input (keybind, menu click, vim command, canvas click) calls `actions.enqueue(app, cmd, msg)` which pushes onto `app.queue`
2. `main.zig:processQueuedCommands()` pops commands and calls `command.dispatch(cmd, &app)`
3. `Dispatch.zig` routes: `Command.immediate` -> `dispatchImmediate()` (switch on tag -> handler module), `Command.undoable` -> `dispatchUndoable()` (switch on tag -> `Edit`/`File`/`Sim`)
4. Handlers mutate `AppState` fields (document data, selection, viewport, flags)
5. Undoable handlers push `CommandInverse` onto `app.history` before mutating

**Plugin Communication Flow:**

1. `Runtime.tick()` builds input batch: `[tick header + dt][pending file responses][pending GUI events]`
2. Calls `plugin.process(in_ptr, in_len, out_ptr, out_cap)` via C ABI
3. If return == `maxInt(usize)`, doubles output buffer and retries (up to 64KB)
4. Parses output messages: `register_panel`, `set_status`, `log`, `push_command`, `file_read_request`, `file_write`, `register_keybind`, `register_command`, `set_config`, `request_refresh`
5. For visible panels: sends `draw_panel` message, parses `ui_*` widget tags into `ParsedWidget` list
6. `gui/PluginPanels.zig` reads `ParsedWidget` lists and renders via dvui, dispatching click/slider/checkbox events back to `Runtime.pending_events`

**State Management:**
- Single mutable `AppState` instance in `main.zig` (stack-allocated)
- `AppState` owns a `GeneralPurposeAllocator` used for all dynamic allocations
- Documents stored in `ArrayListUnmanaged(Document)`, indexed by `active_idx`
- Each `Document` owns a `core.Schemify` which holds all schematic data in MultiArrayLists
- Selection is `DynamicBitSetUnmanaged` parallel to instance/wire arrays
- Plugin runtime accessed via `app.plugin_runtime_ptr: ?*anyopaque` cast to `*Runtime`

## Key Abstractions

**Schemify (Core Data Model):**
- Purpose: Central schematic storage -- instances, wires, pins, lines, rects, arcs, circles, texts, props, conns, nets
- Location: `src/core/Schemify.zig`
- Pattern: Structure-of-Arrays via `std.MultiArrayList` for cache-friendly iteration. Each element type (Instance, Wire, Pin, etc.) has its own MAL. Properties and connections use flat arrays with `prop_start`/`prop_count` index ranges on Instance.

**Command (Mutation Protocol):**
- Purpose: Every user action that modifies state is a typed union
- Location: `src/commands/types.zig`
- Pattern: Two-level discriminated union: `Command = union(enum) { immediate: Immediate, undoable: Undoable }`. Immediate commands never enter history (zoom, toggle, tab switch). Undoable commands record inverses.

**Plugin ABI v6 (Binary Wire Protocol):**
- Purpose: Language-agnostic plugin communication
- Location: `src/plugins/types.zig`, `src/plugins/Reader.zig`, `src/plugins/Writer.zig`
- Pattern: Single C-callable entry point `schemify_process(in_ptr, in_len, out_ptr, out_cap) -> usize`. Messages are `[u8 tag][u16 LE payload_sz][payload]`. Tags 0x01-0x12 are host-to-plugin, 0x80-0xAB are plugin-to-host. No vtable, no host imports (except WASM VFS).

**Vfs (Platform Abstraction):**
- Purpose: Filesystem operations that compile to either `std.fs` (native) or `extern "host"` WASM imports
- Location: `src/utility/Vfs.zig`
- Pattern: Comptime backend selection. All file I/O outside `utility/` and `cli/` must use Vfs (enforced by build-time lint step in `build.zig`).

## Entry Points

**Native GUI (`src/main.zig`):**
- Location: `src/main.zig`
- Triggers: `zig build run` or direct execution
- Responsibilities: Exports `dvui_app` descriptor with `config`, `initFn`, `deinitFn`, `frameFn`. dvui calls `appInit` (creates AppState, loads config, inits logger, loads plugins), then loops calling `appFrame` (drain queue, tick plugins, render GUI). CLI dispatch happens in `getConfig` before GUI starts -- if a CLI command matches, `std.process.exit(0)` prevents GUI launch.

**WASM Entry (`src/main.zig` compiled to wasm32):**
- Location: Same `src/main.zig`, compiled with `-Dbackend=web`
- Triggers: Browser loads `schemify.wasm` via `boot.js`
- Responsibilities: Same dvui_app pattern but dvui uses its web backend. CLI is compiled out (`cli = struct {}`). WASM host JS files (`web/boot.js`, `web/vfs.js`, `src/web/schemify_host.js`) provide VFS and platform imports.

**CLI (`src/cli.zig`):**
- Location: `src/cli.zig`
- Triggers: `schemify --plugin-install <url>`, `--plugin-list`, `--plugin-remove <name>`, `--export-svg <file>`, `--netlist [--xyce] <file>`, `--help`
- Responsibilities: Parse argv via `StaticStringMap`, dispatch to handler, print results, exit. No GUI started.

**Build System (`build.zig`):**
- Location: `build.zig`
- Triggers: `zig build [run|test|-Dbackend=web|run_local|get_size]`
- Responsibilities: Two-pass module graph creation (create all modules, then wire imports to resolve circular deps). Backend selection (native=raylib, web=WASM). Lint step banning `std.fs`/`std.posix.getenv` outside allowed paths. Test suite registration. Web asset installation. Size reporting.

## Error Handling

**Strategy:** Named error sets per handler module, merged at dispatch level. No `anyerror`.

**Patterns:**
- Each command handler file exports a specific `Error` type (e.g., `Edit.Error = error{OutOfMemory}`, `file.Error = error{OutOfMemory, WriteFailed}`)
- `Dispatch.zig` merges all handler errors into `DispatchError` using error set union (`||`)
- `main.zig:processQueuedCommands()` catches dispatch errors, sets status message, and logs -- never crashes the frame loop
- Plugin runtime catches `OutOfMemory` and `PluginOutputTooLarge` from `callPluginProcess`, silently skips failed plugins
- Vfs operations use `IoError` named error set (`FileNotFound`, `ReadError`, `WriteError`, etc.)
- Status bar is the primary error surface for users (`app.setStatusErr("...")`)

## Cross-Cutting Concerns

**Logging:** Ring-buffer `Logger` in `src/utility/Logger.zig`. Fixed-capacity entries (128-byte message, 32-byte source tag). Gated by `Level` enum. Used as `app.log.info("TAG", fmt, args)` / `.err()` / `.warn()`. Not file-backed -- entries visible via GUI log viewer or stderr.

**Validation:** Minimal explicit validation. Commands guard with `state.active() orelse return` for no-document case. Plugin ABI version checked on load (`desc.abi_version != ABI_VERSION` -> reject). Plugin commands filtered through `isCommandAllowed()` whitelist.

**Authentication:** Not applicable -- local desktop application. Plugin installation trusts URLs directly.

**Platform Abstraction:** `Vfs` for filesystem, `Platform` for HTTP/URLs/env/processes. Comptime `is_wasm` switches backend. Build-time lint enforces no raw `std.fs`/`std.posix` outside `utility/` and `cli/`.

**Build-Time Lint:** `build.zig` runs a shell command that `grep`s for banned API calls (`std.fs.open`, `std.fs.create`, `std.posix.getenv`, etc.) in all `.zig` files outside `src/utility/` and `src/cli/`. The executable step depends on this lint step, so builds fail on violations.

---

*Architecture analysis: 2026-04-04*
