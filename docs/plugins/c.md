# C / C++ Plugin

The recommended pattern is to keep the Schemify-facing plugin ABI in Zig
(a thin wrapper that draws dvui widgets and calls into the host) while
delegating all heavy lifting — signal processing, SPICE parsing, simulation
engines, hardware interfaces — to a C or C++ library.

## Layout

```
my-c-plugin/
  build.zig
  build.zig.zon
  plugin.toml
  src/
    main.zig          ← Zig plugin entry, draws UI
    engine.h          ← C API header
    engine.c          ← C implementation
```

## `build.zig`

```zig
const std    = @import("std");
const sdk    = @import("schemify_sdk");
const helper = sdk.build_plugin_helper;

pub fn build(b: *std.Build) void {
    const sdk_dep = b.dependency("schemify_sdk", .{});
    const ctx     = helper.setup(b, sdk_dep);

    if (!ctx.is_web) {
        const lib = helper.addNativePluginLibrary(b, ctx, "MyCPlugin", "src/main.zig");

        // Compile engine.c and link it into the same shared library
        lib.addCSourceFile(.{
            .file  = b.path("src/engine.c"),
            .flags = &.{ "-std=c11", "-O2" },
        });
        lib.addIncludePath(b.path("src"));
        lib.linkLibC();

        b.installArtifact(lib);
        helper.addNativeAutoInstallRunStep(b, "MyCPlugin", sdk_dep, "MyCPlugin");
    }
}
```

For C++ replace `"-std=c11"` with `"-std=c++17"` and call `lib.linkLibCpp()`
instead of (or in addition to) `lib.linkLibC()`.

## `src/engine.h`

```c
#pragma once
#include <stddef.h>

// Run the engine and return a null-terminated result string.
// Caller must free() the returned pointer.
char* engine_run(const char* input, size_t len);
void  engine_free(char* result);
```

## `src/engine.c`

```c
#include "engine.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

char* engine_run(const char* input, size_t len) {
    // ... heavy computation ...
    char* out = malloc(64);
    snprintf(out, 64, "processed %zu bytes", len);
    return out;
}

void engine_free(char* result) { free(result); }
```

## `src/main.zig` — calling C from Zig

```zig
const Plugin = @import("PluginIF");
const dvui   = @import("dvui");
const c      = @cImport(@cInclude("engine.h"));

export const schemify_plugin: Plugin.Descriptor = .{
    .abi_version = Plugin.ABI_VERSION,
    .name        = "my-c-plugin",
    .version_str = "0.1.0",
    .set_ctx     = Plugin.setCtx,
    .on_load     = &onLoad,
    .on_unload   = &onUnload,
    .on_tick     = null,
};

fn onLoad() callconv(.c) void {
    Plugin.setStatus("my-c-plugin loaded");
    _ = Plugin.registerOverlay(&.{
        .name     = "my-c-plugin",
        .keybind  = 'c',
        .draw_fn  = &drawPanel,
    });
}

fn onUnload() callconv(.c) void {}

fn drawPanel() callconv(.c) void {
    _ = dvui.label(@src(), "C engine result:", .{});

    const input = "hello";
    const raw = c.engine_run(input.ptr, input.len);
    if (raw) |ptr| {
        defer c.engine_free(ptr);
        const result = std.mem.span(ptr);
        _ = dvui.label(@src(), result, .{});
    }
}

const std = @import("std");
```

## Linking an existing system library

For a library already installed on the system (e.g. `libfftw3`):

```zig
lib.linkSystemLibrary("fftw3");
lib.linkLibC();
```

Zig will pass `-lfftw3` to the linker and resolve it through the system
library paths.

## Linking a prebuilt static library

If you ship a prebuilt `.a` alongside your plugin:

```zig
lib.addObjectFile(b.path("lib/libengine.a"));
lib.addIncludePath(b.path("include"));
lib.linkLibC();
```

## WASM note

C code compiles to WASM without changes as long as it avoids OS syscalls.
Replace any `open()` / `fopen()` with `Plugin.Vfs` calls in the Zig wrapper.
The build helper's `addWasmPlugin` uses `wasm32-freestanding` so `libc` is
not available; use `lib.linkLibC()` only for the native step.

```zig
if (!ctx.is_web) {
    const lib = helper.addNativePluginLibrary(b, ctx, "MyCPlugin", "src/main.zig");
    lib.addCSourceFile(.{ .file = b.path("src/engine.c"), .flags = &.{"-std=c11"} });
    lib.linkLibC();
    b.installArtifact(lib);
}
if (ctx.is_web) {
    // WASM variant: provide a Zig-only fallback or stub for the C engine
    helper.addWasmPlugin(b, ctx, "MyCPlugin", "src/main_wasm.zig");
}
```

## Rust via C FFI

Build a Rust static library with `crate-type = ["staticlib"]`, then link it
the same way as a prebuilt `.a`:

```zig
// build.zig (after running `cargo build --release` separately)
lib.addObjectFile(b.path("../my-rust-lib/target/release/libmy_rust_lib.a"));
lib.addIncludePath(b.path("../my-rust-lib/include"));
lib.linkLibC();
lib.linkLibCpp(); // Rust's stdlib requires C++ runtime on most platforms
```

Alternatively, use `b.addSystemCommand` to run `cargo build` as a build step
before linking.
