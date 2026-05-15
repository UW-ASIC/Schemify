# plugins

Extension system: load, lifecycle-manage, and communicate with native (.so/.dylib/.dll) plugins via a synchronous binary protocol. Plugins are out-of-tree shared libraries that export a single `schemify_plugin` symbol pointing to a `Descriptor` with an ABI version and a `process` function pointer. The host serializes messages into a flat byte buffer, calls `process`, and deserializes the response buffer. No threads, no callbacks from the plugin side, no shared memory.

## Public API

| Symbol | Kind | Purpose |
|--------|------|---------|
| `Runtime` | struct | Full plugin lifecycle: init, loadOne, loadStartup, tick, drawPanel, hover, keyEvent, refresh, deinit. Owns all loaded plugins and panel state. |
| `Runtime.host()` | method | Constructs a `PluginHost` vtable pointing at this Runtime for use by GUI code. |
| `HostCallbacks` | struct | 15-field callback table the application (main.zig) populates so Runtime can call back into app state without importing gui/core. |
| `PluginHost` | struct (vtable) | Type-erased interface the GUI calls: drawPanel, dispatchButton/Slider/Checkbox/Text, dispatchHover, dispatchKeyEvent, widgets, panelHtml, tooltipText, loadPlugin. |
| `PluginHost.from(T, *T)` | fn | Constructs a PluginHost from any type implementing the required method set. |
| `PluginManager` | struct | Binary discovery: resolve plugin .so/.wasm paths under a config directory. SoA layout (names, paths, lazys, binary_types). |
| `PluginManager.resolve()` | method | Probe candidate filenames for each enabled PluginSpec, return fail count. |
| `PluginManager.autoDiscover()` | method | Scan config dir subdirectories for untracked plugin binaries. |
| `PluginSpec` (PluginManager) | struct | `{name, enabled, lazy}` -- input to PluginManager.resolve(). |
| `Framework` | namespace | Comptime plugin authoring framework. `define(State, *State, PluginSpec)` generates the `process` function and `Descriptor` export. Widget/panel/hook constructors. |
| `Framework.PluginSpec` | struct | Declarative plugin definition: name, version, panels (with widget specs or custom draw_fn), lifecycle hooks (load/unload/tick/command/hover/key_event), event subscription mask. |
| `Framework.define()` | fn | Returns a type with `process` (callconv(.c)) and `export_plugin()` that emits the two required linker symbols. |
| `Capability` | packed struct | 5 boolean capability flags + 3-bit pad. |
| `validateReadPath()` | fn | Check path against capability + scoped directories. |
| `validateWritePath()` | fn | Check path against capability + plugin data directory. |
| `isProcessAllowed()` | fn | Check process name against AllowedProcesses allow-list. |
| `AllowedProcesses` | struct | Fixed-capacity (8) process name allow-list. |
| `Manifest` | struct | Full plugin.toml representation: plugin metadata, capabilities, panels, commands, menus, config, activation events, build, messages, file_types, extension_points. |
| `Manifest.parse()` | fn | Line-by-line TOML parser producing a Manifest. Allocates; caller calls `deinit`. |
| `Reader` | struct | Zero-copy host-to-plugin message decoder. Skips plugin-to-host tags. |
| `Writer` | struct | Plugin-to-host message encoder into caller-owned flat buffer. Tracks overflow. |
| `types.Tag` | enum(u8) | 20 host-to-plugin tags (0x01-0x14), 16 plugin-to-host command tags (0x80-0x95), 15 UI widget tags (0xA0-0xAE). Non-exhaustive. |
| `types.InMsg` | tagged union | Decoded host-to-plugin message. Plugin-to-host variants are void (never appear as input). |
| `types.Descriptor` | extern struct | ABI v8 export: abi_version, name, version_str, process fn ptr. |
| `types.ProcessFn` | fn ptr | `fn([*]const u8, usize, [*]u8, usize) callconv(.c) usize` -- the plugin entry point. |
| `types.ParsedWidget` | struct | Decoded UI widget for host-side rendering. |
| `types.WidgetTag` | enum(u8) | 13 widget kinds: label, button, separator, begin_row, end_row, slider, checkbox, progress, collapsible_start/end, tooltip, text_input, text_area. |
| `types.PanelDef` | struct | Panel registration data sent over the wire. |
| `types.PanelLayout` | enum(u8) | overlay, left_sidebar, right_sidebar, bottom_bar. |
| `types.ABI_VERSION` | u32 | Current ABI version: 8. |
| `safety.inspectElf()` | fn | Parse ELF64 .dynsym/.dynstr to find dangerous imports (dlopen, execve, fork, socket, etc.). |
| `safety.isTrusted()` | fn | SHA-256 TOFU check against `~/.config/schemify/trusted_plugins.json`. |
| `safety.trustPlugin()` | fn | Add/update a plugin's hash in the trust store. |
| `safety.revokePlugin()` | fn | Remove a plugin from the trust store. |
| `safety.hashFile()` | fn | Streaming SHA-256 of a file, returned as 64-char hex. |
| `safety.hashBytes()` | fn | SHA-256 of a byte slice. |
| `installer.Installer.install()` | fn | Download a plugin binary from URL (with GitHub release resolution), place it in the expected directory. |
| `installer.Target` | enum | `native` or `web`. |
| `installer.InstallOptions` | struct | Target + optional web output dir. |
| `installer.InstallError` | error set | InvalidUrl, InvalidGitHubUrl, NoPluginAsset, OutOfMemory, HttpError, NoHomeDir. |

## Internal Structure

| File | LOC | Purpose |
|------|-----|---------|
| `lib.zig` | 73 | Module entry point. Re-exports all public symbols. 4 protocol round-trip tests. Comptime ref-tests for types/Reader/Writer/PluginHost/Capability. |
| `types.zig` | 340 | ABI v8 wire protocol: Tag enum (51 variants), InMsg tagged union, Descriptor extern struct, ParsedWidget, WidgetTag, wire-format helpers (readStr, readPanelWidget, parsePayload), constants (HEADER_SZ=3, ABI_VERSION=8, MAX_OUT_BUF=64K). |
| `Runtime.zig` | 992 | Core lifecycle engine. PluginLib (dlopen/dlsym/dlclose with RTLD_GLOBAL), LoadedPlugin (per-plugin state: lib handle, descriptor, output buffer, pending file/state responses, event mask, capabilities), PanelState (MultiArrayList of ParsedWidget + HTML + arena), EventBuf (fixed 64-event ring), Runtime struct. Command whitelist (~80 allowed commands). |
| `PluginHost.zig` | 90 | Type-erased vtable: 12 function pointer fields. `from(T, *T)` generates the vtable from any conforming type. |
| `PluginManager.zig` | 161 | Binary discovery. Probes 6 candidate paths per plugin (4 .so, 2 .wasm). SoA storage. autoDiscover scans directories. |
| `Framework.zig` | 270 | Comptime plugin SDK. WidgetSpec (slider/button/label/label_fmt/checkbox/separator/progress), PanelSpec, PluginSpec, type-erasure wrappers, `define()` generates process+descriptor. |
| `Reader.zig` | 36 | Stateless decoder: init(buf) then iterate next(). Skips non-host-to-plugin tags. |
| `Writer.zig` | 257 | Stateful encoder with overflow tracking. Methods for all 16 plugin-to-host commands + 15 UI widgets. |
| `Manifest.zig` | 636 | Hand-rolled TOML parser for plugin.toml. Supports [plugin], [capabilities], [activation], [build], [messages], [[panels]], [[commands]], [[menus]], [[config]], [[file_types]], [[extension_points]]. Full deinit. |
| `safety.zig` | 688 | ELF64 inspector (13 dangerous imports), SHA-256 TOFU trust store (JSON file at XDG_CONFIG_HOME/schemify/). Extensive tests including synthetic ELF construction. |
| `Capability.zig` | 76 | 5-flag packed struct, path validation (isUnder prefix check), process allow-list. |
| `installer/lib.zig` | 19 | Re-exports Installer, Target, InstallOptions, InstallError. |
| `installer/Installer.zig` | 228 | HTTP fetcher (std.http.Client), GitHub release API resolver, web manifest (plugins.json) updater. |
| `installer/types.zig` | 27 | Target enum, InstallOptions, InstallError error set. |

## Dependencies

- **utility** -- `platform.fs.cwd()` in PluginManager, `Vfs` + `platform` + `Logger` in src/plugins/PluginManager.zig and installer.
- **dvui** -- only transitively: PluginHost.WidgetSlice = `std.MultiArrayList(ParsedWidget).Slice` (no actual dvui import in modules/plugins; the dvui dependency is in build.zig for the GUI that consumes this module).
- **state** -- only in `src/plugins/PluginManager.zig` (the richer variant), not in `modules/plugins/`.
- **std** -- ELF parsing, crypto (SHA-256), HTTP client, JSON, filesystem, POSIX dlopen.

## Gaps

### Missing Features

1. **WASM sandboxing** -- `PluginManager` discovers `.wasm` files and records `BinaryType.wasm`, but Runtime has no WASM execution engine. All WASM paths are dead (`is_wasm` guards return early / skip). No fuel metering, no memory limits.
2. **Plugin marketplace API** -- Installer can fetch from a URL or resolve GitHub releases, but there is no registry, no search, no versioned catalog, no update-check mechanism.
3. **Dependency resolution between plugins** -- Manifest has `messages.publishes`/`subscribes` but nothing reads them at load time. No topological sort, no load ordering, no declared dependencies.
4. **Plugin versioning / compatibility matrix** -- Manifest stores `version`, `api`, `abi` but only `abi_version` is checked (must equal ABI_VERSION exactly). No semver range matching. No host-version constraint. No minimum-api enforcement.
5. **Hot reload** -- `Runtime.refresh()` unloads all and reloads from scratch. No incremental reload, no state preservation across reloads.
6. **Plugin configuration UI generation** -- Manifest has rich `[[config]]` definitions (type, default, options, min/max, title, description) but nothing generates UI from them. The config definitions are parsed and immediately discarded.
7. **Plugin testing harness** -- No mock Runtime, no way to unit-test a plugin's process function without building a real .so and dlopen-ing it.
8. **Plugin performance monitoring** -- No timing of process calls, no per-plugin frame budget tracking, no detection of slow plugins.
9. **Inter-plugin communication** -- `messages.publishes`/`subscribes` fields exist in Manifest but no message bus, no pub/sub dispatch.
10. **Plugin templates / scaffolding** -- No `schemify plugin init` command, no template project.
11. **Permission escalation flow** -- `safety.inspectElf()` detects dangerous imports but nothing in Runtime calls it before loading. The trust store exists but is never consulted during `loadOne()`. The safety system is fully implemented but unwired.
12. **Subprocess / hybrid runtime** -- Manifest supports `runtime = "subprocess"` and `subprocess_command` but Runtime only handles native dlopen. No IPC, no stdio protocol.

### API Issues

1. **Capability.fromName() and Capability.merge() missing** -- `Manifest.zig` calls `Cap.fromName(key)` and `Cap.merge()` but neither function exists in `Capability.zig`. The manifest parser will fail to compile if capabilities parsing is exercised outside tests. The test passes only because `canvas_draw` (referenced in test) is also not a field on `Capability`, meaning the test itself would fail.
2. **Capability.canvas_draw missing** -- Manifest test asserts `m.capabilities.canvas_draw` but Capability packed struct has no `canvas_draw` field. The five actual fields are: `file_read_project`, `file_read_plugin_data`, `file_write_plugin_data`, `schematic_mutate`, `network`.
3. **Two divergent PluginManagers** -- `modules/plugins/PluginManager.zig` is a thin binary-discovery struct (no allocator field, no install, no scope checking). `src/plugins/PluginManager.zig` is richer (auto-install from URL, scope validation, ConfigSource tracking, Logger integration). They have the same name but different APIs.
4. **ABI stability** -- ABI_VERSION=8 is an exact-match check. Adding a single new Tag or changing any payload format requires bumping the version and breaks all existing plugins. No forward/backward compatibility, no feature negotiation.
5. **No error propagation from process calls** -- `callPluginProcess` returns `error{OutOfMemory, PluginOutputTooLarge}` but callers silently discard errors (`catch return`). A plugin that consistently overflows is retried every tick with no backoff or disable.
6. **Missing lifecycle hooks** -- No `on_project_open`, `on_project_close`, `on_save`, `on_before_save`. Plugins can only react to `schematic_changed` and `selection_changed` which carry minimal data.
7. **Payload size limited to u16** -- Wire header uses u16 for payload size (max 65535 bytes). Plot data, images, and large file contents can easily exceed this. Writer handles overflow by setting a flag and silently dropping the message.
8. **tick_alloc capture pattern** -- Runtime captures an allocator in `tick_alloc` at tick/hover/keyEvent entry so PluginHost vtable methods can use it without an allocator parameter. This is a hidden coupling: calling PluginHost methods outside a tick/hover/keyEvent context uses whatever allocator was last captured, which may be freed.
9. **dlclose skipped** -- `deinit()` comment says "Skip dlclose -- CPython teardown". Plugin .so files are never unloaded from the process, leaking their memory and preventing true hot reload.
10. **Command whitelist is static** -- The ~80 allowed commands are hardcoded in a `StaticStringMap`. Plugins cannot push commands that the host adds after compilation without updating this list.
