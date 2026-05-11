//! Simulation handlers — launch simulator, open waveform viewer.

const std = @import("std");
const core = @import("core");
const h = @import("helpers.zig");
const is_wasm = h.is_wasm;
const types = h.types;
const pathExists = h.pathExists;

pub fn handleRunSim(p: types.RunSim, state: anytype) void {
    if (is_wasm) { state.setStatus("Simulation not available in browser"); return; }
    const fio = state.active() orelse { state.setStatus("No active document"); return; };
    const alloc = state.allocator();

    // Need a saved file to derive the temp netlist path.
    const base_name: []const u8 = switch (fio.origin) {
        .chn_file => |path| std.fs.path.stem(path),
        else => { state.setStatus("Save the file first"); return; },
    };

    // Map types.SimBackend -> core SpiceIF.Backend (same tag names).
    const Sim = core.simulation.SpiceIF.Backend;
    const sim: Sim = @enumFromInt(@intFromEnum(p.sim));

    // Generate the SPICE netlist.
    const spice = fio.createNetlist(sim) catch {
        state.setStatus("Netlist generation failed");
        return;
    };
    defer alloc.free(spice);

    // Write netlist to /tmp/{stem}.spice
    var path_buf: [512]u8 = undefined;
    const netlist_path = std.fmt.bufPrint(&path_buf, "/tmp/{s}.spice", .{base_name}) catch {
        state.setStatus("Path too long");
        return;
    };
    const file = std.fs.cwd().createFile(netlist_path, .{}) catch {
        state.setStatus("Failed to write netlist temp file");
        return;
    };
    file.writeAll(spice) catch {
        file.close();
        state.setStatus("Failed to write netlist temp file");
        return;
    };
    file.close();

    // Spawn the simulator process (non-blocking).
    const bin: []const u8 = switch (sim) { .ngspice => "ngspice", .xyce => "xyce", .vacask => "vacask" };
    var child = std.process.Child.init(&.{ bin, netlist_path }, alloc);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch {
        state.setStatus("Failed to launch simulator");
        return;
    };

    var status_buf: [128]u8 = undefined;
    const status_msg = std.fmt.bufPrint(&status_buf, "Simulation launched ({s})", .{@tagName(p.sim)}) catch "Simulation launched";
    state.setStatus(status_msg);
}

fn tryLaunchViewer(alloc: std.mem.Allocator, bin: []const u8, path: []const u8) bool {
    var child = std.process.Child.init(&.{ bin, path }, alloc);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return false;
    return true;
}

pub fn handleOpenWaveformViewer(state: anytype) void {
    if (is_wasm) { state.setStatus("Waveform viewer not available in browser"); return; }
    const fio = state.active() orelse { state.setStatus("No active document"); return; };
    const base_name: []const u8 = switch (fio.origin) {
        .chn_file => |p| std.fs.path.stem(p),
        else => { state.setStatus("Save the file first"); return; },
    };

    // Look for the .raw file produced by simulation
    var raw_buf: [512]u8 = undefined;
    const raw_path = std.fmt.bufPrint(&raw_buf, "/tmp/{s}.raw", .{base_name}) catch {
        state.setStatus("Path too long");
        return;
    };
    if (!pathExists(raw_path)) {
        state.setStatus("No simulation results found \xe2\x80\x94 run a simulation first");
        return;
    }

    // Try gaw first, then gtkwave, then fallback to ngspice
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
