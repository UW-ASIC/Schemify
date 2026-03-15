# Plugin Overview

Schemify's plugin system lets you extend the editor without forking it.
Plugins run as separate shared libraries (`.so`) on native desktops, or as
WebAssembly modules (`.wasm`) in the browser — the same source file compiles
to both targets.

## What plugins can do

| Capability | How |
|------------|-----|
| Add a dockable panel or overlay to the UI | `w.registerPanel(...)` in response to `.load` |
| Set the editor status bar text | `w.setStatus(msg)` |
| Write structured log messages | `w.log(level, tag, msg)` |
| Read and write project files | `Plugin.Vfs` |
| Trigger a UI redraw | `w.requestRefresh()` |
| Place devices / wires in the schematic | `w.placeDevice(...)` / `w.addWire(...)` |
| Persist per-plugin key/value state | `w.setState(key, val)` / `w.getState(key)` |
| Push commands to the host queue | `w.pushCommand(tag, payload)` |
| Register keyboard shortcuts | `w.registerKeybind(key, mods, tag)` |
| Query schematic instances and nets | `w.queryInstances()` / `w.queryNets()` |

## Plugin lifecycle

Every plugin exports a symbol named `schemify_plugin` (`PluginIF.Descriptor`)
and a single function `schemify_process`.  The host drives the plugin purely
by passing binary message batches through that function:

```
Runtime                             Plugin
  │                                   │
  │── process([load msg]) ───────────►│  registers panels, sets status
  │                                   │
  │   ... per frame ...               │
  │── process([tick msg]) ───────────►│  background work, state updates
  │── process([draw_panel msg]) ──────►│  emits ui_* widget messages
  │                                   │
  │── process([unload msg]) ─────────►│  cleanup
```

The return value is the number of bytes written to the output buffer.  If the
buffer is too small the plugin returns `maxInt(usize)` and the host retries
with a doubled buffer.

## Language support

| Language | Mechanism |
|----------|-----------|
| **Zig** | Write the plugin entirely in Zig |
| **C / C++** | Call via `@cImport` / `addCSourceFile` in build.zig |
| **Rust** | `schemify-plugin` crate; `export_plugin!` macro |
| **Python** | Pure `.py` files; `addPythonPlugin` deploys them |
| **TinyGo** | `schemify` package; `RunPlugin` entry point |
| **C / C++** | `schemify_plugin.h` header + `addCPlugin` / `addCppPlugin` |

The plugin ABI boundary is a plain C `extern struct`, so any language that
can emit C-compatible shared-library exports works.

## Deployment

| Target | Output | Install location |
|--------|--------|-----------------|
| Native (Linux) | `lib<Name>.so` | `~/.config/Schemify/<Name>/` |
| Native (macOS) | `lib<Name>.dylib` | `~/.config/Schemify/<Name>/` |
| Web (WASM) | `<Name>.wasm` | Loaded by `plugin_host.js` from `plugins/` |

`zig build run` (via `addNativeAutoInstallRunStep`) copies the build output
into the correct directory and then launches the host automatically.
