# schemify_plugins

Plugin runtime — discovery, lifecycle management, capability negotiation, JSON-RPC transport, and host-side message handling. Plugins are external processes (or WASM modules) that communicate via newline-delimited JSON-RPC 2.0 over stdin/stdout.

See `plugins/examples/README.md` for the full protocol reference and example plugins.

## Architecture

```
┌──────────────────────────────────────────────────────┐
│  Host (SchemifyRS)                                   │
│                                                      │
│  PluginManager                                       │
│   ├─ scan_directories()  →  discover plugin.toml     │
│   ├─ start_plugin()      →  spawn transport          │
│   │   └─ sends lifecycle/initialize                  │
│   ├─ tick()              →  drain messages            │
│   │   └─ returns Vec<HostAction>                     │
│   ├─ broadcast()         →  notify all plugins       │
│   └─ stop_plugin()       →  sends lifecycle/shutdown │
│                                                      │
│  HostAction pipeline                                 │
│   ├─ RegisterPanel → display adds panel to sidebar   │
│   ├─ UpdateWidgets → display re-renders widget tree  │
│   ├─ UpdateOverlay → display draws shapes on canvas  │
│   ├─ DispatchCommand → handler processes command     │
│   ├─ QueryInstances → handler serializes instances   │
│   └─ ...                                             │
└──────────┬───────────────────────────────────────────┘
           │  stdin/stdout (newline-delimited JSON-RPC)
           │
┌──────────▼───────────────────────────────────────────┐
│  Plugin (subprocess or WASM)                         │
│                                                      │
│  Reads from stdin:                                   │
│   ├─ lifecycle/initialize, lifecycle/shutdown         │
│   ├─ state/schematic_changed, state/selection_changed │
│   └─ responses to requests (matched by ID)           │
│                                                      │
│  Writes to stdout:                                   │
│   ├─ panels/register, panels/update_widgets          │
│   ├─ commands/register, commands/dispatch             │
│   ├─ overlay/update, theme/override                  │
│   ├─ host/set_status, host/log                       │
│   └─ state/query_instances, state/query_nets (reqs)  │
└──────────────────────────────────────────────────────┘
```

## Files

### `manager.rs` — Plugin lifecycle

`PluginManager` discovers, starts, stops, and communicates with plugins.

**Lifecycle states:**
```
Discovered → Starting → Running → Stopping → Stopped
     ↓           ↓          ↓                    ↓
   Error       Error      Error              Starting (restart)
```

**Key methods:**
- `scan_directories()` — find `plugin.toml` manifests in registered dirs.
- `start_plugin(name)` — spawn transport, send `lifecycle/initialize` with host capabilities.
- `stop_plugin(name)` — send `lifecycle/shutdown`, stop transport.
- `tick()` — drain up to 16 messages per plugin per tick, return `Vec<HostAction>`.
- `broadcast(method, params)` — send notification to all running plugins.
- `notify_plugin(name, method, params)` — send notification to one plugin.
- `send_response(name, id, result)` / `send_error_response(name, id, code, msg)` — reply to plugin requests.
- `send_request(name, method, params)` — send request to plugin, returns request ID.

**Convenience broadcasts:**
- `notify_schematic_changed()` — `state/schematic_changed`
- `notify_selection_changed()` — `state/selection_changed`
- `notify_theme_changed(tokens)` — `state/theme_changed` with token map

**How to add a new lifecycle broadcast:**
1. Add a convenience method on `PluginManager` that calls `broadcast()` with the method name.
2. Document the event name so plugin authors can subscribe in `[events].listen`.

### `manifest.rs` — plugin.toml parsing

`PluginManifest` parsed from TOML with sections:

| Section | Fields |
|---------|--------|
| `[plugin]` | id, name, version, description, entry, runtime, api_version |
| `[capabilities]` | panels, commands, overlays, theme (all bool) |
| `[[panels.panel]]` | name, slot, priority |
| `[[commands.command]]` | name, description, keybind |
| `[sandbox]` | network (bool), paths (path + access pairs, supports `$PLUGIN_DIR`) |
| `[events]` | listen (string array) |

**`PluginRuntime` enum:** `Native`, `Subprocess` (default), `Wasm`.

Plugin IDs must be 3-64 chars, lowercase alphanumeric with hyphens (`[a-z0-9][a-z0-9-]*[a-z0-9]`).

**How to add a new manifest section:**
1. Create a struct with `#[serde(default)]` for the section fields.
2. Add it as a field on `PluginManifest`.
3. Access it during `start_plugin()` or `tick()` as needed.

### `capability.rs` — Capability negotiation

`negotiate()` computes the intersection of host and plugin capabilities. The result gates which JSON-RPC methods the plugin can use at runtime.

**Host capabilities** (sent during initialize):
- `panels`, `commands`, `overlays`, `theme` — feature toggles.
- `query_instances`, `query_nets` — host-only; plugins always get these if the host supports them.
- `api_version` — protocol version string.

**How to add a new capability:**
1. Add a bool field to `HostCapabilities` (what the host offers).
2. Add a bool field to `ManifestCapabilities` in `manifest.rs` (what the plugin requests).
3. Add a bool field to `NegotiatedCapabilities` (the intersection).
4. AND them together in `negotiate()`.
5. Gate the relevant methods in `host.rs` with `if capability.your_cap`.

### `host.rs` — Message handling

Converts incoming JSON-RPC messages into `HostAction` variants that the handler/display layers consume.

**Notification methods (fire-and-forget from plugin):**

| Plugin method | Capability gate | HostAction |
|---------------|----------------|------------|
| `panels/register` | panels | `RegisterPanel(PanelRegistration)` |
| `panels/update_widgets` | panels | `UpdateWidgets { plugin_id, panel_name, widgets }` |
| `commands/register` | commands | `RegisterCommand(CommandRegistration)` |
| `overlay/update` | overlays | `UpdateOverlay(OverlayLayer)` |
| `theme/override` | theme | `ThemeOverride(ThemeOverride)` |
| `commands/dispatch` | — | `DispatchCommand { plugin_id, command_json }` |
| `host/set_status` | — | `SetStatus { plugin_id, message }` |
| `host/log` | — | `Log { plugin_id, level, message }` |

**Request methods (plugin sends request, host replies):**

| Plugin method | Capability gate | HostAction |
|---------------|----------------|------------|
| `state/query_instances` | query_instances | `QueryInstances { plugin_id, request_id }` |
| `state/query_nets` | query_nets | `QueryNets { plugin_id, request_id }` |
| `state/query_theme` | theme | `QueryTheme { plugin_id, request_id }` |

The handler serializes the response data and sends it back via `PluginManager::send_response()`.

**How to add a new host action:**
1. Add a variant to `HostAction`.
2. Create a param struct for typed deserialization (e.g., `YourParams` with serde).
3. Add a match arm in `handle_notification()` (for fire-and-forget) or `handle_request()` (for request-response).
4. If capability-gated, check `capability.your_cap` before processing.
5. Handle the returned `HostAction` in the handler/display integration code.

**How to add a new query method:**
1. Add a `HostAction` variant with `plugin_id` and `request_id`.
2. Handle it in `handle_request()`.
3. In the handler integration, serialize the query result and call `send_response()`.

### `jsonrpc.rs` — JSON-RPC 2.0 protocol

Wire protocol encode/decode. All messages are single-line JSON terminated by `\n`.

**Types:**
- `Notification` — outgoing, no id (fire-and-forget).
- `Request` — outgoing, with id (expects response).
- `SuccessResponse` / `ErrorResponse` — outgoing replies.
- `IncomingMessage` — parsed: `Request`, `Notification`, or `Response`.

**Standard error codes:**
| Code | Meaning |
|------|---------|
| -32700 | Parse error |
| -32600 | Invalid request |
| -32601 | Method not found |
| -32602 | Invalid params |
| -32603 | Internal error |

### `transport/mod.rs` — Transport abstraction

`PluginTransport` trait — the interface every transport implements:

```rust
fn spawn(&mut self, manifest, plugin_dir) -> Result<()>;
fn send(&mut self, msg: &str) -> Result<()>;
fn recv(&mut self) -> Result<Option<String>>;  // non-blocking
fn stop(&mut self) -> Result<()>;
fn is_running(&self) -> bool;
```

Factory function `create_transport(language)`:
- `"subprocess"` / `"native"` / `"python"` → `SubprocessTransport`
- `"wasm"` → `WasmTransport`
- anything else → `SubprocessTransport` (default)

**How to add a new transport:**
1. Create a struct implementing `PluginTransport`.
2. Add a match arm in `create_transport()`.
3. Consider adding a `PluginRuntime` variant in `manifest.rs` if it needs its own manifest keyword.

### `transport/subprocess.rs` — Subprocess transport

Spawns a child process with piped stdin/stdout. Non-blocking receive via `O_NONBLOCK` fcntl on Unix. Stderr redirected to `/dev/null`. Supports multi-word entry commands with arguments (e.g., `python3 plugin.py --verbose`).

The transport implements `Drop` to kill the child process on cleanup.

### `transport/wasm.rs` — WASM transport

Feature-gated (`wasm` feature). Uses wasmtime to load and run `.wasm` modules.

**Host functions exposed to WASM guest:**
- `host_send(ptr, len)` — plugin writes a message to the host (reads from WASM linear memory, pushes to outbox).
- `host_recv(ptr, len) -> i32` — plugin reads a message from the host. Returns byte count, 0 if empty, -1 if buffer too small, -2 on memory error.

The host calls `plugin_poll()` (if exported) on each `send()` for synchronous message processing. Plugins can also export `_start` or `_initialize` for one-time setup.

Without the `wasm` feature, all methods return `WasmError`.

## Writing a plugin

See `plugins/examples/README.md` for the full protocol reference, widget catalog, overlay shape list, and example plugins in Python, Node.js, Rust, and Bash.

**Quick checklist:**
1. Create a directory with a `plugin.toml` manifest.
2. Declare capabilities, commands, panels, and events.
3. Write your entry program — read JSON lines from stdin, write JSON lines to stdout.
4. Handle `lifecycle/initialize` (setup) and `lifecycle/shutdown` (cleanup).
5. Subscribe to events like `schematic_changed` to react to edits.
6. Use `state/query_instances` or `state/query_nets` to read schematic data.
7. Push UI via `panels/update_widgets`, draw on canvas via `overlay/update`.
8. Install with `schemify plugin install --from-file your-plugin.tar.gz`.
