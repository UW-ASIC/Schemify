# Plugin Overview

Schemify's plugin system lets you extend the editor without forking it.
Plugins run as separate shared libraries (`.so`) on native desktops, or as
WebAssembly modules (`.wasm`) in the browser — the same source file compiles
to both targets.

## What plugins can do

| Capability | API |
|------------|-----|
| Add a dockable panel or overlay to the UI | `Plugin.registerPanel` / `Plugin.registerOverlay` |
| Set the editor status bar text | `Plugin.setStatus` |
| Write structured log messages | `Plugin.logInfo` / `logWarn` / `logErr` |
| Read and write project files | `Plugin.Vfs` |
| Allocate memory on the host heap | `Plugin.allocator()` |
| Know which project is open | `Plugin.getProjectDir` |
| Know which schematic is active | `Plugin.getActiveSchematicName` |
| Trigger a UI redraw | `Plugin.requestRefresh` |
| Register PDK symbol libraries | `SymbolLibrary` vtable (see Devices) |

## Plugin lifecycle

Every plugin exports a single symbol named `schemify_plugin` of type
`PluginIF.Descriptor`.  The runtime calls three lifecycle hooks around each
application frame:

```
Runtime                         Plugin
  │                               │
  │── set_ctx(&ctx) ─────────────►│
  │── on_load() ─────────────────►│  (once, on first load)
  │── set_ctx(null) ──────────────►│
  │                               │
  │   ... per frame ...           │
  │                               │
  │── set_ctx(&ctx) ─────────────►│
  │── on_tick(dt) ───────────────►│  (every frame, optional)
  │── set_ctx(null) ──────────────►│
  │                               │
  │── set_ctx(&ctx) ─────────────►│
  │── on_unload() ───────────────►│  (on exit / hot-reload)
  │── set_ctx(null) ──────────────►│
```

`set_ctx` injects the host context pointer so the plugin can call back into
the host.  Only use host APIs **inside** a lifecycle function — the context
pointer is `null` outside them.

## Language support

| Language | Mechanism |
|----------|-----------|
| **Zig** | Write the plugin entirely in Zig |
| **C / C++** | Call via `@cImport` / `addCSourceFile` in build.zig |
| **Rust** | Build a static lib, link into Zig's plugin wrapper |
| **Python** | Use `libpython` loaded at runtime via dlopen (see the Python guide) |
| **Any language** | Compile to a C-ABI static library, link into a thin Zig wrapper |

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
