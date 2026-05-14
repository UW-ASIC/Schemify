# plugins

Extension system: load, run, and communicate with native (.so) plugins via binary protocol.

## Functionality

- Plugin manifest parsing (plugin.toml → panels, commands, menus, config, capabilities)
- Native plugin loading via dlopen with RTLD_GLOBAL (CPython interop)
- Binary protocol: Reader/Writer for host <-> plugin message passing
- PluginHost: vtable for plugin -> host callbacks (panels, commands, keybinds, files, state)
- Runtime: full lifecycle (load/tick/draw/hover/keyEvent/unload), lazy loading, event dispatch
- PluginManager: discovery, path resolution, auto-install
- Safety: ELF inspection for dangerous imports, SHA-256 TOFU trust store
- Capability flags: file_read, file_write, canvas_draw, schematic_mutate, network

Removed in cleanup: scheduler.zig (dead, referenced nonexistent PluginSystem), host_api.zig (dead, only imported by scheduler), loader_native.zig (dead, referenced nonexistent v1 types).

## Public API

| Symbol | Purpose |
|--------|---------|
| `Runtime` | Plugin lifecycle: init, loadOne, loadStartup, tick, drawPanel, hover, keyEvent |
| `HostCallbacks` | Callback table wired by main.zig |
| `PluginHost` | vtable constructed from Runtime |
| `PluginManager` / `PluginSpec` | Discovery + path resolution |
| `Framework` | Plugin framework utilities |
| `Capability` | Capability flag type + merge/validate |
| `types.*` | Tag, InMsg, Descriptor, ProcessFn, ParsedWidget, WidgetTag |
| `Reader` / `Writer` | Binary protocol codec |

## Internal Structure

| File | Purpose |
|------|---------|
| `lib.zig` | Module entry, re-exports, protocol round-trip tests |
| `Runtime.zig` | Plugin lifecycle, tick, event dispatch, output message handling |
| `PluginHost.zig` | vtable construction from Runtime methods |
| `PluginManager.zig` | Plugin discovery, path resolution |
| `Framework.zig` | Plugin framework utilities |
| `Reader.zig` / `Writer.zig` | Binary protocol codec |
| `Manifest.zig` | plugin.toml TOML parser |
| `safety.zig` | ELF inspection, trust store (SHA-256 TOFU) |
| `Capability.zig` | Capability flags and path validation |
| `types.zig` | ABI v8 wire protocol types |
| `installer/` | Plugin download and installation |

## Dependencies

- `dvui` — widget types for panel rendering
- `utility` — platform helpers
