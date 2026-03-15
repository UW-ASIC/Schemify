# Writing a Rust Plugin

Schemify provides a Rust crate (`tools/sdk/bindings/rust/schemify-plugin/`)
that wraps the ABI v6 message-passing protocol with idiomatic Rust.  Implement
the `Plugin` trait, use a `Writer` to emit UI commands, and the `export_plugin!`
macro generates the C-ABI entry points the host expects.  Native (`.so`) builds
are fully supported; WASM support via `cargo` + `wasm-pack` is planned.

## 1. Prerequisites

- Rust stable toolchain via `rustup` — https://rustup.rs/
- `cargo` in `PATH`
- `rust-analyzer` for IDE support (optional but recommended)
- Zig 0.14+ (only needed if you use `zig build` to drive the build)

## 2. Project layout

```
my-rust-plugin/
  Cargo.toml
  build.zig          ← optional; wraps cargo for `zig build run`
  build.zig.zon      ← optional; needed only if using zig build
  src/
    lib.rs
```

## 3. `Cargo.toml`

```toml
[package]
name    = "my-rust-plugin"
version = "0.1.0"
edition = "2021"

[lib]
crate-type = ["cdylib"]

[dependencies]
# Inside the monorepo — path dependency:
schemify-plugin = { path = "../../../../tools/sdk/bindings/rust/schemify-plugin" }

# Standalone project — published crate (when available):
# schemify-plugin = "0.1.0"
```

## 4. `src/lib.rs`

```rust
use schemify_plugin::{export_plugin, InMsg, PanelDef, PanelLayout, Plugin, Writer};

#[derive(Default)]
struct MyPlugin;

impl Plugin for MyPlugin {
    fn on_load(&mut self, w: &mut Writer) {
        w.register_panel(&PanelDef {
            id:      "my-plugin",
            title:   "My Plugin",
            vim_cmd: "myplugin",
            layout:  PanelLayout::Overlay,
            keybind: b'm',
        });
        w.set_status("My Rust plugin loaded!");
    }

    fn on_draw(&mut self, _panel_id: u16, w: &mut Writer) {
        w.label("Hello from Rust!",         0);
        w.label("Built with the Rust SDK.", 1);
    }

    fn on_event(&mut self, _ev: InMsg, _w: &mut Writer) {}
}

export_plugin!(MyPlugin, "MyPlugin", "0.1.0");
```

`export_plugin!(Type, name, version)` generates the `schemify_plugin` export
symbol and the `schemify_process` entry point.  `Type` must implement `Plugin`
and `Default`.

## 5. Building with Cargo

```bash
cargo build --release
# produces: target/release/libmy_rust_plugin.so
```

Install manually:

```bash
mkdir -p ~/.config/Schemify/MyPlugin
cp target/release/libmy_rust_plugin.so ~/.config/Schemify/MyPlugin/
```

## 6. Building with `zig build` (optional)

Add a thin `build.zig` to drive cargo and install automatically:

**`build.zig.zon`**

```zig
.{
    .name    = .my_rust_plugin,
    .version = "0.1.0",
    .minimum_zig_version = "0.14.0",
    .fingerprint = 0x<random_hex>,
    .dependencies = .{
        .schemify_sdk = .{ .path = "../../.." },
        // Standalone: replace with .url + .hash
    },
    .paths = .{ "build.zig", "build.zig.zon", "src", "Cargo.toml" },
}
```

**`build.zig`**

```zig
const std    = @import("std");
const sdk    = @import("schemify_sdk");
const helper = sdk.build_plugin_helper;

pub fn build(b: *std.Build) void {
    const sdk_dep = b.dependency("schemify_sdk", .{});
    // Runs `cargo build --release` and copies the .so to zig-out/lib/
    helper.addRustPlugin(b, ".", "my_rust_plugin");
    helper.addNativeAutoInstallRunStep(b, "MyPlugin", sdk_dep, "my-plugin");
}
```

| Build command | Result |
|---------------|--------|
| `cargo build --release` | `target/release/libmy_rust_plugin.so` |
| `zig build` | runs cargo + copies to `zig-out/lib/` |
| `zig build run` | installs + launches Schemify |

## 7. Complete working example

The repo ships a ready-to-build example at `plugins/examples/rust-hello/`:

```
plugins/examples/rust-hello/
  Cargo.toml
  build.zig
  build.zig.zon
  src/
    lib.rs
```

```bash
cd plugins/examples/rust-hello
zig build run   # cargo build --release + install + launch
# or:
cargo build --release
```

## 8. LSP / IDE setup

`rust-analyzer` works out of the box with `Cargo.toml` — open the plugin
directory in VS Code or any LSP-capable editor.  No extra configuration is
needed.

## 9. Standalone git project

For a plugin in its own repository, update `Cargo.toml` to use the published
crate once it is available on crates.io:

```toml
[dependencies]
schemify-plugin = "0.1.0"
```

If you are also using `zig build`, update `build.zig.zon` to use a URL
dependency for the SDK instead of the `.path` form:

```zig
.schemify_sdk = .{
    .url  = "https://github.com/UWASIC/Schemify/archive/refs/tags/v1.0.0.tar.gz",
    .hash = "...",
},
```

Run `zig fetch --save=schemify_sdk <url>` to populate the hash.

## 10. Plugin API reference

The crate lives at `tools/sdk/bindings/rust/schemify-plugin/src/lib.rs`.
Key items:

### `Plugin` trait

```rust
pub trait Plugin: Default {
    fn on_load(&mut self, w: &mut Writer);
    fn on_unload(&mut self, w: &mut Writer) {}
    fn on_tick(&mut self, dt: f32, w: &mut Writer) {}
    fn on_draw(&mut self, panel_id: u16, w: &mut Writer);
    fn on_event(&mut self, ev: InMsg, w: &mut Writer);
}
```

### `Writer` methods

| Method | Description |
|---|---|
| `register_panel(&PanelDef)` | Register a panel or overlay |
| `set_status(text)` | Set status bar text |
| `log(level, tag, msg)` | Structured log |
| `label(text, id)` | Text label |
| `button(text, id)` | Button (check `InMsg::ButtonClicked` in `on_event`) |
| `separator(id)` | Horizontal rule |
| `slider(val, min, max, id)` | Float slider |
| `checkbox(checked, text, id)` | Labeled checkbox |
| `progress(fraction, id)` | Progress bar (0.0–1.0) |
| `begin_row(id)` / `end_row(id)` | Horizontal layout pair |

### `PanelLayout`

```rust
pub enum PanelLayout {
    Overlay      = 0,
    LeftSidebar  = 1,
    RightSidebar = 2,
    BottomBar    = 3,
}
```

### Incoming events (`InMsg`)

Handle events in `on_event`:

```rust
fn on_event(&mut self, ev: InMsg, w: &mut Writer) {
    match ev {
        InMsg::ButtonClicked { widget_id, .. } if widget_id == 0 => {
            w.set_status("Button clicked!");
        }
        InMsg::SliderChanged { widget_id: 1, val, .. } => {
            self.threshold = val;
        }
        _ => {}
    }
}
```

See `docs/plugins/api.md` for the full binary message protocol reference.
