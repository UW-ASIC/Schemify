# Writing a C Plugin

Schemify ships a header-only C99 SDK (`tools/sdk/schemify_plugin.h`) so you can
write plugins entirely in C with no Zig source required.  The same header also
works for C++ (see `docs/plugins/cpp.md`).  Both native (`.so`) and WASM targets
are supported — the header works identically for both.

## 1. Prerequisites

No extra toolchain is needed.  The SDK build helper uses `zig cc` under the
hood, so Zig (0.14+) is the only dependency.

## 2. Project layout

```
my-c-plugin/
  build.zig
  build.zig.zon
  src/
    main.c
```

## 3. `build.zig.zon`

```zig
.{
    .name    = .my_c_plugin,
    .version = "0.1.0",
    .minimum_zig_version = "0.14.0",
    .fingerprint = 0x<random_hex>,
    .dependencies = .{
        // Inside the monorepo:
        .schemify_sdk = .{ .path = "../../.." },

        // Standalone project — replace with URL (see section 7):
        // .schemify_sdk = .{
        //     .url  = "https://github.com/UWASIC/Schemify/archive/refs/tags/v1.0.0.tar.gz",
        //     .hash = "...",
        // },
    },
    .paths = .{ "build.zig", "build.zig.zon", "src" },
}
```

## 4. `build.zig`

```zig
const std    = @import("std");
const sdk    = @import("schemify_sdk");
const helper = sdk.build_plugin_helper;

pub fn build(b: *std.Build) void {
    const sdk_dep = b.dependency("schemify_sdk", .{});
    const ctx     = helper.setup(b, sdk_dep);

    if (!ctx.is_web) {
        const lib = helper.addCPlugin(b, ctx, sdk_dep, "MyCPlugin", "src/main.c");
        b.installArtifact(lib);
        helper.addNativeAutoInstallRunStep(b, "MyCPlugin", sdk_dep, "my-c-plugin");
    }

    if (ctx.is_web) {
        helper.addCWasmPlugin(b, sdk_dep, "MyCPlugin", "src/main.c");
        helper.addWasmAutoServeStep(b, sdk_dep, "MyCPlugin", "my-c-plugin");
    }
}
```

`addCPlugin` automatically:

- Compiles your source with `-std=c11 -fvisibility=default`
- Adds `tools/sdk/` to the include path so `#include "schemify_plugin.h"` works
- Links libc

| Build command | Result |
|---------------|--------|
| `zig build` | `zig-out/lib/libMyCPlugin.so` |
| `zig build run` | installs + launches Schemify |
| `zig build -Dbackend=web` | `zig-out/plugins/MyCPlugin.wasm` |
| `zig build run -Dbackend=web` | builds + serves at `localhost:8080` |

## 5. `src/main.c`

```c
/* my-c-plugin — minimal Schemify C plugin (ABI v6) */

#include "schemify_plugin.h"

static size_t my_process(
    const uint8_t* in_ptr,  size_t in_len,
    uint8_t*       out_ptr, size_t out_cap)
{
    SpReader r = sp_reader_init(in_ptr, in_len);
    SpWriter w = sp_writer_init(out_ptr, out_cap);
    SpMsg msg;

    while (sp_reader_next(&r, &msg)) {
        switch (msg.tag) {
        case SP_TAG_LOAD:
            sp_write_register_panel(&w,
                "my-plugin", 9,          /* id       */
                "My Plugin", 9,          /* title    */
                "myplugin",  8,          /* vim_cmd  */
                SP_LAYOUT_OVERLAY,       /* layout   */
                'm');                    /* keybind  */
            sp_write_set_status(&w, "My C plugin loaded!", 19);
            break;

        case SP_TAG_DRAW_PANEL:
            sp_write_ui_label(&w, "Hello from C!",  13, 0);
            sp_write_ui_label(&w, "Built with the C SDK.", 21, 1);
            break;

        default:
            break;
        }
    }

    return sp_writer_overflow(&w) ? (size_t)-1 : w.pos;
}

SCHEMIFY_PLUGIN("MyCPlugin", "0.1.0", my_process)
```

The `SCHEMIFY_PLUGIN(name, version, process_fn)` macro exports the
`schemify_plugin` descriptor symbol that the host loads.

## 6. Complete working example

The repo ships a ready-to-build example at `plugins/examples/c-hello/`:

```
plugins/examples/c-hello/
  build.zig
  build.zig.zon
  src/
    main.c
```

```bash
cd plugins/examples/c-hello
zig build run            # install + launch
zig build run -Dbackend=web  # WASM build + serve
```

## 7. LSP / IDE setup

`clangd` needs to know the include path for `schemify_plugin.h`.  The SDK
build helper writes a `compile_flags.txt` into `src/` the first time you run
`zig build`.  Run it once before opening your editor:

```bash
zig build
# src/compile_flags.txt now contains: -I../../../tools/sdk
# (adjusted to point at the actual SDK location)
```

After that, `clangd` resolves `schemify_plugin.h` automatically in VS Code,
Neovim, and any other LSP-capable editor.

## 8. Standalone git project

For a plugin in its own repository, replace the `.path` entry in
`build.zig.zon` with a URL dependency:

```zig
.schemify_sdk = .{
    .url  = "https://github.com/UWASIC/Schemify/archive/refs/tags/v1.0.0.tar.gz",
    .hash = "...",
},
```

Run `zig fetch --save=schemify_sdk <url>` to populate the hash automatically.
The `build.zig` is unchanged.

## 9. SDK API reference

`tools/sdk/schemify_plugin.h` is the complete C API.  Key types:

### `SpReader` / `SpWriter`

All communication with the host goes through a pair of byte buffers.

```c
SpReader r = sp_reader_init(in_ptr, in_len);
SpWriter w = sp_writer_init(out_ptr, out_cap);
SpMsg msg;
while (sp_reader_next(&r, &msg)) { /* dispatch on msg.tag */ }
return sp_writer_overflow(&w) ? (size_t)-1 : w.pos;
```

### Incoming message tags

| Tag constant | When the host sends it |
|---|---|
| `SP_TAG_LOAD` | Plugin loaded for the first time |
| `SP_TAG_UNLOAD` | Plugin about to be unloaded |
| `SP_TAG_TICK` | Every frame; `msg.tick.dt` holds delta-time in seconds |
| `SP_TAG_DRAW_PANEL` | Host is drawing your panel; emit UI commands |
| `SP_TAG_BUTTON_CLICKED` | A button widget was clicked; `msg.button.widget_id` |
| `SP_TAG_SLIDER_CHANGED` | A slider moved; `msg.slider.widget_id`, `.val` |
| `SP_TAG_TEXT_CHANGED` | A text input changed |
| `SP_TAG_CHECKBOX_CHANGED` | A checkbox toggled |
| `SP_TAG_COMMAND` | A registered keybind or command was triggered |

### Output helpers

| Function | Description |
|---|---|
| `sp_write_register_panel(&w, id, id_len, title, title_len, vim_cmd, vim_cmd_len, layout, keybind)` | Register a panel |
| `sp_write_set_status(&w, msg, len)` | Set status bar text |
| `sp_write_ui_label(&w, text, len, widget_id)` | Render a label |
| `sp_write_ui_button(&w, text, len, widget_id)` | Render a button |
| `sp_write_ui_separator(&w, widget_id)` | Horizontal rule |
| `sp_write_ui_slider(&w, val, min, max, widget_id)` | Float slider |
| `sp_write_ui_checkbox(&w, checked, text, len, widget_id)` | Checkbox |
| `sp_write_ui_progress(&w, fraction, widget_id)` | Progress bar |
| `sp_write_log(&w, level, tag, tag_len, msg, msg_len)` | Structured log |

### Layout constants

| Constant | Position |
|----------|----------|
| `SP_LAYOUT_OVERLAY` | Floating overlay |
| `SP_LAYOUT_LEFT_SIDEBAR` | Left panel |
| `SP_LAYOUT_RIGHT_SIDEBAR` | Right panel |
| `SP_LAYOUT_BOTTOM_BAR` | Bottom bar |

## Linking an existing C library

Use `addCPlugin` then attach additional sources and link flags in `build.zig`:

```zig
const lib = helper.addCPlugin(b, ctx, sdk_dep, "MyCPlugin", "src/main.c");
lib.addCSourceFile(.{ .file = b.path("src/engine.c"), .flags = &.{"-O2"} });
lib.addIncludePath(b.path("include"));
lib.linkSystemLibrary("fftw3");
lib.linkLibC();
b.installArtifact(lib);
```
