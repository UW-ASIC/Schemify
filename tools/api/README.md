# Schemify Plugin API

Language-native bindings for the Schemify plugin protocol (ABI v6).
Each language folder is **self-contained** — no `build.zig.zon` or Zig toolchain required.

Exposes `dvui.HTML` rendering (via UI widget protocol) and `dvui.fs` style state
access (via `get_state` / `set_state` messages).

---

## Languages

| Language       | Folder       | Build system          | Output          |
|----------------|--------------|-----------------------|-----------------|
| **C**          | `c/`         | `make` / CMake        | `.so` / `.wasm` |
| **C++**        | `cpp/`       | `make` / CMake        | `.so` / `.wasm` |
| **Zig**        | `zig/`       | `zig build` (no .zon) | `.so` / `.wasm` |
| **Rust**       | `rust/`      | `cargo build`         | `.so` / `.wasm` |
| **Python**     | `python/`    | subprocess (Bun host) | `.py`           |
| **TypeScript** | `js_w_bun/`  | `bun build`           | subprocess      |
| **Go/TinyGo**  | `tinygo/`    | `go build` / `tinygo` | `.so` / `.wasm` |

---

## Quick start — C

```c
#include "lib.h"   // copy from c/inc/lib.h

static size_t my_process(const uint8_t* in, size_t in_len,
                          uint8_t* out, size_t out_cap) {
    SpReader r = sp_reader_init(in, in_len);
    SpWriter w = sp_writer_init(out, out_cap);
    SpMsg msg;
    while (sp_reader_next(&r, &msg)) {
        switch (msg.tag) {
        case SP_TAG_LOAD:
            sp_write_register_panel(&w, "hello", 5, "Hello", 5, "hello", 5,
                                    SP_LAYOUT_LEFT_SIDEBAR, 0);
            break;
        case SP_TAG_DRAW_PANEL:
            sp_write_ui_label(&w, "Hello World", 11, 1);
            break;
        }
    }
    return sp_writer_overflow(&w) ? (size_t)-1 : w.pos;
}
SCHEMIFY_PLUGIN("my-plugin", "0.1.0", my_process)
```

```sh
make -f tools/api/c/Makefile PLUGIN_SRC=src/plugin.c PLUGIN_NAME=my_plugin
```

---

## Quick start — Zig

```zig
// Copy tools/api/zig/src/lib.zig as "schemify.zig" — no .zon needed.
const sp = @import("schemify.zig");

fn process(in: []const u8, out: []u8) usize {
    var r = sp.Reader.init(in);
    var w = sp.Writer.init(out);
    while (r.next()) |msg| {
        switch (msg) {
            .load => w.registerPanel("hello", "Hello", "hello", .left_sidebar, 0),
            .draw_panel => w.label("Hello from Zig!", 1),
            else => {},
        }
    }
    return w.finish() catch ~@as(usize, 0);
}

export const schemify_plugin = sp.descriptor("my-plugin", "0.1.0", process);
```

```sh
zig build            # .so
zig build -Dbackend=web   # .wasm
```

---

## Quick start — Rust

```rust
use schemify::{Plugin, Writer, Layout};   // copy tools/api/rust/src/lib.rs

#[derive(Default)]
struct MyPlugin;
impl Plugin for MyPlugin {
    fn on_load(&mut self, w: &mut Writer) {
        w.register_panel(b"hello", b"Hello", b"hello", Layout::LeftSidebar, 0);
    }
    fn on_draw_panel(&mut self, _: u16, w: &mut Writer) { w.label(b"Hello from Rust!", 1); }
}
schemify::export_plugin!("my-plugin", "0.1.0", MyPlugin);
```

---

## Quick start — Python (subprocess)

```python
from schemify_plugin import Plugin, Writer, Layout, run   # copy src/lib.py

class MyPlugin(Plugin):
    def on_load(self, w): w.register_panel("hello", "Hello", "hello", Layout.LEFT_SIDEBAR)
    def on_draw_panel(self, _, w): w.label("Hello from Python!", 1)

if __name__ == "__main__":
    run(MyPlugin())
```

---

## Quick start — TypeScript (Bun)

```typescript
import { Plugin, Writer, Layout, run } from "./lib";   // copy src/lib.ts

class MyPlugin extends Plugin {
    onLoad(w: Writer) { w.registerPanel("hello", "Hello", "hello", Layout.LeftSidebar); }
    onDrawPanel(_: number, w: Writer) { w.label("Hello from TypeScript!", 1); }
}
run(new MyPlugin());
```

---

## Protocol

Binary message-passing over a shared buffer.  Every plugin exports:

```c
const SchemifyDescriptor schemify_plugin = {
    .abi_version = 6,
    .name        = "my-plugin",
    .version_str = "0.1.0",
    .process     = my_process_fn,
};
```

Full format documented in `c/inc/lib.h` (header-only, self-contained C99).
