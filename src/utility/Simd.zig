//! SIMD-accelerated text scanning primitives used by Reader/Writer.

const std = @import("std");

const VEC_LEN = 16;
const Vec = @Vector(VEC_LEN, u8);

/// Locate a byte using 16-byte vector chunks with scalar tail fallback.
pub fn findByte(haystack: []const u8, needle: u8) ?usize {
    const splat_n: Vec = @splat(needle);
    var i: usize = 0;
    while (i + VEC_LEN <= haystack.len) {
        const chunk: Vec = haystack[i..][0..VEC_LEN].*;
        const cmp = chunk == splat_n;
        const mask: u16 = @bitCast(@as(@Vector(VEC_LEN, u1), @intFromBool(cmp)));
        if (mask != 0) return i + @ctz(mask);
        i += VEC_LEN;
    }
    while (i < haystack.len) : (i += 1) {
        if (haystack[i] == needle) return i;
    }
    return null;
}

/// Newline scanner for large text inputs.
pub const LineIterator = struct {
    data: []const u8,
    pos: usize = 0,

    /// Wrap a byte slice for line-by-line iteration without copying.
    pub fn init(data: []const u8) LineIterator {
        return .{ .data = data };
    }

    /// Advance to the next line; returns null when the input is exhausted.
    pub fn next(self: *LineIterator) ?[]const u8 {
        if (self.pos >= self.data.len) return null;
        const remaining = self.data[self.pos..];
        if (findByte(remaining, '\n')) |nl| {
            const line = remaining[0..nl];
            self.pos += nl + 1;
            return line;
        }
        self.pos = self.data.len;
        return remaining;
    }
};

/// Heuristic output-size estimate for CHN writer pre-allocation.
pub fn estimateCHNSize(s: anytype) usize {
    return 64 +
        s.wires.len * 60 +
        s.instances.len * 128 +
        s.texts.len * 80 +
        s.lines.len * 50 +
        s.rects.len * 50 +
        s.arcs.len * 60 +
        s.circles.len * 50 +
        s.pins.len * 40 +
        s.sym_props.items.len * 40;
}
