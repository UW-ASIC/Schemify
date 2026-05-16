// mod.zig — PySpice import backend.
//
// Runs Python scripts that use PySpice and captures the SPICE netlist
// they emit on stdout. The netlist is then fed through the shared
// spice pipeline (parse -> layout -> route -> Schemify).
//
// Usage:
//   const pyspice = @import("PySpice/mod.zig");
//   const results = try pyspice.importPySpiceProject(alloc, "path/to/project");
//
// Or from a string:
//   const results = try pyspice.importPySpiceText(alloc, source, "my_circuit");

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const List = std.ArrayListUnmanaged;
const spice = @import("../spice/mod.zig");
const ct = @import("../types.zig");
const platform = @import("utility").platform;
pub const ConvertResult = ct.ConvertResult;
pub const ConvertResultList = ct.ConvertResultList;

pub const Error = error{
    PythonExecFailed,
    NoPySpiceFiles,
};

// ── Public API ──────────────────────────────────────────────────────────────

/// Import all PySpice .py files from a project directory.
///
/// Scans `project_dir` for `.py` files containing PySpice imports (checked
/// in the first 50 lines), runs each through `python3`, captures the SPICE
/// netlist from stdout, and converts via the spice pipeline.
/// The original Python source is stored in `schemify.pyspice_source`.
pub fn importPySpiceProject(alloc: Allocator, project_dir: []const u8) !ConvertResultList {
    var list_arena = std.heap.ArenaAllocator.init(alloc);
    errdefer list_arena.deinit();
    const la = list_arena.allocator();

    const py_files = try findPySpiceFiles(la, project_dir);
    if (py_files.len == 0) return Error.NoPySpiceFiles;

    var results: List(ConvertResult) = .{};

    for (py_files) |rel_path| {
        const full_path = try std.fs.path.join(la, &.{ project_dir, rel_path });
        const py_source = platform.fs.cwd().readFileAlloc(la, full_path, 1 << 24) catch continue;

        const spice_output = runPythonWithRoot(la, full_path, project_dir) catch continue;
        if (spice_output.len == 0) continue;

        const netlist = spice.parseNetlist(la, spice_output) catch continue;
        const converted = spice.convertNetlist(la, netlist, rel_path) catch continue;

        for (converted) |result| {
            var r = result;
            try r.schemify.setPySpiceSource(la, py_source);
            try results.append(la, r);
        }
    }

    if (results.items.len == 0) return Error.PythonExecFailed;

    return .{
        .results = try la.dupe(ConvertResult, results.items),
        .arena = list_arena,
    };
}

/// Import a PySpice file by running it in-place (not a temp copy).
///
/// Preserves the real file path so cross-file imports work.
/// Auto-detects PYTHONPATH from project root markers.
pub fn importPySpiceFile(alloc: Allocator, file_path: []const u8) !ConvertResultList {
    var list_arena = std.heap.ArenaAllocator.init(alloc);
    errdefer list_arena.deinit();
    const la = list_arena.allocator();

    const py_source = platform.fs.cwd().readFileAlloc(la, file_path, 1 << 24) catch
        return Error.PythonExecFailed;
    if (!isPySpiceFile(py_source)) return Error.PythonExecFailed;

    const python_root = findPythonRoot(file_path);
    const spice_output = try runPythonWithRoot(la, file_path, python_root);
    if (spice_output.len == 0) return Error.PythonExecFailed;

    const name = std.fs.path.stem(file_path);
    const netlist = try spice.parseNetlist(la, spice_output);
    const converted = try spice.convertNetlist(la, netlist, name);

    var results: List(ConvertResult) = .{};
    for (converted) |result| {
        var r = result;
        try r.schemify.setPySpiceSource(la, py_source);
        try results.append(la, r);
    }

    return .{
        .results = try la.dupe(ConvertResult, results.items),
        .arena = list_arena,
    };
}

/// Import a PySpice circuit from a source string.
///
/// Writes `source` to a temp file, runs it through `python3`, captures
/// the SPICE netlist from stdout, and converts via the spice pipeline.
pub fn importPySpiceText(alloc: Allocator, source: []const u8, name: []const u8) !ConvertResultList {
    var list_arena = std.heap.ArenaAllocator.init(alloc);
    errdefer list_arena.deinit();
    const la = list_arena.allocator();

    const tmp_path = try writeTempFile(la, source);
    defer platform.fs.cwd().deleteFile(tmp_path) catch {};

    const spice_output = try runPython(la, tmp_path);
    if (spice_output.len == 0) return Error.PythonExecFailed;

    const netlist = try spice.parseNetlist(la, spice_output);
    const converted = try spice.convertNetlist(la, netlist, name);

    var results: List(ConvertResult) = .{};
    for (converted) |result| {
        var r = result;
        try r.schemify.setPySpiceSource(la, source);
        try results.append(la, r);
    }

    return .{
        .results = try la.dupe(ConvertResult, results.items),
        .arena = list_arena,
    };
}

/// Check if a `.py` file contains PySpice-RS or legacy PySpice imports in its first 50 lines.
pub fn isPySpiceFile(content: []const u8) bool {
    var lines: usize = 0;
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        lines += 1;
        if (lines > 50) break;

        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        if (std.mem.startsWith(u8, trimmed, "from pyspice_rs") or
            std.mem.startsWith(u8, trimmed, "import pyspice_rs") or
            std.mem.startsWith(u8, trimmed, "from PySpice") or
            std.mem.startsWith(u8, trimmed, "import PySpice"))
        {
            return true;
        }
    }
    return false;
}

// ── Subprocess execution ────────────────────────────────────────────────────

fn runPython(alloc: Allocator, file_path: []const u8) ![]const u8 {
    return runPythonWithRoot(alloc, file_path, null);
}

fn runPythonWithRoot(alloc: Allocator, file_path: []const u8, python_root: ?[]const u8) ![]const u8 {
    if (comptime builtin.cpu.arch.isWasm()) return Error.PythonExecFailed;
    const argv = [_][]const u8{ "python3", file_path };
    var child = std.process.Child.init(&argv, alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    // Set PYTHONPATH so cross-file imports resolve.
    if (python_root) |root| {
        var env_map = std.process.EnvMap.init(alloc);
        defer env_map.deinit();

        // Inherit essential env vars
        if (platform.getEnv("PATH")) |v| env_map.put("PATH", v) catch {};
        if (platform.getEnv("HOME")) |v| env_map.put("HOME", v) catch {};
        if (platform.getEnv("VIRTUAL_ENV")) |v| env_map.put("VIRTUAL_ENV", v) catch {};
        if (platform.getEnv("PYTHONPATH")) |v| {
            // Prepend our root to existing PYTHONPATH
            const combined = std.fmt.allocPrint(alloc, "{s}:{s}", .{ root, v }) catch root;
            env_map.put("PYTHONPATH", combined) catch {};
        } else {
            env_map.put("PYTHONPATH", root) catch {};
        }
        child.env_map = &env_map;

        try child.spawn();
    } else {
        try child.spawn();
    }

    const max_output: usize = 1 << 24; // 16 MiB
    const stdout = if (child.stdout) |f| try f.readToEndAlloc(alloc, max_output) else "";
    // Drain stderr so the child doesn't block.
    const stderr = if (child.stderr) |f| f.readToEndAlloc(alloc, max_output) catch "" else "";
    _ = stderr;

    const term = try child.wait();
    if (term.Exited != 0) return Error.PythonExecFailed;

    return stdout;
}

/// Find the project root by walking up from `file_path` looking for
/// `__init__.py`, `Config.toml`, `pyproject.toml`, or `setup.py`.
pub fn findPythonRoot(file_path: []const u8) ?[]const u8 {
    const markers = [_][]const u8{ "__init__.py", "Config.toml", "pyproject.toml", "setup.py" };
    var dir = std.fs.path.dirname(file_path) orelse return null;

    for (0..10) |_| {
        for (&markers) |marker| {
            var buf: [1024]u8 = undefined;
            const check = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, marker }) catch continue;
            if (platform.fs.cwd().access(check, .{})) |_| {
                return dir;
            } else |_| {}
        }
        dir = std.fs.path.dirname(dir) orelse break;
    }
    return null;
}

// ── File discovery ──────────────────────────────────────────────────────────

fn findPySpiceFiles(arena: Allocator, dir: []const u8) ![]const []const u8 {
    var files: List([]const u8) = .{};

    var d = platform.fs.cwd().openDir(dir, .{ .iterate = true }) catch return &.{};
    defer d.close();
    var it = d.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".py")) continue;

        const full_path = try std.fs.path.join(arena, &.{ dir, entry.name });
        const content = platform.fs.cwd().readFileAlloc(arena, full_path, 1 << 16) catch continue;

        if (isPySpiceFile(content)) {
            try files.append(arena, try arena.dupe(u8, entry.name));
        }
    }

    return files.items;
}

// ── Temp file ───────────────────────────────────────────────────────────────

fn writeTempFile(alloc: Allocator, source: []const u8) ![]const u8 {
    // Use a deterministic-ish name under /tmp.
    const prefix = "/tmp/schemify_pyspice_";
    const suffix = ".py";

    // Build a simple hash-based filename to avoid collisions.
    var hash: u64 = 0;
    for (source) |b| {
        hash = hash *% 31 +% b;
    }

    var name_buf: [80]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "{s}{x}{s}", .{ prefix, hash, suffix }) catch
        "/tmp/schemify_pyspice_tmp.py";

    const path = try alloc.dupe(u8, name);

    const file = try platform.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(source);

    return path;
}

// ── Tests ───────────────────────────────────────────────────────────────────

test "isPySpiceFile — detects PySpice import" {
    const source =
        \\#!/usr/bin/env python3
        \\import numpy as np
        \\from PySpice.Spice.Netlist import Circuit
        \\
        \\circuit = Circuit('Test')
    ;
    try std.testing.expect(isPySpiceFile(source));
}

test "isPySpiceFile — detects 'import PySpice' form" {
    const source =
        \\import PySpice
        \\import PySpice.Logging.Logging as Logging
    ;
    try std.testing.expect(isPySpiceFile(source));
}

test "isPySpiceFile — detects pyspice_rs 'from' import" {
    const source =
        \\from pyspice_rs import Circuit
        \\from pyspice_rs.unit import *
    ;
    try std.testing.expect(isPySpiceFile(source));
}

test "isPySpiceFile — detects pyspice_rs 'import' form" {
    const source =
        \\import pyspice_rs
    ;
    try std.testing.expect(isPySpiceFile(source));
}

test "isPySpiceFile — ignores non-PySpice Python" {
    const source =
        \\#!/usr/bin/env python3
        \\import numpy as np
        \\import matplotlib.pyplot as plt
        \\
        \\x = np.linspace(0, 10, 100)
        \\plt.plot(x, np.sin(x))
    ;
    try std.testing.expect(!isPySpiceFile(source));
}

test "isPySpiceFile — handles empty content" {
    try std.testing.expect(!isPySpiceFile(""));
}

test "isPySpiceFile — only scans first 50 lines" {
    // PySpice import on line 51 should be missed.
    var buf: [51 * 2 + 40]u8 = undefined;
    var pos: usize = 0;
    for (0..50) |_| {
        buf[pos] = '#';
        buf[pos + 1] = '\n';
        pos += 2;
    }
    const tail = "from PySpice.Spice.Netlist import Circuit\n";
    @memcpy(buf[pos..][0..tail.len], tail);
    pos += tail.len;

    try std.testing.expect(!isPySpiceFile(buf[0..pos]));
}

test "isPySpiceFile — detects on line 50" {
    // PySpice import on exactly line 50 should be detected.
    var buf: [49 * 2 + 40]u8 = undefined;
    var pos: usize = 0;
    for (0..49) |_| {
        buf[pos] = '#';
        buf[pos + 1] = '\n';
        pos += 2;
    }
    const tail = "from PySpice.Spice.Netlist import Circuit\n";
    @memcpy(buf[pos..][0..tail.len], tail);
    pos += tail.len;

    try std.testing.expect(isPySpiceFile(buf[0..pos]));
}
