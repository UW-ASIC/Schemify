# Writing a C++ Plugin

Schemify's C99 header (`tools/sdk/schemify_plugin.h`) is fully compatible with
C++17.  Write your plugin logic in C++, wrap the entry point in `extern "C"`,
and use the `SCHEMIFY_PLUGIN` macro as in the C SDK.  Both native (`.so`) and
WASM targets are supported.

## 1. Prerequisites

No extra toolchain is needed.  The SDK build helper uses `zig c++` under the
hood, so Zig (0.14+) is the only dependency.

## 2. Project layout

```
my-cpp-plugin/
  build.zig
  build.zig.zon
  src/
    main.cpp
```

## 3. `build.zig.zon`

```zig
.{
    .name    = .my_cpp_plugin,
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
        const lib = helper.addCppPlugin(b, ctx, sdk_dep, "MyCppPlugin", "src/main.cpp");
        b.installArtifact(lib);
        helper.addNativeAutoInstallRunStep(b, "MyCppPlugin", sdk_dep, "my-cpp-plugin");
    }

    if (ctx.is_web) {
        helper.addCppWasmPlugin(b, sdk_dep, "MyCppPlugin", "src/main.cpp");
        helper.addWasmAutoServeStep(b, sdk_dep, "MyCppPlugin", "my-cpp-plugin");
    }
}
```

`addCppPlugin` automatically:

- Compiles your source with `-std=c++17 -fvisibility=default`
- Adds `tools/sdk/` to the include path
- Links libc and libstdc++

| Build command | Result |
|---------------|--------|
| `zig build` | `zig-out/lib/libMyCppPlugin.so` |
| `zig build run` | installs + launches Schemify |
| `zig build -Dbackend=web` | `zig-out/plugins/MyCppPlugin.wasm` |
| `zig build run -Dbackend=web` | builds + serves at `localhost:8080` |

## 5. `src/main.cpp`

```cpp
/**
 * my-cpp-plugin — minimal C++ plugin example for Schemify (ABI v6).
 *
 * The process function and the SCHEMIFY_PLUGIN macro must be in extern "C"
 * to produce the correct C-ABI symbol names.
 */

#include "schemify_plugin.h"

extern "C" {

static size_t my_cpp_process(
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
                "my-cpp-plugin", 13,     /* id       */
                "My C++ Plugin", 13,     /* title    */
                "mycppplugin",   11,     /* vim_cmd  */
                SP_LAYOUT_OVERLAY,       /* layout   */
                'h');                    /* keybind  */
            sp_write_set_status(&w, "Hello from C++!", 15);
            break;

        case SP_TAG_DRAW_PANEL:
            sp_write_ui_label(&w, "Hello from C++!",        15, 0);
            sp_write_ui_label(&w, "Built with the C++ SDK.", 23, 1);
            break;

        default:
            break;
        }
    }

    return sp_writer_overflow(&w) ? (size_t)-1 : w.pos;
}

SCHEMIFY_PLUGIN("MyCppPlugin", "0.1.0", my_cpp_process)

} /* extern "C" */
```

Wrap everything in `extern "C" { ... }` to prevent C++ name mangling of the
`schemify_plugin` symbol and `schemify_process` entry point.

## 6. Using C++ features

You can use the full C++ standard library inside your plugin:

```cpp
#include "schemify_plugin.h"
#include <string>
#include <vector>
#include <algorithm>
#include <format>   // C++20

extern "C" {

static std::vector<std::string> g_items;

static size_t my_process(
    const uint8_t* in_ptr, size_t in_len,
    uint8_t*       out_ptr, size_t out_cap)
{
    SpReader r = sp_reader_init(in_ptr, in_len);
    SpWriter w = sp_writer_init(out_ptr, out_cap);
    SpMsg msg;

    while (sp_reader_next(&r, &msg)) {
        switch (msg.tag) {
        case SP_TAG_LOAD:
            g_items = {"Alpha", "Beta", "Gamma"};
            sp_write_register_panel(&w,
                "cpp-demo", 8, "C++ Demo", 8, "cppdemo", 7,
                SP_LAYOUT_RIGHT_SIDEBAR, 'd');
            break;

        case SP_TAG_DRAW_PANEL: {
            uint32_t id = 0;
            for (const auto& item : g_items) {
                sp_write_ui_label(&w, item.c_str(), item.size(), id++);
            }
            break;
        }

        case SP_TAG_UNLOAD:
            g_items.clear();
            break;

        default:
            break;
        }
    }

    return sp_writer_overflow(&w) ? (size_t)-1 : w.pos;
}

SCHEMIFY_PLUGIN("CppDemo", "0.1.0", my_process)

} /* extern "C" */
```

## 7. Complete working example

The repo ships a ready-to-build example at `plugins/examples/cpp-hello/`:

```
plugins/examples/cpp-hello/
  build.zig
  build.zig.zon
  src/
    main.cpp
```

```bash
cd plugins/examples/cpp-hello
zig build run                # install + launch
zig build run -Dbackend=web  # WASM build + serve
```

## 8. LSP / IDE setup

`clangd` needs to know the include path for `schemify_plugin.h`.  Run
`zig build` once to generate `src/compile_flags.txt`, then open your editor:

```bash
zig build
# src/compile_flags.txt now contains: -I../../../tools/sdk
```

`clangd` picks this up automatically.  `clang-tidy`, VS Code C/C++ extension,
and Neovim's `clangd` integration all work the same way.

## 9. Standalone git project

For a plugin in its own repository, replace the `.path` entry in
`build.zig.zon` with a URL dependency:

```zig
.schemify_sdk = .{
    .url  = "https://github.com/UWASIC/Schemify/archive/refs/tags/v1.0.0.tar.gz",
    .hash = "...",
},
```

Run `zig fetch --save=schemify_sdk <url>` to populate the hash automatically.

## 10. Plugin API reference

`tools/sdk/schemify_plugin.h` is the complete C/C++ API (used unchanged from
C++).  Key types:

- `SpReader` / `SpWriter` — buffer-based message IO (see `docs/plugins/c.md`
  for the full table of tags and output helpers)
- `SpMsg` — union discriminated by `.tag`; variant fields for each message type
- `SCHEMIFY_PLUGIN(name, version, process_fn)` — exports the descriptor symbol

The C API reference in `docs/plugins/c.md` applies directly to C++ plugins.
See also `docs/plugins/api.md` for the binary message protocol.

## Linking a C++ library

```zig
const lib = helper.addCppPlugin(b, ctx, sdk_dep, "MyCppPlugin", "src/main.cpp");
lib.addCSourceFile(.{ .file = b.path("src/engine.cpp"), .flags = &.{"-std=c++17"} });
lib.addIncludePath(b.path("include"));
lib.linkSystemLibrary("eigen3");
lib.linkLibCpp();
b.installArtifact(lib);
```
