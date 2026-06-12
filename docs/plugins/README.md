# Schemify Plugins

Plugins extend Schemify with custom panels, commands, overlays, and theme
overrides. A plugin is a subprocess that speaks JSON-RPC 2.0 over stdin/stdout.

## Quick start

```
my-plugin/
  plugin.toml       # manifest (required)
  src/main.rs       # your code
  Cargo.toml
```

Write a `plugin.toml`:

```toml
[plugin]
id = "my-plugin"
name = "My Plugin"
version = "0.1.0"
description = "What it does"
entry = "cargo run --release"

[capabilities]
panels = true
commands = true
overlays = false
theme = false
```

Write `src/main.rs`:

```rust
use schemify_plugins::sdk::{Plugin, PluginRuntime, RuntimeError};

struct MyPlugin;
impl Plugin for MyPlugin {}

fn main() -> Result<(), RuntimeError> {
    PluginRuntime::stdio().run(&mut MyPlugin)
}
```

Add `schemify-plugins` as a dependency:

```toml
[dependencies]
schemify-plugins = { path = "../../crates/plugins" }
```

That's it. Schemify discovers plugins by scanning directories for subdirs
containing `plugin.toml`.

## Docs

- [Manifest reference](manifest.md) — `plugin.toml` fields and capabilities
- [SDK reference](sdk.md) — the `Plugin` trait, `PluginRuntime` API, widget types
- [Publishing](publishing.md) — how to package and submit to the registry

## Examples

See [`plugin_examples/`](../../plugin_examples/) for working plugins:

| Example | What it shows |
|---|---|
| `hello-world` | Minimal — logs on changes, registers a command |
| `bom-panel` | Queries instances, builds a table widget in a sidebar panel |
| `drc-overlay` | Draws overlay markers, shows alerts in a bottom panel |

## First-party plugins

[`plugins/`](../../plugins/) holds the real plugins (each headed for its own
repo eventually):

| Plugin | What it does |
|---|---|
| `theme-registry` | Hot-swap themes from the tinted-theming base16/base24 registry (Catppuccin, Gruvbox, 230+); persists across restarts |
| `pdk-switcher` | One-click download/install/enable of sky130 / gf180mcu / ihp-sg13g2 from ciel-releases (ciel-compatible `$PDK_ROOT` layout), then `[pdk_switcher]` activation in Config.toml |
| `gmid-lut` | gm/Id characterization via the vendored GmIDVisualizer (ngspice sweeps): `.glut` lookup tables, SVG figures in-panel, design curves opened in the waveform viewer |
| `pdk-mapper` | Cross-PDK retargeting: source `.op` extraction → gm/Id LUT inversion (Stage A) → sim-in-the-loop refinement (Stage B) → per-device residual matrix → Apply |

`pdk-mapper` depends on PDKs installed by `pdk-switcher` and `.glut` tables
produced by `gmid-lut`. `gmid-lut` needs its vendored C++ tool built once:

```sh
cd plugins/gmid-lut/GmIDVisualizer
nix develop --command bash -c "cmake -B build -G Ninja && cmake --build build"
```
