//! Fast parsing and formatting primitives for CHN/XSchem text formats.
//!
//! Provides vectorized byte scanning, fast integer/float parsing without
//! std.fmt overhead, fast integer formatting via digit-pair lookup tables,
//! and a SIMD-accelerated line iterator.
//!
//! All @Vector operations use 128-bit width (16 × u8) for universal target
//! support: x86 SSE2, ARM NEON, WASM SIMD128.
//!
//! Use these primitives in hot parse/write loops (CHN reader, XSchem reader,
//! netlist writer). Use std.fmt everywhere else — it handles edge cases (NaN,
//! Inf, scientific notation) that these fast paths deliberately skip.

const std = @import("std");

const VEC_LEN = 16;
const Vec = @Vector(VEC_LEN, u8);

// SIMD Byte Scanning
/// Locate a byte in a large buffer without a scalar loop — 16× throughput vs memchr.
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

/// Resume a findByte search from a known offset without re-scanning the prefix.
pub fn findByteFrom(haystack: []const u8, start: usize, needle: u8) ?usize {
    if (start >= haystack.len) return null;
    const off = findByte(haystack[start..], needle) orelse return null;
    return start + off;
}

// Fast Integer Parsing
/// Avoid std.fmt overhead for the i32 hot path — schematic files are 90% integers.
/// Wrapping arithmetic correctly handles INT_MIN without a special case.
pub fn fastParseI32(s: []const u8) ?i32 {
    if (s.len == 0) return null;
    var i: usize = 0;
    const neg = s[0] == '-';
    if (neg) i = 1;
    if (i >= s.len or s[i] -% '0' > 9) return null;
    var v: u32 = 0;
    while (i < s.len) : (i += 1) {
        const d = s[i] -% '0';
        if (d > 9) return null;
        v = v *% 10 +% d;
    }
    return if (neg) -%@as(i32, @bitCast(v)) else @as(i32, @bitCast(v));
}

/// Range-checked i16 parse reusing the i32 fast path.
pub fn fastParseI16(s: []const u8) ?i16 {
    const v = fastParseI32(s) orelse return null;
    if (v < std.math.minInt(i16) or v > std.math.maxInt(i16)) return null;
    return @intCast(v);
}

/// Range-checked u8 parse reusing the i32 fast path.
pub fn fastParseU8(s: []const u8) ?u8 {
    const v = fastParseI32(s) orelse return null;
    if (v < 0 or v > std.math.maxInt(u8)) return null;
    return @intCast(v);
}

/// Range-checked u16 parse reusing the i32 fast path.
pub fn fastParseU16(s: []const u8) ?u16 {
    const v = fastParseI32(s) orelse return null;
    if (v < 0 or v > std.math.maxInt(u16)) return null;
    return @intCast(v);
}

// Fast Float Parsing
/// Avoid std.fmt overhead for schematic coordinates, which are almost always
/// integer-valued. No scientific notation — falls back to std.fmt when needed.
pub fn fastParseF64(s: []const u8) ?f64 {
    if (s.len == 0) return null;
    var i: usize = 0;
    const neg = s[0] == '-';
    if (neg or s[0] == '+') i = 1;
    if (i >= s.len) return null;

    const digit_start = i;
    var int_part: i64 = 0;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {
        int_part = int_part * 10 + (s[i] - '0');
    }

    var frac_div: f64 = 1.0;
    if (i < s.len and s[i] == '.') {
        i += 1;
        while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {
            int_part = int_part * 10 + (s[i] - '0');
            frac_div *= 10.0;
        }
    }

    if (i == digit_start) return null;

    var result = @as(f64, @floatFromInt(int_part)) / frac_div;
    if (neg) result = -result;
    return result;
}

// Combined Tokenize + Parse — fuse "skip whitespace → extract token → parse"
// into a single pass, eliminating the intermediate allocation tokenizeAny needs.

/// Consume leading horizontal whitespace so token extraction starts on a digit.
inline fn skipWs(data: []const u8, pos: *usize) void {
    while (pos.* < data.len and (data[pos.*] == ' ' or data[pos.*] == '\t')) pos.* += 1;
}

/// Zero-copy tokeniser: returns a view into `data` so the caller can parse
/// without an intermediate allocation. Advances `pos` past the token.
pub fn nextToken(data: []const u8, pos: *usize) ?[]const u8 {
    skipWs(data, pos);
    if (pos.* >= data.len) return null;
    const start = pos.*;
    const sp: Vec = @splat(' ');
    const tab: Vec = @splat('\t');
    while (pos.* + VEC_LEN <= data.len) {
        const chunk: Vec = data[pos.*..][0..VEC_LEN].*;
        const mask: u16 = @bitCast(
            @as(@Vector(VEC_LEN, u1), @intFromBool(chunk == sp)) |
                @as(@Vector(VEC_LEN, u1), @intFromBool(chunk == tab)),
        );
        if (mask != 0) {
            pos.* += @ctz(mask);
            return data[start..pos.*];
        }
        pos.* += VEC_LEN;
    }
    while (pos.* < data.len and data[pos.*] != ' ' and data[pos.*] != '\t') pos.* += 1;
    if (pos.* == start) return null;
    return data[start..pos.*];
}

/// Fused token-and-parse helpers — one call site instead of nextToken + fastParse.
pub fn nextI32(data: []const u8, pos: *usize) ?i32 {
    return fastParseI32(nextToken(data, pos) orelse return null);
}
pub fn nextI16(data: []const u8, pos: *usize) ?i16 {
    return fastParseI16(nextToken(data, pos) orelse return null);
}
pub fn nextU8(data: []const u8, pos: *usize) ?u8 {
    return fastParseU8(nextToken(data, pos) orelse return null);
}
pub fn nextU16(data: []const u8, pos: *usize) ?u16 {
    return fastParseU16(nextToken(data, pos) orelse return null);
}
pub fn nextF64(data: []const u8, pos: *usize) ?f64 {
    return fastParseF64(nextToken(data, pos) orelse return null);
}

/// Grab the remainder of a line after consuming the typed fields that precede it.
pub fn restAfterWs(data: []const u8, pos: usize) []const u8 {
    var p = pos;
    skipWs(data, &p);
    return data[p..];
}

// Fast Integer Formatting

// Digit-pair lookup table: two digits per lookup halves the divmod iterations.
const digit_pairs =
    "00010203040506070809" ++
    "10111213141516171819" ++
    "20212223242526272829" ++
    "30313233343536373839" ++
    "40414243444546474849" ++
    "50515253545556575859" ++
    "60616263646566676869" ++
    "70717273747576777879" ++
    "80818283848586878889" ++
    "90919293949596979899";

/// Avoid std.fmt for the hot write path; caller must supply buf.len >= 11.
pub fn writeI32(buf: []u8, val: i32) usize {
    std.debug.assert(buf.len >= 11);
    if (val == 0) {
        buf[0] = '0';
        return 1;
    }
    var v: u32 = undefined;
    var pos: usize = 0;
    if (val < 0) {
        buf[0] = '-';
        pos = 1;
        v = @intCast(-@as(i64, val));
    } else {
        v = @intCast(val);
    }
    var tmp: [10]u8 = undefined;
    var len: usize = 0;
    while (v >= 100) {
        const r: usize = @intCast(v % 100);
        v /= 100;
        tmp[len] = digit_pairs[r * 2 + 1];
        tmp[len + 1] = digit_pairs[r * 2];
        len += 2;
    }
    if (v >= 10) {
        const r: usize = @intCast(v);
        tmp[len] = digit_pairs[r * 2 + 1];
        tmp[len + 1] = digit_pairs[r * 2];
        len += 2;
    } else {
        tmp[len] = '0' + @as(u8, @intCast(v));
        len += 1;
    }
    @memcpy(buf[pos..][0..len], tmp[0..len]);
    std.mem.reverse(u8, buf[pos..][0..len]);
    return pos + len;
}

/// Write u8 as decimal ASCII, reusing writeI32's digit-pair path.
pub fn writeU8(buf: []u8, val: u8) usize {
    return writeI32(buf, @intCast(val));
}

/// Take the fast integer path for the 95% case (integer-valued coordinates);
/// fall back to std.fmt only for fractional values.
pub fn writeF64(buf: []u8, val: f64) usize {
    const rounded = @round(val);
    if (val == rounded and @abs(val) < 2147483648.0) {
        return writeI32(buf, @as(i32, @intFromFloat(rounded)));
    }
    var fbs = std.io.fixedBufferStream(buf);
    std.fmt.format(fbs.writer(), "{d}", .{val}) catch return 0;
    return fbs.pos;
}

// Line Iterator
/// Newline scanner 16× faster than splitScalar — critical for large XSchem files.
/// Lines include trailing `\r` on CRLF inputs; trim with `std.mem.trim`.
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

// Output Size Estimation
/// Pre-allocate roughly the right buffer size so the CHN writer rarely needs to grow.
/// `s` must have fields: wires, instances, texts, lines, rects, arcs, circles, pins, sym_props.
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

// Tests
test "Expose struct size for parse" {
    const print = std.debug.print;
    print("LineIterator: {d}B\n", .{@sizeOf(LineIterator)});
}
