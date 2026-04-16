//! Simulation command handlers.

const std     = @import("std");
const builtin = @import("builtin");
const is_wasm = builtin.cpu.arch == .wasm32;
const cmd     = @import("../utils/command.zig");
const Immediate = cmd.Immediate;
const RunSim    = cmd.RunSim;

pub const Error = error{};

pub fn handleImmediate(imm: Immediate, state: anytype) Error!void {
    switch (imm) {
        .open_waveform_viewer => {
            if (is_wasm) { state.setStatus("Waveform viewer not available in browser"); return; }
            const fio = state.active() orelse { state.setStatus("No active document"); return; };
            const base_name = switch (fio.origin) {
                .chn_file => |p| std.fs.path.stem(p),
                else => fio.name,
            };
            // Look for ngspice raw output in /tmp
            var buf: [512]u8 = undefined;
            const raw_path = std.fmt.bufPrint(&buf, "/tmp/{s}.raw", .{base_name}) catch "/tmp/schemify.raw";
            var child = std.process.Child.init(
                &.{ "gtkwave", raw_path },
                state.allocator(),
            );
            child.spawn() catch {
                state.setStatus("gtkwave not found — install gtkwave to view waveforms");
                return;
            };
            state.setStatus("Opened gtkwave");
        },
        else => unreachable,
    }
}

pub fn handleRun(p: RunSim, state: anytype) Error!void {
    if (is_wasm) { state.setStatus("Simulation not available in browser"); return; }
    const fio = state.active() orelse return;
    const netlist = fio.createNetlist(p.sim) catch {
        state.setStatus("Netlist generation failed");
        return;
    };
    defer fio.alloc.free(netlist);
    const term = fio.runSpiceSim(p.sim, netlist) catch {
        state.setStatus("Failed to spawn ngspice");
        return;
    };
    switch (term) {
        .Exited => |code| {
            if (code == 0) {
                state.setStatus("Simulation launched in terminal");
            } else {
                state.setStatus("Simulator exited with error");
            }
        },
        else => state.setStatus("Simulator terminated abnormally"),
    }
}
