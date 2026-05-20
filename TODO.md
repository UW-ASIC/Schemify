# SchemifyRS — Implementation Roadmap

See `CONTEXT-MAP.md` for architecture and `docs/adr/` for design decisions.

### 7. Simulation (`crates/sim/`)

SPICE simulation via PySpice. See `../PySpice/` for the backend.

**Work with what exists:** `SimResult`, `Waveform`, `Measurement`, `SpiceBackend` types in core. Handler stores results in `Document.sim_results`.

- Generate SPICE netlist from `Schematic` (walk instances + wires + connectivity)
- Dump to PySpice (Python subprocess or FFI)
- Parse simulation output into `SimResult`
- User-written analysis code is in PySpice
- Handler dispatches `Command::RunSim` → sim crate → results back to state

### 8. Display (`crates/display/`)

egui/eframe GUI. Renders everything.

**Work with what exists:** Handler's `App` API (accessors + dispatch). Core types for rendering data.

- Main app loop: read `App` accessors → render → dispatch `Command`s on input
- Canvas: render `wires()`, `instances()`, shapes from Schematic
- Resolve `Sym` → `&str` via `app.resolve()` for labels/names
- Toolbar, tab bar, side panels
- Dialog rendering (find, properties, settings, etc.) — handler manages open/close state
- Waveform viewer for `sim_results()`
- Library browser from `pdk()`

### 9. Plugins (`crates/plugins/`)

C-ABI plugin system.

**Work with what exists:** `PluginBlock` in core, `PluginUiState` in handler, blob storage in `AppState.plugin_data`.

- C-ABI interface: plugins written in any language
- Plugins dispatch `Command::PluginCommand`/`PluginMutation` through handler
- Plugins read state through handler accessors (exposed via C FFI)
- Persistent plugin state: `HashMap<String, Vec<u8>>` blobs
- Plugin panels in designated GUI spots (managed by handler's `PluginUiState`)

### Ref: `../Schemify/` and `../PySpice/`
