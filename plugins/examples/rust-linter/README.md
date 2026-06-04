# rust-linter (example plugin)

A compiled Rust plugin demonstrating subprocess-based plugin development. It lints schematics by querying nets from the host and drawing warning markers on a canvas overlay.

## What it demonstrates

- **Subprocess communication** — stdin/stdout JSON-RPC 2.0.
- **Lifecycle handling** — responds to `lifecycle/initialize` and `lifecycle/shutdown`.
- **Event listening** — subscribes to `schematic_changed` to auto-lint on edits.
- **Requesting data** — sends `state/query_nets` requests, tracks responses by ID.
- **Commands** — registers `lint_now` with keybinding `Ctrl+Shift+L`.
- **Overlays** — draws `Marker` shapes (kind: `Warning`) at net positions.
- **Status updates** — sets status bar text via `host/set_status`.
- **Logging** — sends debug messages via `host/log`.

## Structure

```
rust-linter/
  plugin.toml       # Manifest: id, capabilities (commands + overlays), events
  Cargo.toml        # Rust package with serde + serde_json
  src/main.rs       # stdin/stdout JSON-RPC loop
```

## Building

```sh
cargo build --release
```

The manifest's `entry` points to `./target/release/rust-linter`.

## How the main loop works

1. Read a line from stdin.
2. Parse as JSON-RPC.
3. Match on method:
   - `lifecycle/initialize` → log ready, register `lint_now` command.
   - `lifecycle/shutdown` → exit.
   - `schematic_changed` → send `state/query_nets` request.
   - Response with matching ID → run lint logic on net data, push overlay.
   - `commands/dispatch` with `lint_now` → trigger manual lint.
4. Write responses/notifications to stdout.

## Using as a template

1. Copy this directory.
2. Edit `plugin.toml` — change id, name, capabilities, events.
3. Replace the lint logic with your own in `main.rs`.
4. Build and install: `schemify plugin install --from-file your-plugin.tar.gz`.
