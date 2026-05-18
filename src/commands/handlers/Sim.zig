const std = @import("std");
const builtin = @import("builtin");
const is_wasm = builtin.cpu.arch == .wasm32;
const types = @import("../types.zig");

pub fn handleRunSim(p: types.RunSim, state: anytype) void {
    if (is_wasm) {
        state.setStatus("Simulation not available in browser");
        return;
    }
    _ = p;
    const fio = state.active() orelse return;

    // 1. Get the .chn file path
    const chn_path: []const u8 = switch (fio.origin) {
        .chn_file => |path| path,
        else => {
            state.setStatus("Save the schematic first to run simulation");
            return;
        },
    };

    // 2. Derive analysis path
    const chn_dir = std.fs.path.dirname(chn_path) orelse ".";
    const stem = std.fs.path.stem(chn_path);
    const alloc = state.allocator();
    const platform_fs = @import("utility").platform.fs;

    var analysis_buf: [512]u8 = undefined;
    const analysis_path = std.fmt.bufPrint(&analysis_buf, "{s}/{s}_analysis.py", .{ chn_dir, stem }) catch {
        state.setStatus("Path too long");
        return;
    };

    // 3. Create or update analysis file
    const analysis_exists = blk: {
        platform_fs.cwd().access(analysis_path, .{}) catch break :blk false;
        break :blk true;
    };

    if (!analysis_exists) {
        const pyspice_code = @import("simulation").Netlist.emitPySpice(&fio.sch, alloc, null, state.sim_backend) catch null;
        defer if (pyspice_code) |code| alloc.free(code);
        generateAnalysisTemplate(alloc, analysis_path, stem, pyspice_code) catch {
            state.setStatus("Failed to create analysis template");
            return;
        };
        openInEditor(alloc, analysis_path);
        state.setStatus("Analysis file created — edit and re-run :sim");
        return;
    }

    // 4. Regenerate the above-marker section with fresh PySpice output
    regenerateAboveMarker(alloc, analysis_path, &fio.sch, state.sim_backend);

    // 6. Execute analysis file
    // Ensure cache dir exists
    var cache_buf: [256]u8 = undefined;
    const home = @import("utility").platform.homeDir() orelse "/tmp";
    const cache_dir = std.fmt.bufPrint(&cache_buf, "{s}/.cache/schemify", .{home}) catch "/tmp";
    @import("utility").platform.fs.cwd().makePath(cache_dir) catch {};

    var child = std.process.Child.init(
        &.{ "python3", analysis_path },
        alloc,
    );
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.spawn() catch |err| {
        if (err == error.FileNotFound) {
            state.setStatus("Install Python 3 to run simulations");
        } else {
            state.setStatus("Failed to spawn simulation process");
        }
        return;
    };

    // Read stdout/stderr before wait to avoid pipe buffer deadlock
    const max_output = 1 << 20; // 1 MiB
    const stdout_data = if (child.stdout) |f| f.readToEndAlloc(alloc, max_output) catch "" else "";
    defer if (stdout_data.len > 0) alloc.free(stdout_data);
    const stderr_data = if (child.stderr) |f| f.readToEndAlloc(alloc, max_output) catch "" else "";
    defer if (stderr_data.len > 0) alloc.free(stderr_data);

    // Wait for completion
    const term = child.wait() catch {
        state.setStatus("Simulation process failed");
        return;
    };

    // Populate sim_results on the document
    const results = @import("simulation").results;
    switch (term) {
        .Exited => |code| {
            if (code == 0) {
                fio.sim_results = .{
                    .status = .success,
                    .raw_output = stdout_data,
                };
                fio.sim_generation +%= 1;
                state.setStatus("Simulation complete");
            } else {
                // Check stderr for known errors
                if (std.mem.indexOf(u8, stderr_data, "ModuleNotFoundError: No module named 'PySpice'") != null) {
                    fio.sim_results = .{ .status = .pyspice_not_found };
                    fio.sim_generation +%= 1;
                    state.setStatus("Install PySpice: pip install PySpice");
                } else {
                    fio.sim_results = .{
                        .status = .unknown_error,
                        .raw_output = stderr_data,
                        .errors = &.{results.SimError{
                            .severity = .@"error",
                            .message = firstLine(stderr_data),
                        }},
                    };
                    fio.sim_generation +%= 1;
                    // Show first line of stderr in status bar
                    const msg = firstLine(stderr_data);
                    if (msg.len > 0) {
                        state.setStatus(msg);
                    } else {
                        state.setStatus("Simulation script error — check analysis file");
                    }
                }
            }
        },
        else => {
            fio.sim_results = .{ .status = .unknown_error };
            fio.sim_generation +%= 1;
            state.setStatus("Simulation terminated abnormally");
        },
    }
}

pub fn handleViewPySpiceNetlist(state: anytype) void {
    if (is_wasm) {
        state.setStatus("File write not available in browser");
        return;
    }
    const fio = state.active() orelse {
        state.setStatus("No active document");
        return;
    };

    const chn_path: []const u8 = switch (fio.origin) {
        .chn_file => |path| path,
        else => {
            state.setStatus("Save the schematic first");
            return;
        },
    };

    const chn_dir = std.fs.path.dirname(chn_path) orelse ".";
    const stem = std.fs.path.stem(chn_path);
    const alloc = state.allocator();
    const platform_fs = @import("utility").platform.fs;

    var analysis_buf: [512]u8 = undefined;
    const analysis_path = std.fmt.bufPrint(&analysis_buf, "{s}/{s}_analysis.py", .{ chn_dir, stem }) catch {
        state.setStatus("Path too long");
        return;
    };

    // Create or update analysis file (same as :sim but without running)
    const analysis_exists = blk: {
        platform_fs.cwd().access(analysis_path, .{}) catch break :blk false;
        break :blk true;
    };

    if (!analysis_exists) {
        const pyspice_code = @import("simulation").Netlist.emitPySpice(&fio.sch, alloc, null, state.sim_backend) catch null;
        defer if (pyspice_code) |code| alloc.free(code);
        generateAnalysisTemplate(alloc, analysis_path, stem, pyspice_code) catch {
            state.setStatus("Failed to create analysis file");
            return;
        };
    } else {
        regenerateAboveMarker(alloc, analysis_path, &fio.sch, state.sim_backend);
    }

    openInEditor(alloc, analysis_path);
    state.setStatus("Analysis file ready — edit freely below the marker");
}

fn tryLaunchViewer(alloc: std.mem.Allocator, bin: []const u8, path: []const u8) bool {
    var child = std.process.Child.init(&.{ bin, path }, alloc);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return false;
    return true;
}

fn pathExists(path: []const u8) bool {
    @import("utility").platform.fs.cwd().access(path, .{}) catch return false;
    return true;
}

pub fn handleOpenWaveformViewer(state: anytype) void {
    if (is_wasm) {
        state.setStatus("Waveform viewer not available in browser");
        return;
    }
    const fio = state.active() orelse {
        state.setStatus("No active document");
        return;
    };

    // Try SimResult waveforms first (new PySpice-rs path)
    if (fio.sim_results) |sim| {
        if (sim.waveforms.len > 0) {
            const base_name: []const u8 = switch (fio.origin) {
                .chn_file => |p| std.fs.path.stem(p),
                else => "untitled",
            };
            var csv_buf: [512]u8 = undefined;
            const csv_path = std.fmt.bufPrint(&csv_buf, "/tmp/{s}_waveforms.csv", .{base_name}) catch {
                state.setStatus("Path too long");
                return;
            };

            // Write CSV
            if (writeWaveformCsv(state.allocator(), csv_path, sim.waveforms)) {
                if (tryLaunchViewer(state.allocator(), "gaw", csv_path) or
                    tryLaunchViewer(state.allocator(), "gtkwave", csv_path))
                {
                    state.setStatus("Waveform viewer opened");
                    return;
                }
            }

            // Fallback: status summary
            var msg_buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "{d} waveform(s) in sim results", .{sim.waveforms.len}) catch "Waveforms available";
            state.setStatusBuf(msg);
            return;
        }
    }

    // Fallback: legacy .raw file path
    const base_name: []const u8 = switch (fio.origin) {
        .chn_file => |p| std.fs.path.stem(p),
        else => {
            state.setStatus("Save the file first");
            return;
        },
    };

    var raw_buf: [512]u8 = undefined;
    const raw_path = std.fmt.bufPrint(&raw_buf, "/tmp/{s}.raw", .{base_name}) catch {
        state.setStatus("Path too long");
        return;
    };
    if (!pathExists(raw_path)) {
        state.setStatus("No simulation results found — run a simulation first");
        return;
    }

    if (tryLaunchViewer(state.allocator(), "gaw", raw_path) or
        tryLaunchViewer(state.allocator(), "gtkwave", raw_path))
    {
        state.setStatus("Waveform viewer opened");
        return;
    }
    // Fallback: ngspice in xterm
    var cmd_buf: [1024]u8 = undefined;
    const cmd_str = std.fmt.bufPrint(&cmd_buf, "ngspice \"{s}\"; echo '--- Press Enter to close ---'; read", .{raw_path}) catch {
        state.setStatus("Path too long for viewer command");
        return;
    };
    var child = std.process.Child.init(
        &.{ "xterm", "-T", "Schemify Waveforms", "-e", "sh", "-c", cmd_str },
        state.allocator(),
    );
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch {
        state.setStatus("Failed to launch waveform viewer");
        return;
    };
    state.setStatus("Waveform viewer opened (ngspice)");
}

fn writeWaveformCsv(alloc: std.mem.Allocator, path: []const u8, waveforms: []const @import("simulation").results.Waveform) bool {
    const platform_fs = @import("utility").platform.fs;

    // Find max length
    var max_len: usize = 0;
    for (waveforms) |wf| {
        if (wf.x_data.len > max_len) max_len = wf.x_data.len;
    }
    if (max_len == 0) return false;

    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(alloc);
    const w = buf.writer(alloc);

    // Header
    w.writeAll("x") catch return false;
    for (waveforms) |wf| {
        w.print(",{s}", .{if (wf.name.len > 0) wf.name else "?"}) catch return false;
    }
    w.writeByte('\n') catch return false;

    // Data rows
    for (0..max_len) |i| {
        // x value from first waveform
        if (waveforms.len > 0 and i < waveforms[0].x_data.len) {
            w.print("{e}", .{waveforms[0].x_data[i]}) catch return false;
        } else {
            w.writeByte('0') catch return false;
        }
        for (waveforms) |wf| {
            if (i < wf.y_data.len) {
                w.print(",{e}", .{wf.y_data[i]}) catch return false;
            } else {
                w.writeAll(",0") catch return false;
            }
        }
        w.writeByte('\n') catch return false;
    }

    platform_fs.cwd().writeFile(.{ .sub_path = path, .data = buf.items }) catch return false;
    return true;
}

// ── Helpers ──────────────────────────────────────────────────────────────────

const analysis_marker = "# === YOUR ANALYSIS BELOW ===";

/// Return the first line of a string (up to first newline, or the whole string).
fn firstLine(s: []const u8) []const u8 {
    if (s.len == 0) return s;
    const end = std.mem.indexOfScalar(u8, s, '\n') orelse s.len;
    return s[0..end];
}

/// Regenerate the auto-generated section above the marker in an existing
/// analysis file, preserving everything the user wrote below the marker.
fn regenerateAboveMarker(alloc: std.mem.Allocator, analysis_path: []const u8, sch: anytype, backend: @import("simulation").SpiceIF.Backend) void {
    const Netlist = @import("simulation").Netlist;
    const platform_fs = @import("utility").platform.fs;

    // Generate fresh PySpice code from the current schematic
    const pyspice_code = Netlist.emitPySpice(sch, alloc, null, backend) catch return;
    defer alloc.free(pyspice_code);

    // Read the existing analysis file
    const existing = platform_fs.cwd().readFileAlloc(alloc, analysis_path, 1 << 20) catch return;
    defer alloc.free(existing);

    // Find the marker line
    const marker_pos = std.mem.indexOf(u8, existing, analysis_marker) orelse return;

    // Everything from the marker onward is the user's code (preserved)
    const user_section = existing[marker_pos..];

    // Build the new file: fresh auto-generated header + user section
    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(alloc);
    const w = buf.writer(alloc);

    w.writeAll("#!/usr/bin/env python3\n") catch return;
    w.writeAll("# === AUTO-GENERATED FROM SCHEMATIC (do not edit above this line) ===\n") catch return;
    w.writeAll("#\n# Dependencies: pip install PySpice\n#\n\n") catch return;

    // Emit the PySpice circuit-building code
    w.writeAll(pyspice_code) catch return;
    w.writeByte('\n') catch return;

    // Append the preserved user section (starts with the marker)
    w.writeAll(user_section) catch return;

    platform_fs.cwd().writeFile(.{ .sub_path = analysis_path, .data = buf.items }) catch return;
}

// ── Analysis template generation ─────────────────────────────────────────────

fn generateAnalysisTemplate(
    alloc: std.mem.Allocator,
    path: []const u8,
    stem: []const u8,
    pyspice_code: ?[]const u8,
) !void {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(alloc);
    const w = buf.writer(alloc);

    try w.writeAll("#!/usr/bin/env python3\n");
    try w.writeAll("# === AUTO-GENERATED FROM SCHEMATIC (do not edit above this line) ===\n");
    try w.print("# Analysis script for: {s}\n", .{stem});
    try w.writeAll("# Dependencies: pip install pyspice-rs\n");
    try w.writeAll("#\n\n");

    if (pyspice_code) |code| {
        try w.writeAll(code);
        try w.writeByte('\n');
    } else {
        try w.writeAll("from pyspice_rs import Circuit\n");
        try w.writeAll("from pyspice_rs.unit import *\n\n");
        try w.print("circuit = Circuit('{s}')\n\n", .{stem});
    }

    try w.writeAll(analysis_marker);
    try w.writeAll("\n\n");
    try w.writeAll("# Example: DC operating point\n");
    try w.writeAll("# sim = circuit.simulator(simulator='ngspice')\n");
    try w.writeAll("# analysis = sim.operating_point()\n");
    try w.writeAll("# for node in analysis.nodes.values():\n");
    try w.writeAll("#     print(f'{node}: {float(node):.4f} V')\n\n");
    try w.writeAll("print(f'Circuit: {circuit.title}')\n");
    try w.writeAll("print('Edit this file to add your simulation analysis.')\n");

    try @import("utility").platform.fs.cwd().writeFile(.{ .sub_path = path, .data = buf.items });
}

fn openInEditor(alloc: std.mem.Allocator, path: []const u8) void {
    const editor = @import("utility").platform.getEnv("EDITOR") orelse @import("utility").platform.getEnv("VISUAL") orelse return;

    // Try terminal editors in xterm
    var child = std.process.Child.init(
        &.{ "xterm", "-T", "Schemify Analysis", "-e", editor, path },
        alloc,
    );
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch {
        // Fallback: try opening directly (for GUI editors like code, gedit)
        var direct = std.process.Child.init(&.{ editor, path }, alloc);
        direct.stdout_behavior = .Ignore;
        direct.stderr_behavior = .Ignore;
        direct.spawn() catch return;
    };
}
