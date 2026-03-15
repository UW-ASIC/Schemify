//! XschemExtractor — XSchem-specific extraction helpers.
//!
//! Covers:
//!   - Symbol file resolution (search-dir traversal, extension fallback)
//!   - Pin-name helpers (bus range matching, expanded name appending)
//!   - Port symbol detection (`isPortSymbol`)
//!
//! These functions are called both during `fromXSchemWithSymbols` construction
//! and during `generateSpiceFor` subckt recursion.

const std = @import("std");
const Allocator = std.mem.Allocator;
const List = std.ArrayListUnmanaged;

// ── Symbol file resolution ────────────────────────────────────────────────── //

/// Find the actual on-disk path for a symbol reference, searching `search_dirs`.
/// Returns an arena-duped path or `error.NotFound`.
pub fn findSymbolFile(a: Allocator, sym_path: []const u8, search_dirs: []const []const u8) ![]const u8 {
    _ = std.fs.cwd().access(sym_path, .{}) catch {
        const base = std.fs.path.basename(sym_path);
        const base_ext = std.fs.path.extension(base);
        const try_sym_ext = base_ext.len == 0;
        const sym_has_dir = std.mem.indexOfScalar(u8, sym_path, '/') != null;
        for (search_dirs) |dir| {
            const candidate1 = std.fmt.allocPrint(a, "{s}/{s}", .{ dir, sym_path }) catch continue;
            _ = std.fs.cwd().access(candidate1, .{}) catch {
                if (!sym_has_dir) {
                    const candidate2 = std.fmt.allocPrint(a, "{s}/{s}", .{ dir, base }) catch continue;
                    _ = std.fs.cwd().access(candidate2, .{}) catch {
                        if (try_sym_ext) {
                            const candidate3 = std.fmt.allocPrint(a, "{s}/{s}.sym", .{ dir, sym_path }) catch continue;
                            _ = std.fs.cwd().access(candidate3, .{}) catch {
                                const candidate4 = std.fmt.allocPrint(a, "{s}/{s}.sym", .{ dir, base }) catch continue;
                                _ = std.fs.cwd().access(candidate4, .{}) catch continue;
                                return candidate4;
                            };
                            return candidate3;
                        }
                        continue;
                    };
                    return candidate2;
                } else if (try_sym_ext) {
                    const candidate3 = std.fmt.allocPrint(a, "{s}/{s}.sym", .{ dir, sym_path }) catch continue;
                    _ = std.fs.cwd().access(candidate3, .{}) catch continue;
                    return candidate3;
                }
                continue;
            };
            return candidate1;
        }
        return error.NotFound;
    };
    return a.dupe(u8, sym_path);
}

// ── Pin name helpers ──────────────────────────────────────────────────────── //

/// Append expanded pin name(s) to `out`. Handles bus ranges like `A[3:0]`.
pub fn appendExpandedPinName(out: *List(u8), name: []const u8, a: Allocator) !void {
    const ob = std.mem.indexOfScalar(u8, name, '[') orelse {
        try out.append(a, ' ');
        try out.appendSlice(a, name);
        return;
    };
    const colon = std.mem.indexOfScalarPos(u8, name, ob + 1, ':') orelse {
        try out.append(a, ' ');
        try out.appendSlice(a, name);
        return;
    };
    const cb = std.mem.indexOfScalarPos(u8, name, colon + 1, ']') orelse {
        try out.append(a, ' ');
        try out.appendSlice(a, name);
        return;
    };
    const prefix = name[0..ob];
    const hi = std.fmt.parseInt(i32, name[ob + 1 .. colon], 10) catch {
        try out.append(a, ' ');
        try out.appendSlice(a, name);
        return;
    };
    const lo = std.fmt.parseInt(i32, name[colon + 1 .. cb], 10) catch {
        try out.append(a, ' ');
        try out.appendSlice(a, name);
        return;
    };
    if (hi >= lo) {
        var i: i32 = hi;
        while (i >= lo) : (i -= 1) {
            const expanded = try std.fmt.allocPrint(a, " {s}[{d}]", .{ prefix, i });
            try out.appendSlice(a, expanded);
        }
    } else {
        var i: i32 = hi;
        while (i <= lo) : (i += 1) {
            const expanded = try std.fmt.allocPrint(a, " {s}[{d}]", .{ prefix, i });
            try out.appendSlice(a, expanded);
        }
    }
}

/// Returns true when a .cir-file pin name matches a bbox (symbol) pin name.
/// Handles scalar-indexed vs range-indexed pin naming.
pub fn pinNameMatchesBbox(cir_pin: []const u8, bbox_pin: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(cir_pin, bbox_pin)) return true;
    const cir_ob = std.mem.indexOfScalar(u8, cir_pin, '[') orelse return false;
    const cir_cb = std.mem.indexOfScalarPos(u8, cir_pin, cir_ob + 1, ']') orelse return false;
    if (std.mem.indexOfScalarPos(u8, cir_pin, cir_ob + 1, ':') != null) return false;
    const cir_prefix = cir_pin[0..cir_ob];
    const cir_idx = std.fmt.parseInt(i32, cir_pin[cir_ob + 1 .. cir_cb], 10) catch return false;
    const bbox_ob = std.mem.indexOfScalar(u8, bbox_pin, '[') orelse return false;
    const bbox_colon = std.mem.indexOfScalarPos(u8, bbox_pin, bbox_ob + 1, ':') orelse return false;
    const bbox_cb = std.mem.indexOfScalarPos(u8, bbox_pin, bbox_colon + 1, ']') orelse return false;
    if (!std.ascii.eqlIgnoreCase(cir_prefix, bbox_pin[0..bbox_ob])) return false;
    const bbox_hi = std.fmt.parseInt(i32, bbox_pin[bbox_ob + 1 .. bbox_colon], 10) catch return false;
    const bbox_lo = std.fmt.parseInt(i32, bbox_pin[bbox_colon + 1 .. bbox_cb], 10) catch return false;
    const lo = @min(bbox_hi, bbox_lo);
    const hi = @max(bbox_hi, bbox_lo);
    return cir_idx >= lo and cir_idx <= hi;
}

// ── Port symbol detection ─────────────────────────────────────────────────── //

/// Returns true if the device's symbol is an XSchem port pin declaration.
pub fn isPortSymbol(symbol: []const u8) bool {
    const base = if (std.mem.lastIndexOfScalar(u8, symbol, '/')) |i| symbol[i + 1 ..] else symbol;
    return std.mem.eql(u8, base, "ipin.sym") or
        std.mem.eql(u8, base, "opin.sym") or
        std.mem.eql(u8, base, "iopin.sym");
}

// ── Symbol base-name helper ───────────────────────────────────────────────── //

pub fn baseSymbol(sym: []const u8) []const u8 {
    const after_slash = if (std.mem.lastIndexOfScalar(u8, sym, '/')) |i| sym[i + 1 ..] else sym;
    return if (std.mem.indexOfScalar(u8, after_slash, '.')) |i| after_slash[0..i] else after_slash;
}

/// Returns true if `name` contains a parseable bus range like `[3:0]`.
pub fn hasBusRange(name: []const u8) bool {
    const ob = std.mem.indexOfScalar(u8, name, '[') orelse return false;
    const colon = std.mem.indexOfScalarPos(u8, name, ob + 1, ':') orelse return false;
    const cb = std.mem.indexOfScalarPos(u8, name, colon + 1, ']') orelse return false;
    _ = std.fmt.parseInt(i32, name[ob + 1 .. colon], 10) catch return false;
    _ = std.fmt.parseInt(i32, name[colon + 1 .. cb], 10) catch return false;
    return true;
}
