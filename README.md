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

### GUI

```sh
cargo run
```

### CLI

Pass a subcommand to run headless against a schematic file:

```sh
# Import a SPICE netlist
cargo run -- --file my_schematic.chn import-spice my_circuit.spice --save

# Place a device
cargo run -- --file my_schematic.chn place-device \
    --symbol-path resistor --name R1 --x 100 --y 200 --save

# Add a wire
cargo run -- --file my_schematic.chn add-wire \
    --x0 0 --y0 0 --x1 100 --y1 0 --save

# Transform operations
cargo run -- --file my_schematic.chn rotate-cw --save
cargo run -- --file my_schematic.chn flip-horizontal --save

# Set properties
cargo run -- --file my_schematic.chn set-instance-prop \
    --idx 0 --key value --value 10k --save

# Run simulation
cargo run -- --file my_schematic.chn run-sim

# List all commands
cargo run -- help
```

Every `Command` variant in `schemify-core` is available as a CLI subcommand.
Use `--file` to load a schematic and `--save` to write changes back.

## Architecture

- **Data-oriented**: SoA via `soa_derive` for hot paths, AoS where access is scalar
- **Command pattern**: Single flat `Command` enum, all undoable
- **String interning**: `lasso::Spur` internally, `String` at API boundary
- **Plugin system**: TOML manifests, capability negotiation, subprocess or WASM transport

See `docs/adr/` for architectural decision records.

## License

MIT
