# Plugins Module Architecture

This directory contains plugin loading/runtime logic and plugin installation helpers.

## Files

- `src/plugins/runtime.zig`
  - Native runtime for dynamic plugins (`.so`, `.dylib`, `.dll` support is selected by platform tooling, runtime currently scans `.so` locations used by native builds).
  - Owns plugin lifecycle: load, tick, draw-panel requests, unload.
  - Marshals PluginIF wire messages to and from `AppState`.
- `src/plugins/installer.zig`
  - CLI-facing installer.
  - Resolves direct URLs or GitHub latest-release assets.
  - Installs native plugin binaries under `~/.config/Schemify/<plugin>/`.
  - Installs web plugins (`.wasm`) under `zig-out/bin/plugins/` and updates `plugins.json`.

## Runtime Data Flow (Native)

1. Startup (`Runtime.loadStartup`)
   - Stores `AppState` pointer.
   - Scans `~/.config/Schemify/*` and each plugin `lib/` subdir.
   - Loads each shared object and validates `schemify_plugin` ABI descriptor.
   - Sends `load` message with project directory to plugin.

2. Frame tick (`Runtime.tick`)
   - Sends one `tick` message per loaded plugin.
   - Tick input includes:
     - `dt`
     - queued file responses from prior plugin `file_read_request`
     - queued GUI events (button/slider/checkbox interactions)
   - Dispatches plugin output messages back into app state (panel registration, status/logging, commands, config updates, VFS ops, keybinds, refresh requests).

3. Panel draw phase (`Runtime.tick` -> `callProcessDrawPanel`)
   - For each visible plugin panel, sends `draw_panel(panel_id)`.
   - Parses returned UI messages into `ParsedWidget` records.
   - Stores widgets in per-panel state (`MultiArrayList`) for GUI rendering (`src/gui/PluginPanels.zig`).

4. Shutdown / refresh (`Runtime.unloadAll`)
   - Sends `unload` to each plugin.
   - Clears pending buffers/responses and closes dynamic libraries.
   - Clears app-registered plugin commands.

## Lifecycle Notes

- Runtime is a no-op on wasm targets; web plugins are hosted by JS (`plugin_host.js`) and use host imports directly.
- Output parsing is frame-based and robust to malformed frames (bounds-checked frame iteration and payload parsing).
- File reads are async across frames:
  - Plugin emits `file_read_request`.
  - Runtime reads via VFS and queues `file_response`.
  - Response is delivered in the next `tick` input.
