# Python Plugin

Python is useful for plugins that need rich libraries — NumPy, PyTorch,
SciPy, NetworkX — while Zig handles the Schemify UI panel and the ABI
boundary.  The two patterns below cover most use cases.

## Pattern A — subprocess (simple, no libpython)

Zig calls a Python script as a child process via `std.process.Child`.
The script reads from `stdin` or a temp file and writes results to `stdout`.
No linking to `libpython` required; any Python installation on the system works.

### `build.zig` (excerpt)

```zig
const lib = helper.addNativePluginLibrary(b, ctx, "MyPyPlugin", "src/main.zig");
lib.linkLibC();
b.installArtifact(lib);

// Install Python sources alongside the .so
helper.addInstallFiles(b, .lib, &.{
    "src/worker.py",
    "plugin.toml",
});

helper.addNativeAutoInstallRunStep(b, "MyPyPlugin", sdk_dep, "MyPyPlugin");
```

### `src/main.zig`

```zig
const Plugin = @import("PluginIF");
const dvui   = @import("dvui");
const std    = @import("std");

export const schemify_plugin: Plugin.Descriptor = .{
    .abi_version = Plugin.ABI_VERSION,
    .name        = "my-py-plugin",
    .version_str = "0.1.0",
    .set_ctx     = Plugin.setCtx,
    .on_load     = &onLoad,
    .on_unload   = &onUnload,
    .on_tick     = null,
};

fn onLoad() callconv(.c) void {
    Plugin.setStatus("my-py-plugin loaded");
    _ = Plugin.registerPanel(&.{
        .id      = "py-panel",
        .title   = "Py Panel",
        .vim_cmd = "py-panel",
        .layout  = .right_sidebar,
        .keybind = 'p',
        .draw_fn = &drawPanel,
    });
}
fn onUnload() callconv(.c) void {}

fn drawPanel() callconv(.c) void {
    var alloc = Plugin.allocator();

    if (dvui.button(@src(), "Run Python", .{})) {
        runPython(alloc) catch |err| {
            Plugin.logErr("py-panel", @errorName(err));
        };
    }
}

fn runPython(alloc: std.mem.Allocator) !void {
    // Find the script next to the installed .so
    var dir_buf: [512]u8 = undefined;
    const project = Plugin.getProjectDir(&dir_buf);
    const script  = try std.fmt.allocPrint(alloc,
        "{s}/../.config/Schemify/MyPyPlugin/worker.py", .{project});
    defer alloc.free(script);

    var result = try std.process.Child.run(.{
        .allocator = alloc,
        .argv      = &.{ "python3", script, "--input", "data" },
    });
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);

    Plugin.setStatus(result.stdout);
}
```

### `src/worker.py`

```python
#!/usr/bin/env python3
import sys
import argparse

def main():
    p = argparse.ArgumentParser()
    p.add_argument("--input")
    args = p.parse_args()
    # ... do work with numpy, scipy, etc. ...
    print(f"processed: {args.input}", end="")

if __name__ == "__main__":
    main()
```

---

## Pattern B — embedded libpython (used by Circuit Visionary, GmID Visualizer)

Link `libpython3` directly into the plugin's `.so`.  The Python interpreter
runs in the same process as Schemify and communicates through the Python C API.
This eliminates process-spawn overhead and allows passing large objects
(e.g. NumPy arrays) without serialisation.

### `build.zig` (excerpt)

```zig
const lib = helper.addNativePluginLibrary(b, ctx, "MyPyPlugin", "src/main.zig");

// Locate Python headers via `python3-config --includes`
const py_include = pyIncludePath(b) orelse "/usr/include/python3";
lib.addIncludePath(.{ .cwd_relative = py_include });
lib.linkSystemLibrary("python3");
lib.linkLibC();
if (ctx.target.result.os.tag == .linux) lib.linkSystemLibrary("dl");

b.installArtifact(lib);
helper.addInstallFiles(b, .lib, &.{
    "src/worker.py",
    "plugin.toml",
});
helper.addNativeAutoInstallRunStep(b, "MyPyPlugin", sdk_dep, "MyPyPlugin");

// ...

fn pyIncludePath(b: *std.Build) ?[]const u8 {
    const result = std.process.Child.run(.{
        .allocator = b.allocator,
        .argv      = &.{ "python3-config", "--includes" },
    }) catch return null;
    const out = std.mem.trim(u8, result.stdout, " \n\r\t");
    var it = std.mem.splitScalar(u8, out, ' ');
    while (it.next()) |tok| {
        if (std.mem.startsWith(u8, tok, "-I")) return b.dupe(tok[2..]);
    }
    return null;
}
```

### `src/python_bridge.zig`

```zig
const std = @import("std");
const c   = @cImport({
    @cDefine("PY_SSIZE_T_CLEAN", "1");
    @cInclude("Python.h");
});

pub fn init() !void {
    c.Py_Initialize();
}

pub fn deinit() void {
    c.Py_Finalize();
}

/// Call `worker.run(data)` and return the result string. Caller owns memory.
pub fn runWorker(alloc: std.mem.Allocator, data: []const u8) ![]u8 {
    const module_name = c.PyUnicode_DecodeFSDefault("worker");
    defer c.Py_DecRef(module_name);

    const module = c.PyImport_Import(module_name) orelse return error.ImportFailed;
    defer c.Py_DecRef(module);

    const func = c.PyObject_GetAttrString(module, "run") orelse return error.AttrFailed;
    defer c.Py_DecRef(func);

    const arg = c.PyUnicode_FromStringAndSize(data.ptr, @intCast(data.len));
    defer c.Py_DecRef(arg);

    const result = c.PyObject_CallOneArg(func, arg) orelse return error.CallFailed;
    defer c.Py_DecRef(result);

    const raw = c.PyUnicode_AsUTF8(result) orelse return error.EncodeFailed;
    return alloc.dupe(u8, std.mem.span(raw));
}
```

### `src/worker.py`

```python
def run(data: str) -> str:
    # Use any Python library here
    import json
    return json.dumps({"echo": data, "len": len(data)})
```

### `src/main.zig` (using the bridge)

```zig
const Plugin = @import("PluginIF");
const dvui   = @import("dvui");
const py     = @import("python_bridge.zig");
const std    = @import("std");

fn onLoad() callconv(.c) void {
    py.init() catch {
        Plugin.logErr("py-plugin", "Python init failed");
        return;
    };
    // Tell Python where to find worker.py (next to the installed .so)
    // ...
}

fn onUnload() callconv(.c) void {
    py.deinit();
}

fn drawPanel() callconv(.c) void {
    var alloc = Plugin.allocator();
    const result = py.runWorker(alloc, "test input") catch "error";
    defer alloc.free(result);
    _ = dvui.label(@src(), result, .{});
}
```

## Installing Python dependencies

Ship a `requirements.txt` alongside the plugin:

```
numpy>=1.24
scipy>=1.11
```

During development install them with:

```bash
pip install -r requirements.txt
```

For distribution, document that users must run `pip install` or provide a
`setup.sh` script.

## WASM note

`libpython` is a large native library and does not compile to WASM cleanly.
For web builds, either:

- Provide a Zig-only stub that skips Python (`if (ctx.is_web)`)
- Use Pyodide loaded separately by the JavaScript host page, then communicate
  via the VFS (write inputs, read outputs)
