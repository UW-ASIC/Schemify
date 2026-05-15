//! RawFile.zig — Zero-allocation SPICE raw file parser (.raw from ngspice/xyce).
//!
//! The binary raw file format (ngspice):
//!   - ASCII header lines: Title, Date, Plotname, Flags, No. Variables,
//!     No. Points, Variables (indexed list), then "Binary:" or "Values:".
//!   - Binary section: interleaved f64 values (real) or pairs of f64 (complex).
//!
//! All parsing works on a `[]const u8` slice — no heap allocations.

const std = @import("std");

// ── Constants ────────────────────────────────────────────────────────────────

pub const MAX_VARIABLES = 512;
pub const MAX_NAME_LEN = 64;

// ── Types ────────────────────────────────────────────────────────────────────

pub const VarType = enum {
    voltage,
    current,
    time,
    frequency,
    unknown,

    fn fromStr(s: []const u8) VarType {
        const lower = trimWhitespace(s);
        if (eqlIgnoreCase(lower, "voltage")) return .voltage;
        if (eqlIgnoreCase(lower, "current")) return .current;
        if (eqlIgnoreCase(lower, "time")) return .time;
        if (eqlIgnoreCase(lower, "frequency")) return .frequency;
        return .unknown;
    }
};

pub const Variable = struct {
    name: [MAX_NAME_LEN]u8 = .{0} ** MAX_NAME_LEN,
    name_len: u8 = 0,
    var_type: VarType = .unknown,

    fn nameSlice(self: *const Variable) []const u8 {
        return self.name[0..self.name_len];
    }
};

pub const RawHeader = struct {
    num_variables: u32 = 0,
    num_points: u32 = 0,
    is_complex: bool = false,
    is_binary: bool = false,
    variables: [MAX_VARIABLES]Variable = @as([MAX_VARIABLES]Variable, @splat(.{})),
    data_offset: usize = 0,
};

// ── Public API ───────────────────────────────────────────────────────────────

/// Parse raw file header from a memory buffer. No allocations.
/// Returns null if the header is malformed or missing required fields.
pub fn parseHeader(data: []const u8) ?RawHeader {
    var hdr = RawHeader{};
    var pos: usize = 0;
    var in_variables = false;
    var var_count: u32 = 0;

    while (pos < data.len) {
        const line_end = findLineEnd(data, pos);
        const line = data[pos..line_end];

        if (in_variables) {
            // Variable line format: "\t<idx>\t<name>\t<type>\n"
            // or sometimes: "  <idx>  <name>  <type>"
            const trimmed = trimWhitespace(line);
            if (trimmed.len == 0) {
                pos = skipNewline(data, line_end);
                continue;
            }

            // Check if this is a header keyword (end of variables section)
            if (startsWithIgnoreCase(trimmed, "Binary:")) {
                hdr.is_binary = true;
                hdr.data_offset = skipNewline(data, line_end);
                break;
            }
            if (startsWithIgnoreCase(trimmed, "Values:")) {
                hdr.is_binary = false;
                hdr.data_offset = skipNewline(data, line_end);
                break;
            }

            // Parse variable entry
            if (var_count < MAX_VARIABLES) {
                if (parseVariableLine(trimmed)) |v| {
                    hdr.variables[var_count] = v;
                    var_count += 1;
                }
            }
        } else {
            // Header key: value lines
            if (startsWithIgnoreCase(line, "No. Variables:")) {
                hdr.num_variables = parseU32After(line, "No. Variables:") orelse 0;
            } else if (startsWithIgnoreCase(line, "No. Points:")) {
                hdr.num_points = parseU32After(line, "No. Points:") orelse 0;
            } else if (startsWithIgnoreCase(line, "Flags:")) {
                const flags_val = valueAfter(line, "Flags:");
                if (containsIgnoreCase(flags_val, "complex")) hdr.is_complex = true;
            } else if (startsWithIgnoreCase(line, "Variables:")) {
                in_variables = true;
            } else if (startsWithIgnoreCase(line, "Binary:")) {
                hdr.is_binary = true;
                hdr.data_offset = skipNewline(data, line_end);
                break;
            } else if (startsWithIgnoreCase(line, "Values:")) {
                hdr.is_binary = false;
                hdr.data_offset = skipNewline(data, line_end);
                break;
            }
        }

        pos = skipNewline(data, line_end);
    }

    // Validate
    if (hdr.num_variables == 0 or hdr.num_points == 0) return null;
    if (hdr.data_offset == 0) return null;

    return hdr;
}

/// Find variable index by net name. Performs case-insensitive matching.
/// Searches for exact match on `v(name)` or `i(name)`, or the raw name.
fn findVariable(header: *const RawHeader, name: []const u8) ?u32 {
    // Try exact match first
    for (0..header.num_variables) |i| {
        const vname = header.variables[i].nameSlice();
        if (eqlIgnoreCase(vname, name)) return @intCast(i);
    }

    // Try v(name) form
    var v_buf: [MAX_NAME_LEN + 4]u8 = undefined;
    if (name.len + 3 <= v_buf.len) {
        v_buf[0] = 'v';
        v_buf[1] = '(';
        @memcpy(v_buf[2 .. 2 + name.len], name);
        v_buf[2 + name.len] = ')';
        const v_name = v_buf[0 .. 3 + name.len];
        for (0..header.num_variables) |i| {
            const vname = header.variables[i].nameSlice();
            if (eqlIgnoreCase(vname, v_name)) return @intCast(i);
        }
    }

    // Try i(name) form
    if (name.len + 3 <= v_buf.len) {
        v_buf[0] = 'i';
        v_buf[1] = '(';
        @memcpy(v_buf[2 .. 2 + name.len], name);
        v_buf[2 + name.len] = ')';
        const i_name = v_buf[0 .. 3 + name.len];
        for (0..header.num_variables) |i| {
            const vname = header.variables[i].nameSlice();
            if (eqlIgnoreCase(vname, i_name)) return @intCast(i);
        }
    }

    return null;
}

/// Format a floating-point value in engineering notation into a fixed buffer.
/// Returns the slice of formatted text. E.g., 1.234e-3 -> "1.234m", 5.678e6 -> "5.678M".
fn formatEngineering(buf: []u8, value: f64, unit: []const u8) []const u8 {
    if (buf.len < 2) return "";

    const abs_val = @abs(value);
    const is_neg = value < 0;

    const Prefix = struct { threshold: f64, divisor: f64, suffix: u8 };
    const prefixes = [_]Prefix{
        .{ .threshold = 1e12, .divisor = 1e12, .suffix = 'T' },
        .{ .threshold = 1e9, .divisor = 1e9, .suffix = 'G' },
        .{ .threshold = 1e6, .divisor = 1e6, .suffix = 'M' },
        .{ .threshold = 1e3, .divisor = 1e3, .suffix = 'k' },
        .{ .threshold = 1.0, .divisor = 1.0, .suffix = 0 },
        .{ .threshold = 1e-3, .divisor = 1e-3, .suffix = 'm' },
        .{ .threshold = 1e-6, .divisor = 1e-6, .suffix = 'u' },
        .{ .threshold = 1e-9, .divisor = 1e-9, .suffix = 'n' },
        .{ .threshold = 1e-12, .divisor = 1e-12, .suffix = 'p' },
        .{ .threshold = 1e-15, .divisor = 1e-15, .suffix = 'f' },
    };

    // Handle zero
    if (abs_val == 0 or abs_val < 1e-18) {
        return std.fmt.bufPrint(buf, "0{s}", .{unit}) catch "";
    }

    for (prefixes) |p| {
        if (abs_val >= p.threshold * 0.9999) {
            const scaled = (if (is_neg) -abs_val else abs_val) / p.divisor;
            if (p.suffix != 0) {
                return std.fmt.bufPrint(buf, "{d:.3}{c}{s}", .{ scaled, p.suffix, unit }) catch "";
            } else {
                return std.fmt.bufPrint(buf, "{d:.3}{s}", .{ scaled, unit }) catch "";
            }
        }
    }

    // Fallback for very small values
    return std.fmt.bufPrint(buf, "{e}{s}", .{ value, unit }) catch "";
}

// ── Private helpers ──────────────────────────────────────────────────────────

fn parseVariableLine(line: []const u8) ?Variable {
    // Format: "<idx>\t<name>\t<type>"
    // Skip leading whitespace + index
    var pos: usize = 0;

    // Skip index number
    while (pos < line.len and (line[pos] >= '0' and line[pos] <= '9')) : (pos += 1) {}

    // Skip whitespace/tabs
    while (pos < line.len and (line[pos] == ' ' or line[pos] == '\t')) : (pos += 1) {}

    // Read variable name
    const name_start = pos;
    while (pos < line.len and line[pos] != ' ' and line[pos] != '\t') : (pos += 1) {}
    const name = line[name_start..pos];
    if (name.len == 0) return null;

    // Skip whitespace/tabs
    while (pos < line.len and (line[pos] == ' ' or line[pos] == '\t')) : (pos += 1) {}

    // Read type
    const type_start = pos;
    while (pos < line.len and line[pos] != ' ' and line[pos] != '\t' and line[pos] != '\r' and line[pos] != '\n') : (pos += 1) {}
    const var_type_str = line[type_start..pos];

    var v = Variable{};
    const nlen = @min(name.len, MAX_NAME_LEN);
    @memcpy(v.name[0..nlen], name[0..nlen]);
    v.name_len = @intCast(nlen);
    v.var_type = VarType.fromStr(var_type_str);

    return v;
}

fn findLineEnd(data: []const u8, start: usize) usize {
    var pos = start;
    while (pos < data.len and data[pos] != '\n' and data[pos] != '\r') : (pos += 1) {}
    return pos;
}

fn skipNewline(data: []const u8, pos: usize) usize {
    var p = pos;
    if (p < data.len and data[p] == '\r') p += 1;
    if (p < data.len and data[p] == '\n') p += 1;
    return p;
}

fn trimWhitespace(s: []const u8) []const u8 {
    var start: usize = 0;
    while (start < s.len and (s[start] == ' ' or s[start] == '\t')) : (start += 1) {}
    var end = s.len;
    while (end > start and (s[end - 1] == ' ' or s[end - 1] == '\t' or s[end - 1] == '\r' or s[end - 1] == '\n')) : (end -= 1) {}
    return s[start..end];
}

fn parseU32After(line: []const u8, prefix: []const u8) ?u32 {
    if (line.len <= prefix.len) return null;
    const val_str = trimWhitespace(line[prefix.len..]);
    return std.fmt.parseInt(u32, val_str, 10) catch null;
}

fn valueAfter(line: []const u8, prefix: []const u8) []const u8 {
    if (line.len <= prefix.len) return "";
    return trimWhitespace(line[prefix.len..]);
}

fn startsWithIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (haystack.len < needle.len) return false;
    for (haystack[0..needle.len], needle) |h, n| {
        if (toLower(h) != toLower(n)) return false;
    }
    return true;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    for (0..haystack.len - needle.len + 1) |i| {
        if (startsWithIgnoreCase(haystack[i..], needle)) return true;
    }
    return false;
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ac, bc| {
        if (toLower(ac) != toLower(bc)) return false;
    }
    return true;
}

fn toLower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

// ── Tests ────────────────────────────────────────────────────────────────────

test "parseHeader basic" {
    const raw =
        "Title: test\n" ++
        "Date: now\n" ++
        "Plotname: Operating Point\n" ++
        "Flags: real\n" ++
        "No. Variables: 3\n" ++
        "No. Points: 1\n" ++
        "Variables:\n" ++
        "\t0\tv(out)\tvoltage\n" ++
        "\t1\tv(in)\tvoltage\n" ++
        "\t2\ti(v1)\tcurrent\n" ++
        "Binary:\n" ++
        "DEADBEEF";

    const hdr = parseHeader(raw) orelse unreachable;
    try std.testing.expectEqual(@as(u32, 3), hdr.num_variables);
    try std.testing.expectEqual(@as(u32, 1), hdr.num_points);
    try std.testing.expect(hdr.is_binary);
    try std.testing.expect(!hdr.is_complex);
    try std.testing.expectEqualStrings("v(out)", hdr.variables[0].nameSlice());
    try std.testing.expectEqual(VarType.voltage, hdr.variables[0].var_type);
    try std.testing.expectEqualStrings("i(v1)", hdr.variables[2].nameSlice());
    try std.testing.expectEqual(VarType.current, hdr.variables[2].var_type);
}

test "findVariable case insensitive" {
    var hdr = RawHeader{ .num_variables = 2, .num_points = 1, .is_binary = true };
    const name0 = "v(OUT)";
    @memcpy(hdr.variables[0].name[0..name0.len], name0);
    hdr.variables[0].name_len = name0.len;
    hdr.variables[0].var_type = .voltage;
    const name1 = "i(V1)";
    @memcpy(hdr.variables[1].name[0..name1.len], name1);
    hdr.variables[1].name_len = name1.len;
    hdr.variables[1].var_type = .current;

    // Exact match
    try std.testing.expectEqual(@as(?u32, 0), findVariable(&hdr, "v(OUT)"));
    // Case-insensitive
    try std.testing.expectEqual(@as(?u32, 0), findVariable(&hdr, "v(out)"));
    // By net name -> v(name)
    try std.testing.expectEqual(@as(?u32, 0), findVariable(&hdr, "OUT"));
    // Not found
    try std.testing.expectEqual(@as(?u32, null), findVariable(&hdr, "nonexistent"));
}

test "formatEngineering" {
    var buf: [32]u8 = undefined;
    const mv = formatEngineering(&buf, 0.00123, "V");
    try std.testing.expect(mv.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, mv, "m") != null);

    var buf2: [32]u8 = undefined;
    const zero = formatEngineering(&buf2, 0.0, "V");
    try std.testing.expectEqualStrings("0V", zero);
}
