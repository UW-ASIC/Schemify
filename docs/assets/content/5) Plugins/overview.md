# Plugin Overview

Schemify's plugin system lets you extend the editor without forking it. Plugins run as shared libraries (`.so`) on native, or as WebAssembly modules (`.wasm`) in the browser. The same source compiles to both targets.

## What Plugins Can Do

| Capability | How |
|------------|-----|
| Add a dockable panel or overlay | `w.registerPanel(...)` in `.load` |
| Set the editor status bar text | `w.setStatus(msg)` |
| Write structured log messages | `w.log(level, tag, msg)` |
| Trigger a UI redraw | `w.requestRefresh()` |
| Place devices / wires | `w.placeDevice(...)` / `w.addWire(...)` |
| Persist per-plugin key/value state | `w.setState(key, val)` / `w.getState(key)` |
| Push commands to the host queue | `w.pushCommand(tag, payload)` |
| Register keyboard shortcuts | `w.registerKeybind(key, mods, tag)` |
| Query schematic instances and nets | `w.queryInstances()` / `w.queryNets()` |
| Read/write files (platform-agnostic) | `w.fileReadRequest(path)` / `w.fileWrite(path, data)` |

## Plugin Lifecycle

```
Runtime                             Plugin
  |                                   |
  |-- process([load msg]) ----------->|  registers panels, sets status
  |                                   |
  |   ... per frame ...               |
  |-- process([tick msg]) ----------->|  background work, state updates
  |-- process([draw_panel msg]) ----->|  emits ui_* widget messages
  |                                   |
  |-- process([unload msg]) --------->|  cleanup
```

Return value = bytes written to output buffer. If buffer too small, return `maxInt(usize)` — host retries with doubled buffer.

## Language Support

Every language uses its **own native build system**. No Zig toolchain required (except for Zig plugins). The plugin SDK is a single header/module you copy into your project.

| Language | Build System | SDK File | Output |
|----------|-------------|----------|--------|
| **Zig** | `zig build` | `lib.zig` | `.so` / `.wasm` |
| **C** | `make` / CMake | `lib.h` (header-only) | `.so` / `.wasm` |
| **C++** | `make` / CMake | `lib.h` (C++ wrapper) | `.so` / `.wasm` |
| **Rust** | `cargo build` | `lib.rs` crate | `.so` / `.wasm` |
| **Python** | subprocess | `lib.py` | `.py` (stdin/stdout) |
| **TypeScript** | `bun run` | `lib.ts` | subprocess (Bun) |
| **Go/TinyGo** | `go build` / `tinygo` | `schemify.go` | `.so` / `.wasm` |

The ABI boundary is a plain C `extern struct` — any language that emits C-compatible shared-library exports works.

SDK bindings live in `tools/api/<language>/`. Copy the SDK file into your project and build with your language's toolchain.

## Virtual Filesystem (DVUI.fs)

Plugins don't access the disk directly. Instead, Schemify passes a **DVUI.fs** handle that abstracts the filesystem — the same code works on native (real disk) and web (browser virtual FS / IndexedDB).

Use the file request/response protocol:
- **Write:** `w.fileWrite("config.toml", data)` — fire-and-forget
- **Read:** `w.fileReadRequest("config.toml")` — response arrives next tick as `.file_response { .path, .data }`

This ensures plugins are portable across all targets without `#ifdef` or conditional compilation.

## Plugin Logo

Each plugin can provide a `logo.svg` file in its root directory. The logo is referenced in `registry.json` via the `logo_url` field and displayed in the docs-site marketplace listing. Inside the editor, the marketplace panel shows a colored accent square as a placeholder since dvui cannot render SVGs at runtime.

## Deployment

| Target | Output | Install location |
|--------|--------|-----------------|
| Native (Linux) | `<Name>.so` | `~/.config/Schemify/<Name>/` |
| Native (macOS) | `<Name>.dylib` | `~/.config/Schemify/<Name>/` |
| Web (WASM) | `<Name>.wasm` | `plugins/` dir, loaded by `plugin_host.js` |

## Included Plugins

### EasyImport
Imports xschem `.sch`/`.sym` files, Virtuoso schematics, and TCL-based symbol libraries into Schemify's `.chn` format. Primary migration path for existing xschem projects.

```bash
# From CLI
schemify --cli import-xschem ./inverter.sch
# From UI: Plugins > EasyImport > Import XSchem File
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
Workflow: select target metric > set param ranges > run > view convergence plot
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
Hover instance > tooltip shows: "R1.value changed by alice@... 3 days ago"
```

## Minimal Plugin (Zig)

```zig
const sp = @import("schemify");

fn process(in: []const u8, out: []u8) usize {
    var r = sp.Reader.init(in);
    var w = sp.Writer.init(out);

    while (r.next()) |msg| {
        switch (msg) {
            .load => {
                w.registerPanel("demo", "Demo Panel", "demo", .right_sidebar, 'd');
                w.setStatus("demo plugin loaded");
            },
            .draw_panel => w.label("Hello from plugin!", 0),
            else => {},
        }
    }

    return w.finish() catch ~@as(usize, 0);
}

export const schemify_plugin = sp.descriptor("demo", "0.1.0", process);
```

```sh
zig build            # native .so
zig build -Dbackend=web   # .wasm
```

## Minimal Plugin (C)

```c
#include "lib.h"

static size_t my_process(const uint8_t* in, size_t in_len,
                          uint8_t* out, size_t out_cap) {
    SpReader r = sp_reader_init(in, in_len);
    SpWriter w = sp_writer_init(out, out_cap);
    SpMsg msg;
    while (sp_reader_next(&r, &msg)) {
        switch (msg.tag) {
        case SP_TAG_LOAD:
            sp_write_register_panel(&w, "demo", 4, "Demo Panel", 10,
                                    "demo", 4, SP_LAYOUT_RIGHT_SIDEBAR, 'd');
            break;
        case SP_TAG_DRAW_PANEL:
            sp_write_ui_label(&w, "Hello from plugin!", 18, 0);
            break;
        }
    }
    return sp_writer_overflow(&w) ? (size_t)-1 : w.pos;
}
SCHEMIFY_PLUGIN("demo", "0.1.0", my_process)
```

```sh
make native   # .so
make web      # .wasm
```

## Plugin Examples

Language examples in `plugins/examples/`:

| Directory | Language | Build |
|-----------|---------|-------|
| `zig-demo/` | Zig | `zig build` |
| `c-demo/` | C | `make` |
| `cpp-demo/` | C++ | `make` |
| `rust-demo/` | Rust | `cargo build --release` |
| `python-demo/` | Python | `python plugin.py` |
| `go-demo/` | Go | `make` (CGo / TinyGo) |

Each demonstrates: message parsing, panel registration, widget drawing, state persistence.
