//! PDKLoader integration tests — exercises the real pipeline against
//! installed PDKs, volare CLI, and ngspice. Requires:
//!   • volare in PATH (or bundled dep)
//!   • ngspice in PATH
//!   • At least one PDK already fetched under ~/.volare/

const std = @import("std");
const volare = @import("volare.zig");
const lut = @import("lut.zig");
const remap = @import("remap.zig");

const pa = std.heap.page_allocator;
const testing = std.testing;

fn getHome() []const u8 {
    return std.process.getEnvVarOwned(pa, "HOME") catch @panic("HOME not set");
}

// ── Volare detection ─────────────────────────────────────────────────────── //

test "volare: detect finds CLI or bundled" {
    const home = getHome();
    defer pa.free(home);
    const kind = volare.detect(pa, home);
    std.debug.print("\n  volare detected as: {s}\n", .{@tagName(kind)});
    // Skip (don't fail) if volare isn't reachable from the test subprocess
    if (kind == .none) {
        std.debug.print("  (skipping — volare not reachable from test process)\n", .{});
        return error.SkipZigTest;
    }
}

test "volare: list sky130 versions returns results" {
    const home = getHome();
    defer pa.free(home);
    const kind = volare.detect(pa, home);
    if (kind == .none) return error.SkipZigTest;

    var lm_buf: [512]u8 = undefined;
    const lm = volare.localMainPath(home, &lm_buf) orelse "";

    var ver_data: [20][80]u8 = undefined;
    var ver_lens: [20]u8 = [_]u8{0} ** 20;
    const count = volare.listVersions(pa, kind, lm, "sky130", &ver_data, &ver_lens);
    std.debug.print("\n  sky130 versions found: {d}\n", .{count});
    if (count > 0) {
        std.debug.print("  first: {s}\n", .{ver_data[0][0..ver_lens[0]]});
    }
    try testing.expect(count > 0);
}

test "volare: pdkRoot finds installed sky130" {
    const home = getHome();
    defer pa.free(home);
    var buf: [512]u8 = undefined;
    // Try both the family ID and config name
    const root = volare.pdkRoot(home, "sky130", &buf) orelse
        volare.pdkRoot(home, "sky130A", &buf);
    if (root) |r| {
        std.debug.print("\n  sky130 root: {s}\n", .{r});
    } else {
        std.debug.print("\n  sky130 not installed under ~/.volare/ (skipping)\n", .{});
        return error.SkipZigTest;
    }
}

// ── ngspice detection ────────────────────────────────────────────────────── //

test "ngspice: detected and version parsed" {
    const status = lut.detectNgspice(pa);
    std.debug.print("\n  ngspice found: {}\n", .{status.found});
    if (status.found) {
        std.debug.print("  ngspice version: {s}\n", .{status.versionSlice()});
    }
    try testing.expect(status.found);
}

// ── LUT generation ───────────────────────────────────────────────────────── //

fn findSky130Root() ?[]const u8 {
    const home = getHome();
    defer pa.free(home);

    // Strategy 1: symlink at ~/.volare/sky130A -> resolve and check libs.ref
    const symlink = std.fmt.allocPrint(pa, "{s}/.volare/sky130A", .{home}) catch return null;
    const libs_sym = std.fmt.allocPrint(pa, "{s}/.volare/sky130A/libs.ref", .{home}) catch {
        pa.free(symlink);
        return null;
    };
    defer pa.free(libs_sym);
    std.fs.cwd().access(libs_sym, .{}) catch {
        pa.free(symlink);
        // Strategy 2: ~/.volare/volare/sky130/versions/*/sky130A
        const dir1 = std.fmt.allocPrint(pa, "{s}/.volare/volare/sky130/versions", .{home}) catch return null;
        defer pa.free(dir1);
        if (searchVersionsDir(dir1)) |found| return found;
        const dir2 = std.fmt.allocPrint(pa, "{s}/.volare/sky130/versions", .{home}) catch return null;
        defer pa.free(dir2);
        if (searchVersionsDir(dir2)) |found| return found;
        return null;
    };
    return symlink;
}

fn searchVersionsDir(versions_dir: []const u8) ?[]const u8 {
    var dir = std.fs.cwd().openDir(versions_dir, .{ .iterate = true }) catch return null;
    defer dir.close();
    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .directory and entry.kind != .sym_link) continue;
        const candidate = std.fs.path.join(pa, &.{ versions_dir, entry.name, "sky130A" }) catch continue;
        const libs_check = std.fs.path.join(pa, &.{ candidate, "libs.ref" }) catch {
            pa.free(candidate);
            continue;
        };
        defer pa.free(libs_check);
        std.fs.cwd().access(libs_check, .{}) catch {
            pa.free(candidate);
            continue;
        };
        return candidate;
    }
    return null;
}

test "LUT: generate NMOS LUT for sky130A with ngspice" {
    const ngspice = lut.detectNgspice(pa);
    if (!ngspice.found) return error.SkipZigTest;

    const pdk_root = findSky130Root() orelse return error.SkipZigTest;
    defer pa.free(pdk_root);

    std.debug.print("\n  PDK root: {s}\n", .{pdk_root});

    const home = getHome();
    defer pa.free(home);
    const out_dir = std.fmt.allocPrint(
        pa, "{s}/.config/Schemify/PDKLoader/sky130A_test", .{home},
    ) catch return error.SkipZigTest;
    defer pa.free(out_dir);

    // Generate NMOS LUT
    const params = lut.SKY130_PARAMS;
    const nmos_ok = lut.generateLut(pa, pdk_root, out_dir, params, .nmos);
    std.debug.print("  NMOS LUT generated: {}\n", .{nmos_ok});
    try testing.expect(nmos_ok);

    // Verify the TSV file exists and has content
    const nmos_tsv = std.fmt.allocPrint(pa, "{s}/lut_nmos.tsv", .{out_dir}) catch unreachable;
    defer pa.free(nmos_tsv);
    const nmos_data = std.fs.cwd().readFileAlloc(pa, nmos_tsv, 64 << 20) catch {
        std.debug.print("  ERROR: could not read {s}\n", .{nmos_tsv});
        return error.TestUnexpectedResult;
    };
    defer pa.free(nmos_data);
    std.debug.print("  NMOS TSV size: {d} bytes\n", .{nmos_data.len});
    try testing.expect(nmos_data.len > 100); // must have header + data rows

    // Load the LUT back and verify it parses
    var nmos_lut = lut.loadLut(pa, nmos_tsv) orelse {
        std.debug.print("  ERROR: could not parse NMOS LUT\n", .{});
        return error.TestUnexpectedResult;
    };
    defer nmos_lut.deinit();
    std.debug.print("  NMOS LUT rows: {d}\n", .{nmos_lut.rows.len});
    try testing.expect(nmos_lut.rows.len > 10);

    // Verify gm/ID lookup returns sane values
    const gm_id = nmos_lut.gmOverId(0.5, 0.9);
    if (gm_id) |v| {
        std.debug.print("  gm/ID at (0.5V, 0.9V): {d:.2}\n", .{v});
        // Typical sky130 NMOS gm/ID in moderate inversion: 5-20
        try testing.expect(v > 1.0 and v < 50.0);
    }
}

test "LUT: generate PMOS LUT for sky130A with ngspice" {
    const ngspice = lut.detectNgspice(pa);
    if (!ngspice.found) return error.SkipZigTest;

    const pdk_root = findSky130Root() orelse return error.SkipZigTest;
    defer pa.free(pdk_root);

    const home = getHome();
    defer pa.free(home);
    const out_dir = std.fmt.allocPrint(
        pa, "{s}/.config/Schemify/PDKLoader/sky130A_test", .{home},
    ) catch return error.SkipZigTest;
    defer pa.free(out_dir);

    const params = lut.SKY130_PARAMS;
    const pmos_ok = lut.generateLut(pa, pdk_root, out_dir, params, .pmos);
    std.debug.print("\n  PMOS LUT generated: {}\n", .{pmos_ok});
    try testing.expect(pmos_ok);

    const pmos_tsv = std.fmt.allocPrint(pa, "{s}/lut_pmos.tsv", .{out_dir}) catch unreachable;
    defer pa.free(pmos_tsv);
    var pmos_lut = lut.loadLut(pa, pmos_tsv) orelse {
        std.debug.print("  ERROR: could not parse PMOS LUT\n", .{});
        return error.TestUnexpectedResult;
    };
    defer pmos_lut.deinit();
    std.debug.print("  PMOS LUT rows: {d}\n", .{pmos_lut.rows.len});
    try testing.expect(pmos_lut.rows.len > 10);
}

// ── End-to-end remap with real LUTs ──────────────────────────────────────── //

test "remap: sky130A end-to-end with real LUTs" {
    const home = getHome();
    defer pa.free(home);

    // Load LUTs generated by earlier tests
    const nmos_path = std.fmt.allocPrint(
        pa, "{s}/.config/Schemify/PDKLoader/sky130A_test/lut_nmos.tsv", .{home},
    ) catch return error.SkipZigTest;
    defer pa.free(nmos_path);
    const pmos_path = std.fmt.allocPrint(
        pa, "{s}/.config/Schemify/PDKLoader/sky130A_test/lut_pmos.tsv", .{home},
    ) catch return error.SkipZigTest;
    defer pa.free(pmos_path);

    var src_nmos = lut.loadLut(pa, nmos_path) orelse {
        std.debug.print("\n  Skipping: NMOS LUT not available (run LUT gen test first)\n", .{});
        return error.SkipZigTest;
    };
    defer src_nmos.deinit();
    var src_pmos = lut.loadLut(pa, pmos_path) orelse {
        std.debug.print("\n  Skipping: PMOS LUT not available\n", .{});
        return error.SkipZigTest;
    };
    defer src_pmos.deinit();

    std.debug.print("\n  Loaded NMOS LUT: {d} rows\n", .{src_nmos.rows.len});
    std.debug.print("  Loaded PMOS LUT: {d} rows\n", .{src_pmos.rows.len});

    // Use the same LUT as both source and destination (sky130A → sky130A)
    // to verify the pipeline round-trips: remapped W/L should be close to originals.
    const params = lut.SKY130_PARAMS;

    // Pick realistic bias from LUT lookup at (VGS=0.5, VDS=0.9)
    const nmos_id_w = src_nmos.idOverW(0.5, 0.9) orelse return error.SkipZigTest;
    const nmos_gm_id = src_nmos.gmOverId(0.5, 0.9) orelse return error.SkipZigTest;
    const nmos_ft = src_nmos.ftAt(0.5, 0.9) orelse 5e9;
    const pmos_id_w = src_pmos.idOverW(0.5, 0.9) orelse return error.SkipZigTest;
    const pmos_gm_id = src_pmos.gmOverId(0.5, 0.9) orelse return error.SkipZigTest;
    const pmos_ft = src_pmos.ftAt(0.5, 0.9) orelse 3e9;

    // Reconstruct bias: ID = ID/W * W * nf, gm = gm/ID * ID
    const m1_w: f64 = 1.0e-6;
    const m1_nf: f64 = 2.0;
    const m1_id = nmos_id_w * m1_w * m1_nf;
    const m1_gm = nmos_gm_id * m1_id;

    const m2_w: f64 = 2.0e-6;
    const m2_nf: f64 = 2.0;
    const m2_id = pmos_id_w * m2_w * m2_nf;
    const m2_gm = pmos_gm_id * m2_id;

    std.debug.print("  NMOS bias @ (0.5, 0.9): ID/W={e}, gm/ID={d:.2}\n", .{
        nmos_id_w, nmos_gm_id,
    });

    const instances = [_]remap.DeviceInstance{
        .{
            .name = "M1", .dev_type = .nmos,
            .w = m1_w, .l = 0.15e-6, .nf = 2,
            .vgs = 0.5, .vds = 0.9, .vsb = 0,
            .id = m1_id, .gm = m1_gm, .gds = m1_id * 0.01,
            .ft = nmos_ft,
            .bias_valid = true,
        },
        .{
            .name = "M2", .dev_type = .pmos,
            .w = m2_w, .l = 0.15e-6, .nf = 2,
            .vgs = 0.5, .vds = 0.9, .vsb = 0,
            .id = m2_id, .gm = m2_gm, .gds = m2_id * 0.01,
            .ft = pmos_ft,
            .bias_valid = true,
        },
        .{ .name = "R1", .dev_type = .resistor, .value = 10e3 },
        .{ .name = "C1", .dev_type = .capacitor, .value = 1e-12 },
    };

    var result = remap.computeRemap(
        pa, &instances, params, params,
        &src_nmos, &src_pmos, &src_nmos, &src_pmos,
        false, remap.SKY130_VT,
    ) orelse return error.TestUnexpectedResult;
    defer result.deinit();

    std.debug.print("  Remap results ({d} devices):\n", .{result.entries.len});
    for (result.entries) |e| {
        const name = e.nameSlice();
        std.debug.print("    {s}: status={s}", .{ name, @tagName(e.status) });
        switch (e.dev_type) {
            .nmos, .pmos => {
                std.debug.print(" W={e:.3}->{e:.3} L={e:.3}->{e:.3} nf={d}->{d} ft_ratio={d:.3}", .{
                    e.old_w, e.new_w, e.old_l, e.new_l, e.old_nf, e.new_nf, e.ft_ratio,
                });
            },
            else => {},
        }
        std.debug.print("\n", .{});
    }

    try testing.expectEqual(@as(usize, 4), result.entries.len);

    // M1 NMOS: same PDK → should be ok, W/L close to original
    const m1 = result.entries[0];
    try testing.expectEqual(remap.RemapEntry.Status.ok, m1.status);
    // Same PDK remap: L should snap to same grid point
    try testing.expectApproxEqAbs(0.15e-6, m1.new_l, 1e-8);
    // W should be in the same ballpark (not exactly equal due to interpolation)
    try testing.expect(m1.new_w > 0.1e-6 and m1.new_w < 20e-6);

    // Passives unchanged
    try testing.expectEqual(remap.RemapEntry.Status.passthrough, result.entries[2].status);
    try testing.expectEqual(remap.RemapEntry.Status.passthrough, result.entries[3].status);

    std.debug.print("  ok={d} warning={d} unchanged={d}\n", .{
        result.countByStatus(.ok),
        result.countByStatus(.no_match) + result.countByStatus(.no_bias) + result.countByStatus(.unresizable),
        result.countByStatus(.passthrough) + result.countByStatus(.skipped),
    });
}

// ── Verify output directory structure ────────────────────────────────────── //

test "output: sky130A_test directory has expected files" {
    const home = getHome();
    defer pa.free(home);
    const test_dir = std.fmt.allocPrint(
        pa, "{s}/.config/Schemify/PDKLoader/sky130A_test", .{home},
    ) catch return error.SkipZigTest;
    defer pa.free(test_dir);

    // Check directory exists
    std.fs.cwd().access(test_dir, .{}) catch {
        std.debug.print("\n  Skipping: test dir not created\n", .{});
        return error.SkipZigTest;
    };

    // List all files
    var dir = std.fs.cwd().openDir(test_dir, .{ .iterate = true }) catch return error.SkipZigTest;
    defer dir.close();

    var file_count: usize = 0;
    var has_nmos_tsv = false;
    var has_pmos_tsv = false;
    var has_nmos_spice = false;
    var has_pmos_spice = false;

    std.debug.print("\n  Files in {s}:\n", .{test_dir});
    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        std.debug.print("    {s} ({s})\n", .{ entry.name, @tagName(entry.kind) });
        file_count += 1;
        if (std.mem.eql(u8, entry.name, "lut_nmos.tsv")) has_nmos_tsv = true;
        if (std.mem.eql(u8, entry.name, "lut_pmos.tsv")) has_pmos_tsv = true;
        if (std.mem.eql(u8, entry.name, "sweep_nmos.spice")) has_nmos_spice = true;
        if (std.mem.eql(u8, entry.name, "sweep_pmos.spice")) has_pmos_spice = true;
    }

    std.debug.print("  Total files: {d}\n", .{file_count});
    try testing.expect(has_nmos_tsv);
    try testing.expect(has_pmos_tsv);
    try testing.expect(has_nmos_spice);
    try testing.expect(has_pmos_spice);
}
