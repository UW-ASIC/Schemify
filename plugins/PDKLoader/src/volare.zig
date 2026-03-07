//! Volare-compatible PDK discovery, cloning, and XSchem conversion.
//!
//! Provides three main capabilities:
//!   1. Discover installed PDKs in standard locations.
//!   2. Clone/enable a PDK variant via the `volare` Python tool.
//!   3. Convert a PDK's xschem/ symbols to CHN format files.
//!
//! Discovery search order per variant:
//!   1. $HOME/.volare/<variant>/
//!   2. $PDK_ROOT/<variant>/
//!   3. $PDK/<variant>/
//!   4. /usr/share/pdk/<variant>/
//!   5. /opt/pdk/<variant>/
//!
//! A variant is valid only if it contains `libs.tech/`.

const std = @import("std");
const core = @import("core");

const Allocator = std.mem.Allocator;
const List = std.ArrayListUnmanaged;
const XSchem = core.XSchem;

// ── PDK variant descriptor ───────────────────────────────────────────────── //

/// Describes a single located PDK variant on disk.
pub const PdkVariant = struct {
    /// Short tag, e.g. "sky130A".
    name: []const u8,
    /// Absolute path to the variant root (contains libs.tech/).
    root: []const u8,
    /// Version string from volare metadata, if found.
    version: ?[]const u8,
    /// Absolute path to the primary ngspice .lib.spice file, if found.
    spice_lib: ?[]const u8,
    /// True when `libs.tech/xschem/` exists under root.
    has_xschem: bool,
};

// ── Known variants ───────────────────────────────────────────────────────── //

/// All PDK variant names supported by volare.
pub const KNOWN_VARIANTS = [_][]const u8{
    "sky130A", "sky130B",
    "sg13g2",  "ihp-sg13g2",
    "gf180mcuD", "gf180mcuC", "gf180mcuB",
    "asap7",
};

// ── Internal helpers ─────────────────────────────────────────────────────── //

fn envAlloc(a: Allocator, name: []const u8) ?[]const u8 {
    const val = std.posix.getenv(name) orelse return null;
    return a.dupe(u8, val) catch null;
}

fn homeDir(a: Allocator) ?[]const u8 {
    return envAlloc(a, "HOME");
}

fn volareBase(a: Allocator) ?[]const u8 {
    const home = homeDir(a) orelse return null;
    defer a.free(home);
    return std.fs.path.join(a, &.{ home, ".volare" }) catch null;
}

fn readVersion(a: Allocator, root: []const u8) ?[]const u8 {
    for ([_][]const u8{ "pdk.log", "version", ".version" }) |fname| {
        const path = std.fs.path.join(a, &.{ root, fname }) catch continue;
        defer a.free(path);
        const data = std.fs.cwd().readFileAlloc(a, path, 256) catch continue;
        defer a.free(data);
        const trimmed = std.mem.trim(u8, data, " \t\r\n");
        if (trimmed.len > 0) return a.dupe(u8, trimmed) catch null;
    }
    return null;
}

fn findSpiceLib(a: Allocator, root: []const u8, variant: []const u8) ?[]const u8 {
    var name_buf: [128]u8 = undefined;
    var candidates: [6][]const u8 = undefined;
    var n: usize = 0;

    const c0 = std.fmt.bufPrint(&name_buf, "libs.tech/ngspice/{s}.lib.spice", .{variant}) catch null;
    if (c0) |p| { candidates[n] = p; n += 1; }
    if (std.mem.startsWith(u8, variant, "sky130")) {
        candidates[n] = "libs.tech/ngspice/sky130.lib.spice"; n += 1;
    }
    if (std.mem.startsWith(u8, variant, "sg13") or std.mem.startsWith(u8, variant, "ihp")) {
        candidates[n] = "libs.tech/ngspice/models/ngspice/sg13g2.lib.spice"; n += 1;
    }
    if (std.mem.startsWith(u8, variant, "gf180")) {
        candidates[n] = "libs.tech/ngspice/gf180mcu.lib.spice"; n += 1;
    }
    candidates[n] = "libs.tech/ngspice/primitives.spice"; n += 1;

    for (candidates[0..n]) |rel| {
        const full = std.fs.path.join(a, &.{ root, rel }) catch continue;
        if (std.fs.accessAbsolute(full, .{})) {
            return full;
        } else |_| {
            a.free(full);
        }
    }
    return null;
}

fn probeVariant(a: Allocator, root: []const u8, variant: []const u8) ?PdkVariant {
    if (!std.fs.path.isAbsolute(root)) return null;
    const libs_tech = std.fs.path.join(a, &.{ root, "libs.tech" }) catch return null;
    defer a.free(libs_tech);
    std.fs.accessAbsolute(libs_tech, .{}) catch return null;

    const root_owned = a.dupe(u8, root) catch return null;
    const name_owned = a.dupe(u8, variant) catch { a.free(root_owned); return null; };

    const xschem_path = std.fs.path.join(a, &.{ root, "libs.tech", "xschem" }) catch null;
    const has_xschem = if (xschem_path) |p| blk: {
        const ok = if (std.fs.accessAbsolute(p, .{})) true else |_| false;
        a.free(p);
        break :blk ok;
    } else false;

    return .{
        .name      = name_owned,
        .root      = root_owned,
        .version   = readVersion(a, root_owned),
        .spice_lib = findSpiceLib(a, root_owned, variant),
        .has_xschem = has_xschem,
    };
}

fn buildBases(a: Allocator, out: *List([]const u8)) !void {
    if (volareBase(a)) |vb|          try out.append(a, vb);
    if (envAlloc(a, "PDK_ROOT")) |v| try out.append(a, v);
    if (envAlloc(a, "PDK"))      |v| try out.append(a, v);
    try out.append(a, try a.dupe(u8, "/usr/share/pdk"));
    try out.append(a, try a.dupe(u8, "/opt/pdk"));
}

// ── Public API ───────────────────────────────────────────────────────────── //

/// Scan all standard locations for every known PDK variant.
/// Appends found variants to `out`. All strings are allocator-owned.
pub fn scan(a: Allocator, out: *List(PdkVariant)) !void {
    var bases: List([]const u8) = .{};
    defer { for (bases.items) |b| a.free(b); bases.deinit(a); }
    try buildBases(a, &bases);

    for (KNOWN_VARIANTS) |variant| {
        for (bases.items) |base| {
            const candidate = std.fs.path.join(a, &.{ base, variant }) catch continue;
            defer a.free(candidate);
            if (probeVariant(a, candidate, variant)) |pv| {
                try out.append(a, pv);
                break;
            }
        }
    }
}

/// Alias for scan() — discover all installed PDK variants.
pub fn discover(a: Allocator, out: *List(PdkVariant)) !void {
    return scan(a, out);
}

/// Scan for a single named variant across all standard locations.
/// Returns the first match, or null if not found.
pub fn findVariant(a: Allocator, variant: []const u8) ?PdkVariant {
    var bases: List([]const u8) = .{};
    defer { for (bases.items) |b| a.free(b); bases.deinit(a); }
    buildBases(a, &bases) catch return null;

    for (bases.items) |base| {
        const candidate = std.fs.path.join(a, &.{ base, variant }) catch continue;
        defer a.free(candidate);
        if (probeVariant(a, candidate, variant)) |pv| return pv;
    }
    return null;
}

/// Free all allocator-owned strings inside a PdkVariant returned by scan/findVariant.
pub fn freeVariant(a: Allocator, pv: PdkVariant) void {
    a.free(pv.name);
    a.free(pv.root);
    if (pv.version)   |v| a.free(v);
    if (pv.spice_lib) |s| a.free(s);
}

/// Errors from clone().
pub const CloneError = error{
    HomeNotFound,
    VariantUnknown,
    VolareUnavailable,
    CloneFailed,
    OutOfMemory,
};

/// Enable/clone a PDK variant using the `volare` Python tool.
///
/// Requires `volare` to be installed (`pip install volare`).
/// On success the PDK is available at `~/.volare/<variant>/`.
/// Returns `VolareUnavailable` if volare is not in PATH.
/// Returns `VariantUnknown` if `variant` is not in KNOWN_VARIANTS.
pub fn clone(a: Allocator, variant: []const u8) CloneError!void {
    var known = false;
    for (KNOWN_VARIANTS) |v| if (std.mem.eql(u8, v, variant)) { known = true; break; };
    if (!known) return CloneError.VariantUnknown;

    const home = homeDir(a) orelse return CloneError.HomeNotFound;
    defer a.free(home);

    const volare_dir = std.fs.path.join(a, &.{ home, ".volare" }) catch return CloneError.OutOfMemory;
    defer a.free(volare_dir);
    std.fs.cwd().makePath(volare_dir) catch {};

    const argv = [_][]const u8{ "volare", "enable", variant };
    var child = std.process.Child.init(&argv, a);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return CloneError.VolareUnavailable;
    const term = child.wait() catch return CloneError.CloneFailed;
    if (term == .Exited and term.Exited == 0) return;
    return CloneError.CloneFailed;
}

/// Convert all XSchem symbols/schematics in a variant's libs.tech/xschem/
/// directory to CHN format and write them to `out_dir`.
///
/// `.sch` files become `.chn`, `.sym` files become `.chn_sym`.
/// Creates `out_dir` if it does not exist.
/// Returns the number of files successfully converted.
pub fn convertToSchemify(a: Allocator, variant: PdkVariant, out_dir: []const u8) !u32 {
    const xschem_path = xschemDir(a, variant.root) orelse return 0;
    defer a.free(xschem_path);

    std.fs.cwd().makePath(out_dir) catch |e| return e;

    var dir = std.fs.openDirAbsolute(xschem_path, .{ .iterate = true }) catch return 0;
    defer dir.close();

    var walker = try dir.walk(a);
    defer walker.deinit();

    var count: u32 = 0;
    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        const is_sch = std.mem.endsWith(u8, entry.basename, ".sch");
        const is_sym = std.mem.endsWith(u8, entry.basename, ".sym");
        if (!is_sch and !is_sym) continue;

        const in_path = try std.fs.path.join(a, &.{ xschem_path, entry.path });
        defer a.free(in_path);

        const data = std.fs.cwd().readFileAlloc(a, in_path, 4 * 1024 * 1024) catch continue;
        defer a.free(data);

        var xs = XSchem.readFile(data, a, null);
        defer xs.deinit();

        var sch = xs.toSchemify(a) catch continue;
        defer sch.deinit();

        const out_data = sch.writeFile(a, null) orelse continue;
        defer a.free(out_data);

        const ext = if (is_sch) ".chn" else ".chn_sym";
        const stem_len = entry.basename.len - 4; // ".sch" or ".sym"
        const out_name = try std.fmt.allocPrint(a, "{s}{s}", .{ entry.basename[0..stem_len], ext });
        defer a.free(out_name);

        const out_path = try std.fs.path.join(a, &.{ out_dir, out_name });
        defer a.free(out_path);

        std.fs.cwd().writeFile(.{ .sub_path = out_path, .data = out_data }) catch continue;
        count += 1;
    }
    return count;
}

/// Returns the absolute path to `<root>/libs.tech/xschem/`, or null.
pub fn xschemDir(a: Allocator, root: []const u8) ?[]const u8 {
    const p = std.fs.path.join(a, &.{ root, "libs.tech", "xschem" }) catch return null;
    if (std.fs.accessAbsolute(p, .{})) return p else |_| { a.free(p); return null; }
}

/// Returns the absolute path to `<root>/libs.tech/ngspice/`, or null.
pub fn ngspiceDir(a: Allocator, root: []const u8) ?[]const u8 {
    const p = std.fs.path.join(a, &.{ root, "libs.tech", "ngspice" }) catch return null;
    if (std.fs.accessAbsolute(p, .{})) return p else |_| { a.free(p); return null; }
}

/// Returns the CHN output directory for a given variant.
/// Path: `~/.config/Schemify/pdks/<variant>/`. Allocator-owned.
pub fn chnOutDir(a: Allocator, variant_name: []const u8) ?[]const u8 {
    const home = homeDir(a) orelse return null;
    defer a.free(home);
    return std.fs.path.join(a, &.{ home, ".config", "Schemify", "pdks", variant_name }) catch null;
}

// ── PDK family mapping ────────────────────────────────────────────────────── //

/// Map a full variant name to the volare PDK family name.
/// e.g. "sky130A" → "sky130", "gf180mcuD" → "gf180mcu", "ihp-sg13g2" → "ihp-sg13g2".
pub fn pdkFamily(variant: []const u8) []const u8 {
    if (std.mem.startsWith(u8, variant, "sky130"))   return "sky130";
    if (std.mem.startsWith(u8, variant, "gf180"))    return "gf180mcu";
    if (std.mem.startsWith(u8, variant, "sg13") or
        std.mem.startsWith(u8, variant, "ihp"))      return "ihp-sg13g2";
    if (std.mem.startsWith(u8, variant, "asap7"))    return "asap7";
    return variant;
}

// ── Remote version listing ────────────────────────────────────────────────── //

/// List available remote versions for the PDK family of `variant`.
///
/// Requires `volare` in PATH. Runs `volare ls-remote <family>` and parses each
/// output line as a version string. Appends allocator-owned strings to `out`.
/// Returns without error (leaves `out` empty) if volare is unavailable.
pub fn listRemoteVersions(a: Allocator, variant: []const u8, out: *List([]const u8)) !void {
    const family = pdkFamily(variant);
    const argv = [_][]const u8{ "volare", "ls-remote", family };

    var child = std.process.Child.init(&argv, a);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return; // volare not available
    defer _ = child.wait() catch {};

    const stdout = child.stdout orelse return;
    const content = stdout.readToEndAlloc(a, 256 * 1024) catch return;
    defer a.free(content);

    var lines = std.mem.tokenizeScalar(u8, content, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        // Skip header lines like "Available sky130 PDK versions:"
        if (std.mem.indexOfScalar(u8, line, ':') != null) continue;
        // Strip trailing badges like " [installed]" or " *"
        const ver = blk: {
            if (std.mem.indexOf(u8, line, " [")) |i| break :blk line[0..i];
            if (std.mem.indexOfScalar(u8, line, ' ')) |i| break :blk line[0..i];
            break :blk line;
        };
        if (ver.len == 0) continue;
        try out.append(a, try a.dupe(u8, ver));
    }
}

// ── Persistent version selection ──────────────────────────────────────────── //

fn selectedVerFilePath(a: Allocator) ?[]const u8 {
    const home = homeDir(a) orelse return null;
    defer a.free(home);
    return std.fs.path.join(a, &.{ home, ".config", "Schemify", "pdks", "selected_versions" }) catch null;
}

/// Load the persisted selected version for a variant.
/// Returns an allocator-owned string, or null if none saved.
pub fn loadSelectedVersion(a: Allocator, variant: []const u8) ?[]const u8 {
    const path = selectedVerFilePath(a) orelse return null;
    defer a.free(path);
    const data = std.fs.cwd().readFileAlloc(a, path, 64 * 1024) catch return null;
    defer a.free(data);

    var lines = std.mem.tokenizeScalar(u8, data, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
        const key = std.mem.trim(u8, trimmed[0..eq], " ");
        if (!std.mem.eql(u8, key, variant)) continue;
        const val = std.mem.trim(u8, trimmed[eq + 1 ..], " ");
        return a.dupe(u8, val) catch null;
    }
    return null;
}

/// Persist the selected version for a variant.
/// Overwrites any existing entry for this variant in the config file.
pub fn saveSelectedVersion(a: Allocator, variant: []const u8, version: []const u8) !void {
    const path = selectedVerFilePath(a) orelse return error.HomeNotFound;
    defer a.free(path);

    if (std.fs.path.dirname(path)) |dir_path| {
        const d = try a.dupe(u8, dir_path);
        defer a.free(d);
        std.fs.cwd().makePath(d) catch {};
    }

    const existing = std.fs.cwd().readFileAlloc(a, path, 64 * 1024) catch "";
    defer if (existing.len > 0) a.free(existing);

    var buf = std.ArrayListUnmanaged(u8){};
    defer buf.deinit(a);

    var found = false;
    var lines = std.mem.tokenizeScalar(u8, existing, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse {
            try buf.appendSlice(a, trimmed);
            try buf.append(a, '\n');
            continue;
        };
        const key = std.mem.trim(u8, trimmed[0..eq], " ");
        if (std.mem.eql(u8, key, variant)) {
            try buf.writer(a).print("{s}={s}\n", .{ variant, version });
            found = true;
        } else {
            try buf.appendSlice(a, trimmed);
            try buf.append(a, '\n');
        }
    }
    if (!found) try buf.writer(a).print("{s}={s}\n", .{ variant, version });
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = buf.items });
}
