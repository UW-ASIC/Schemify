# src Architecture

This document explains the top-level `src/` module layout and how the root modules wire the rest of the system.

## Top-level map

- `main.zig`: app entrypoint and lifecycle glue (CLI gate, app init/deinit, frame loop).
- `cli.zig`: headless command handlers (`--plugin-*`, `--export-svg`, `--netlist`).
- `state.zig`: core shared data model (`AppState`, `Document`, GUI/plugin state buckets).
- `toml.zig`: `Config.toml` parser and path glob expansion for project config.
- `PluginIF.zig`: host<->plugin ABI types, wire protocol reader/writer, plugin framework.
- `commands/`: command model + dispatchers for mutations and UI actions.
- `gui/`: frame composition, key handling, dialogs, renderer, plugin panel drawing.
- `core/`: schematic/domain logic (read/write format, devices, netlisting, simulation glue).
- `plugins/`: runtime loader/bridge and installer.
- `utility/`: shared services (VFS, logger, platform helpers, data structures).
- `web/`: browser/WASM host-side integration assets.

## Runtime wiring (native app)

1. Process starts in `main.zig` via `dvui_app`.
2. `getConfig()` reads CLI/project-dir context:
   - sets `project_dir` from `argv[1]` fallback `.`
   - calls `cli.dispatch()`; if a CLI command is handled, process exits before GUI starts
3. `appInit()` builds shared state:
   - `AppState.init(project_dir)`
   - `AppState.loadConfig()` -> `toml.ProjectConfig.parseFromPath(...)`
   - logger init
   - plugin runtime init + startup load
4. `appFrame()` loop order:
   - drain `app.queue` and dispatch through `commands.dispatch(...)`
   - refresh plugins if requested
   - tick plugins
   - render one GUI frame via `gui.frame(&app)`
5. `appDeinit()` tears down GUI side state, plugins, then app state.

## Command path

- UI, keybinds, and plugins enqueue `commands.Command` into `AppState.queue`.
- `main.zig` drains queue each frame.
- `commands/Dispatch.zig` routes to focused handler modules (`View`, `Edit`, `File`, `Hierarchy`, etc.).
- Handlers mutate `state.AppState`/`state.Document` and may call into `core/` for heavy logic.

## State and config boundaries

- `state.zig` is the in-memory contract used across GUI, commands, and plugin runtime.
- `Document` wraps `core.Schemify` plus origin/dirty metadata.
- `toml.zig` owns configuration parsing and glob resolution; `state.AppState.loadConfig()` consumes it and stores a `ProjectConfig` snapshot.

## Plugin architecture

- `PluginIF.zig` defines ABI v6 message schema and helper types used by both host and plugins.
- `plugins/runtime.zig` loads plugin binaries, ABI-checks descriptors, and exchanges protocol messages.
- Plugin-originated commands/UI intents are converted into host-side state changes and queued commands.
- Root app stores a type-erased runtime pointer (`AppState.plugin_runtime_ptr`) for GUI/plugin panel integration.

## WASM split

- `main.zig` and `plugins/runtime.zig` guard native-only behavior with `is_wasm` checks.
- On WASM targets, Zig runtime plugin loading is a no-op; browser host runtime handles WASM plugins.
