# Writing a Zig Plugin

This guide walks through creating a complete Zig plugin from scratch — from
the initial `build.zig.zon` to a rendered panel in the editor.

## 1. Project layout

```
my-plugin/
  build.zig
  build.zig.zon
  plugin.toml
  src/
    main.zig
```

## 2. `build.zig.zon` — single dependency

```zig
.{
    .name    = .my_plugin,
    .version = "0.1.0",
    .dependencies = .{
        // For an external (published) SDK:
        .schemify_sdk = .{
            .url  = "https://github.com/UWASIC/Schemify/archive/<COMMIT>.tar.gz",
            .hash = "<hash from zig fetch>",
        },
        // Or, when working inside the Schemify monorepo:
        // .schemify_sdk = .{ .path = "../.." },
    },
    .paths = .{ "build.zig", "build.zig.zon", "plugin.toml", "src" },
}
```

Run `zig fetch --save=schemify_sdk <url>` once to fill in the hash.

## 3. `build.zig` — two lines of SDK

```zig
const std    = @import("std");
const sdk    = @import("schemify_sdk");   // imports Schemify's build.zig
const helper = sdk.build_plugin_helper;

pub fn build(b: *std.Build) void {
    const sdk_dep = b.dependency("schemify_sdk", .{});
    const ctx     = helper.setup(b, sdk_dep);

    // ── Native .so ──────────────────────────────────────────────────────── //

    if (!ctx.is_web) {
        const lib = helper.addNativePluginLibrary(b, ctx, "MyPlugin", "src/main.zig");
        b.installArtifact(lib);

        // Copies .so to ~/.config/Schemify/MyPlugin/ and runs `zig build run`
        // in the host repo:
        helper.addNativeAutoInstallRunStep(b, "MyPlugin", sdk_dep, "MyPlugin");
    }

    // ── Web .wasm ───────────────────────────────────────────────────────── //

    if (ctx.is_web) {
        helper.addWasmPlugin(b, ctx, "MyPlugin", "src/main.zig");
    }
}
```

| Build command | Result |
|---------------|--------|
| `zig build` | `zig-out/lib/libMyPlugin.so` |
| `zig build run` | installs + launches Schemify |
| `zig build -Dbackend=web` | `zig-out/plugins/MyPlugin.wasm` |

## 4. `src/main.zig` — minimal plugin

```zig
const std    = @import("std");
const Plugin = @import("PluginIF");

// ── Plugin descriptor ───────────────────────────────────────────────────── //

export const schemify_plugin: Plugin.Descriptor = .{
    .abi_version = Plugin.ABI_VERSION,
    .name        = "my-plugin",
    .version_str = "0.1.0",
    .set_ctx     = Plugin.setCtx,   // always this; the SDK provides it
    .on_load     = &onLoad,
    .on_unload   = &onUnload,
    .on_tick     = null,            // set to &onTick if you need per-frame work
};

// ── Lifecycle ───────────────────────────────────────────────────────────── //

fn onLoad() callconv(.c) void {
    Plugin.setStatus("my-plugin loaded");
    Plugin.logInfo("my-plugin", "onLoad");

    // Register a panel that appears as a sidebar tab
    _ = Plugin.registerPanel(&.{
        .id       = "my-plugin",
        .title    = "My Plugin",
        .vim_cmd  = "my-plugin",
        .layout   = .right_sidebar,
        .keybind  = 'm',
        .draw_fn  = &drawPanel,
    });
}

fn onUnload() callconv(.c) void {
    Plugin.logInfo("my-plugin", "onUnload");
}

// ── Panel draw callback ─────────────────────────────────────────────────── //
//
// The host passes a `*const Plugin.UiCtx` each frame.  Call widgets through
// it — do NOT import dvui directly (the host and plugin compile separate
// static copies of dvui; sharing its internal state leads to crashes).
//
// Every `id` argument must be unique within a single frame for your panel.
// A simple sequential constant works well.

fn drawPanel(ctx: *const Plugin.UiCtx) callconv(.c) void {
    const alloc = Plugin.allocator();

    // Show the current project directory in the status bar
    var dir_buf: [512]u8 = undefined;
    const project = Plugin.getProjectDir(&dir_buf);
    Plugin.setStatus(project);

    ctx.label("Hello from my-plugin!", 21, 0);
    ctx.separator(1);

    // Read a file from the project using the platform-agnostic VFS
    if (Plugin.Vfs.readAlloc(alloc, "myconfig.toml") catch null) |d| {
        defer alloc.free(d);
        ctx.label(d.ptr, @intCast(d.len), 2);
    }
}
```

## 5. `plugin.toml`

```toml
[plugin]
name        = "my-plugin"
version     = "0.1.0"
author      = "Your Name"
description = "Minimal example plugin."
entry       = "libMyPlugin.so"
```

## Receiving per-frame updates

Set `.on_tick = &onTick` in your `Descriptor` to receive a delta-time callback
every frame:

```zig
var elapsed: f32 = 0;

fn onTick(dt: f32) callconv(.c) void {
    elapsed += dt;
    if (elapsed > 5.0) {
        elapsed = 0;
        Plugin.requestRefresh(); // trigger a UI redraw
    }
}
```

## Using the host allocator

`Plugin.allocator()` returns a `std.mem.Allocator` backed by the host's heap.
You can use it for any allocation that the plugin needs:

```zig
const alloc = Plugin.allocator();
const buf   = try alloc.alloc(u8, 1024);
defer alloc.free(buf);
```

On WASM this returns `std.heap.wasm_allocator` automatically — no special
handling needed for dual-target builds.
