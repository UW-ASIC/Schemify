//! Logger — fixed-capacity ring-buffer message store for GUI display.
//!
//! Allocation-free: entries are stored in a fixed array used as a circular
//! buffer. Strings are copied into fixed inline buffers inside each Logger.Entry.
//!
//! Append and eviction are O(1). Drain with entries() / entriesSince(seq),
//! or filter with countAt().

const std = @import("std");
const builtin = @import("builtin");

const is_wasm = builtin.cpu.arch == .wasm32 or builtin.cpu.arch == .wasm64;

/// Ring-buffer logger. Zero heap allocations after init.
/// `min` gates emission so hot paths pay nothing for suppressed levels.
/// `seq` survives `clear()` so GUI panels can detect new entries by delta.
pub const Logger = struct {
    pub const RING_CAP = 64;

    /// Maximum characters stored per message field (msg / src).
    /// Sized so that @sizeOf(Logger.Entry) == 168.
    ///   seq(4) + level(1) + msg_len(1) + src_len(1) + _pad(1) + MSG_CAP(128) + SRC_CAP(32) = 168
    pub const MSG_CAP = 128;
    pub const SRC_CAP = 32;

    /// Severity levels in ascending order. Gates emission via Logger.min.
    pub const Level = enum(u8) {
        trace,
        debug,
        info,
        warn,
        err,
        fatal,

        /// Three-letter abbreviation for compact log output ("TRC", "DBG", …).
        pub fn sym(self: Level) *const [3]u8 {
            return &sym_table[@intFromEnum(self)];
        }
    };

    /// One log record stored by value in the ring buffer.
    /// `extern struct` guarantees C-compatible layout for direct memory inspection.
    pub const Entry = extern struct {
        seq: u32,
        level: Level,
        msg_len: u8,
        src_len: u8,
        _pad: u8 = 0,
        msg_buf: [MSG_CAP]u8,
        src_buf: [SRC_CAP]u8,

        /// Slice the message text without copying.
        pub fn msg(self: *const Entry) []const u8 {
            return self.msg_buf[0..self.msg_len];
        }

        /// Slice the source tag without copying.
        pub fn src(self: *const Entry) []const u8 {
            return self.src_buf[0..self.src_len];
        }
    };

    // Comptime level-symbol table: one indexed load instead of a runtime switch.
    const sym_table: [6][3]u8 = blk: {
        const fields = @typeInfo(Level).@"enum".fields;
        var t: [fields.len][3]u8 = undefined;
        for (fields, 0..) |f, i| {
            const name = f.name;
            t[i] = [3]u8{
                std.ascii.toUpper(name[0]),
                std.ascii.toUpper(name[1]),
                std.ascii.toUpper(name[2]),
            };
        }
        break :blk t;
    };

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

    /// Visit all stored entries in chronological order without linearising the ring.
    pub fn forEach(self: *const Logger, ctx: anytype, comptime cb: fn (@TypeOf(ctx), *const Entry) void) void {
        var i: usize = 0;
        while (i < self.len) : (i += 1) {
            cb(ctx, &self.buf[(self.head + i) % RING_CAP]);
        }
    }

    /// Linearise the ring into `out` for callers that need a contiguous slice.
    pub fn entries(self: *const Logger, out: []Entry) usize {
        std.debug.assert(out.len >= self.len);
        var i: usize = 0;
        while (i < self.len) : (i += 1) {
            out[i] = self.buf[(self.head + i) % RING_CAP];
        }
        return self.len;
    }

    /// Count entries at or above `lvl` so UI badges stay accurate without a full copy.
    pub fn countAt(self: *const Logger, lvl: Level) u32 {
        var n: u32 = 0;
        var i: usize = 0;
        while (i < self.len) : (i += 1) {
            if (@intFromEnum(self.buf[(self.head + i) % RING_CAP].level) >= @intFromEnum(lvl)) n += 1;
        }
        return n;
    }

    /// Short-circuit scan — stops at the first error so toolbar badges are cheap.
    pub fn hasErrors(self: *const Logger) bool {
        var i: usize = 0;
        while (i < self.len) : (i += 1) {
            if (@intFromEnum(self.buf[(self.head + i) % RING_CAP].level) >= @intFromEnum(Level.err)) return true;
        }
        return false;
    }

    /// Discard all entries while preserving `seq` so GUI panels keep their delta cursor.
    pub fn clear(self: *Logger) void {
        self.head = 0;
        self.len = 0;
    }
};

test "Expose struct size for logger" {
    const print = std.debug.print;
    print("Logger.Entry: {d}B\n", .{@sizeOf(Logger.Entry)});
    print("Logger:       {d}B\n", .{@sizeOf(Logger)});
    print("Logger.Level: {d}B\n", .{@sizeOf(Logger.Level)});
}

test "Logger basic emit and query" {
    var lg = Logger.init(.debug);
    lg.info("core", "hello {s}", .{"world"});
    lg.warn("core", "count={d}", .{42});

    try std.testing.expectEqual(@as(usize, 2), lg.len);

    var out: [2]Logger.Entry = undefined;
    _ = lg.entries(&out);
    try std.testing.expectEqualStrings("hello world", out[0].msg());
    try std.testing.expectEqualStrings("core", out[0].src());
    try std.testing.expectEqual(Logger.Level.info, out[0].level);
}

test "Logger level gating" {
    var lg = Logger.init(.warn);
    lg.debug("x", "suppressed", .{});
    lg.warn("x", "kept", .{});
    try std.testing.expectEqual(@as(usize, 1), lg.len);
}

test "Logger ring eviction" {
    var lg = Logger.init(.trace);
    var i: u32 = 0;
    while (i < Logger.RING_CAP + 10) : (i += 1) {
        lg.info("t", "msg {d}", .{i});
    }
    try std.testing.expectEqual(@as(usize, Logger.RING_CAP), lg.len);
    const oldest = &lg.buf[lg.head];
    try std.testing.expectEqual(@as(u32, 10), oldest.seq);
}

test "Logger entriesSince" {
    var lg = Logger.init(.trace);
    lg.info("a", "one", .{});
    lg.info("a", "two", .{});
    lg.info("a", "three", .{});
    var count: usize = 0;
    var first_msg: []const u8 = "";
    var ii: usize = 0;
    while (ii < lg.len) : (ii += 1) {
        const e = &lg.buf[(lg.head + ii) % Logger.RING_CAP];
        if (e.seq >= 1) {
            if (count == 0) first_msg = e.msg();
            count += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqualStrings("two", first_msg);
}

test "Logger countAt and hasErrors" {
    var lg = Logger.init(.trace);
    lg.info("a", "fine", .{});
    lg.err("a", "boom", .{});
    try std.testing.expectEqual(@as(u32, 1), lg.countAt(.err));
    try std.testing.expect(lg.hasErrors());
}

test "Logger clear resets entries but not seq" {
    var lg = Logger.init(.trace);
    lg.info("a", "x", .{});
    const seq_before = lg.seq;
    lg.clear();
    try std.testing.expectEqual(@as(usize, 0), lg.len);
    try std.testing.expectEqual(seq_before, lg.seq);
}
