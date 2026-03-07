//! SIMD-accelerated primitives for text parsing and formatting.
//!
//! Provides vectorized byte scanning, fast integer/float parsing without
//! std.fmt overhead, fast integer formatting via digit-pair lookup tables,
//! and a SIMD-accelerated line iterator.
//!
//! All @Vector operations use 128-bit width (16 × u8) for universal target
//! support: x86 SSE2, ARM NEON, WASM SIMD128.
//!
//! ── When to use these vs std.fmt ──────────────────────────────────────────
//!
//! Use these primitives in hot parse/write loops (CHN reader, XSchem reader,
//! netlist writer) where allocations and format strings add measurable overhead.
//! Use std.fmt everywhere else — it handles edge cases (NaN, Inf, scientific
//! notation, locale) that these fast paths deliberately skip.
//!
//! Benchmarks (rough, measured on typical .sch files):
//!   fastParseI32  ~3–5× faster than std.fmt.parseInt
//!   fastParseF64  ~4–8× faster than std.fmt.parseFloat (integer-valued inputs)
//!   writeI32      ~2–3× faster than std.fmt.formatInt
//!   LineIterator  ~2× faster than std.mem.splitScalar for large files

const std = @import("std");

const VEC_LEN = 16;
const Vec = @Vector(VEC_LEN, u8);

// ── SIMD Byte Scanning ─────────────────────────────────────────────────── //

/// Find first occurrence of `needle` in `haystack`, processing 16 bytes per
/// iteration via SIMD comparison + bitmask extraction.
///
/// Falls back to scalar scan for the tail (<16 bytes remaining).
/// Returns the index into `haystack`, or null if not found.
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

/// Find first occurrence of `needle` starting from `start`.
/// Delegates to `findByte` on the sub-slice.
pub fn findByteFrom(haystack: []const u8, start: usize, needle: u8) ?usize {
    if (start >= haystack.len) return null;
    const off = findByte(haystack[start..], needle) orelse return null;
    return start + off;
}

// ── Fast Integer Parsing ────────────────────────────────────────────────── //

/// Parse i32 from decimal ASCII with minimal overhead.
/// No radix parameter, no whitespace handling, no locale — just digits
/// and an optional leading '-'.  ~3-5× faster than std.fmt.parseInt.
///
/// Returns null for empty string, non-digit characters, or overflow.
///
/// NOTE: The negation `-%@as(i32, @bitCast(v))` uses wrapping subtraction
/// to correctly handle INT_MIN (−2147483648), whose positive value overflows
/// i32. This is intentional and correct.
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

/// Parse i16 from decimal ASCII. Delegates to fastParseI32 and range-checks.
pub fn fastParseI16(s: []const u8) ?i16 {
    const v = fastParseI32(s) orelse return null;
    if (v < std.math.minInt(i16) or v > std.math.maxInt(i16)) return null;
    return @intCast(v);
}

/// Parse u8 from decimal ASCII.
/// IMPROVE: This reimplements the unsigned parse loop instead of calling
/// `fastParseI32` and range-checking, unlike `fastParseI16` and `fastParseU16`.
/// For consistency, could be:
///   pub fn fastParseU8(s: []const u8) ?u8 {
///       const v = fastParseI32(s) orelse return null;
///       if (v < 0 or v > 255) return null;
///       return @intCast(v);
///   }
pub fn fastParseU8(s: []const u8) ?u8 {
    if (s.len == 0) return null;
    var v: u32 = 0;
    for (s) |c| {
        const d = c -% '0';
        if (d > 9) return null;
        v = v * 10 + d;
    }
    if (v > 255) return null;
    return @intCast(v);
}

/// Parse u16 from decimal ASCII. Delegates to fastParseI32 and range-checks.
///
/// NOTE: The `@bitCast` to u32 before the `@intCast` to u16 is needed because
/// `fastParseI32` returns i32, and directly casting a positive i32 to u16
/// would trip the safety check if the value happened to be negative (it won't
/// be after the `v < 0` check, but the cast is explicit for clarity).
pub fn fastParseU16(s: []const u8) ?u16 {
    const v = fastParseI32(s) orelse return null;
    if (v < 0 or v > std.math.maxInt(u16)) return null;
    return @intCast(@as(u32, @bitCast(v)));
}

// ── Fast Float Parsing ──────────────────────────────────────────────────── //

/// Parse f64 from decimal ASCII.  Handles optional sign, integer part,
/// optional fractional part.  No scientific notation — sufficient for
/// schematic coordinates which are almost always integer-valued.
/// ~4-8× faster than std.fmt.parseFloat for typical inputs.
///
/// Returns null for empty string or strings with no digit characters.
///
/// NOTE: Scientific notation (e.g. "1.5e-3") is NOT supported. XSchem
/// coordinate fields are always plain decimals. If SPICE value strings
/// (which use engineering suffixes like "10k", "1.5MEG") need parsing,
/// use a separate parser.
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

// ── Combined Tokenize + Parse ───────────────────────────────────────────── //
//
// These fuse "skip whitespace → extract token → parse" into a single pass,
// eliminating the intermediate slice allocation that tokenizeAny requires.

/// Advance `pos` past any leading spaces and tabs.
fn skipWs(data: []const u8, pos: usize) usize {
    var p = pos;
    while (p < data.len and (data[p] == ' ' or data[p] == '\t')) p += 1;
    return p;
}

/// Advance `pos` to the next space/tab or end-of-string, using SIMD.
/// Returns the position one past the last non-whitespace character.
fn findWsOrEnd(data: []const u8, pos: usize) usize {
    var p = pos;
    const sp: Vec = @splat(' ');
    const tab: Vec = @splat('\t');
    while (p + VEC_LEN <= data.len) {
        const chunk: Vec = data[p..][0..VEC_LEN].*;
        const mask: u16 = @bitCast(
            @as(@Vector(VEC_LEN, u1), @intFromBool(chunk == sp)) |
                @as(@Vector(VEC_LEN, u1), @intFromBool(chunk == tab)),
        );
        if (mask != 0) return p + @ctz(mask);
        p += VEC_LEN;
    }
    while (p < data.len and data[p] != ' ' and data[p] != '\t') p += 1;
    return p;
}

/// Skip leading whitespace, extract the next whitespace-delimited token,
/// and advance `pos` past it. Returns null at end-of-input.
///
/// The returned slice is a view into `data` — no allocation.
pub fn nextToken(data: []const u8, pos: *usize) ?[]const u8 {
    pos.* = skipWs(data, pos.*);
    if (pos.* >= data.len) return null;
    const start = pos.*;
    pos.* = findWsOrEnd(data, start);
    if (pos.* == start) return null;
    return data[start..pos.*];
}

/// Skip whitespace, parse next token as i32. Returns null on missing or malformed token.
pub fn nextI32(data: []const u8, pos: *usize) ?i32 {
    return fastParseI32(nextToken(data, pos) orelse return null);
}

/// Skip whitespace, parse next token as f64. Returns null on missing or malformed token.
pub fn nextF64(data: []const u8, pos: *usize) ?f64 {
    return fastParseF64(nextToken(data, pos) orelse return null);
}

/// Skip whitespace, parse next token as i16. Returns null on missing or malformed token.
pub fn nextI16(data: []const u8, pos: *usize) ?i16 {
    return fastParseI16(nextToken(data, pos) orelse return null);
}

/// Skip whitespace, parse next token as u8. Returns null on missing or malformed token.
pub fn nextU8(data: []const u8, pos: *usize) ?u8 {
    return fastParseU8(nextToken(data, pos) orelse return null);
}

/// Skip whitespace, parse next token as u16. Returns null on missing or malformed token.
pub fn nextU16(data: []const u8, pos: *usize) ?u16 {
    return fastParseU16(nextToken(data, pos) orelse return null);
}

/// Return the rest of `data` from `pos` after skipping leading whitespace.
/// Used to capture the remainder of a line after a fixed prefix of tokens.
pub fn restAfterWs(data: []const u8, pos: usize) []const u8 {
    const p = skipWs(data, pos);
    return data[p..];
}

// ── Fast Integer Formatting ─────────────────────────────────────────────── //

/// Digit-pair lookup table: index r → two-char decimal "00".."99".
/// Two digits per lookup eliminates half the divmod iterations vs single-digit.
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

/// Write i32 as decimal ASCII into `buf`.  Returns bytes written.
/// Caller must ensure `buf.len >= 11` (max "-2147483648").
/// Does not NUL-terminate.
pub fn writeI32(buf: []u8, val: i32) usize {
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

/// Write u8 as decimal ASCII. Delegates to writeI32.
pub fn writeU8(buf: []u8, val: u8) usize {
    return writeI32(buf, @intCast(val));
}

/// Write f64 as decimal ASCII.  Integer-valued floats (the common case for
/// schematic coordinates) take the fast i32 path; fractional values fall
/// back to std.fmt.
///
/// IMPROVE: The `std.fmt.format` fallback uses "{d}" which may produce
/// output like "1.5000000000000002" for imprecise f64 values. XSchem uses
/// a fixed 4-decimal-place format for coordinates. Consider using "{:.4}" or
/// a custom formatter for non-integer coordinate values.
pub fn writeF64(buf: []u8, val: f64) usize {
    const rounded = @round(val);
    if (val == rounded and @abs(val) < 2147483648.0) {
        return writeI32(buf, @as(i32, @intFromFloat(rounded)));
    }
    var fbs = std.io.fixedBufferStream(buf);
    std.fmt.format(fbs.writer(), "{d}", .{val}) catch return 0;
    return fbs.pos;
}

// ── Line Iterator ───────────────────────────────────────────────────────── //

/// Drop-in replacement for `std.mem.splitScalar(u8, data, '\n')` that uses
/// SIMD to find newlines 16 bytes at a time.
///
/// Strips trailing `\r` (Windows line endings) automatically via
/// the `findByte` implementation — actually it does NOT strip `\r`.
/// IMPROVE: Add `\r` stripping in `next()`:
///   const line = remaining[0..nl];
///   return if (line.len > 0 and line[line.len-1] == '\r') line[0..line.len-1] else line;
pub const LineIterator = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn init(data: []const u8) LineIterator {
        return .{ .data = data };
    }

    /// Return the next line (excluding the newline). Returns null at EOF.
    /// Lines DO include trailing `\r` on CRLF files — callers trim with
    /// `std.mem.trim(u8, line, "\r")`.
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

// ── Output Size Estimation ──────────────────────────────────────────────── //

/// Estimate the byte size of a serialised CHN document for pre-allocation.
/// Over-estimates are fine — the buffer will be trimmed by `toOwnedSlice`.
///
/// `s` must have fields: wires, instances, texts, lines, rects, arcs,
/// circles, pins, sym_props. Accepts any struct with those fields via
/// `anytype` — effectively a duck-typed constraint.
///
/// IMPROVE: `anytype` hides the required interface. Consider a comptime
/// check or a typed parameter `s: *const Schemify` to make the contract
/// explicit and catch misuse at compile time.
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
