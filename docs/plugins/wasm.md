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
fn drawPanel() callconv(.c) void {
    var alloc = Plugin.allocator();

    // Works on both native and WASM without any conditional compilation
    const data = Plugin.Vfs.readAlloc(alloc, "config.toml") catch |err| {
        Plugin.logWarn("my-plugin", @errorName(err));
        return;
    };
    defer alloc.free(data);

    _ = dvui.label(@src(), data, .{});
}
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

- **No `std.os` syscalls** — use `Plugin.Vfs` for files, `Plugin.allocator()` for memory
- **No threads** — WASM is single-threaded; `on_tick(dt)` is the event loop
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

## The host import contract

For reference, here are all `extern "host"` functions that `plugin_host.js`
provides to WASM plugins.  You should never call them directly — use the
module-level API in `PluginIF` and `Vfs` instead.

### Control

| Import | Description |
|--------|-------------|
| `set_status(ptr, len)` | Update status bar |
| `log_msg(level, tag_ptr, tag_len, msg_ptr, msg_len)` | Structured log |
| `register_panel(id, title, vim, layout, keybind, draw_fn_idx)` | Register panel |
| `project_dir_len() → i32` | Byte count of project directory path |
| `project_dir_copy(dest, dest_len)` | Copy path into WASM memory |
| `active_schematic_len() → i32` | `-1` if none open |
| `active_schematic_copy(dest, dest_len)` | Copy name into WASM memory |
| `request_refresh()` | Queue a UI redraw |

### VFS

| Import | Description |
|--------|-------------|
| `vfs_file_len(path, len) → i32` | File size, `-1` = not found |
| `vfs_file_read(path, plen, dest, dlen) → i32` | Read file into buffer |
| `vfs_file_write(path, plen, src, slen) → i32` | Write buffer to file |
| `vfs_file_delete(path, len) → i32` | Delete file |
| `vfs_dir_make(path, len) → i32` | Create directory |
| `vfs_dir_list_len(path, len) → i32` | Byte count of NUL-separated listing |
| `vfs_dir_list_read(path, plen, dest, dlen) → i32` | Fill listing buffer |

## Debugging WASM plugins

Open browser DevTools → **Console**.  `Plugin.logInfo` / `logWarn` / `logErr`
output there.  `Plugin.setStatus` updates the status bar visible in the canvas.

For crashes or traps, enable DWARF debug info:

```bash
zig build -Dbackend=web -Doptimize=Debug
```

Then use the browser's WASM source-map support to step through Zig source.
