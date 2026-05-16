# plugins

Extension system for Schemify. Manages plugins that communicate via JSON-RPC 2.0 (NDJSON). On native, plugins run as subprocesses over stdin/stdout pipes. On WASM, they run as Web Workers over postMessage. The transport is comptime-selected; all JSON-RPC dispatch logic is shared.

## Language

**Plugin**:
A separate process (or Web Worker) that extends Schemify through JSON-RPC 2.0 messages. Spawned at runtime, lifecycle-managed by the host. Can be written in any language (Python SDK provided in `sdk/python/`).
_Avoid_: extension (too vague), add-on, module (overloaded with Zig build modules)

**Manifest**:
A `plugin.toml` file declaring a Plugin's metadata, capabilities, run command, and activation events. Parsed at discovery time by `PluginManager`.
_Avoid_: config (overloaded with user settings), descriptor (legacy in-memory ABI struct)

**Transport**:
The communication channel between host and Plugin. Comptime-selected: `Subprocess` on native (stdin/stdout pipes), `WebWorkerTransport` on WASM (postMessage via JS host).
_Avoid_: backend (overloaded with render backend), channel

## Relationships

- A **Plugin** is described by one **Manifest**
- A **Plugin** communicates with the host via JSON-RPC 2.0 notifications and requests
- A **Plugin** may register panels (UI surfaces), respond to lifecycle hooks, and emit commands
- A **Manifest** declares capabilities that gate what the **Plugin** is allowed to do (file access, network, schematic mutation)
- `Runtime` uses a comptime-selected **Transport** (`Subprocess` or `WebWorkerTransport`) to manage plugins, send lifecycle/tick/UI notifications, and drain JSON-RPC responses each frame
- `PluginManager` discovers `plugin.toml` files and resolves run commands

## Key files

| File | Purpose |
|------|---------|
| `Runtime.zig` | Plugin lifecycle, tick dispatch, JSON-RPC message routing (transport-agnostic) |
| `subprocess.zig` | Native transport: child process spawn/kill, non-blocking stdout pipe reads |
| `webworker.zig` | WASM transport: Web Worker spawn/kill via `extern "host"` JS bridge |
| `jsonrpc.zig` | JSON-RPC 2.0 encode/decode, NDJSON framing |
| `PluginManager.zig` | Plugin discovery from `plugin.toml` files |
| `Capability.zig` | Capability flags and path validation |
| `types.zig` | Widget types, panel definitions, protocol version |
| `Manifest.zig` | TOML manifest parser |
| `lib.zig` | Module re-exports |

## Example dialogue

> **Dev:** "How does a Plugin get loaded?"
> **Domain expert:** "The PluginManager discovers `plugin.toml` files in the config directory and extracts the run command. The Runtime spawns the plugin using the comptime-selected Transport -- a subprocess on native, a Web Worker on WASM -- and sends a `lifecycle/initialize` JSON-RPC notification. From then on the host sends notifications (tick, draw_panel, UI events) and reads back JSON-RPC messages (register_panel, set_status, emit_widgets)."

> **Dev:** "How do plugins work in the browser?"
> **Domain expert:** "On WASM, the Transport is WebWorkerTransport. It calls `extern 'host'` functions implemented in `web/schemify_host.js` to spawn Web Workers, send messages via postMessage, and poll for responses. Each plugin's web bundle includes a `worker.js` that loads Pyodide and bridges postMessage to the Python SDK's stdin/stdout contract."

> **Dev:** "Can a Plugin modify the Schematic?"
> **Domain expert:** "Only if its Manifest declares the `schematic_mutate` capability. The Plugin sends a `host/push_command` notification with the command name -- it never touches the Schematic directly."
