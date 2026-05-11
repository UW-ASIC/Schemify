//! Shared helpers used across multiple handler sub-modules.

const std = @import("std");
const builtin = @import("builtin");
pub const is_wasm = builtin.cpu.arch == .wasm32;
const core = @import("core");
pub const types = @import("../types.zig");
pub const Immediate = types.Immediate;
pub const Undoable = types.Undoable;
pub const Point = types.Point;

pub const Error = error{
    OutOfMemory,
    FileNotFound,
    AccessDenied,
    Unexpected,
    Full,
};

pub inline fn selInst(fio: anytype, i: usize) bool {
    return i < fio.selection.instances.bit_length and fio.selection.instances.isSet(i);
}

pub inline fn selWire(fio: anytype, i: usize) bool {
    return i < fio.selection.wires.bit_length and fio.selection.wires.isSet(i);
}

pub inline fn ptEq(a: Point, b: Point) bool {
    return a[0] == b[0] and a[1] == b[1];
}

pub inline fn toggleFlag(state: anytype, comptime field: []const u8, comptime label: []const u8) void {
    const ptr = &@field(state.cmd_flags, field);
    ptr.* = !ptr.*;
    state.setStatus(if (ptr.*) label ++ " on" else label ++ " off");
}

/// Get active document or set a "No document open" status and return null.
/// Replaces the repeated `state.active() orelse return` + status pattern.
pub inline fn withActiveDoc(state: anytype) ?@TypeOf(state.active().?) {
    return state.active() orelse {
        state.setStatus("No document open");
        return null;
    };
}

pub fn pathExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

pub fn resolveSymbolFile(state: anytype, fio: anytype, symbol: []const u8, ext: []const u8, buf: *[512]u8) ?[]const u8 {
    if (std.mem.endsWith(u8, symbol, ext)) {
        if (pathExists(symbol)) return symbol;
    }
    const dir: []const u8 = switch (fio.origin) {
        .chn_file => |p| std.fs.path.dirname(p) orelse ".",
        else => ".",
    };
    if (std.fmt.bufPrint(buf, "{s}/{s}{s}", .{ dir, symbol, ext })) |path| {
        if (pathExists(path)) return path;
    } else |_| {}
    if (std.fmt.bufPrint(buf, "{s}/{s}{s}", .{ state.project_dir, symbol, ext })) |path| {
        if (pathExists(path)) return path;
    } else |_| {}
    return null;
}
