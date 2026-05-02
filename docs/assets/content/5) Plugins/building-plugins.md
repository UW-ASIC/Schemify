# Building Plugins

Each language uses its **own build system**. No Zig toolchain required (except for Zig plugins). The plugin SDK for each language is a single file you copy into your project — no package manager needed.

SDK bindings: `tools/api/<language>/`

## Zig Plugin

Copy `tools/api/zig/src/lib.zig` as `schemify.zig` next to your build.zig — no `.zon` needed.

**`src/plugin.zig`:**
```zig
const sp = @import("schemify");

var slider_val: f32 = 0.5;

fn process(in: []const u8, out: []u8) usize {
    var r = sp.Reader.init(in);
    var w = sp.Writer.init(out);
    while (r.next()) |msg| {
        switch (msg) {
            .load => {
                w.registerPanel("my-panel", "My Panel", "mp", .right_sidebar, 0);
                w.setStatus("plugin loaded");
            },
            .draw_panel => {
                w.label("Threshold:", 0);
                w.slider(slider_val, 0.0, 1.0, 1);
                w.button("Apply", 2);
            },
            .slider_changed => |ev| {
                if (ev.widget_id == 1) slider_val = ev.val;
            },
            else => {},
        }
    }
    return w.finish() catch ~@as(usize, 0);
}

export const schemify_plugin = sp.descriptor("my-plugin", "0.1.0", process);
```

**`build.zig`:**
```zig
const std = @import("std");
const Backend = enum { native, web };

pub fn build(b: *std.Build) void {
    const backend  = b.option(Backend, "backend", "native or web") orelse .native;
    const optimize = b.standardOptimizeOption(.{});
    const sdk = b.createModule(.{ .root_source_file = b.path("schemify.zig") });

    if (backend == .native) {
        const target = b.standardTargetOptions(.{});
        const lib = b.addLibrary(.{
            .name = "plugin",
            .linkage = .dynamic,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/plugin.zig"),
                .target           = target,
                .optimize         = optimize,
            }),
        });
        lib.root_module.addImport("schemify", sdk);
        b.installArtifact(lib);
    } else {
        const wasm_target = b.resolveTargetQuery(.{
            .cpu_arch = .wasm32, .os_tag = .freestanding,
        });
        const wasm = b.addExecutable(.{
            .name = "plugin",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/plugin.zig"),
                .target           = wasm_target,
                .optimize         = optimize,
            }),
        });
        wasm.entry    = .disabled;
        wasm.rdynamic = true;
        wasm.root_module.addImport("schemify", sdk);
        const install = b.addInstallArtifact(wasm, .{
            .dest_dir = .{ .override = .{ .custom = "plugins" } },
        });
        b.getInstallStep().dependOn(&install.step);
    }
}
```

```bash
zig build                  # native .so
zig build -Dbackend=web    # .wasm
```

## C Plugin

Copy `tools/api/c/inc/lib.h` into your project. Header-only, C99, no dependencies.

**`src/plugin.c`:**
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
            sp_write_register_panel(&w, "hello", 5, "Hello", 5,
                                    "hello", 5, SP_LAYOUT_LEFT_SIDEBAR, 0);
            sp_write_set_status(&w, "C plugin loaded", 15);
            break;
        case SP_TAG_DRAW_PANEL:
            sp_write_ui_label(&w, "Hello from C!", 13, 0);
            break;
        default: break;
        }
    }
    return sp_writer_overflow(&w) ? (size_t)-1 : w.pos;
}
SCHEMIFY_PLUGIN("my-plugin", "0.1.0", my_process)
```

Build with `make` (using the provided Makefile) or raw compiler commands:

```bash
# Using the SDK Makefile:
make -f tools/api/c/Makefile PLUGIN_SRC=src/plugin.c PLUGIN_NAME=my_plugin

# Or directly:
cc -std=c99 -shared -fPIC -Itools/api/c/inc -o plugin.so src/plugin.c

# WASM:
clang --target=wasm32 --no-standard-libraries \
      -Wl,--export-dynamic -Wl,--no-entry -Wl,--allow-undefined \
      -Itools/api/c/inc -o plugin.wasm src/plugin.c
```

CMake is also supported — see `tools/api/c/CMakeLists.txt`.

## C++ Plugin

Two headers: copy `tools/api/cpp/inc/lib.h` (C++17 wrapper) and `tools/api/c/inc/lib.h` (rename to `schemify_c.h` — the C++ wrapper includes it).

**`src/plugin.cpp`:**
```cpp
#include "lib.h"   // C++ wrapper — includes schemify_c.h internally

class MyPlugin : public schemify::Plugin {
    void onLoad(schemify::Writer& w) override {
        w.registerPanel("hello", "Hello", "hello", SP_LAYOUT_LEFT_SIDEBAR);
        w.setStatus("C++ plugin loaded");
    }
    void onDrawPanel(uint16_t, schemify::Writer& w) override {
        w.label("Hello from C++!", 1);
    }
};
static MyPlugin g_plugin;
SCHEMIFY_PLUGIN_CPP("my-plugin", "0.1.0", g_plugin)
```

Or use the raw C API directly (same as C, but with C++ features):

```bash
# Using the SDK Makefile:
make -f tools/api/cpp/Makefile PLUGIN_SRC=src/plugin.cpp PLUGIN_NAME=my_plugin

# Or directly:
c++ -std=c++17 -shared -fPIC -fvisibility=hidden \
    -Itools/api/cpp/inc -Itools/api/c/inc -o plugin.so src/plugin.cpp
```

## Rust Plugin

Copy `tools/api/rust/src/lib.rs` into your project, or add it as a path/crate dependency. Pure Rust, `no_std`, zero external crates.

**`Cargo.toml`:**
```toml
[package]
name    = "my-plugin"
version = "0.1.0"
edition = "2021"

[lib]
crate-type = ["cdylib"]

[dependencies]
schemify = { path = "path/to/tools/api/rust", package = "schemify-plugin" }

[profile.release]
opt-level = "s"
lto       = true
panic     = "abort"
```

**`src/lib.rs`:**
```rust
use schemify::{Plugin, Writer, Layout};

#[derive(Default)]
struct MyPlugin;

impl Plugin for MyPlugin {
    fn on_load(&mut self, w: &mut Writer) {
        w.register_panel(b"hello", b"Hello", b"hello", Layout::LeftSidebar, 0);
        w.set_status(b"Rust plugin loaded");
    }
    fn on_draw_panel(&mut self, _panel_id: u16, w: &mut Writer) {
        w.label(b"Hello from Rust!", 1);
    }
}

schemify::export_plugin!("my-plugin", "0.1.0", MyPlugin);
```

```bash
cargo build --release              # native .so in target/release/
cargo build --release --target wasm32-unknown-unknown  # .wasm
```

## Python Plugin (subprocess)

Copy `tools/api/python/src/lib.py` as `schemify_plugin.py`. Pure Python, stdlib only.

**`plugin.py`:**
```python
from schemify_plugin import Plugin, Writer, Layout, run

class MyPlugin(Plugin):
    def on_load(self, w: Writer) -> None:
        w.register_panel("hello", "Hello", "hello", Layout.LEFT_SIDEBAR)
        w.set_status("Python plugin loaded")

    def on_draw_panel(self, panel_id: int, w: Writer) -> None:
        w.label("Hello from Python!", 1)

if __name__ == "__main__":
    run(MyPlugin())
```

Python plugins communicate via stdin/stdout binary frames. The host spawns the Python process and exchanges messages through pipes.

```bash
python plugin.py   # started by host automatically
```

## TypeScript Plugin (Bun subprocess)

Copy `tools/api/js_w_bun/src/lib.ts`. Requires Bun runtime.

**`plugin.ts`:**
```typescript
import { Plugin, Writer, Layout, run } from "./lib";

class MyPlugin extends Plugin {
    onLoad(w: Writer) {
        w.registerPanel("hello", "Hello", "hello", Layout.LeftSidebar);
        w.setStatus("TypeScript plugin loaded");
    }
    onDrawPanel(_panelId: number, w: Writer) {
        w.label("Hello from TypeScript!", 1);
    }
}

run(new MyPlugin());
```

```bash
bun run plugin.ts   # started by host automatically
```

## Go / TinyGo Plugin

Copy `tools/api/tinygo/schemify.go` into a local `schemify/` package (or use `go.mod` replace).

**`plugin.go`:**
```go
package main

import "schemify"

type MyPlugin struct{}

func (p *MyPlugin) OnLoad(w *schemify.WriterBuf) {
    w.RegisterPanel("hello", "Hello", "hello", schemify.LayoutLeftSidebar, 0)
    w.SetStatus("Go plugin loaded")
}
func (p *MyPlugin) OnDrawPanel(_ uint16, w *schemify.WriterBuf) {
    w.Label("Hello from Go!", 1)
}
// ... implement remaining PluginHandler methods as no-ops ...

var plugin MyPlugin

//export schemify_process
func schemify_process(inPtr *byte, inLen uint, outPtr *byte, outCap uint) uint {
    return schemify.Process(&plugin, inPtr, inLen, outPtr, outCap)
}

func main() {}
```

```bash
# Native .so (CGo):
CGO_ENABLED=1 go build -buildmode=c-shared -o plugin.so .

# WASM (TinyGo):
tinygo build -o plugin.wasm -target wasm .
```

## Virtual Filesystem (DVUI.fs)

Plugins never access the disk directly. Schemify provides a **DVUI.fs** handle that abstracts filesystem access — same code runs on native (real disk) and web (IndexedDB / virtual FS).

```zig
// Read a file (async — .file_response arrives next tick)
w.fileReadRequest("pdk/sky130A/libs.ref/index.json");

// Write a file (fire-and-forget)
w.fileWrite("cache/result.json", json_bytes);
```

**C:**
```c
// Not yet exposed in C header — use setState/getState for key-value persistence.
```

**Rust / Python / Go:** Use the equivalent `file_read_request` / `file_write` methods on the Writer.

This ensures all plugins are portable across native and WASM without `#ifdef` or platform checks.

## Plugin Installation

Users install plugins by:

1. Placing `<Name>.so` (or `.dylib`/`.wasm`) in `~/.config/Schemify/<Name>/`
2. Adding the plugin name to `[plugins] enabled` in `Config.toml`
3. Restarting Schemify

Or via the CLI:
```bash
schemify --plugin-install ./my_plugin.so
schemify --plugin-install https://example.com/plugins/MyPlugin.wasm
```

## Local Development Workflow

```bash
# 1. Create plugin directory
mkdir my-plugin && cd my-plugin

# 2. Copy the SDK file for your language from tools/api/<lang>/
#    e.g., cp tools/api/c/inc/lib.h .

# 3. Write your plugin source

# 4. Build with your language's toolchain:
make                          # C / C++
zig build                     # Zig
cargo build --release         # Rust
# Python / TS: no build step

# 5. Install:
cp plugin.so ~/.config/Schemify/my-plugin/

# The host auto-reloads plugins when they change (native only).
```
