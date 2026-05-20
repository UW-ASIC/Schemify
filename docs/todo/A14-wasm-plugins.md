# A14: WASM Plugin Transport

**Wave**: 4 (post-MVP)
**Depends on**: A6 (plugin runtime — native transport must work first)

## Goal
Add WebAssembly transport to plugin system. Plugins compiled to WASM run in-process via wasmtime/wasmer. Same JSON-RPC protocol as subprocess transport.

## Branch
`feat/wasm-plugins`

## Zig Reference Files
- `../Schemify/src/plugins/webworker.zig` — Web Worker transport (WASM context)

## Crate/File Map

### plugins (`crates/plugins/src/`)
- NEW `transport/mod.rs` — trait `PluginTransport` (shared by subprocess + WASM)
- REFACTOR `runtime.rs` — extract transport trait, subprocess becomes one impl
- NEW `transport/subprocess.rs` — extracted from runtime.rs
- NEW `transport/wasm.rs` — wasmtime-based WASM execution

## Transport Trait

```rust
pub trait PluginTransport {
    fn spawn(&mut self, manifest: &PluginManifest) -> Result<(), PluginError>;
    fn send(&mut self, msg: &JsonRpcMessage) -> Result<(), PluginError>;
    fn recv(&mut self) -> Result<Option<JsonRpcMessage>, PluginError>;
    fn stop(&mut self) -> Result<(), PluginError>;
    fn is_running(&self) -> bool;
}
```

Subprocess and WASM both implement this. Runtime selects based on manifest `language` field.

## Potential Deps
```toml
wasmtime = "22"  # or wasmer = "4"
```

## Checklist
- [ ] Extract `PluginTransport` trait from existing runtime
- [ ] Refactor subprocess into `transport/subprocess.rs` implementing trait
- [ ] `transport/wasm.rs`: load .wasm module via wasmtime
- [ ] WASM host functions: expose JSON-RPC send/recv to guest
- [ ] WASM memory management: shared buffer for message passing
- [ ] Manifest: `language = "wasm"` selects WASM transport
- [ ] Tests: load simple WASM plugin, send initialize, get response
- [ ] Tests: WASM plugin registers panel via JSON-RPC
- [ ] Commit after each meaningful change

## Do NOT Touch
- `core/src/plugin_types.rs` — types are transport-agnostic
- `plugins/src/jsonrpc.rs` — protocol is transport-agnostic
- `plugins/src/host.rs` — host callbacks are transport-agnostic
- `display/` — not your crate
