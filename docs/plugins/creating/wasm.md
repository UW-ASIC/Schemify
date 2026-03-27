# WASM / Web Plugin

Web plugins run as `.wasm` modules loaded by `plugin_host.js` in the browser.
The same Zig source file that compiles to a native `.so` compiles to `.wasm`
unchanged — the only requirement is using `Plugin.Vfs` instead of direct
`std.fs` calls.

## Building for the web

```bash
zig build -Dbackend=web
# output: zig-out/plugins/MyPlugin.wasm
```

The build helper selects `wasm32-freestanding` as the target and sets
`.entry = .disabled` + `.rdynamic = true` so the WASM exports are visible
to the JavaScript host.

## Deploying

Place the `.wasm` file alongside `index.html` in `plugins/` and register
it in `plugins/plugins.json`:

```json
{ "plugins": ["MyPlugin.wasm"] }
```

`plugin_host.js` fetches this manifest on startup, instantiates each `.wasm`,
and calls `on_load()` / `on_tick(dt)` / `on_unload()` at the appropriate times.

## VFS — filesystem on the web {#vfs}

The browser has no direct filesystem access.  `Plugin.Vfs` abstracts this
through `extern "host"` imports that `plugin_host.js` provides:

| Operation | Zig call | JS host |
|-----------|----------|---------|
| Read file | `Vfs.readAlloc(alloc, path)` | reads from in-memory Map |
| Write file | `Vfs.writeAll(path, data)` | writes to in-memory Map |
| Check file exists | `Vfs.exists(path)` | checks Map |
| Delete | `Vfs.delete(path)` | removes from Map |
| Create dir | `Vfs.makePath(path)` | records dir path |
| List dir | `Vfs.listDir(alloc, path)` | returns NUL-sep entries |

### Example: read a project file

```zig
// Inside schemify_process, during a draw_panel message:
.draw_panel => {
    var alloc = std.heap.wasm_allocator; // or any allocator
    const data = Plugin.Vfs.readAlloc(alloc, "config.toml") catch |err| {
        w.log(.warn, "my-plugin", @errorName(err));
        return;
    };
    defer alloc.free(data);
    w.label(data, 1);
},
```

### Example: enumerate PDK files

```zig
fn loadPdk(alloc: std.mem.Allocator, pdk_root: []const u8) !void {
    const listing = try Plugin.Vfs.listDir(alloc, pdk_root);
    defer listing.deinit(alloc);

    for (listing.entries) |name| {
        if (!std.mem.endsWith(u8, name, ".sym")) continue;

        const full = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ pdk_root, name });
        defer alloc.free(full);

        const bytes = try Plugin.Vfs.readAlloc(alloc, full);
        defer alloc.free(bytes);

        // parse and register symbol ...
    }
}
```

### Seeding the VFS from the host page

The JavaScript host exposes `schemifyPluginHost.vfs` so the page can pre-load
files before boot:

```js
// index.html or a wrapper script
schemifyPluginHost.vfs.write(
    "pdk/sky130A/nfet_01v8.sym",
    new Uint8Array(await fetch("pdk/nfet.sym").then(r => r.arrayBuffer()))
);
```

This is how PDK files, project schematics, and configuration are made
available to WASM plugins without a server.

## Handling the missing libc

WASM plugins run on `wasm32-freestanding` — there is no C standard library.
In practice:

- **No `std.os` syscalls** — use `Plugin.Vfs` for files; use `std.heap.wasm_allocator` for memory
- **No threads** — WASM is single-threaded; the `.tick` message is the event loop
- **No `@cImport`** — C headers that pull in OS types will fail to compile

### Splitting native and web source

When a plugin genuinely needs different logic for each target:

```zig
// src/main.zig
const backend = if (comptime @import("builtin").cpu.arch == .wasm32)
    @import("backend_wasm.zig")
else
    @import("backend_native.zig");
```

Or in `build.zig`:

```zig
if (!ctx.is_web) {
    helper.addNativePluginLibrary(b, ctx, "MyPlugin", "src/main_native.zig");
}
if (ctx.is_web) {
    helper.addWasmPlugin(b, ctx, "MyPlugin", "src/main_wasm.zig");
}
```

## WASM host contract

WASM plugins use the same binary message-passing protocol as native plugins —
no `extern "host"` function imports needed.  The host calls the exported
`schemify_process` entry point, passing a message batch in and collecting
responses out.  `plugin_host.js` decodes the response messages and updates the
DOM accordingly.

The only host-provided import is the Vfs layer, which the `Plugin.Vfs` API
wraps automatically:

| JS-side VFS hook | Used by |
|-----------------|---------|
| `vfs_file_read` / `vfs_file_write` | `Vfs.readAlloc` / `Vfs.writeAll` |
| `vfs_file_delete` | `Vfs.delete` |
| `vfs_dir_make` | `Vfs.makePath` |
| `vfs_dir_list_read` | `Vfs.listDir` |

## Debugging WASM plugins

Open browser DevTools → **Console**.  `w.log(.info / .warn / .err, ...)` messages
appear there.  `w.setStatus(msg)` updates the status bar visible in the canvas.

For crashes or traps, enable DWARF debug info:

```bash
zig build -Dbackend=web -Doptimize=Debug
```

Then use the browser's WASM source-map support to step through Zig source.
