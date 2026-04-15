# Plugin Overview

Schemify's plugin system lets you extend the editor without forking it. Plugins run as shared libraries (`.so`) on native, or as WebAssembly modules (`.wasm`) in the browser. The same source compiles to both targets.

## What Plugins Can Do

| Capability | How |
|------------|-----|
| Add a dockable panel or overlay | `w.registerPanel(...)` in `.load` |
| Set the editor status bar text | `w.setStatus(msg)` |
| Write structured log messages | `w.log(level, tag, msg)` |
| Read and write project files | `Plugin.Vfs` |
| Trigger a UI redraw | `w.requestRefresh()` |
| Place devices / wires | `w.placeDevice(...)` / `w.addWire(...)` |
| Persist per-plugin key/value state | `w.setState(key, val)` / `w.getState(key)` |
| Push commands to the host queue | `w.pushCommand(tag, payload)` |
| Register keyboard shortcuts | `w.registerKeybind(key, mods, tag)` |
| Query schematic instances and nets | `w.queryInstances()` / `w.queryNets()` |

## Plugin Lifecycle

```
Runtime                             Plugin
  │                                   │
  │── process([load msg]) ───────────►│  registers panels, sets status
  │                                   │
  │   ... per frame ...               │
  │── process([tick msg]) ───────────►│  background work, state updates
  │── process([draw_panel msg]) ──────►│  emits ui_* widget messages
  │                                   │
  │── process([unload msg]) ─────────►│  cleanup
```

Return value = bytes written to output buffer. If buffer too small → return `maxInt(usize)`, host retries with doubled buffer.

## Language Support

| Language | Mechanism |
|----------|-----------|
| **Zig** | Direct import of `PluginIF` |
| **C / C++** | `schemify_plugin.h` header + `addCPlugin` / `addCppPlugin` |
| **Rust** | `schemify-plugin` crate; `export_plugin!` macro |
| **Python** | Pure `.py` files; `addPythonPlugin` deploys them |
| **TinyGo** | `schemify` package; `RunPlugin` entry point |

The ABI boundary is a plain C `extern struct` — any language that emits C-compatible shared-library exports works.

## Deployment

| Target | Output | Install location |
|--------|--------|-----------------|
| Native (Linux) | `lib<Name>.so` | `~/.config/Schemify/<Name>/` |
| Native (macOS) | `lib<Name>.dylib` | `~/.config/Schemify/<Name>/` |
| Web (WASM) | `<Name>.wasm` | `plugins/` dir, loaded by `plugin_host.js` |

`zig build run` (via `addNativeAutoInstallRunStep`) copies the build output to the install directory and launches the host.

## Included Plugins

### EasyImport
Imports xschem `.sch`/`.sym` files, Virtuoso schematics, and TCL-based symbol libraries into Schemify's `.chn` format. Primary migration path for existing xschem projects.

```bash
# From CLI
schemify --cli import-xschem ./inverter.sch
# From UI: Plugins → EasyImport → Import XSchem File
```

### PDKLoader (Volare)
Install and switch PDKs (SKY130, GF180, IHP-SG13G2) from inside the editor. Talks to the Volare registry. Manages `$PDK` path configuration.

```
Panel: PDK Manager (right sidebar)
Commands: :pdk install sky130, :pdk switch gf180
```

### Optimizer
Bayesian optimization of circuit parameters. Given a schematic and a target metric (e.g., maximize phase margin), iteratively sweeps parameters and re-simulates.

```
Panel: Optimizer (right sidebar)
Workflow: select target metric → set param ranges → run → view convergence plot
```

### Themes
Live theme switching via JSON theme files. Overrides colors, fonts, and spacing without restarting. Ships with built-in themes: Default Light, Default Dark, Tokyonight, Gruvbox, Catppuccin.

```
Panel: Theme Switcher (overlay)
Command: :theme tokyonight
```

### GitBlame
Shows git commit info for components — who last changed each instance's properties and when. Useful for design review.

```
Hover instance → tooltip shows: "R1.value changed by alice@... 3 days ago"
```

## Minimal Plugin

```zig
const Plugin = @import("PluginIF");

export fn schemify_process(
    in_ptr:  [*]const u8, in_len:  usize,
    out_ptr: [*]u8,       out_cap: usize,
) usize {
    var r = Plugin.Reader.init(in_ptr[0..in_len]);
    var w = Plugin.Writer.init(out_ptr[0..out_cap]);

    while (r.next()) |msg| {
        switch (msg) {
            .load => {
                w.registerPanel(.{
                    .id      = "demo",
                    .title   = "Demo Panel",
                    .vim_cmd = "demo",
                    .layout  = .right_sidebar,
                    .keybind = 'd',
                });
                w.setStatus("demo plugin loaded");
            },
            .draw_panel => {
                w.label("Hello from plugin!", 0);
            },
            else => {},
        }
    }

    return if (w.overflow()) std.math.maxInt(usize) else w.pos;
}

export const schemify_plugin: Plugin.Descriptor = .{
    .name        = "demo",
    .version_str = "0.1.0",
    .process     = schemify_process,
};
```

## Plugin Examples

Language examples in `plugins/examples/`:

| Directory | Language |
|-----------|---------|
| `zig-demo/` | Zig |
| `c-demo/` | C |
| `cpp-demo/` | C++ |
| `rust-demo/` | Rust |
| `python-demo/` | Python |
| `go-demo/` | TinyGo |

Each demonstrates: message parsing, panel registration, widget drawing, state persistence.
