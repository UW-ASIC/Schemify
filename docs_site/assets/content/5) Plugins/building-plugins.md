# Building Plugins

## Zig Plugin

The simplest case — pure Zig:

**`build.zig.zon`:**
```zig
.{
    .name = "my-plugin",
    .version = "0.1.0",
    .dependencies = .{
        .schemify_sdk = .{
            .url = "https://github.com/UWASIC/Schemify/archive/<hash>.tar.gz",
            .hash = "...",
        },
    },
}
```

**`build.zig`:**
```zig
const helper = @import("schemify_sdk").build_plugin_helper;

pub fn build(b: *std.Build) void {
    const sdk_dep = b.dependency("schemify_sdk", .{});
    const ctx = helper.setup(b, sdk_dep);

    // Native shared library
    const lib = helper.addNativePluginLibrary(b, ctx, "MyPlugin", "src/main.zig");
    b.installArtifact(lib);

    // WASM module
    helper.addWasmPlugin(b, ctx, "MyPlugin", "src/main.zig");

    // Auto-install + run step
    helper.addNativeAutoInstallRunStep(b, "MyPlugin", sdk_dep, "MyPlugin");
}
```

```bash
zig build run   # builds, installs to ~/.config/Schemify/MyPlugin/, launches host
```

## C Plugin

```c
// src/main.c
#include "schemify_plugin.h"

size_t schemify_process(
    const uint8_t* in_ptr, size_t in_len,
    uint8_t* out_ptr, size_t out_cap
) {
    SchWriter w = sch_writer_init(out_ptr, out_cap);

    SchReader r = sch_reader_init(in_ptr, in_len);
    SchMsg msg;
    while (sch_reader_next(&r, &msg)) {
        if (msg.tag == SCH_MSG_LOAD) {
            sch_write_set_status(&w, "C plugin loaded", 15);
        }
    }

    return sch_writer_overflow(&w) ? SIZE_MAX : w.pos;
}

SCHEMIFY_PLUGIN_EXPORT const SchPluginDescriptor schemify_plugin = {
    .abi_version = 6,
    .name        = "CHelloPlugin",
    .version_str = "0.1.0",
    .process     = schemify_process,
};
```

**`build.zig`:**
```zig
const lib = helper.addCPlugin(b, ctx, sdk_dep, "CHelloPlugin", "src/main.c");
b.installArtifact(lib);
```

## C++ Plugin

```cpp
// src/main.cpp
#include "schemify_plugin.h"
#include <string>

extern "C" {

size_t schemify_process(
    const uint8_t* in_ptr, size_t in_len,
    uint8_t* out_ptr, size_t out_cap
) {
    // Same as C but can use C++ features
    SchWriter w = sch_writer_init(out_ptr, out_cap);
    // ...
    return sch_writer_overflow(&w) ? SIZE_MAX : w.pos;
}

SCHEMIFY_PLUGIN_EXPORT const SchPluginDescriptor schemify_plugin = {
    .abi_version = 6,
    .name        = "CppPlugin",
    .version_str = "0.1.0",
    .process     = schemify_process,
};

} // extern "C"
```

**`build.zig`:**
```zig
const lib = helper.addCppPlugin(b, ctx, sdk_dep, "CppPlugin", "src/main.cpp");
b.installArtifact(lib);
```

## Rust Plugin

Add to `Cargo.toml`:
```toml
[dependencies]
schemify-plugin = "0.6"
```

```rust
use schemify_plugin::{export_plugin, Plugin, Writer, InMsg};

struct MyPlugin;

impl Plugin for MyPlugin {
    fn process(&mut self, msgs: &[InMsg], w: &mut Writer) {
        for msg in msgs {
            match msg {
                InMsg::Load => {
                    w.set_status("Rust plugin loaded");
                }
                InMsg::DrawPanel { panel_id: _ } => {
                    w.label("Hello from Rust!", 0);
                }
                _ => {}
            }
        }
    }
}

export_plugin!(MyPlugin, "rust-plugin", "0.1.0");
```

**`build.zig`:**
```zig
helper.addRustPlugin(b, "rust/my-plugin", "my_plugin");
```

## Python Plugin

```python
# src/plugin.py
import schemify

def on_load(w):
    w.set_status("Python plugin loaded")
    w.register_panel(id="py-panel", title="Python Panel", vim_cmd="py", layout="right")

def on_draw_panel(w, panel_id):
    w.label("Hello from Python!", 0)
    w.button("Click me", 1)

def on_button_clicked(w, panel_id, widget_id):
    if widget_id == 1:
        w.set_status("Button clicked!")

schemify.run(on_load=on_load, on_draw_panel=on_draw_panel, on_button_clicked=on_button_clicked)
```

**`build.zig`:**
```zig
helper.addPythonPlugin(b, "MyPyPlugin", sdk_dep,
    &.{ "src/plugin.py" },
    null,  // no requirements.txt
    "MyPyPlugin",
);
```

Python plugins are deployed to `~/.config/Schemify/SchemifyPython/scripts/<plugin_name>/`.

## WASM Plugin (C via Emscripten)

```zig
helper.addCWasmPlugin(b, sdk_dep, "CHelloWasm", "src/main.c");
// Output: zig-out/plugins/CHelloWasm.wasm
```

## Local Development Workflow

```bash
# 1. Create plugin directory
mkdir my-plugin && cd my-plugin
zig init-lib

# 2. Add schemify_sdk dependency to build.zig.zon
# 3. Write src/main.zig
# 4. Build, install, and launch:
zig build run

# The host auto-reloads plugins when they change (native only)
```

## Plugin Installation

Users install plugins by:

1. Placing `lib<Name>.so` (or `.dylib`/`.wasm`) in `~/.config/Schemify/<Name>/`
2. Adding the plugin name to `[plugins] enabled` in `Config.toml`
3. Restarting Schemify

Or via the CLI:
```bash
schemify --plugin-install ./libMyPlugin.so
schemify --plugin-install https://example.com/plugins/MyPlugin.wasm
```
