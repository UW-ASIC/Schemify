//! Logger — fixed-capacity ring-buffer message store for GUI display.
//!
//! Allocation-free: entries are stored in a fixed array used as a circular
//! buffer. Strings are copied into fixed inline buffers inside each Logger.Entry.
//!
//! Append and eviction are O(1). Drain with entries() / entriesSince(seq),
//! or filter with countAt().

const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");

const is_wasm = builtin.cpu.arch == .wasm32 or builtin.cpu.arch == .wasm64;

/// Ring-buffer logger. Zero heap allocations after init.
/// `min` gates emission so hot paths pay nothing for suppressed levels.
/// `seq` survives `clear()` so GUI panels can detect new entries by delta.
pub const Logger = struct {
    // Re-export shared types so callers can use Logger.Entry / Logger.Level /
    // Logger.RING_CAP without knowing about types.zig.
    pub const RING_CAP = types.RING_CAP;
    pub const MSG_CAP = types.Entry.MSG_CAP;
    pub const SRC_CAP = types.Entry.SRC_CAP;
    pub const Level = types.Level;
    pub const Entry = types.Entry;

    min: Level,
    seq: u32 = 0,
    head: usize = 0,
    len: usize = 0,
    buf: [RING_CAP]Entry = undefined,

    /// Construct a zero-allocation logger that suppresses messages below `min`.
    pub fn init(min: Level) Logger {
        return .{ .min = min };
    }

    /// Append a formatted message; truncates with `...` if it exceeds MSG_CAP.
    pub fn log(
        self: *Logger,
        lvl: Level,
        source: []const u8,
        comptime fmt: []const u8,
        args: anytype,
    ) void {
        if (@intFromEnum(lvl) < @intFromEnum(self.min)) return;

        const slot = (self.head + self.len) % RING_CAP;
        const entry: *Entry = &self.buf[slot];
        entry.seq = self.seq;
        entry.level = lvl;
        entry._pad = 0;

        const msg_written = std.fmt.bufPrint(&entry.msg_buf, fmt, args) catch blk: {
            _ = std.fmt.bufPrint(entry.msg_buf[0 .. MSG_CAP - 3], fmt, args) catch {};
            entry.msg_buf[MSG_CAP - 3] = '.';
            entry.msg_buf[MSG_CAP - 2] = '.';
            entry.msg_buf[MSG_CAP - 1] = '.';
            break :blk entry.msg_buf[0..MSG_CAP];
        };
        entry.msg_len = @intCast(@min(msg_written.len, MSG_CAP));

        const src_len = @min(source.len, SRC_CAP);
        @memcpy(entry.src_buf[0..src_len], source[0..src_len]);
        entry.src_len = @intCast(src_len);

        if (self.len == RING_CAP) {
            self.head = (self.head + 1) % RING_CAP;
        } else {
            self.len += 1;
        }
        self.seq +%= 1;

        if (!is_wasm) {
            std.debug.print("[{s}] {s}: {s}\n", .{ lvl.sym(), entry.src(), entry.msg() });
        }
    }

    /// Level-specific convenience wrappers — prefer these over calling `log` directly.
    pub fn trace(self: *Logger, source: []const u8, comptime f: []const u8, a: anytype) void {
        self.log(.trace, source, f, a);
    }
    pub fn debug(self: *Logger, source: []const u8, comptime f: []const u8, a: anytype) void {
        self.log(.debug, source, f, a);
    }
    pub fn info(self: *Logger, source: []const u8, comptime f: []const u8, a: anytype) void {
        self.log(.info, source, f, a);
    }
    pub fn warn(self: *Logger, source: []const u8, comptime f: []const u8, a: anytype) void {
        self.log(.warn, source, f, a);
    }
    pub fn err(self: *Logger, source: []const u8, comptime f: []const u8, a: anytype) void {
        self.log(.err, source, f, a);
    }
    pub fn fatal(self: *Logger, source: []const u8, comptime f: []const u8, a: anytype) void {
        self.log(.fatal, source, f, a);
    }

    /// Discard all entries while preserving `seq` so GUI panels keep their delta cursor.
    pub fn clear(self: *Logger) void {
        self.head = 0;
        self.len = 0;
    }
};

test "Expose struct size for logger" {
    const print = std.debug.print;
    print("Logger:       {d}B\n", .{@sizeOf(Logger)});
}
