//! Fixed-size ring buffer for optimizer log lines.
//! 100 lines × 128 bytes each. No allocator.

const std = @import("std");

pub const LOG_LINES = 100;
pub const LOG_LINE_LEN = 128;

pub const LogBuf = struct {
    buf: [LOG_LINES][LOG_LINE_LEN]u8 = [_][LOG_LINE_LEN]u8{[_]u8{0} ** LOG_LINE_LEN} ** LOG_LINES,
    lens: [LOG_LINES]u8 = [_]u8{0} ** LOG_LINES,
    head: usize = 0,
    count: usize = 0,

    /// Append a line (truncated to LOG_LINE_LEN-1). Overwrites oldest when full.
    pub fn append(self: *LogBuf, line: []const u8) void {
        const slot = self.head % LOG_LINES;
        const n = @min(line.len, LOG_LINE_LEN - 1);
        @memcpy(self.buf[slot][0..n], line[0..n]);
        self.lens[slot] = @intCast(n);
        self.head = (self.head + 1) % LOG_LINES;
        if (self.count < LOG_LINES) self.count += 1;
    }

    /// Number of valid lines currently stored.
    pub fn len(self: *const LogBuf) usize {
        return self.count;
    }

    /// Get the i-th line (0 = oldest, count-1 = newest).
    pub fn get(self: *const LogBuf, i: usize) []const u8 {
        std.debug.assert(i < self.count);
        const oldest = if (self.count < LOG_LINES)
            0
        else
            self.head % LOG_LINES;
        const slot = (oldest + i) % LOG_LINES;
        return self.buf[slot][0..self.lens[slot]];
    }

    pub fn clear(self: *LogBuf) void {
        self.head = 0;
        self.count = 0;
    }
};

test "append and get in order" {
    var lb = LogBuf{};
    lb.append("line A");
    lb.append("line B");
    lb.append("line C");
    try std.testing.expectEqual(@as(usize, 3), lb.len());
    try std.testing.expectEqualStrings("line A", lb.get(0));
    try std.testing.expectEqualStrings("line C", lb.get(2));
}

test "ring wraps oldest" {
    var lb = LogBuf{};
    for (0..LOG_LINES + 5) |i| {
        var buf: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "line {d}", .{i}) catch unreachable;
        lb.append(s);
    }
    try std.testing.expectEqual(@as(usize, LOG_LINES), lb.len());
    try std.testing.expectEqualStrings("line 5", lb.get(0));
}
