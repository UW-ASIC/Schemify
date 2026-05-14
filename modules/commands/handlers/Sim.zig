const std = @import("std");
const builtin = @import("builtin");
const is_wasm = builtin.cpu.arch == .wasm32;
const types = @import("../types.zig");

pub fn handleRunSim(p: types.RunSim, state: anytype) void {
    if (is_wasm) { state.setStatus("Simulation not available in browser"); return; }
    _ = p;
    const fio = state.active() orelse return;

    // 1. Get the .chn file path
    const chn_path: []const u8 = switch (fio.origin) {
        .chn_file => |path| path,
        else => { state.setStatus("Save the schematic first to run simulation"); return; },
    };

    // 2. Derive paths
    const chn_dir = std.fs.path.dirname(chn_path) orelse ".";
    const stem = std.fs.path.stem(chn_path);

    var spice_buf: [512]u8 = undefined;
    const spice_path = std.fmt.bufPrint(&spice_buf, "{s}/{s}.spice", .{ chn_dir, stem }) catch {
        state.setStatus("Path too long"); return;
    };

    var analysis_buf: [512]u8 = undefined;
    const analysis_path = std.fmt.bufPrint(&analysis_buf, "{s}/{s}_analysis.py", .{ chn_dir, stem }) catch {
        state.setStatus("Path too long"); return;
    };

    // 3. Generate SPICE netlist
    const alloc = state.allocator();
    const spice_text = fio.createNetlist() catch {
        state.setStatus("Netlist generation failed");
        return;
    };
    defer alloc.free(spice_text);

    // Write SPICE file
    const platform_fs = @import("utility").platform.fs;
    platform_fs.cwd().writeFile(.{ .sub_path = spice_path, .data = spice_text }) catch {
        state.setStatus("Failed to write SPICE netlist");
        return;
    };

    // 4. Check if analysis file exists
    const analysis_exists = blk: {
        platform_fs.cwd().access(analysis_path, .{}) catch break :blk false;
        break :blk true;
    };

    if (!analysis_exists) {
        // Generate initial template with PySpice circuit code + boilerplate
        const pyspice_code = @import("simulation").Netlist.emitPySpice(&fio.sch, alloc, null) catch null;
        defer if (pyspice_code) |code| alloc.free(code);
        generateAnalysisTemplate(alloc, analysis_path, stem, spice_path, pyspice_code) catch {
            state.setStatus("Failed to create analysis template");
            return;
        };
        // Try to open in $EDITOR
        openInEditor(alloc, analysis_path);
        state.setStatus("Analysis file created — edit and re-run :sim");
        return;
    }

    // 5. Regenerate the above-marker section with fresh PySpice output (B2)
    regenerateAboveMarker(alloc, analysis_path, &fio.sch);

    // 6. Execute analysis file
    // Ensure cache dir exists
    var cache_buf: [256]u8 = undefined;
    const home = std.posix.getenv("HOME") orelse "/tmp";
    const cache_dir = std.fmt.bufPrint(&cache_buf, "{s}/.cache/schemify", .{home}) catch "/tmp";
    std.fs.cwd().makePath(cache_dir) catch {};

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
                state.setStatus("Simulation complete");
            } else {
                // Check stderr for known errors
                if (std.mem.indexOf(u8, stderr_data, "ModuleNotFoundError: No module named 'PySpice'") != null) {
                    fio.sim_results = .{ .status = .pyspice_not_found };
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
            state.setStatus("Simulation terminated abnormally");
        },
    }
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
    if (is_wasm) { state.setStatus("Waveform viewer not available in browser"); return; }
    const fio = state.active() orelse { state.setStatus("No active document"); return; };
    const base_name: []const u8 = switch (fio.origin) {
        .chn_file => |p| std.fs.path.stem(p),
        else => { state.setStatus("Save the file first"); return; },
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
    // Fallback: open raw file in xterm with ngspice
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
fn regenerateAboveMarker(alloc: std.mem.Allocator, analysis_path: []const u8, sch: anytype) void {
    const Netlist = @import("simulation").Netlist;
    const platform_fs = @import("utility").platform.fs;

    // Generate fresh PySpice code from the current schematic
    const pyspice_code = Netlist.emitPySpice(sch, alloc, null) catch return;
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
    spice_path: []const u8,
    pyspice_code: ?[]const u8,
) !void {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(alloc);
    const w = buf.writer(alloc);

    try w.writeAll("#!/usr/bin/env python3\n");
    try w.writeAll("# === AUTO-GENERATED FROM SCHEMATIC (do not edit above this line) ===\n");
    try w.writeAll("#\n");
    try w.print("# Analysis script for: {s}\n", .{stem});
    try w.print("# SPICE netlist: {s}\n", .{spice_path});
    try w.writeAll("#\n");
    try w.writeAll("# Dependencies: pip install PySpice\n");
    try w.writeAll("#\n\n");

    // Emit PySpice circuit code if available, otherwise fall back to parser-based template
    if (pyspice_code) |code| {
        try w.writeAll(code);
        try w.writeByte('\n');
    } else {
        try w.writeAll("import sys\n");
        try w.writeAll("try:\n");
        try w.writeAll("    from PySpice.Spice.Parser import SpiceParser\n");
        try w.writeAll("    from PySpice.Spice.Netlist import Circuit\n");
        try w.writeAll("    from PySpice.Unit import *\n");
        try w.writeAll("except ImportError:\n");
        try w.writeAll("    print('PySpice not installed. Run: pip install PySpice', file=sys.stderr)\n");
        try w.writeAll("    sys.exit(1)\n\n");
        try w.print("parser = SpiceParser(path='{s}')\n", .{spice_path});
        try w.writeAll("circuit = parser.build_circuit()\n\n");
    }

    try w.writeAll(analysis_marker);
    try w.writeAll("\n\n");
    try w.writeAll("# Example: DC operating point\n");
    try w.writeAll("# simulator = circuit.simulator()\n");
    try w.writeAll("# analysis = simulator.operating_point()\n");
    try w.writeAll("# for node in analysis.nodes.values():\n");
    try w.writeAll("#     print(f'{node}: {float(node):.4f} V')\n\n");
    try w.writeAll("# Example: Transient analysis\n");
    try w.writeAll("# simulator = circuit.simulator()\n");
    try w.writeAll("# analysis = simulator.transient(step_time=1@u_ns, end_time=100@u_ns)\n\n");
    try w.writeAll("print(f'Circuit: {circuit.title}')\n");
    try w.writeAll("print(f'Nodes: {len(circuit.nodes)} Devices: {len(circuit.elements)}')\n");
    try w.writeAll("print('Edit this file to add your simulation analysis.')\n");

    try @import("utility").platform.fs.cwd().writeFile(.{ .sub_path = path, .data = buf.items });
}

fn openInEditor(alloc: std.mem.Allocator, path: []const u8) void {
    const editor = std.posix.getenv("EDITOR") orelse std.posix.getenv("VISUAL") orelse return;

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
