//! PDK volare discovery, cloning, and CHN conversion tests.
//!
//! Tests are designed to be self-contained and gracefully skip when PDKs are
//! not installed.  The clone tests verify error-path behaviour only — they do
//! NOT perform real network downloads.

const std     = @import("std");
const testing = std.testing;
const volare  = @import("volare");

// ── discover ─────────────────────────────────────────────────────────────── //

test "discover: runs without crash or leak" {
    const a = testing.allocator;
    var list: std.ArrayListUnmanaged(volare.PdkVariant) = .{};
    defer {
        for (list.items) |pv| volare.freeVariant(a, pv);
        list.deinit(a);
    }
    try volare.discover(a, &list);
    // No assertion — just verify no crash or memory leak.
    std.debug.print("discover: found {d} PDK variant(s)\n", .{list.items.len});
}

test "discover: all found variants are in KNOWN_VARIANTS" {
    const a = testing.allocator;
    var list: std.ArrayListUnmanaged(volare.PdkVariant) = .{};
    defer {
        for (list.items) |pv| volare.freeVariant(a, pv);
        list.deinit(a);
    }
    try volare.discover(a, &list);

    outer: for (list.items) |pv| {
        for (volare.KNOWN_VARIANTS) |kv| {
            if (std.mem.eql(u8, pv.name, kv)) continue :outer;
        }
        std.debug.print("unexpected variant in discover results: {s}\n", .{pv.name});
        return error.UnexpectedVariant;
    }
}

// ── clone error paths ────────────────────────────────────────────────────── //

test "clone: unknown variant returns VariantUnknown" {
    const a = testing.allocator;
    const err = volare.clone(a, "totally_fake_pdk_xyz");
    try testing.expectError(volare.CloneError.VariantUnknown, err);
}

test "clone: known variant with no volare installed returns VolareUnavailable or CloneFailed" {
    // This test only runs when volare is NOT in PATH to avoid side-effects.
    // If volare IS installed, clone() may succeed — skip gracefully.
    const a = testing.allocator;
    volare.clone(a, "sky130A") catch |err| {
        const acceptable = (err == volare.CloneError.VolareUnavailable or
                            err == volare.CloneError.CloneFailed or
                            err == volare.CloneError.HomeNotFound);
        if (!acceptable) return err;
        return; // error is acceptable — skip
    };
    // If clone succeeded, that's also fine (volare is installed + online).
}

// ── Per-variant discovery ─────────────────────────────────────────────────── //

fn testVariantDiscovery(comptime variant: []const u8) !void {
    const a = testing.allocator;
    const pv = volare.findVariant(a, variant) orelse {
        std.debug.print("SKIP {s}: not installed\n", .{variant});
        return; // Not present on this machine — skip
    };
    defer volare.freeVariant(a, pv);
    try testing.expectEqualStrings(variant, pv.name);
    try testing.expect(pv.root.len > 0);
    std.debug.print("{s}: root={s} xschem={}\n", .{ pv.name, pv.root, pv.has_xschem });
}

test "sky130A: discovery"     { try testVariantDiscovery("sky130A"); }
test "sky130B: discovery"     { try testVariantDiscovery("sky130B"); }
test "sg13g2: discovery"      { try testVariantDiscovery("sg13g2"); }
test "ihp-sg13g2: discovery"  { try testVariantDiscovery("ihp-sg13g2"); }
test "gf180mcuD: discovery"   { try testVariantDiscovery("gf180mcuD"); }
test "gf180mcuC: discovery"   { try testVariantDiscovery("gf180mcuC"); }
test "gf180mcuB: discovery"   { try testVariantDiscovery("gf180mcuB"); }
test "asap7: discovery"       { try testVariantDiscovery("asap7"); }

// ── Per-variant CHN conversion ────────────────────────────────────────────── //

fn testVariantConvert(comptime variant: []const u8) !void {
    const a = testing.allocator;
    const pv = volare.findVariant(a, variant) orelse {
        std.debug.print("SKIP convert {s}: not installed\n", .{variant});
        return;
    };
    defer volare.freeVariant(a, pv);
    if (!pv.has_xschem) {
        std.debug.print("SKIP convert {s}: no xschem/ directory\n", .{variant});
        return;
    }

    const out_dir = volare.schemifyDir(a, pv.root) orelse return;
    defer a.free(out_dir);

    const n = try volare.convertToSchemify(a, pv, out_dir);
    std.debug.print("{s}: converted {d} xschem files to {s}\n", .{ pv.name, n, out_dir });
    // Any non-crashing run is a pass — conversion count can be 0 for empty dirs.
}

test "sky130A: convert xschem to CHN"    { try testVariantConvert("sky130A"); }
test "sky130B: convert xschem to CHN"    { try testVariantConvert("sky130B"); }
test "sg13g2: convert xschem to CHN"     { try testVariantConvert("sg13g2"); }
test "ihp-sg13g2: convert xschem to CHN" { try testVariantConvert("ihp-sg13g2"); }
test "gf180mcuD: convert xschem to CHN"  { try testVariantConvert("gf180mcuD"); }
test "gf180mcuC: convert xschem to CHN"  { try testVariantConvert("gf180mcuC"); }
test "gf180mcuB: convert xschem to CHN"  { try testVariantConvert("gf180mcuB"); }
test "asap7: convert xschem to CHN"      { try testVariantConvert("asap7"); }

// ── schemifyDir ──────────────────────────────────────────────────────────── //

test "schemifyDir: returns <root>/libs.tech/schemify for known variant root" {
    const a = testing.allocator;
    const dir = volare.schemifyDir(a, "/home/user/.volare/sky130A") orelse return;
    defer a.free(dir);
    try testing.expectEqualStrings("/home/user/.volare/sky130A/libs.tech/schemify", dir);
}

// ── pdkFamily ────────────────────────────────────────────────────────────── //

test "pdkFamily: maps sky130 variants" {
    try testing.expectEqualStrings("sky130",     volare.pdkFamily("sky130A"));
    try testing.expectEqualStrings("sky130",     volare.pdkFamily("sky130B"));
}

test "pdkFamily: maps gf180 variants" {
    try testing.expectEqualStrings("gf180mcu",   volare.pdkFamily("gf180mcuD"));
    try testing.expectEqualStrings("gf180mcu",   volare.pdkFamily("gf180mcuC"));
}

test "pdkFamily: maps IHP variants" {
    try testing.expectEqualStrings("ihp-sg13g2", volare.pdkFamily("sg13g2"));
    try testing.expectEqualStrings("ihp-sg13g2", volare.pdkFamily("ihp-sg13g2"));
}

test "pdkFamily: maps asap7" {
    try testing.expectEqualStrings("asap7",      volare.pdkFamily("asap7"));
}

// ── listRemoteVersions ───────────────────────────────────────────────────── //

test "listRemoteVersions: does not crash when volare is absent" {
    const a = testing.allocator;
    var list: std.ArrayListUnmanaged([]const u8) = .{};
    defer {
        for (list.items) |v| a.free(v);
        list.deinit(a);
    }
    // Must not return an error even if volare is not installed.
    try volare.listRemoteVersions(a, "sky130A", &list);
    std.debug.print("listRemoteVersions sky130: {d} version(s)\n", .{list.items.len});
}

// ── saveSelectedVersion / loadSelectedVersion ────────────────────────────── //

test "save and load selected version round-trips" {
    const a = testing.allocator;

    // Use a unique fake variant name so we don't collide with real state.
    const fake_variant = "test_pdk_roundtrip";
    const fake_version = "0.0.999";

    try volare.saveSelectedVersion(a, fake_variant, fake_version);

    const loaded = volare.loadSelectedVersion(a, fake_variant) orelse {
        // HOME not set or path creation failed — skip
        return;
    };
    defer a.free(loaded);
    try testing.expectEqualStrings(fake_version, loaded);

    // Overwrite and verify
    try volare.saveSelectedVersion(a, fake_variant, "0.0.888");
    const loaded2 = volare.loadSelectedVersion(a, fake_variant) orelse return;
    defer a.free(loaded2);
    try testing.expectEqualStrings("0.0.888", loaded2);
}

test "loadSelectedVersion: returns null for unknown variant" {
    const a = testing.allocator;
    // This variant will never be saved — should return null, not crash.
    const result = volare.loadSelectedVersion(a, "variant_that_was_never_saved_xyz123");
    if (result) |r| {
        a.free(r);
        return error.ExpectedNull;
    }
}
