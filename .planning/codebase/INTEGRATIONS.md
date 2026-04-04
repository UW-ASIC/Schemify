# External Integrations

**Analysis Date:** 2026-04-04

## APIs & External Services

**GitHub Releases API:**
- Used by plugin installer to auto-resolve latest release assets
- Implementation: `src/plugins/installer.zig`
- HTTP client: `std.http.Client` (native) or `fetch()` (WASM via `src/utility/Platform.zig`)
- Auth: None (public repos only, no API key)
- URL patterns accepted:
  - `https://github.com/user/repo` (resolves latest release)
  - `https://github.com/user/repo/releases/latest`
  - Direct file URL (any host)

**Plugin Marketplace Registry:**
- Fetched via HTTP GET from a remote JSON endpoint
- Implementation: `src/gui/Marketplace.zig` + `src/state/` (`MarketplaceState`, `MarketplaceEntry`)
- Uses `Platform.httpGetSync` (native) or `Platform.AsyncGet` (WASM polling model)
- Auth: None

## Circuit Simulation Backends

**NGSpice (Optional):**
- Purpose: SPICE circuit simulation (transient, AC, DC analysis)
- Bindings: `deps/ngspice.zig` wraps `sharedspice.h` via `@cImport`
- Library: `libngspice.so` (dynamic linking)
- Source path: `deps/ngspice/` (must be built from source)
- Build: `./autogen.sh && ./configure --with-ngshared --enable-xspice --enable-cider && make`
- Config: `tools/build_dep.zig` `SpiceConfig` struct controls paths
- API: Callback-driven C API — `NgSpice.init()`, `.command()`, `.run()`, `.getVoltage()`
- Connection: Linked at build time, called at runtime via `deps/lib.zig` `Simulator` abstraction

**Xyce (Optional):**
- Purpose: Parallel circuit simulation, co-simulation mode
- Bindings: `deps/xyce.zig` wraps `xyce_c_api.h` via `@cImport`
- C++ shim: `deps/Xyce/xyce_c_api.cpp` compiled as part of the module
- Library: `libxyce.so` (dynamic linking) + Trilinos dependency
- Source path: `deps/Xyce/` (must be built from source with Trilinos)
- Build: Trilinos first (`cmake` with `-fPIC`), then Xyce (`configure --enable-shared`)
- API: `Xyce.init()`, `.initializeFromNetlist()`, `.runSimulation()`, `.simulateUntil()`, `.getSolution()`
- Connection: Linked at build time, called at runtime via `deps/lib.zig` `Simulator` abstraction

**Unified Simulator Interface:**
- File: `deps/lib.zig`
- Abstracts NGSpice and Xyce behind `Simulator` struct with `Backend` enum
- Usage: `src/core/SpiceIF.zig` and CLI `--netlist` command

## Data Storage

**Databases:**
- None. All data is file-based.

**File Storage:**
- Native: Local filesystem via `src/utility/Vfs.zig` (thin wrapper around `std.fs`)
- Web: In-memory `Map<string, Uint8Array>` backed by OPFS (Origin Private File System)
  - VFS layer: `web/vfs.js` (main thread facade) + `web/vfs-worker.js` (persistence worker)
  - Host bridge: `src/web/schemify_host.js` maps WASM `extern "host"` imports to VFS operations
  - Persistence: Automatic writeback to OPFS via Web Worker on `markDirty(path)`

**File Storage Paths:**
- Project files: Working directory (`.` or CLI argument)
- Plugin binaries: `~/.config/Schemify/<PluginName>/` (native)
- Web plugin binaries: `zig-out/bin/plugins/` + `plugins.json`
- Config: `Config.toml` in project root

**Caching:**
- None (no explicit cache layer)
- WASM VFS retains files in memory for the session; OPFS persists across sessions

## Authentication & Identity

**Auth Provider:**
- None. Schemify is a local-first desktop/web application with no user accounts.
- Plugin marketplace uses unauthenticated HTTP requests.

## Monitoring & Observability

**Error Tracking:**
- None (no external error tracking service)

**Logs:**
- Custom logger: `src/utility/Logger.zig`
- Levels: trace, debug, info, warn, err, fatal (enum `Level` in `src/utility/types.zig`)
- Output: stderr (native), browser console (WASM via dvui)
- Format: `[LEVEL] [SOURCE] message` (e.g., `[INF] [PLUGIN] loaded MyPlugin v1.0.0`)
- Plugin logs forwarded via ABI v6 `.log` output message tag

## CI/CD & Deployment

**Hosting:**
- Native: Distributed as compiled binary (`zig build` produces `schemify` executable)
- Web: Static file hosting (any HTTP server serves `zig-out/bin/` contents)
  - Dev server: `python3 -m http.server 8080` (invoked by `zig build run_local -Dbackend=web`)

**CI Pipeline:**
- Not detected in repository (no `.github/workflows/`, `.gitlab-ci.yml`, etc.)

## Plugin System (ABI v6)

**Plugin Loading (Native):**
- Mechanism: `dlopen()` via `std.DynLib` in `src/plugins/runtime.zig`
- Discovery: Scans `~/.config/Schemify/<name>/` for `.so` files
- Symbol lookup: `schemify_plugin` export (type `*const Descriptor`)
- ABI version check: `desc.abi_version == 6` required
- Lifecycle: load -> tick (each frame) -> draw_panel (per visible panel) -> unload

**Plugin Loading (Web):**
- Mechanism: JavaScript-side `WebAssembly.instantiate()` (handled by `plugin_host.js`)
- Discovery: `plugins.json` in web output directory
- The Zig runtime is a no-op stub on WASM targets

**Plugin Communication Protocol:**
- Wire format: `[u8 tag][u16 payload_sz LE][payload bytes]`
- Entry point: `schemify_process(in_ptr, in_len, out_ptr, out_cap) -> usize`
- Overflow: returns `usize_max`, host doubles buffer and retries (up to `MAX_OUT_BUF`)
- Input messages (host -> plugin): `load`, `unload`, `tick`, `draw_panel`, `button_clicked`, `slider_changed`, `checkbox_changed`, `file_response`
- Output messages (plugin -> host): `register_panel`, `set_status`, `log`, `register_command`, `register_keybind`, `push_command`, `set_config`, `file_read_request`, `file_write`, `request_refresh`, UI widgets (`ui_label`, `ui_button`, `ui_slider`, `ui_checkbox`, `ui_separator`, `ui_progress`, `ui_collapsible_start`, `ui_collapsible_end`, `ui_begin_row`, `ui_end_row`)

**Plugin File I/O:**
- Plugins request file reads via `file_read_request` output tag
- Host reads via `Vfs.readAlloc()` and delivers data as `file_response` input on next tick
- Plugins write files via `file_write` output tag (host calls `Vfs.writeAll()`)

**Plugin Command Dispatch:**
- Plugins can push whitelisted commands via `push_command` output tag
- Whitelist defined in `src/plugins/runtime.zig` `allowed_plugin_commands` array
- Allowed: zoom, toggle UI flags, snap, select, plugins_refresh

## WASM Host Bridge

**Import Namespace: `"host"`**
- Implemented in: `src/web/schemify_host.js`
- Consumed by: `src/utility/Vfs.zig` and `src/utility/Platform.zig` (via `extern "host"` declarations)

**VFS Imports (Vfs.zig -> schemify_host.js):**
- `vfs_file_len(path_ptr, path_len) -> i32`
- `vfs_file_read(path_ptr, path_len, dest, dlen) -> i32`
- `vfs_file_write(path_ptr, path_len, src, slen) -> i32`
- `vfs_dir_make(path_ptr, path_len) -> i32`
- `vfs_dir_list_len(path_ptr, path_len) -> i32`
- `vfs_dir_list_read(path_ptr, path_len, dest, dlen) -> i32`

**Platform Imports (Platform.zig -> schemify_host.js):**
- `platform_open_url(ptr, len) -> void`
- `platform_http_get_start(url_ptr, url_len, req_id) -> void`
- `platform_http_get_poll(req_id, buf_ptr, buf_len) -> i32` (-1=pending, -2=error, >=0=bytes)
- `platform_env_get(name_ptr, name_len, out_ptr, out_len) -> i32`

## HDL / Synthesis Integration

**Verilog/VHDL Parser:**
- Built-in: `src/core/HdlParser.zig`
- Parses behavioral models for component descriptions

**Yosys (External Tool):**
- JSON output parser: `src/core/YosysJson.zig`
- Synthesis invocation: `src/core/Synthesis.zig`
- Spawned as child process via `Platform.spawnProcess`
- Not available on WASM target

## Theme System

**Plugin-Driven Theming:**
- File: `src/gui/Theme.zig`
- Plugins can override canvas colors, wire widths, grid dot sizes, tab shapes via `set_config` ABI message
- JSON payload parsed by `theme_config.applyJson()` in `src/plugins/runtime.zig`
- Overrides stored in `ThemeOverrides` struct with optional fields (null = use default)

## Environment Configuration

**Required env vars:**
- `HOME` - Locates plugin directory (`~/.config/Schemify/`). Required for plugin loading on native.

**Optional env vars:**
- None detected. All configuration is via `Config.toml` or CLI flags.

**Secrets location:**
- No secrets required. The application does not authenticate to any service.

## Webhooks & Callbacks

**Incoming:**
- None

**Outgoing:**
- None

## External Existing Plugins

These are shipped in the `plugins/` directory at the project root (not installed at runtime):

| Plugin | Directory | Purpose |
|--------|-----------|---------|
| EasyImport | `plugins/EasyImport/` | Component import helper |
| GmID Visualizer | `plugins/GmID Visualizer/` | MOSFET gm/ID curve visualization |
| Optimizer | `plugins/Optimizer/` | Bayesian circuit optimization |
| PDKLoader | `plugins/PDKLoader/` | PDK discovery and management |
| Themes | `plugins/Themes/` | Color theme customization |

Additional plugins (documented in memory, may be in separate repos):
- **SchemifyPython** - CPython embedder for `.py` plugin scripts
- **Circuit Visionary** - AI pipeline via CPython

---

*Integration audit: 2026-04-04*
