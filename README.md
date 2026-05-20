# SchemifyRS

Schematic capture tool for circuit design. Built in Rust with egui.

## Crates

| Crate | Purpose |
|-------|---------|
| `schemify-core` | Types shared across crate boundaries (zero logic) |
| `schemify-handler` | App state + `dispatch(Command)` API |
| `schemify-io` | File I/O and format parsing |
| `schemify-display` | GUI (egui/eframe) |
| `schemify-sim` | SPICE IR and multi-dialect netlist emission |
| `schemify-plugins` | Plugin runtime with subprocess and WASM transports |

## Build

```sh
cargo build
```

With WASM plugin support:

```sh
cargo build --features schemify-plugins/wasm
```

## Run

```sh
cargo run -p schemify-display
```

## Architecture

- **Data-oriented**: SoA via `soa_derive` for hot paths, AoS where access is scalar
- **Command pattern**: Single flat `Command` enum, all undoable
- **String interning**: `lasso::Spur` internally, `String` at API boundary
- **Plugin system**: TOML manifests, capability negotiation, subprocess or WASM transport

See `docs/adr/` for architectural decision records.

## License

MIT
