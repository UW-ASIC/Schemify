const std = @import("std");
const builtin = @import("builtin");

pub const Level = enum(u2) {
    debug,
    info,
    warn,
    err,

    const tags = [_]*const [5]u8{ "DEBUG", "INFO ", "WARN ", "ERROR" };

    pub fn label(self: Level) []const u8 {
        return std.mem.trimRight(u8, tags[@intFromEnum(self)], " ");
    }
};

level: Level,

const Self = @This();

pub fn init(level: Level) Self {
    return .{ .level = level };
}

pub fn info(self: Self, comptime cat: []const u8, comptime fmt: []const u8, args: anytype) void {
    self.emit(.info, cat, fmt, args);
}

pub fn warn(self: Self, comptime cat: []const u8, comptime fmt: []const u8, args: anytype) void {
    self.emit(.warn, cat, fmt, args);
}

pub fn err(self: Self, comptime cat: []const u8, comptime fmt: []const u8, args: anytype) void {
    self.emit(.err, cat, fmt, args);
}

pub fn debug(self: Self, comptime cat: []const u8, comptime fmt: []const u8, args: anytype) void {
    self.emit(.debug, cat, fmt, args);
}

fn emit(self: Self, lvl: Level, comptime cat: []const u8, comptime fmt: []const u8, args: anytype) void {
    if (@intFromEnum(lvl) < @intFromEnum(self.level)) return;
    if (comptime builtin.cpu.arch.isWasm()) return;
    const w = std.fs.File.stderr().deprecatedWriter();
    w.print("[{s}] {s}: " ++ fmt ++ "\n", .{Level.tags[@intFromEnum(lvl)]} ++ .{cat} ++ args) catch {};
}

test "logger suppresses below level" {
    const log = init(.warn);
    // Should not panic — debug is below warn threshold, just a no-op.
    log.debug("test", "value={d}", .{42});
    log.err("test", "oops", .{});
}
