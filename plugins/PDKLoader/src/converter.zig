//! PDK symbol conversion pipeline.
//!
//! After volare fetch, scans `~/.volare/<pdk>/libs.ref/*/xschem/*.sym`,
//! converts each to .chn_prim via the EasyImport XSchem converter, and
//! writes output to `~/.config/Schemify/PDKLoader/<pdk>/prims/`.

const std = @import("std");
const XSchem = @import("xschem");
const core = @import("core");

const Allocator = std.mem.Allocator;

pub const ConvertStats = struct {
    total:     u32 = 0,
    converted: u32 = 0,
    skipped:   u32 = 0,
};

/// Scan all .sym files under the PDK's xschem dirs and convert to .chn_prim.
/// `pdk_root` is e.g. `~/.volare/sky130A/versions/<ver>/sky130A`.
/// `out_dir` is e.g. `~/.config/Schemify/PDKLoader/sky130A/prims/`.
pub fn convertPdkSymbols(
    alloc: Allocator,
    pdk_root: []const u8,
    out_dir: []const u8,
) ConvertStats {
    var stats = ConvertStats{};

    // Ensure output directory exists
    std.fs.cwd().makePath(out_dir) catch return stats;

    // Scan libs.ref/*/xschem/*.sym
    const libs_ref = std.fs.path.join(alloc, &.{ pdk_root, "libs.ref" }) catch return stats;
    defer alloc.free(libs_ref);

    var libs_dir = std.fs.cwd().openDir(libs_ref, .{ .iterate = true }) catch return stats;
    defer libs_dir.close();

    var libs_iter = libs_dir.iterate();
    while (libs_iter.next() catch null) |lib_entry| {
        if (lib_entry.kind != .directory) continue;
        const xschem_path = std.fs.path.join(alloc, &.{
            libs_ref, lib_entry.name, "xschem",
        }) catch continue;
        defer alloc.free(xschem_path);

        var xschem_dir = std.fs.cwd().openDir(xschem_path, .{ .iterate = true }) catch continue;
        defer xschem_dir.close();

        // Create per-library output subdir
        const lib_out = std.fs.path.join(alloc, &.{ out_dir, lib_entry.name }) catch continue;
        defer alloc.free(lib_out);
        std.fs.cwd().makePath(lib_out) catch continue;

        var sym_iter = xschem_dir.iterate();
        while (sym_iter.next() catch null) |sym_entry| {
            if (sym_entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, sym_entry.name, ".sym")) continue;

            stats.total += 1;
            if (convertOneSymbol(alloc, xschem_path, sym_entry.name, lib_out))
                stats.converted += 1
            else
                stats.skipped += 1;
        }
    }

    return stats;
}

/// Convert a single .sym file to .chn_prim and write to out_dir.
fn convertOneSymbol(
    alloc: Allocator,
    sym_dir: []const u8,
    sym_name: []const u8,
    out_dir: []const u8,
) bool {
    // Read the .sym file
    const full_path = std.fs.path.join(alloc, &.{ sym_dir, sym_name }) catch return false;
    defer alloc.free(full_path);
    const data = std.fs.cwd().readFileAlloc(alloc, full_path, 4 << 20) catch return false;
    defer alloc.free(data);

    // Parse XSchem format
    var parsed = XSchem.parse(alloc, data) catch return false;
    defer parsed.deinit();

    // Strip .sym extension for stem name
    const stem = if (std.mem.endsWith(u8, sym_name, ".sym"))
        sym_name[0 .. sym_name.len - 4]
    else
        sym_name;

    // Convert to Schemify (symbol-only: no schematic, just the symbol as primitive)
    var sfy = XSchem.convert(alloc, &parsed, null, stem, null) catch return false;
    defer sfy.deinit();

    // Force primitive stype for PDK symbols
    sfy.setStype(.primitive);

    // Serialize to .chn_prim
    const bytes = sfy.writeFile(alloc, null) orelse return false;
    defer alloc.free(bytes);

    // Write output
    const out_name = std.fmt.allocPrint(alloc, "{s}.chn_prim", .{stem}) catch return false;
    defer alloc.free(out_name);
    const out_path = std.fs.path.join(alloc, &.{ out_dir, out_name }) catch return false;
    defer alloc.free(out_path);

    std.fs.cwd().writeFile(.{ .sub_path = out_path, .data = bytes }) catch return false;
    return true;
}

/// Find the actual PDK root under ~/.volare/<family>/.
/// Volare stores PDKs as: ~/.volare/<family>/versions/<hash>/<variant>/
/// Returns the path to the variant directory, or null.
pub fn findPdkVariantRoot(
    alloc: Allocator,
    home: []const u8,
    volare_id: []const u8,
    config_name: []const u8,
) ?[]const u8 {
    // Check for ~/.volare/<family>/versions/*/config_name
    const versions_dir = std.fmt.allocPrint(
        alloc, "{s}/.volare/{s}/versions", .{ home, volare_id },
    ) catch return null;
    defer alloc.free(versions_dir);

    var dir = std.fs.cwd().openDir(versions_dir, .{ .iterate = true }) catch return null;
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .directory) continue;
        const candidate = std.fs.path.join(alloc, &.{
            versions_dir, entry.name, config_name,
        }) catch continue;
        // Check if this looks like a real PDK (has libs.ref/)
        const libs_check = std.fs.path.join(alloc, &.{ candidate, "libs.ref" }) catch {
            alloc.free(candidate);
            continue;
        };
        defer alloc.free(libs_check);
        std.fs.cwd().access(libs_check, .{}) catch {
            alloc.free(candidate);
            continue;
        };
        return candidate;
    }
    return null;
}

/// Build the output directory path for converted prims.
pub fn primsOutputDir(alloc: Allocator, home: []const u8, config_name: []const u8) ?[]const u8 {
    return std.fmt.allocPrint(
        alloc, "{s}/.config/Schemify/PDKLoader/{s}/prims", .{ home, config_name },
    ) catch null;
}
