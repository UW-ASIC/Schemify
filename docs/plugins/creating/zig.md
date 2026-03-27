# Writing a Zig Plugin

This guide walks through creating a complete Zig plugin from scratch — from
`build.zig.zon` to a rendered panel in the editor.  Zig is the first-class
plugin language: the plugin interface is defined in Zig and all host internals
are written in Zig.  Both native (`.so`) and WASM targets are supported from
a single source file.

## 1. Prerequisites

- Zig 0.14 or later — https://ziglang.org/download/
- `zls` for IDE support (optional but recommended)

## 2. Project layout

```
my-plugin/
  build.zig
  build.zig.zon
  src/
    main.zig
```

## 3. `build.zig.zon` — single dependency

```zig
.{
    .name    = .my_plugin,
    .version = "0.1.0",
    .minimum_zig_version = "0.14.0",
    .fingerprint = 0x<random_hex>,
    .dependencies = .{
        // Inside the Schemify monorepo (examples use this form):
        .schemify_sdk = .{ .path = "../../.." },

        // For a standalone project outside the monorepo, replace the path
        // with a URL dependency (see section 7):
        // .schemify_sdk = .{
        //     .url  = "https://github.com/UWASIC/Schemify/archive/refs/tags/v1.0.0.tar.gz",
        //     .hash = "...",
        // },
    },
    .paths = .{ "build.zig", "build.zig.zon", "src" },
}
```

Run `zig fetch --save=schemify_sdk <url>` once to populate the hash for a URL
dependency.

## 4. `build.zig`

```zig
const std    = @import("std");
const sdk    = @import("schemify_sdk");
const helper = sdk.build_plugin_helper;

pub fn build(b: *std.Build) void {
    const sdk_dep = b.dependency("schemify_sdk", .{});
    const ctx     = helper.setup(b, sdk_dep);

    // ── Native .so ──────────────────────────────────────────────────────── //

    if (!ctx.is_web) {
        const lib = helper.addNativePluginLibrary(b, ctx, "MyPlugin", "src/main.zig");
        b.installArtifact(lib);

        // Copies .so to ~/.config/Schemify/MyPlugin/ then launches Schemify:
        helper.addNativeAutoInstallRunStep(b, "MyPlugin", sdk_dep, "my-plugin");
    }

    // ── WASM .wasm ──────────────────────────────────────────────────────── //

    if (ctx.is_web) {
        helper.addWasmPlugin(b, ctx, "MyPlugin", "src/main.zig");
        helper.addWasmAutoServeStep(b, sdk_dep, "MyPlugin", "my-plugin");
    }
}
```

| Build command | Result |
|---------------|--------|
| `zig build` | `zig-out/lib/libMyPlugin.so` |
| `zig build run` | installs + launches Schemify |
| `zig build -Dbackend=web` | `zig-out/plugins/MyPlugin.wasm` |
| `zig build run -Dbackend=web` | builds + serves at `localhost:8080` |

## 5. `src/main.zig` — minimal plugin

```zig
const std    = @import("std");
const Plugin = @import("PluginIF");

// ── Plugin descriptor ───────────────────────────────────────────────────── //

export const schemify_plugin: Plugin.Descriptor = .{
    .name        = "MyPlugin",
    .version_str = "0.1.0",
    .process     = schemify_process,
};

// ── Entry point — called by the host for every lifecycle event ──────────── //
//
// The host sends messages in `in_ptr[0..in_len]` and reads responses from
// `out_ptr[0..out_cap]`.  Use Plugin.Reader to iterate incoming messages and
// Plugin.Writer to emit responses.  Return the number of bytes written, or
// std.math.maxInt(usize) on buffer overflow.

export fn schemify_process(
    in_ptr:  [*]const u8,
    in_len:  usize,
    out_ptr: [*]u8,
    out_cap: usize,
) usize {
    var r = Plugin.Reader.init(in_ptr[0..in_len]);
    var w = Plugin.Writer.init(out_ptr[0..out_cap]);

    while (r.next()) |msg| {
        switch (msg) {
            .load => {
                // Register a panel shown as an overlay (keybind: 'm')
                w.registerPanel(.{
                    .id       = "my-plugin",
                    .title    = "My Plugin",
                    .vim_cmd  = "myplugin",
                    .layout   = .overlay,
                    .keybind  = 'm',
                });
                w.setStatus("My plugin loaded!");
            },
            .draw_panel => {
                w.label("Hello from Zig!", 0);
                w.label("Built with the Zig SDK.", 1);
            },
            else => {},
        }
    }

    return if (w.overflow()) std.math.maxInt(usize) else w.pos;
}
```

## 6. Complete working example

The repo ships a ready-to-build example at `plugins/examples/zig-hello/`:

```
plugins/examples/zig-hello/
  build.zig
  build.zig.zon
  src/
    main.zig          ← same structure as above
```

```bash
cd plugins/examples/zig-hello
zig build run          # install + launch
zig build run -Dbackend=web  # WASM build + serve
```

## 7. LSP / IDE setup

`zls` works out of the box — point your editor at the directory containing
`build.zig` and language features (completion, go-to-definition, error
highlighting) are available immediately.

## 8. Standalone git project

For a plugin that lives in its own repository, replace the `.path` entry in
`build.zig.zon` with a `.url` + `.hash` remote dependency:

```zig
.dependencies = .{
    .schemify_sdk = .{
        .url  = "https://github.com/UWASIC/Schemify/archive/refs/tags/v1.0.0.tar.gz",
        .hash = "...",
    },
},
```

Run `zig fetch --save=schemify_sdk <url>` to populate the hash automatically.
The rest of `build.zig` is identical.

## 9. Plugin API reference

The full interface is defined in `src/PluginIF.zig`.  The key types are:

- `Plugin.Descriptor` — exported symbol `schemify_plugin`; holds `.name`,
  `.version_str`, and `.process`
- `Plugin.Reader` — iterate over incoming host messages (`.load`, `.unload`,
  `.tick`, `.draw_panel`, `.button_clicked`, `.slider_changed`, etc.)
- `Plugin.Writer` — emit responses: `registerPanel`, `setStatus`, `label`,
  `button`, `slider`, `checkbox`, `separator`, `progress`, `plot`, `image`,
  `collapsibleSection`, and more

See also `docs/plugins/api.md` for the complete message protocol reference.

## Receiving per-frame updates

Handle the `.tick` message variant to receive a delta-time value every frame:

```zig
.tick => |dt| {
    _ = dt; // seconds since last frame
    w.setStatus("tick");
},
```

## Panel layout constants

| Zig value | Position |
|-----------|----------|
| `.overlay` | Floating overlay |
| `.left_sidebar` | Left panel |
| `.right_sidebar` | Right panel |
| `.bottom_bar` | Bottom bar |
