# Plugin System Overview

Schemify plugins extend the editor with custom panels, commands, keybindings, canvas overlays, data providers, and schematic automation. Plugins communicate with the host via **Plugin API v1** -- named C ABI function exports with a host function pointer table.

---

## Architecture

```
Plugin (.so / .dylib / .dll / .wasm)
  exports: schemify_activate, schemify_render, schemify_on_*, ...
  calls:   host->log(), host->push_command(), host->schematic->instances(), ...
     |
     v
Plugin Host (src/plugins/lib.zig)
  loads plugins, dispatches async calls on worker threads, collects results
     |
     v
PanelRenderer (src/gui/PanelRenderer.zig)
  caches HTML, injects theme CSS, manages litehtml document lifecycle
     |
     v
dep/HTML2DVUI/ (litehtml + dvui bridge)
  parses HTML/CSS, layouts, emits draw commands
     |
     v
dvui renders to screen
```

---

## What Is a Plugin?

A shared library (`.so` on Linux, `.dylib` on macOS, `.dll` on Windows) or WASM module (`.wasm`) that exports C ABI functions. The host discovers it via `plugin.toml`, loads it, resolves export symbols, and calls them at lifecycle points.

There is no binary serialization protocol. All structured data is JSON strings. All UI is HTML strings.

---

## The 11 Export Symbols

| Symbol | Required | Called When |
|--------|----------|------------|
| `schemify_activate(host)` | Yes | Plugin loaded; store the host pointer |
| `schemify_deactivate()` | No | Plugin being unloaded |
| `schemify_render(panel_id)` | No | Host needs HTML for a panel |
| `schemify_on_html_event(panel_id, event_json)` | No | User interacts with a panel element |
| `schemify_on_command(name, args)` | No | A registered command is invoked |
| `schemify_on_schematic_changed()` | No | Schematic has been modified |
| `schemify_on_selection_changed(selection_json)` | No | Selection state changed |
| `schemify_on_key_event(key_json)` | No | A registered keybind fires |
| `schemify_on_hover(hover_json)` | No | Cursor hovers over schematic elements |
| `schemify_provide(provider_type, context_json)` | No | A registered provider is queried |
| `schemify_on_message(sender, topic, payload)` | No | Another plugin sends a message |

All parameters and return values are null-terminated C strings (`const char*`).

---

## Plugin Lifecycle

```
Host starts
  |
  v
DISCOVERY
  Scan plugin directories for plugin.toml manifests
  Parse static declarations (panels, commands) without loading code
  |                          activation event fires
  v
ACTIVATE
  dlopen (native) or wasm3 instantiate (WASM)
  Resolve schemify_activate symbol
  Call schemify_activate(host) -- plugin stores host pointer
  Plugin calls host->register_panel(), register_command(), etc.
  |
  v
ACTIVE
  schemify_render() called each frame for visible panels
  schemify_on_html_event() on user interaction
  schemify_on_command() when commands invoked
  schemify_on_schematic_changed() / on_selection_changed() on model changes
  |                          user disables / app exit
  v
DEACTIVATE
  schemify_deactivate() called
  dlclose / WASM instance freed
  Static contributions removed
```

---

## Plugin Manifest (`plugin.toml`)

Every plugin ships a `plugin.toml` that the host reads without loading the binary:

```toml
[plugin]
name = "My Plugin"
version = "1.0.0"
author = "Your Name"
description = "What your plugin does"
api = 1

[activation]
events = ["on_startup"]

[[panels]]
id = "my-panel"
title = "My Panel"
layout = "right_sidebar"
keybind = "m"
vim_cmd = "myplugin"

[[commands]]
name = "my_plugin.do_thing"
description = "Does the thing"

[build]
binary = "plugin.so"
```

### Activation Events

| Event | Fires when |
|-------|------------|
| `on_startup` | App finishes initializing |
| `on_command:<name>` | User runs `:name` in command bar |
| `on_file:<glob>` | A file matching the pattern is opened |
| `on_keybind` | User presses the declared keybind |
| `on_panel:<id>` | User opens the plugin's panel |
| `on_install` | Plugin is first installed |

---

## Memory Convention

- **Plugin returns** (`schemify_render`, `schemify_provide`): Returned `const char*` is owned by the plugin. Must remain valid until the next `schemify_*` call on the same plugin. The host copies immediately.

- **Host returns** (`read_file`, `project_dir`, schematic queries): Returned `const char*` is owned by the host. Valid until the next call to the same host function from the same plugin.

In practice: use static buffers or string literals. Neither side frees the other's memory.

---

## Native vs WASM

| | Native (.so) | WASM (.wasm) |
|-|---|---|
| Loading | dlopen + dlsym | wasm3 runtime |
| Performance | Full native speed | ~3-10x slower |
| Safety | Trust-on-first-use (TOFU) | Sandboxed (auto-approved) |
| File access | Full system access | Host-mediated only |
| Build | Platform-specific | Universal binary |
| Security prompt | First use + on binary change | None (sandboxed) |

Both use the exact same 11 export symbols. A plugin can ship both formats.

---

## Plugin Discovery (three-tier)

```
# Project-local (highest priority, development)
<project_dir>/.schemify/plugins/<PluginName>/plugin.toml

# User-installed (marketplace or manual)
~/.config/schemify/plugins/<PluginName>/plugin.toml

# Bundled (ships with app, lowest priority)
<app_install_dir>/plugins/<PluginName>/plugin.toml
```

Same `name` in `plugin.toml` = override (project > user > bundled).

---

## Plugin Data Storage

```
~/.local/share/schemify/plugins/<plugin_name>/
├── config.json       # plugin-specific settings
├── cache/            # transient data
└── ...
```

Access via `host->plugin_data_dir()`. The directory is auto-created on first call.

---

## Pick Your Language

| Guide | Best for |
|-------|----------|
| [C](c) | Minimal overhead, single header, C99 |
| [C++](cpp) | RAII, classes, CMake |
| [Zig](zig) | Same language as Schemify, comptime |
| [Rust](rust) | Memory safety, rich type system |
| [Python](python) | Rapid prototyping, scripting |
| [Go](go) | Simple concurrency, TinyGo for WASM |
| [WASM](wasm) | Any language, sandboxed, universal |

All SDKs live in `tools/plugins/<language>/` and are self-contained (copy and build).

---

## Further Reading

- [API Reference](api-reference) -- complete function signatures and types
- [HTML Panels](html-panels) -- rendering, CSS theming, interactive elements
- [WASM Guide](wasm) -- compile to WASM, memory model, security
