# A6: Plugin Runtime

**Wave**: 2
**Depends on**: A2 (plugin types in core)

## Goal
Plugin lifecycle: discover, load manifest, spawn subprocess, communicate via JSON-RPC, register panels/commands/overlays/theme overrides. No WASM transport yet.

## Branch
`feat/plugin-runtime`

## Zig Reference Files
- `../Schemify/src/plugins/PluginManager.zig` — discovery, resolution, lifecycle
- `../Schemify/src/plugins/Runtime.zig` — spawn, lifecycle, IPC loop
- `../Schemify/src/plugins/jsonrpc.zig` — JSON-RPC 2.0 marshaling
- `../Schemify/src/plugins/Manifest.zig` — plugin.toml parser
- `../Schemify/src/plugins/Capability.zig` — capability negotiation
- `../Schemify/src/plugins/subprocess.zig` — native subprocess transport
- `../Schemify/src/plugins/types.zig` — PanelDef, WidgetTag, PluginState

## Crate/File Map

### plugins (`crates/plugins/src/`)
- `lib.rs` — public API: `PluginManager`
- NEW `manifest.rs` — parse `plugin.toml` (serde + toml crate)
- NEW `manager.rs` — discovery (scan dirs), resolution, lifecycle state machine
- NEW `runtime.rs` — spawn subprocess, pipe I/O, tick loop
- NEW `jsonrpc.rs` — JSON-RPC 2.0 request/response/notification marshaling
- NEW `host.rs` — host callbacks (register panel, push command, query schematic)
- NEW `capability.rs` — capability negotiation (what host supports, what plugin needs)

### plugins Cargo.toml additions
```toml
[dependencies]
schemify-core = { path = "../core" }
schemify-handler = { path = "../handler" }
serde = { version = "1", features = ["derive"] }
serde_json = "1"
toml = "0.8"
```

## Plugin Manifest (`plugin.toml`)

```toml
[plugin]
name = "PDKSwitcher"
version = "1.0.0"
description = "Switch between PDK configurations"
entry = "lib_PDKSwitcher.so"   # or "plugin.py"
language = "native"             # native | python

[capabilities]
panels = true
commands = true
overlays = false
theme = true

[panels]
[[panels.panel]]
name = "PDK Config"
slot = "RightSidebar"
priority = 10
```

## JSON-RPC Protocol

**Host → Plugin**:
- `lifecycle/initialize` — send host capabilities, receive plugin capabilities
- `lifecycle/shutdown` — graceful stop
- `state/schematic_changed` — notification on schematic mutation
- `state/selection_changed` — notification on selection change

**Plugin → Host**:
- `panels/register` — register a panel into a slot
- `panels/update` — push new widget tree for a panel
- `commands/register` — register a command
- `commands/dispatch` — push a Command to handler
- `overlay/update` — push overlay shapes
- `theme/override` — push theme token overrides
- `state/query_instances` — read instance data
- `state/query_nets` — read connectivity data

## Lifecycle State Machine

```
Discovered → Starting → Running → Stopping → Stopped
                 │                     ▲
                 └──► ErrorState ──────┘
```

## Checklist
- [ ] `manifest.rs`: parse plugin.toml into `PluginManifest` struct
- [ ] `manager.rs`: scan plugin directories, collect manifests
- [ ] `manager.rs`: lifecycle state machine (start, stop, restart)
- [ ] `jsonrpc.rs`: JSON-RPC 2.0 request/response/notification types
- [ ] `jsonrpc.rs`: serialize/deserialize with serde_json
- [ ] `runtime.rs`: spawn subprocess with stdin/stdout pipes
- [ ] `runtime.rs`: async read loop (read JSON-RPC messages from stdout)
- [ ] `runtime.rs`: write JSON-RPC messages to stdin
- [ ] `host.rs`: handle `panels/register` → update PluginUiState
- [ ] `host.rs`: handle `commands/register` → update PluginUiState
- [ ] `host.rs`: handle `overlay/update` → update OverlayLayer in state
- [ ] `host.rs`: handle `theme/override` → update ThemeOverride in state
- [ ] `host.rs`: handle `state/query_*` → read from App via AppRead
- [ ] `capability.rs`: negotiate capabilities on initialize
- [ ] `manager.rs`: tick() — poll all running plugins, dispatch messages
- [ ] Tests: manifest parsing
- [ ] Tests: JSON-RPC round-trip (serialize → deserialize)
- [ ] Tests: lifecycle state transitions
- [ ] Commit after each meaningful change

## Do NOT Touch
- `core/src/plugin_types.rs` — A2 defined these, consume only
- `core/src/theme.rs` — A2 defined these, consume only
- `display/` — panels render plugin UI, but that's A5's job
- `handler/src/dispatch.rs` — plugin commands already have match arms
