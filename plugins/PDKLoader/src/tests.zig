//! Comprehensive unit tests for PDKLoader — volare.zig + main.zig logic.
//!
//! Covers:
//!   - pdkFamily() mapping for all known variants
//!   - KNOWN_VARIANTS completeness
//!   - schemifyDir() path construction
//!   - convertToSchemify() with a real temp-filesystem PDK tree
//!   - wid() widget-ID arithmetic (logic replicated from main.zig)
//!   - variantIndex() lookup (logic replicated from main.zig)
//!   - PdkSlot slice-accessor behaviour (logic replicated from main.zig)
//!
//! Run with: zig build test-unit

const std     = @import("std");
const testing = std.testing;
const volare  = @import("volare");

// ── 1. pdkFamily() mapping ───────────────────────────────────────────────── //

test "pdkFamily: sky130A maps to sky130" {
    try testing.expectEqualStrings("sky130", volare.pdkFamily("sky130A"));
}

test "pdkFamily: sky130B maps to sky130" {
    try testing.expectEqualStrings("sky130", volare.pdkFamily("sky130B"));
}

test "pdkFamily: gf180mcuD maps to gf180mcu" {
    try testing.expectEqualStrings("gf180mcu", volare.pdkFamily("gf180mcuD"));
}

test "pdkFamily: gf180mcuC maps to gf180mcu" {
    try testing.expectEqualStrings("gf180mcu", volare.pdkFamily("gf180mcuC"));
}

test "pdkFamily: sg13g2 maps to ihp-sg13g2" {
    try testing.expectEqualStrings("ihp-sg13g2", volare.pdkFamily("sg13g2"));
}

test "pdkFamily: ihp-sg13g2 maps to ihp-sg13g2" {
    try testing.expectEqualStrings("ihp-sg13g2", volare.pdkFamily("ihp-sg13g2"));
}

test "pdkFamily: asap7 maps to asap7" {
    try testing.expectEqualStrings("asap7", volare.pdkFamily("asap7"));
}

test "pdkFamily: unknown variant falls through to itself" {
    try testing.expectEqualStrings("unknown", volare.pdkFamily("unknown"));
    try testing.expectEqualStrings("mymcu42", volare.pdkFamily("mymcu42"));
}

// ── 2. KNOWN_VARIANTS completeness ──────────────────────────────────────── //

test "KNOWN_VARIANTS: contains exactly the expected 8 entries" {
    const expected = [_][]const u8{
        "sky130A", "sky130B",
        "sg13g2", "ihp-sg13g2",
        "gf180mcuD", "gf180mcuC", "gf180mcuB",
        "asap7",
    };
    try testing.expectEqual(expected.len, volare.KNOWN_VARIANTS.len);

    for (expected) |exp| {
        var found = false;
        for (volare.KNOWN_VARIANTS) |kv| {
            if (std.mem.eql(u8, kv, exp)) { found = true; break; }
        }
        if (!found) {
            std.debug.print("KNOWN_VARIANTS missing expected entry: {s}\n", .{exp});
            return error.MissingVariant;
        }
    }
}

test "KNOWN_VARIANTS: no duplicate entries" {
    for (volare.KNOWN_VARIANTS, 0..) |a_name, i| {
        for (volare.KNOWN_VARIANTS, 0..) |b_name, j| {
            if (i == j) continue;
            if (std.mem.eql(u8, a_name, b_name)) {
                std.debug.print("duplicate in KNOWN_VARIANTS: {s}\n", .{a_name});
                return error.DuplicateVariant;
            }
        }
    }
}

// ── 3. schemifyDir() path construction ──────────────────────────────────── //

test "schemifyDir: returns <root>/libs.tech/schemify" {
    const a = testing.allocator;
    const dir = volare.schemifyDir(a, "/home/user/.volare/sky130A") orelse return error.Unexpected;
    defer a.free(dir);
    try testing.expectEqualStrings("/home/user/.volare/sky130A/libs.tech/schemify", dir);
}

test "schemifyDir: preserves absolute root path" {
    const a = testing.allocator;
    const dir = volare.schemifyDir(a, "/opt/pdk/sg13g2") orelse return error.Unexpected;
    defer a.free(dir);
    try testing.expectEqualStrings("/opt/pdk/sg13g2/libs.tech/schemify", dir);
    try testing.expect(std.fs.path.isAbsolute(dir));
}

test "schemifyDir: works with any variant root" {
    const a = testing.allocator;
    const dir = volare.schemifyDir(a, "/tmp/test_pdk") orelse return error.Unexpected;
    defer a.free(dir);
    try testing.expect(std.mem.endsWith(u8, dir, "libs.tech/schemify"));
}

// ── 4. convertToSchemify() with real temp-filesystem PDK tree ────────────── //
//
// Directory layout created under /tmp:
//
//   <tmp>/test_pdk_<n>/sky130A/
//     libs.tech/xschem/
//       nfet_01v8.sym       ← .sym only → .chn_sym
//       pfet_01v8.sym       ← .sym only → .chn_sym
//       tb_inv.sch          ← .sch with no matching .sym → .chn_tb
//       inv.sch             ← .sch + inv.sym pair → .chn
//       inv.sym             ← .sym + inv.sch pair → .chn_sym

const SYM_NFET =
    \\v {xschem version=3.4.5 file_version=1.2}
    \\K {type=nfet value=sky130_fd_pr__nfet_01v8 model=sky130_fd_pr__nfet_01v8}
    \\P {pinnumber=1 name=D dir=inout}
    \\P {pinnumber=2 name=G dir=input}
    \\P {pinnumber=3 name=S dir=inout}
    \\P {pinnumber=4 name=B dir=inout}
    \\
;

const SYM_PFET =
    \\v {xschem version=3.4.5 file_version=1.2}
    \\K {type=pfet value=sky130_fd_pr__pfet_01v8 model=sky130_fd_pr__pfet_01v8}
    \\P {pinnumber=1 name=D dir=inout}
    \\P {pinnumber=2 name=G dir=input}
    \\P {pinnumber=3 name=S dir=inout}
    \\P {pinnumber=4 name=B dir=inout}
    \\
;

const SYM_INV =
    \\v {xschem version=3.4.5 file_version=1.2}
    \\K {type=subcircuit}
    \\P {pinnumber=1 name=A dir=input}
    \\P {pinnumber=2 name=Y dir=output}
    \\
;

// Minimal schematic — just the version header.
const SCH_MINIMAL =
    \\v {xschem version=3.4.5 file_version=1.2}
    \\
;

fn makeTmpPdkTree(a: std.mem.Allocator) !struct {
    root: []const u8,
    xschem_dir: []const u8,
} {
    // Build a unique temporary root under /tmp using a timestamp.
    const ts = @as(u64, @intCast(std.time.milliTimestamp()));
    const root = try std.fmt.allocPrint(a, "/tmp/schemify_test_pdk_{d}/sky130A", .{ts});
    const xschem_dir = try std.fs.path.join(a, &.{ root, "libs.tech", "xschem" });

    // Create the full directory tree.
    try std.fs.cwd().makePath(xschem_dir);

    // Write fixture files.
    try writeFile(xschem_dir, "nfet_01v8.sym", SYM_NFET);
    try writeFile(xschem_dir, "pfet_01v8.sym", SYM_PFET);
    try writeFile(xschem_dir, "inv.sym",        SYM_INV);
    try writeFile(xschem_dir, "inv.sch",        SCH_MINIMAL);
    try writeFile(xschem_dir, "tb_inv.sch",     SCH_MINIMAL);

    return .{ .root = root, .xschem_dir = xschem_dir };
}

fn writeFile(dir_path: []const u8, name: []const u8, data: []const u8) !void {
    var dir = try std.fs.openDirAbsolute(dir_path, .{});
    defer dir.close();
    try dir.writeFile(.{ .sub_path = name, .data = data });
}

fn removeTmpTree(root_parent: []const u8) void {
    // Strip the variant leaf ("sky130A") to get the temp root dir.
    const parent = std.fs.path.dirname(root_parent) orelse return;
    std.fs.cwd().deleteTree(parent) catch {};
}

test "convertToSchemify: returns > 0 for synthetic PDK tree" {
    const a = testing.allocator;
    const tree = try makeTmpPdkTree(a);
    defer {
        removeTmpTree(tree.root);
        a.free(tree.root);
        a.free(tree.xschem_dir);
    }

    const out_dir = try std.fmt.allocPrint(a, "/tmp/schemify_test_out_{d}", .{@as(u64, @intCast(std.time.milliTimestamp()))});
    defer {
        std.fs.cwd().deleteTree(out_dir) catch {};
        a.free(out_dir);
    }

    const pv = volare.PdkVariant{
        .name       = "sky130A",
        .root       = tree.root,
        .version    = null,
        .spice_lib  = null,
        .has_xschem = true,
    };

    const n = try volare.convertToSchemify(a, pv, out_dir);
    std.debug.print("convertToSchemify synthetic: converted {d} files\n", .{n});
    try testing.expect(n > 0);
}

test "convertToSchemify: output dir contains .chn_sym files" {
    const a = testing.allocator;
    const tree = try makeTmpPdkTree(a);
    defer {
        removeTmpTree(tree.root);
        a.free(tree.root);
        a.free(tree.xschem_dir);
    }

    const out_dir = try std.fmt.allocPrint(a, "/tmp/schemify_test_out2_{d}", .{@as(u64, @intCast(std.time.milliTimestamp()))});
    defer {
        std.fs.cwd().deleteTree(out_dir) catch {};
        a.free(out_dir);
    }

    const pv = volare.PdkVariant{
        .name = "sky130A", .root = tree.root,
        .version = null, .spice_lib = null, .has_xschem = true,
    };
    _ = try volare.convertToSchemify(a, pv, out_dir);

    var found_chn_sym = false;
    var out = try std.fs.openDirAbsolute(out_dir, .{ .iterate = true });
    defer out.close();
    var it = out.iterate();
    while (try it.next()) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".chn_sym")) found_chn_sym = true;
    }
    try testing.expect(found_chn_sym);
}

test "convertToSchemify: tb_inv.sch (no matching .sym) produces .chn_tb" {
    const a = testing.allocator;
    const tree = try makeTmpPdkTree(a);
    defer {
        removeTmpTree(tree.root);
        a.free(tree.root);
        a.free(tree.xschem_dir);
    }

    const out_dir = try std.fmt.allocPrint(a, "/tmp/schemify_test_out3_{d}", .{@as(u64, @intCast(std.time.milliTimestamp()))});
    defer {
        std.fs.cwd().deleteTree(out_dir) catch {};
        a.free(out_dir);
    }

    const pv = volare.PdkVariant{
        .name = "sky130A", .root = tree.root,
        .version = null, .spice_lib = null, .has_xschem = true,
    };
    _ = try volare.convertToSchemify(a, pv, out_dir);

    var found_chn_tb = false;
    var out = try std.fs.openDirAbsolute(out_dir, .{ .iterate = true });
    defer out.close();
    var it = out.iterate();
    while (try it.next()) |entry| {
        if (std.mem.eql(u8, entry.name, "tb_inv.chn_tb")) found_chn_tb = true;
    }
    try testing.expect(found_chn_tb);
}

test "convertToSchemify: inv.sch (has matching inv.sym) produces .chn" {
    const a = testing.allocator;
    const tree = try makeTmpPdkTree(a);
    defer {
        removeTmpTree(tree.root);
        a.free(tree.root);
        a.free(tree.xschem_dir);
    }

    const out_dir = try std.fmt.allocPrint(a, "/tmp/schemify_test_out4_{d}", .{@as(u64, @intCast(std.time.milliTimestamp()))});
    defer {
        std.fs.cwd().deleteTree(out_dir) catch {};
        a.free(out_dir);
    }

    const pv = volare.PdkVariant{
        .name = "sky130A", .root = tree.root,
        .version = null, .spice_lib = null, .has_xschem = true,
    };
    _ = try volare.convertToSchemify(a, pv, out_dir);

    var found_chn = false;
    var out = try std.fs.openDirAbsolute(out_dir, .{ .iterate = true });
    defer out.close();
    var it = out.iterate();
    while (try it.next()) |entry| {
        if (std.mem.eql(u8, entry.name, "inv.chn")) found_chn = true;
    }
    try testing.expect(found_chn);
}

test "convertToSchemify: returns 0 when xschem dir does not exist" {
    const a = testing.allocator;
    const pv = volare.PdkVariant{
        .name       = "sky130A",
        .root       = "/tmp/this_path_cannot_exist_schemify_test_xyz",
        .version    = null,
        .spice_lib  = null,
        .has_xschem = false,
    };
    const n = try volare.convertToSchemify(a, pv, "/tmp/irrelevant_out_xyz");
    try testing.expectEqual(@as(u32, 0), n);
}

// ── 5. wid() widget-ID arithmetic ───────────────────────────────────────── //
//
// These constants and the wid() function are private to main.zig.
// Their behaviour is documented in main.zig and replicated here for regression.

const WID_REFRESH   : u32 = 9000;
const WID_TITLE     : u32 = 9001;
const WID_TITLE_SEP : u32 = 9002;

fn wid(slot: usize, offset: u32) u32 {
    return @intCast(slot * 100 + offset);
}

test "wid: slot 0 offset 21 == 21 (clone button)" {
    try testing.expectEqual(@as(u32, 21), wid(0, 21));
}

test "wid: slot 1 offset 22 == 122 (convert button slot 1)" {
    try testing.expectEqual(@as(u32, 122), wid(1, 22));
}

test "wid: slot 3 offset 50 == 350" {
    try testing.expectEqual(@as(u32, 350), wid(3, 50));
}

test "wid: WID_REFRESH == 9000" {
    try testing.expectEqual(@as(u32, 9000), WID_REFRESH);
}

test "wid: WID_TITLE == 9001" {
    try testing.expectEqual(@as(u32, 9001), WID_TITLE);
}

test "wid: WID_TITLE_SEP == 9002" {
    try testing.expectEqual(@as(u32, 9002), WID_TITLE_SEP);
}

test "wid: slot 0 offset 0 == 0 (name label)" {
    try testing.expectEqual(@as(u32, 0), wid(0, 0));
}

test "wid: slot 7 offset 99 == 799 (separator)" {
    try testing.expectEqual(@as(u32, 799), wid(7, 99));
}

// ── 6. variantIndex() lookup ─────────────────────────────────────────────── //
//
// variantIndex() is private to main.zig; replicated here.

fn variantIndex(name: []const u8) ?usize {
    for (volare.KNOWN_VARIANTS, 0..) |v, i| {
        if (std.mem.eql(u8, v, name)) return i;
    }
    return null;
}

test "variantIndex: sky130A is at index 0" {
    try testing.expectEqual(@as(?usize, 0), variantIndex("sky130A"));
}

test "variantIndex: sky130B is at index 1" {
    try testing.expectEqual(@as(?usize, 1), variantIndex("sky130B"));
}

test "variantIndex: sg13g2 is at index 2" {
    try testing.expectEqual(@as(?usize, 2), variantIndex("sg13g2"));
}

test "variantIndex: ihp-sg13g2 is at index 3" {
    try testing.expectEqual(@as(?usize, 3), variantIndex("ihp-sg13g2"));
}

test "variantIndex: gf180mcuD is at index 4" {
    try testing.expectEqual(@as(?usize, 4), variantIndex("gf180mcuD"));
}

test "variantIndex: gf180mcuC is at index 5" {
    try testing.expectEqual(@as(?usize, 5), variantIndex("gf180mcuC"));
}

test "variantIndex: gf180mcuB is at index 6" {
    try testing.expectEqual(@as(?usize, 6), variantIndex("gf180mcuB"));
}

test "variantIndex: asap7 is at index 7" {
    try testing.expectEqual(@as(?usize, 7), variantIndex("asap7"));
}

test "variantIndex: unknown variant returns null" {
    try testing.expectEqual(@as(?usize, null), variantIndex("totally_unknown_pdk"));
    try testing.expectEqual(@as(?usize, null), variantIndex(""));
    try testing.expectEqual(@as(?usize, null), variantIndex("Sky130A")); // case-sensitive
}

// ── 7. PdkSlot slice accessors for zero-initialised slot ─────────────────── //
//
// PdkSlot is private to main.zig.  We replicate just the slice-accessor
// semantics here using a small local struct that mirrors the public contract.

const MAX_NAME : usize = 64;
const MAX_PATH : usize = 512;
const MAX_VER  : usize = 64;

const PdkSlotMirror = struct {
    name:     [MAX_NAME]u8 = [_]u8{0} ** MAX_NAME,
    name_len: u8           = 0,
    root:     [MAX_PATH]u8 = [_]u8{0} ** MAX_PATH,
    root_len: u16          = 0,
    version:  [MAX_VER]u8  = [_]u8{0} ** MAX_VER,
    ver_len:  u8           = 0,

    fn nameSlice(self: *const @This()) []const u8 { return self.name[0..self.name_len]; }
    fn rootSlice(self: *const @This()) []const u8 { return self.root[0..self.root_len]; }
    fn verSlice (self: *const @This()) []const u8 { return self.version[0..self.ver_len]; }
};

test "PdkSlot: zero-initialised name is empty" {
    const s = PdkSlotMirror{};
    try testing.expectEqualStrings("", s.nameSlice());
    try testing.expectEqual(@as(usize, 0), s.nameSlice().len);
}

test "PdkSlot: zero-initialised root is empty" {
    const s = PdkSlotMirror{};
    try testing.expectEqualStrings("", s.rootSlice());
}

test "PdkSlot: zero-initialised version is empty" {
    const s = PdkSlotMirror{};
    try testing.expectEqualStrings("", s.verSlice());
}

test "PdkSlot: name slice reflects written bytes" {
    var s = PdkSlotMirror{};
    const n = "sky130A";
    @memcpy(s.name[0..n.len], n);
    s.name_len = @intCast(n.len);
    try testing.expectEqualStrings("sky130A", s.nameSlice());
}

test "PdkSlot: root slice reflects written bytes" {
    var s = PdkSlotMirror{};
    const r = "/home/user/.volare/sky130A";
    @memcpy(s.root[0..r.len], r);
    s.root_len = @intCast(r.len);
    try testing.expectEqualStrings(r, s.rootSlice());
}

test "PdkSlot: version slice reflects written bytes" {
    var s = PdkSlotMirror{};
    const v = "1.2.3-abc";
    @memcpy(s.version[0..v.len], v);
    s.ver_len = @intCast(v.len);
    try testing.expectEqualStrings(v, s.verSlice());
}
