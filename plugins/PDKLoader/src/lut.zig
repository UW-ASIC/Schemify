//! MOSFET Lookup Table generation via ngspice DC sweep.
//!
//! Generates a VGS x VDS x VSB sweep netlist, runs ngspice in batch mode,
//! parses the raw output into a TSV file stored at:
//!   ~/.config/Schemify/PDKLoader/<pdk>/lut_nmos.tsv
//!   ~/.config/Schemify/PDKLoader/<pdk>/lut_pmos.tsv
//!
//! Columns: VGS, VDS, VSB, ID, gm, gds, Cgg, ft
//! Device prefix is auto-detected per PDK. Supports multi-corner generation.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const MosType = enum { nmos, pmos };

/// A voltage domain within a multi-voltage PDK (e.g. gf180 has 3v3 and 5v devices).
pub const VoltageDomain = struct {
    name: []const u8, // e.g. "3v3", "5v0"
    vdd: f64,
    nmos_model: []const u8,
    pmos_model: []const u8,
};

/// Per-PDK electrical parameters needed for LUT generation.
pub const PdkParams = struct {
    model_lib:  []const u8, // relative path under PDK root to .lib.spice
    /// Directory containing per-model SPICE files (relative to PDK root).
    /// Used for direct .include to avoid ngspice scoped binned-model bugs.
    /// When empty, falls back to .lib include (may fail on some ngspice versions).
    model_spice_dir: []const u8 = "",
    nmos_model: []const u8,
    pmos_model: []const u8,
    vdd:        f64,
    l_min:      f64, // minimum L in meters (e.g. 0.15e-6)
    corner:     []const u8, // default corner, e.g. "tt"

    /// Additional process corners (e.g. "ff", "ss", "sf", "fs").
    /// The default corner lives in `.corner` and is NOT duplicated here.
    corners: []const []const u8 = &.{},

    /// For PDKs with multiple voltage domains.
    multi_voltage: []const VoltageDomain = &.{},

    // Discrete available channel lengths in meters (sorted ascending)
    discrete_lengths: []const f64 = &.{},

    // Maximum single-finger width before nf must increase (meters)
    max_finger_w: f64 = 0,

    // BJT saturation currents (0 = unknown)
    bjt_is_npn: f64 = 0,
    bjt_is_pnp: f64 = 0,
};

/// Known PDK parameter sets.
pub const SKY130_PARAMS = PdkParams{
    .model_lib  = "libs.tech/ngspice/sky130.lib.spice",
    .model_spice_dir = "libs.ref/sky130_fd_pr/spice",
    .nmos_model = "sky130_fd_pr__nfet_01v8",
    .pmos_model = "sky130_fd_pr__pfet_01v8",
    .vdd        = 1.8,
    .l_min      = 0.15e-6,
    .corner     = "tt",
    .corners    = &.{ "ff", "ss", "sf", "fs" },
    .discrete_lengths = &.{ 0.15e-6, 0.18e-6, 0.25e-6, 0.5e-6, 1.0e-6, 2.0e-6, 4.0e-6, 8.0e-6 },
    .max_finger_w = 5.0e-6,
    .bjt_is_npn = 0, // sky130 has no BJT models in standard flow
    .bjt_is_pnp = 0,
};

pub const GF180_PARAMS = PdkParams{
    .model_lib  = "libs.tech/ngspice/sm141064.ngspice",
    .nmos_model = "nfet_03v3",
    .pmos_model = "pfet_03v3",
    .vdd        = 3.3,
    .l_min      = 0.28e-6,
    .corner     = "tt",
    .corners    = &.{ "ff", "ss", "sf", "fs" },
    .multi_voltage = &.{
        .{ .name = "3v3", .vdd = 3.3, .nmos_model = "nfet_03v3", .pmos_model = "pfet_03v3" },
        .{ .name = "5v0", .vdd = 5.0, .nmos_model = "nfet_05v0", .pmos_model = "pfet_05v0" },
    },
    .discrete_lengths = &.{ 0.28e-6, 0.30e-6, 0.35e-6, 0.5e-6, 1.0e-6, 2.0e-6, 4.0e-6, 8.0e-6, 10.0e-6 },
    .max_finger_w = 10.0e-6,
    .bjt_is_npn = 0, // populate when BJT models are characterized
    .bjt_is_pnp = 0,
};

/// IHP SG13G2 130nm SiGe BiCMOS — not yet in volare, params are provisional.
pub const IHP_SG13G2_PARAMS = PdkParams{
    .model_lib  = "libs.tech/ngspice/sg13g2.lib.spice",
    .nmos_model = "sg13_lv_nmos",
    .pmos_model = "sg13_lv_pmos",
    .vdd        = 1.2,
    .l_min      = 0.13e-6,
    .corner     = "typ",
    .corners    = &.{ "fast", "slow" },
    .discrete_lengths = &.{ 0.13e-6, 0.18e-6, 0.25e-6, 0.5e-6, 1.0e-6, 2.0e-6 },
    .max_finger_w = 10.0e-6,
    .bjt_is_npn = 0, // SG13G2 has SiGe HBTs — fill when models are available
    .bjt_is_pnp = 0,
};

/// Build ngspice include directives for loading a specific model's corner.
/// Prefers direct .include of per-model SPICE files (avoids scoped binned-model
/// resolution bugs in ngspice 42+). Falls back to .lib if model_spice_dir is empty.
/// Caller must free the returned string.
pub fn buildModelIncludes(
    alloc: Allocator,
    pdk_root: []const u8,
    params: PdkParams,
    model_name: []const u8,
    corner: []const u8,
) ?[]const u8 {
    if (params.model_spice_dir.len > 0) {
        // Try direct include: {model_name}__{corner}.pm3.spice, then .corner.spice
        const spice_dir = std.fs.path.join(alloc, &.{ pdk_root, params.model_spice_dir }) catch return null;
        defer alloc.free(spice_dir);

        const pm3 = std.fmt.allocPrint(alloc, "{s}/{s}__{s}.pm3.spice", .{ spice_dir, model_name, corner }) catch return null;
        const corner_file = std.fmt.allocPrint(alloc, "{s}/{s}__{s}.corner.spice", .{ spice_dir, model_name, corner }) catch {
            alloc.free(pm3);
            return null;
        };
        defer alloc.free(corner_file);
        const mismatch = std.fmt.allocPrint(alloc, "{s}/{s}__mismatch.corner.spice", .{ spice_dir, model_name }) catch {
            alloc.free(pm3);
            return null;
        };
        defer alloc.free(mismatch);

        // Pick whichever model file exists: .pm3.spice preferred, then .corner.spice
        const model_file = blk: {
            std.fs.cwd().access(pm3, .{}) catch {
                std.fs.cwd().access(corner_file, .{}) catch {
                    alloc.free(pm3);
                    break :blk null;
                };
                alloc.free(pm3);
                break :blk alloc.dupe(u8, corner_file) catch null;
            };
            break :blk pm3;
        };

        if (model_file) |mf| {
            defer alloc.free(mf);
            // Include the base model file plus the mismatch and nonfet files
            // needed for parameter definitions. The nonfet file defines
            // parameters like *__wlod_diff that mismatch models reference.
            // model_lib is e.g. "libs.tech/ngspice/sky130.lib.spice"
            // -> lib_dir = "{pdk_root}/libs.tech/ngspice"
            const lib_path = std.fs.path.join(alloc, &.{ pdk_root, params.model_lib }) catch return null;
            defer alloc.free(lib_path);
            const lib_dir = std.fs.path.dirname(lib_path) orelse return null;
            // nonfet.spice: varactor/diode params for the corner
            const nonfet = std.fmt.allocPrint(alloc, "{s}/corners/{s}/nonfet.spice", .{ lib_dir, corner }) catch return null;
            defer alloc.free(nonfet);
            // lod.spice: LOD parameters (wlod_diff etc.) needed by mismatch models.
            // We include this directly instead of all.spice because all.spice uses
            // relative paths that break when included from the output directory,
            // and pulls in many unrelated subcircuits.
            const lod_spice = std.fmt.allocPrint(alloc, "{s}/parameters/lod.spice", .{lib_dir}) catch return null;
            defer alloc.free(lod_spice);

            return std.fmt.allocPrint(alloc,
                \\.param mc_mm_switch=0
                \\.param mc_pr_switch=0
                \\.include "{s}"
                \\.include "{s}"
                \\.include "{s}"
                \\.include "{s}"
            , .{ mf, mismatch, nonfet, lod_spice }) catch null;
        }
    }
    // Fallback: use .lib
    const model_path = std.fs.path.join(alloc, &.{ pdk_root, params.model_lib }) catch return null;
    defer alloc.free(model_path);
    return std.fmt.allocPrint(alloc, ".lib \"{s}\" {s}", .{ model_path, corner }) catch null;
}

pub fn paramsForPdk(config_name: []const u8) ?PdkParams {
    if (std.mem.startsWith(u8, config_name, "sky130")) return SKY130_PARAMS;
    if (std.mem.startsWith(u8, config_name, "gf180"))  return GF180_PARAMS;
    if (std.mem.startsWith(u8, config_name, "ihp-sg13g2")) return IHP_SG13G2_PARAMS;
    return null;
}

// ── ngspice detection ─────────────────────────────────────────────────────── //

/// Result of ngspice version detection.
pub const NgspiceStatus = struct {
    found:       bool = false,
    version:     [64]u8 = [_]u8{0} ** 64,
    version_len: u8 = 0,

    pub fn versionSlice(self: *const NgspiceStatus) []const u8 {
        return self.version[0..self.version_len];
    }

    pub fn label(self: *const NgspiceStatus, buf: []u8) []const u8 {
        if (!self.found) return "ngspice: not found";
        return std.fmt.bufPrint(buf, "ngspice: {s}", .{self.versionSlice()}) catch "ngspice: found";
    }
};

/// Check if ngspice is available by running `ngspice --version` and parsing
/// the version string from stdout. Returns status with version info.
pub fn detectNgspice(alloc: Allocator) NgspiceStatus {
    var status = NgspiceStatus{};
    const res = std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{ "ngspice", "--version" },
        .max_output_bytes = 4096,
    }) catch return status;
    defer alloc.free(res.stdout);
    defer alloc.free(res.stderr);

    // ngspice may exit non-zero for --version on some builds; check stdout
    // regardless. Typical output: "** ngspice-42 : ..." or "ngspice 42 ..."
    const out = if (res.stdout.len > 0) res.stdout else res.stderr;
    if (out.len == 0) return status;

    // Look for a version number after "ngspice"
    if (std.mem.indexOf(u8, out, "ngspice")) |pos| {
        status.found = true;
        // Skip "ngspice" and any separator chars (space, dash, *)
        var i = pos + "ngspice".len;
        while (i < out.len and (out[i] == ' ' or out[i] == '-' or out[i] == '*')) : (i += 1) {}
        // Grab the version token until whitespace/newline/colon
        const start = i;
        while (i < out.len and out[i] != ' ' and out[i] != '\n' and out[i] != '\r' and out[i] != ':') : (i += 1) {}
        const ver = out[start..i];
        const n: u8 = @intCast(@min(ver.len, 63));
        @memcpy(status.version[0..n], ver[0..n]);
        status.version_len = n;
    } else {
        // stdout had content but no "ngspice" — still treat as found if exit 0
        if (res.term == .Exited and res.term.Exited == 0) {
            status.found = true;
            const msg = "unknown version";
            @memcpy(status.version[0..msg.len], msg);
            status.version_len = msg.len;
        }
    }
    return status;
}

// ── Corner availability ──────────────────────────────────────────────────── //

/// Check which corners are available in a PDK model library file.
/// Scans for `.lib <corner>` directives. Returns a slice of available corner
/// name pointers (from params.corners + params.corner). Caller must free the
/// returned slice with `alloc.free(result)`.
pub fn availableCorners(
    alloc: Allocator,
    pdk_root: []const u8,
    params: PdkParams,
) ?[]const []const u8 {
    const model_path = std.fs.path.join(alloc, &.{ pdk_root, params.model_lib }) catch return null;
    defer alloc.free(model_path);

    const content = std.fs.cwd().readFileAlloc(alloc, model_path, 16 << 20) catch return null;
    defer alloc.free(content);

    const max_len = 1 + params.corners.len;
    var result = alloc.alloc([]const u8, max_len) catch return null;
    var count: usize = 0;

    if (cornerExistsInContent(content, params.corner)) {
        result[count] = params.corner;
        count += 1;
    }
    for (params.corners) |c| {
        if (cornerExistsInContent(content, c)) {
            result[count] = c;
            count += 1;
        }
    }

    if (count == 0) {
        alloc.free(result);
        return null;
    }
    return result[0..count];
}

/// Check if a `.lib <corner>` directive exists in the file content.
fn cornerExistsInContent(content: []const u8, corner: []const u8) bool {
    var pos: usize = 0;
    while (pos < content.len) {
        const idx = std.mem.indexOfPos(u8, content, pos, ".lib ") orelse
            (std.mem.indexOfPos(u8, content, pos, ".lib\t") orelse break);
        pos = idx + 5;
        while (pos < content.len and (content[pos] == ' ' or content[pos] == '\t')) pos += 1;
        const tok_start = pos;
        while (pos < content.len and content[pos] != ' ' and content[pos] != '\t' and
            content[pos] != '\n' and content[pos] != '\r') pos += 1;
        if (std.mem.eql(u8, content[tok_start..pos], corner)) return true;
    }
    return false;
}

// ── Device prefix detection ──────────────────────────────────────────────── //

/// Default fallback prefix when detection is not possible.
pub const DEFAULT_PREFIX = "@m.x1.m0";

/// Detect the correct ngspice device parameter prefix for the given PDK/model.
/// Runs a minimal OP simulation and checks which prefix produces valid numeric
/// output. Returns an allocated copy of the working prefix, or null on failure
/// (caller should fall back to `DEFAULT_PREFIX`).
pub fn detectDevicePrefix(
    alloc: Allocator,
    pdk_root: []const u8,
    params: PdkParams,
    mos: MosType,
) ?[]const u8 {
    const model_name = switch (mos) {
        .nmos => params.nmos_model,
        .pmos => params.pmos_model,
    };
    const bulk_node: []const u8 = switch (mos) {
        .nmos => "0",
        .pmos => "vdd",
    };
    const vdd = params.vdd;
    const l_str = std.fmt.allocPrint(alloc, "{e}", .{params.l_min}) catch return null;
    defer alloc.free(l_str);

    const includes = buildModelIncludes(alloc, pdk_root, params, model_name, params.corner) orelse return null;
    defer alloc.free(includes);

    const tmp_dir = "/tmp/schemify_prefix_detect";
    std.fs.cwd().makePath(tmp_dir) catch return null;

    // Build a model-specific guess first, then fall back to common ones.
    const model_guess = std.fmt.allocPrint(alloc, "@m.x1.m{s}", .{model_name}) catch return null;
    defer alloc.free(model_guess);

    const prefixes = [_][]const u8{
        model_guess,
        "@m.x1.m0",
        "@m.m1",
    };

    for (prefixes) |prefix| {
        if (tryPrefix(alloc, includes, vdd, bulk_node, model_name, l_str, tmp_dir, prefix))
            return alloc.dupe(u8, prefix) catch null;
    }
    return null;
}

/// Run a single-point OP sim with the given device prefix and return true if
/// the wrdata output contains a valid non-header numeric line.
fn tryPrefix(
    alloc: Allocator,
    includes: []const u8,
    vdd: f64,
    bulk_node: []const u8,
    model_name: []const u8,
    l_str: []const u8,
    tmp_dir: []const u8,
    prefix: []const u8,
) bool {
    const netlist = std.fmt.allocPrint(alloc,
        \\.title prefix detection
        \\{s}
        \\Vdd vdd 0 {d:.1}
        \\VGS g 0 {d:.1}
        \\VDS d 0 {d:.1}
        \\X1 d g {s} {s} {s} W=1u L={s} nf=1
        \\.control
        \\op
        \\set wr_vecnames
        \\wrdata {s}/prefix_test.tsv {s}[id]
        \\.endc
        \\.end
    , .{
        includes,
        vdd,        vdd * 0.5,
        vdd * 0.5,  bulk_node, bulk_node,
        model_name, l_str,
        tmp_dir,    prefix,
    }) catch return false;
    defer alloc.free(netlist);

    const netlist_file = std.fmt.allocPrint(alloc, "{s}/prefix_test.spice", .{tmp_dir}) catch return false;
    defer alloc.free(netlist_file);
    std.fs.cwd().writeFile(.{ .sub_path = netlist_file, .data = netlist }) catch return false;

    var child = std.process.Child.init(&.{ "ngspice", "-b", netlist_file }, alloc);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return false;
    const term = child.wait() catch return false;
    if (!(term == .Exited and term.Exited == 0)) return false;

    const out_path = std.fmt.allocPrint(alloc, "{s}/prefix_test.tsv", .{tmp_dir}) catch return false;
    defer alloc.free(out_path);
    const out_data = std.fs.cwd().readFileAlloc(alloc, out_path, 4096) catch return false;
    defer alloc.free(out_data);

    var lines = std.mem.splitScalar(u8, out_data, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        if (!std.ascii.isDigit(line[0]) and line[0] != '-' and line[0] != '+') continue;
        var toks = std.mem.tokenizeAny(u8, line, " \t");
        _ = toks.next(); // skip index
        if (toks.next()) |val_tok| {
            _ = std.fmt.parseFloat(f64, val_tok) catch continue;
            return true; // got a valid number — prefix works
        }
    }
    return false;
}

// ── Configurable PdkParams override ───────────────────────────────────────── //

/// Attempt to load user overrides from
/// `~/.config/Schemify/PDKLoader/<pdk>/params.toml`.
/// Starts with the hardcoded defaults and overrides any keys found in the file.
/// Supported keys: model_lib, nmos_model, pmos_model, vdd, l_min, corner.
pub fn loadParamsOverride(
    alloc: Allocator,
    home: []const u8,
    config_name: []const u8,
    defaults: PdkParams,
) PdkParams {
    var params = defaults;
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(
        &path_buf,
        "{s}/.config/Schemify/PDKLoader/{s}/params.toml",
        .{ home, config_name },
    ) catch return params;

    const content = std.fs.cwd().readFileAlloc(alloc, path, 16384) catch return params;
    defer alloc.free(content);

    // Simple line-by-line key=value parser (bare TOML subset).
    // String values may be quoted or bare. Numeric values are parsed as f64.
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, std.mem.trimRight(u8, raw, "\r"), " \t");
        if (line.len == 0 or line[0] == '#' or line[0] == '[') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const val = std.mem.trim(u8, line[eq + 1 ..], " \t\"");
        if (val.len == 0) continue;

        // String overrides — we dupe into alloc so they outlive the file buffer.
        // The plugin uses page_allocator so these are effectively leaked (fine
        // for a plugin that runs for the process lifetime).
        if (std.mem.eql(u8, key, "model_lib")) {
            params.model_lib = alloc.dupe(u8, val) catch continue;
        } else if (std.mem.eql(u8, key, "nmos_model")) {
            params.nmos_model = alloc.dupe(u8, val) catch continue;
        } else if (std.mem.eql(u8, key, "pmos_model")) {
            params.pmos_model = alloc.dupe(u8, val) catch continue;
        } else if (std.mem.eql(u8, key, "corner")) {
            params.corner = alloc.dupe(u8, val) catch continue;
        } else if (std.mem.eql(u8, key, "vdd")) {
            params.vdd = std.fmt.parseFloat(f64, val) catch continue;
        } else if (std.mem.eql(u8, key, "l_min")) {
            params.l_min = std.fmt.parseFloat(f64, val) catch continue;
        }
    }
    return params;
}

/// A single operating point row in the LUT.
pub const LutRow = struct {
    vgs: f64,
    vds: f64,
    vsb: f64,
    id:  f64,
    gm:  f64,
    gds: f64,
    cgg: f64,
    ft:  f64, // unity-gain frequency = gm / (2*pi*Cgg)
};

/// Parsed lookup table.
pub const Lut = struct {
    rows:  []LutRow,
    alloc: Allocator,

    pub fn deinit(self: *Lut) void {
        self.alloc.free(self.rows);
    }

    /// Find gm/ID at a given (VGS, VDS) by nearest-neighbor lookup (VSB=0).
    pub fn gmOverId(self: *const Lut, vgs: f64, vds: f64) ?f64 {
        const row = self.nearest(vgs, vds, 0) orelse return null;
        if (@abs(row.id) < 1e-15) return null;
        return row.gm / row.id;
    }

    /// Find gm/ID at a given (VGS, VDS, VSB).
    pub fn gmOverIdVsb(self: *const Lut, vgs: f64, vds: f64, vsb: f64) ?f64 {
        const row = self.nearest(vgs, vds, vsb) orelse return null;
        if (@abs(row.id) < 1e-15) return null;
        return row.gm / row.id;
    }

    /// Find ID/W at a given (VGS, VDS). W=1u was used in sweep. VSB=0.
    pub fn idOverW(self: *const Lut, vgs: f64, vds: f64) ?f64 {
        const row = self.nearest(vgs, vds, 0) orelse return null;
        return row.id / 1.0e-6; // W=1u in netlist
    }

    /// Find ID/W at a given (VGS, VDS, VSB). W=1u was used in sweep.
    pub fn idOverWVsb(self: *const Lut, vgs: f64, vds: f64, vsb: f64) ?f64 {
        const row = self.nearest(vgs, vds, vsb) orelse return null;
        return row.id / 1.0e-6;
    }

    /// Find ft at a given (VGS, VDS) (VSB=0).
    pub fn ftAt(self: *const Lut, vgs: f64, vds: f64) ?f64 {
        const row = self.nearest(vgs, vds, 0) orelse return null;
        return row.ft;
    }

    /// Find VGS that yields a target gm/ID at VDS ~ target. VSB=0.
    pub fn findVgsForGmId(self: *const Lut, target_gm_id: f64, vds: f64) ?f64 {
        return self.findVgsForGmIdVsb(target_gm_id, vds, 0, 0.15);
    }

    /// Find VGS that yields a target gm/ID at given VDS and VSB.
    /// `vsb_tol` controls the VSB matching tolerance.
    pub fn findVgsForGmIdVsb(
        self: *const Lut,
        target_gm_id: f64,
        vds: f64,
        vsb: f64,
        vsb_tol: f64,
    ) ?f64 {
        var best_dist: f64 = std.math.inf(f64);
        var best_vgs: f64 = 0;
        for (self.rows) |row| {
            if (@abs(row.vds - vds) > 0.15) continue;
            if (@abs(row.vsb - vsb) > vsb_tol) continue;
            if (@abs(row.id) < 1e-15) continue;
            const gm_id = row.gm / row.id;
            const dist = @abs(gm_id - target_gm_id);
            if (dist < best_dist) {
                best_dist = dist;
                best_vgs = row.vgs;
            }
        }
        return if (best_dist < std.math.inf(f64)) best_vgs else null;
    }

    /// Nearest-neighbor lookup considering VGS, VDS, and VSB.
    fn nearest(self: *const Lut, vgs: f64, vds: f64, vsb: f64) ?LutRow {
        var best_dist: f64 = std.math.inf(f64);
        var best: ?LutRow = null;
        for (self.rows) |row| {
            const d = (row.vgs - vgs) * (row.vgs - vgs) +
                (row.vds - vds) * (row.vds - vds) +
                (row.vsb - vsb) * (row.vsb - vsb);
            if (d < best_dist) {
                best_dist = d;
                best = row;
            }
        }
        return best;
    }
};

// ── VSB sweep values ─────────────────────────────────────────────────────── //

/// VSB sweep points (volts). For NMOS these raise the source above ground;
/// for PMOS the source drops below VDD by the same amount.
const VSB_POINTS = [_]f64{ 0.0, 0.2, 0.4, 0.6 };

// ── LUT generation ───────────────────────────────────────────────────────── //

/// Generate a LUT TSV file for the given MOSFET type using the default corner.
/// `pdk_root` is the variant root (e.g. ~/.volare/sky130/versions/.../sky130A).
/// `out_dir` is e.g. ~/.config/Schemify/PDKLoader/sky130A/.
/// Returns true on success.
pub fn generateLut(
    alloc: Allocator,
    pdk_root: []const u8,
    out_dir: []const u8,
    params: PdkParams,
    mos: MosType,
) bool {
    return generateLutCorner(alloc, pdk_root, out_dir, params, mos, params.corner);
}

/// Generate a LUT TSV for a specific process corner.
pub fn generateLutCorner(
    alloc: Allocator,
    pdk_root: []const u8,
    out_dir: []const u8,
    params: PdkParams,
    mos: MosType,
    corner: []const u8,
) bool {
    std.fs.cwd().makePath(out_dir) catch return false;

    const model_name = switch (mos) {
        .nmos => params.nmos_model,
        .pmos => params.pmos_model,
    };

    // Build model include directives (direct .include to avoid scoped binning bugs)
    const includes = buildModelIncludes(alloc, pdk_root, params, model_name, corner) orelse return false;
    defer alloc.free(includes);
    const mos_tag: []const u8 = switch (mos) {
        .nmos => "nmos",
        .pmos => "pmos",
    };
    const mos_char: u8 = switch (mos) {
        .nmos => 'n',
        .pmos => 'p',
    };
    const vdd = params.vdd;
    const l_str = std.fmt.allocPrint(alloc, "{e}", .{params.l_min}) catch return false;
    defer alloc.free(l_str);

    // Detect device prefix or use default
    const detected = detectDevicePrefix(alloc, pdk_root, params, mos);
    const prefix = detected orelse DEFAULT_PREFIX;
    defer if (detected) |p| alloc.free(p);

    // Build wrdata vector list from prefix
    const wrdata_vecs = std.fmt.allocPrint(
        alloc,
        "{s}[id] {s}[gm] {s}[gds] {s}[cgg]",
        .{ prefix, prefix, prefix, prefix },
    ) catch return false;
    defer alloc.free(wrdata_vecs);

    // Build per-VSB sweep commands.
    // For each VSB value we alter the source voltage, run a DC sweep, and
    // write raw output to a separate file tagged with the VSB index.
    var cmds = std.ArrayListUnmanaged(u8){};
    defer cmds.deinit(alloc);
    const cw = cmds.writer(alloc);

    for (VSB_POINTS) |vsb_val| {
        const vsb_tag: u32 = @intFromFloat(@round(vsb_val * 100.0));
        if (mos == .nmos) {
            // NMOS: source node (sb) raised above ground by vsb_val
            cw.print("alter vsb = {d:.2}\n", .{vsb_val}) catch return false;
        } else {
            // PMOS: source node (sb) at VDD - vsb_val
            cw.print("alter vsb = {d:.2}\n", .{vdd - vsb_val}) catch return false;
        }
        cw.print("dc VGS 0 {d:.1} 0.02 VDS 0.05 {d:.1} 0.1\n", .{ vdd, vdd }) catch return false;
        cw.writeAll("set wr_vecnames\n") catch return false;
        cw.print("wrdata {s}/lut_{s}_raw_vsb{d:0>3}.tsv {s}\n", .{
            out_dir, mos_tag, vsb_tag, wrdata_vecs,
        }) catch return false;
        cw.writeAll("destroy all\n") catch return false;
    }

    // Build full netlist.
    // NMOS: D=d  G=g  S=sb  B=0     Vsb: sb-to-gnd (starts at 0)
    // PMOS: D=d  G=g  S=sb  B=sb    Vsb: sb-to-gnd (starts at VDD)
    const bulk_node: []const u8 = switch (mos) {
        .nmos => "0",
        .pmos => "sb",
    };
    const vsb_init = switch (mos) {
        .nmos => @as(f64, 0.0),
        .pmos => vdd,
    };

    const netlist = std.fmt.allocPrint(alloc,
        \\.title MOSFET LUT sweep - {s}
        \\{s}
        \\Vdd vdd 0 {d:.1}
        \\VGS g 0 0
        \\VDS d 0 0
        \\Vsb sb 0 {d:.2}
        \\X1 d g sb {s} {s} W=1u L={s} nf=1
        \\.control
        \\{s}.endc
        \\.end
    , .{
        mos_tag,
        includes,
        vdd,
        vsb_init,
        bulk_node, model_name, l_str,
        cmds.items,
    }) catch return false;
    defer alloc.free(netlist);

    // Write netlist
    const netlist_path = std.fmt.allocPrint(alloc, "{s}/sweep_{c}mos.spice", .{ out_dir, mos_char }) catch return false;
    defer alloc.free(netlist_path);
    std.fs.cwd().writeFile(.{ .sub_path = netlist_path, .data = netlist }) catch return false;

    // Run ngspice in batch
    var child = std.process.Child.init(&.{ "ngspice", "-b", netlist_path }, alloc);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return false;
    const term = child.wait() catch return false;
    if (!(term == .Exited and term.Exited == 0)) return false;

    // Merge per-VSB raw files into a single clean TSV
    const tsv_path = if (std.mem.eql(u8, corner, params.corner))
        std.fmt.allocPrint(alloc, "{s}/lut_{c}mos.tsv", .{ out_dir, mos_char }) catch return false
    else
        std.fmt.allocPrint(alloc, "{s}/lut_{c}mos_{s}.tsv", .{ out_dir, mos_char, corner }) catch return false;
    defer alloc.free(tsv_path);

    return mergeVsbRawFiles(alloc, out_dir, mos_tag, tsv_path);
}

/// Merge per-VSB raw ngspice output files into a single 8-column TSV.
fn mergeVsbRawFiles(
    alloc: Allocator,
    out_dir: []const u8,
    mos_tag: []const u8,
    tsv_path: []const u8,
) bool {
    var out = std.ArrayListUnmanaged(u8){};
    defer out.deinit(alloc);
    const w = out.writer(alloc);
    w.writeAll("VGS\tVDS\tVSB\tID\tgm\tgds\tCgg\tft\n") catch return false;

    for (VSB_POINTS) |vsb_val| {
        const vsb_tag: u32 = @intFromFloat(@round(vsb_val * 100.0));
        const raw_path = std.fmt.allocPrint(alloc, "{s}/lut_{s}_raw_vsb{d:0>3}.tsv", .{
            out_dir, mos_tag, vsb_tag,
        }) catch continue;
        defer alloc.free(raw_path);

        const raw = std.fs.cwd().readFileAlloc(alloc, raw_path, 64 << 20) catch continue;
        defer alloc.free(raw);

        appendRawToTsv(raw, vsb_val, &out, alloc);
    }

    std.fs.cwd().writeFile(.{ .sub_path = tsv_path, .data = out.items }) catch return false;
    return true;
}

/// Parse a single raw ngspice wrdata file (one VSB point) and append rows.
///
/// ngspice `wrdata` with a nested DC sweep (`dc VGS ... VDS ...`) outputs:
///   column 0 = inner sweep variable (VGS)
///   columns 1..N = requested vectors (ID, gm, gds, Cgg)
/// The outer sweep (VDS) advances in blocks — each block is one complete
/// VGS sweep. We detect block boundaries when VGS wraps back toward zero.
fn appendRawToTsv(
    raw: []const u8,
    vsb: f64,
    out: *std.ArrayListUnmanaged(u8),
    alloc: Allocator,
) void {
    const w = out.writer(alloc);

    var vds_idx: usize = 0;
    var prev_vgs: f64 = std.math.inf(f64);
    var first_data = true;

    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        if (!std.ascii.isDigit(line[0]) and line[0] != '-' and line[0] != '+') continue;

        const vals = parseRawLine(line) orelse continue;
        const vgs = vals[0];

        // Detect VDS block boundary: VGS wraps back to start
        if (!first_data and vgs < prev_vgs - 0.01) {
            vds_idx += 1;
        }
        first_data = false;
        prev_vgs = vgs;

        const vds = 0.05 + @as(f64, @floatFromInt(vds_idx)) * 0.1;
        const id = vals[1];
        const gm = vals[2];
        const gds = vals[3];
        const cgg = vals[4];
        const ft = if (@abs(cgg) > 1e-30)
            @abs(gm) / (2.0 * std.math.pi * @abs(cgg))
        else
            0.0;

        w.print("{d:.4}\t{d:.4}\t{d:.2}\t{e}\t{e}\t{e}\t{e}\t{e}\n", .{
            vgs, vds, vsb, id, gm, gds, cgg, ft,
        }) catch {};
    }
}

// ── Line parsers ─────────────────────────────────────────────────────────── //

/// Parse a raw ngspice wrdata line.
/// ngspice `wrdata` emits paired columns: each vector gets its own x-axis copy.
/// With 4 vectors (ID, gm, gds, Cgg) the output is 8 columns:
///   vgs id  vgs gm  vgs gds  vgs cgg
/// We extract indices [0, 1, 3, 5, 7] → (VGS, ID, gm, gds, Cgg).
/// Also handles the legacy 5-column format (VGS, ID, gm, gds, Cgg) directly.
fn parseRawLine(line: []const u8) ?[5]f64 {
    var all: [8]f64 = undefined;
    var count: usize = 0;
    var toks = std.mem.tokenizeAny(u8, line, " \t");
    while (toks.next()) |tok| {
        if (count >= 8) break;
        all[count] = std.fmt.parseFloat(f64, tok) catch return null;
        count += 1;
    }
    if (count >= 8) {
        // Paired format: skip repeated x-axis columns
        return .{ all[0], all[1], all[3], all[5], all[7] };
    }
    if (count >= 5) {
        // Legacy 5-column: VGS, ID, gm, gds, Cgg
        return .{ all[0], all[1], all[2], all[3], all[4] };
    }
    return null;
}

/// Parse a clean TSV line: 8 columns (VGS, VDS, VSB, ID, gm, gds, Cgg, ft).
/// Falls back gracefully for 5-column legacy files (no VSB, Cgg, ft) and
/// 6-column intermediate files (no VSB, no ft).
fn parseTsvLine8(line: []const u8) ?[8]f64 {
    var vals: [8]f64 = .{ 0, 0, 0, 0, 0, 0, 0, 0 };
    var count: usize = 0;
    var toks = std.mem.tokenizeAny(u8, line, " \t");
    while (toks.next()) |tok| {
        if (count >= 8) break;
        vals[count] = std.fmt.parseFloat(f64, tok) catch return null;
        count += 1;
    }
    if (count >= 8) return vals; // new 8-column format
    if (count == 6) {
        // 6-column: VGS, VDS, ID, gm, gds, Cgg -> insert VSB=0, compute ft
        const cgg = vals[5];
        const gm = vals[3];
        const ft = if (@abs(cgg) > 1e-30) @abs(gm) / (2.0 * std.math.pi * @abs(cgg)) else 0.0;
        return .{ vals[0], vals[1], 0, vals[2], vals[3], vals[4], cgg, ft };
    }
    if (count >= 5) {
        // 5-column legacy: VGS, VDS, ID, gm, gds -> VSB=0, Cgg=0, ft=0
        return .{ vals[0], vals[1], 0, vals[2], vals[3], vals[4], 0, 0 };
    }
    return null;
}

// ── Load / Path helpers ──────────────────────────────────────────────────── //

/// Load a previously-generated LUT TSV (supports legacy 5/6-col and new 8-col).
pub fn loadLut(alloc: Allocator, path: []const u8) ?Lut {
    const data = std.fs.cwd().readFileAlloc(alloc, path, 64 << 20) catch return null;
    defer alloc.free(data);

    var rows = std.ArrayListUnmanaged(LutRow){};
    var lines = std.mem.splitScalar(u8, data, '\n');
    // Skip header
    _ = lines.next();

    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        const v = parseTsvLine8(line) orelse continue;
        rows.append(alloc, .{
            .vgs = v[0], .vds = v[1], .vsb = v[2],
            .id  = v[3], .gm  = v[4], .gds = v[5],
            .cgg = v[6], .ft  = v[7],
        }) catch continue;
    }

    if (rows.items.len == 0) {
        rows.deinit(alloc);
        return null;
    }
    return .{
        .rows = rows.toOwnedSlice(alloc) catch { rows.deinit(alloc); return null; },
        .alloc = alloc,
    };
}

/// Path to LUT TSV for a PDK/MOS type (default corner).
pub fn lutPath(alloc: Allocator, home: []const u8, config_name: []const u8, mos: MosType) ?[]const u8 {
    const tag: []const u8 = switch (mos) { .nmos => "nmos", .pmos => "pmos" };
    return std.fmt.allocPrint(
        alloc, "{s}/.config/Schemify/PDKLoader/{s}/lut_{s}.tsv",
        .{ home, config_name, tag },
    ) catch null;
}

/// Path to LUT TSV for a specific corner.
pub fn lutPathCorner(
    alloc: Allocator,
    home: []const u8,
    config_name: []const u8,
    mos: MosType,
    corner: []const u8,
) ?[]const u8 {
    const tag: []const u8 = switch (mos) { .nmos => "nmos", .pmos => "pmos" };
    return std.fmt.allocPrint(
        alloc, "{s}/.config/Schemify/PDKLoader/{s}/lut_{s}_{s}.tsv",
        .{ home, config_name, tag, corner },
    ) catch null;
}

/// Build a Lut from an in-memory TSV string (for testing without filesystem).
pub fn loadLutFromTsv(alloc: Allocator, data: []const u8) ?Lut {
    var rows = std.ArrayListUnmanaged(LutRow){};
    var lines = std.mem.splitScalar(u8, data, '\n');
    _ = lines.next(); // skip header
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        const v = parseTsvLine8(line) orelse continue;
        rows.append(alloc, .{
            .vgs = v[0], .vds = v[1], .vsb = v[2],
            .id  = v[3], .gm  = v[4], .gds = v[5],
            .cgg = v[6], .ft  = v[7],
        }) catch continue;
    }
    if (rows.items.len == 0) { rows.deinit(alloc); return null; }
    return .{
        .rows = rows.toOwnedSlice(alloc) catch { rows.deinit(alloc); return null; },
        .alloc = alloc,
    };
}

// ── Tests ─────────────────────────────────────────────────────────────────── //

const testing = std.testing;

test "parseRawLine valid 5-column" {
    const result = parseRawLine("0.1000  1.234e-05  5.678e-04  1.111e-06  2.345e-15");
    try testing.expect(result != null);
    const v = result.?;
    try testing.expectApproxEqAbs(0.1, v[0], 1e-10);
    try testing.expectApproxEqAbs(1.234e-05, v[1], 1e-18);
    try testing.expectApproxEqAbs(5.678e-04, v[2], 1e-18);
    try testing.expectApproxEqAbs(1.111e-06, v[3], 1e-18);
    try testing.expectApproxEqAbs(2.345e-15, v[4], 1e-28);
}

test "parseRawLine rejects short line" {
    try testing.expect(parseRawLine("0.1  0.2  0.3") == null);
    try testing.expect(parseRawLine("") == null);
}

test "parseRawLine rejects header" {
    try testing.expect(parseRawLine("VGS  ID  gm  gds  Cgg") == null);
}

test "parseTsvLine8 full 8-column" {
    const result = parseTsvLine8("0.5\t0.9\t0.0\t1e-4\t1e-3\t1e-5\t1e-14\t5e9");
    try testing.expect(result != null);
    const v = result.?;
    try testing.expectApproxEqAbs(0.5, v[0], 1e-10);
    try testing.expectApproxEqAbs(0.9, v[1], 1e-10);
    try testing.expectApproxEqAbs(0.0, v[2], 1e-10);
    try testing.expectApproxEqAbs(1e-4, v[3], 1e-18);
    try testing.expectApproxEqAbs(1e-3, v[4], 1e-18);
    try testing.expectApproxEqAbs(1e-5, v[5], 1e-18);
    try testing.expectApproxEqAbs(1e-14, v[6], 1e-28);
    try testing.expectApproxEqAbs(5e9, v[7], 1e-3);
}

test "parseTsvLine8 legacy 5-column inserts VSB=0, Cgg=0, ft=0" {
    const result = parseTsvLine8("0.6\t0.9\t2e-4\t1.5e-3\t2e-5");
    try testing.expect(result != null);
    const v = result.?;
    try testing.expectApproxEqAbs(0.6, v[0], 1e-10); // VGS
    try testing.expectApproxEqAbs(0.9, v[1], 1e-10); // VDS
    try testing.expectApproxEqAbs(0.0, v[2], 1e-10); // VSB=0
    try testing.expectApproxEqAbs(2e-4, v[3], 1e-18); // ID
    try testing.expectApproxEqAbs(1.5e-3, v[4], 1e-18); // gm
    try testing.expectApproxEqAbs(2e-5, v[5], 1e-18); // gds
    try testing.expectApproxEqAbs(0.0, v[6], 1e-30); // Cgg=0
    try testing.expectApproxEqAbs(0.0, v[7], 1e-10); // ft=0
}

test "parseTsvLine8 intermediate 6-column computes ft" {
    // 6-col: VGS, VDS, ID, gm, gds, Cgg
    const result = parseTsvLine8("0.5\t0.9\t1e-4\t1e-3\t1e-5\t1e-14");
    try testing.expect(result != null);
    const v = result.?;
    try testing.expectApproxEqAbs(0.0, v[2], 1e-10); // VSB inserted as 0
    try testing.expectApproxEqAbs(1e-4, v[3], 1e-18); // ID (was col 2)
    try testing.expectApproxEqAbs(1e-14, v[6], 1e-28); // Cgg
    // ft = |gm| / (2*pi*|Cgg|) = 1e-3 / (2*pi*1e-14) ≈ 1.59e10
    const expected_ft = 1e-3 / (2.0 * std.math.pi * 1e-14);
    try testing.expectApproxEqAbs(expected_ft, v[7], 1e6);
}

test "parseTsvLine8 rejects too-short line" {
    try testing.expect(parseTsvLine8("0.5\t0.9\t1e-4") == null);
    try testing.expect(parseTsvLine8("") == null);
}

test "cornerExistsInContent finds corner" {
    const content = ".lib tt\n.model nfet\n.lib ff\n";
    try testing.expect(cornerExistsInContent(content, "tt"));
    try testing.expect(cornerExistsInContent(content, "ff"));
    try testing.expect(!cornerExistsInContent(content, "ss"));
}

test "cornerExistsInContent tab-separated" {
    const content = ".lib\ttt\n";
    try testing.expect(cornerExistsInContent(content, "tt"));
}

test "cornerExistsInContent no false positive on partial match" {
    const content = ".lib tta_extra\n";
    try testing.expect(!cornerExistsInContent(content, "tt"));
}

test "paramsForPdk known PDKs" {
    try testing.expect(paramsForPdk("sky130A") != null);
    try testing.expect(paramsForPdk("sky130B") != null);
    try testing.expect(paramsForPdk("gf180mcu") != null);
    try testing.expect(paramsForPdk("gf180mcuC") != null);
    try testing.expect(paramsForPdk("ihp-sg13g2") != null);
    try testing.expect(paramsForPdk("unknown_pdk") == null);
}

test "paramsForPdk sky130 values" {
    const p = paramsForPdk("sky130A").?;
    try testing.expectApproxEqAbs(1.8, p.vdd, 1e-10);
    try testing.expectApproxEqAbs(0.15e-6, p.l_min, 1e-18);
    try testing.expect(p.discrete_lengths.len > 0);
    try testing.expectApproxEqAbs(0.15e-6, p.discrete_lengths[0], 1e-18);
}

test "paramsForPdk gf180 values" {
    const p = paramsForPdk("gf180mcu").?;
    try testing.expectApproxEqAbs(3.3, p.vdd, 1e-10);
    try testing.expectApproxEqAbs(0.28e-6, p.l_min, 1e-18);
    try testing.expect(p.multi_voltage.len == 2);
}

test "Lut gmOverId and idOverW" {
    var rows = [_]LutRow{
        .{ .vgs = 0.5, .vds = 0.9, .vsb = 0, .id = 1e-4, .gm = 1e-3, .gds = 1e-5, .cgg = 1e-14, .ft = 5e9 },
        .{ .vgs = 0.6, .vds = 0.9, .vsb = 0, .id = 2e-4, .gm = 1.5e-3, .gds = 2e-5, .cgg = 1.5e-14, .ft = 8e9 },
    };
    var l = Lut{ .rows = &rows, .alloc = testing.allocator };

    // gmOverId at (0.5, 0.9) should be gm/id = 1e-3/1e-4 = 10
    const gm_id = l.gmOverId(0.5, 0.9);
    try testing.expect(gm_id != null);
    try testing.expectApproxEqAbs(10.0, gm_id.?, 1e-6);

    // idOverW at (0.5, 0.9) should be id/1u = 1e-4/1e-6 = 100
    const id_w = l.idOverW(0.5, 0.9);
    try testing.expect(id_w != null);
    try testing.expectApproxEqAbs(100.0, id_w.?, 1e-6);

    // ftAt at (0.5, 0.9)
    const ft = l.ftAt(0.5, 0.9);
    try testing.expect(ft != null);
    try testing.expectApproxEqAbs(5e9, ft.?, 1e-3);

    // Don't call deinit — rows is stack-allocated
    _ = &l;
}

test "Lut gmOverId returns null for zero current" {
    var rows = [_]LutRow{
        .{ .vgs = 0.1, .vds = 0.1, .vsb = 0, .id = 0, .gm = 0, .gds = 0, .cgg = 0, .ft = 0 },
    };
    var l = Lut{ .rows = &rows, .alloc = testing.allocator };
    try testing.expect(l.gmOverId(0.1, 0.1) == null);
    _ = &l;
}

test "Lut findVgsForGmId" {
    // Build a small grid: VGS from 0.3 to 0.7, VDS=0.9
    // gm/ID decreases as VGS increases (weak→strong inversion)
    var rows = [_]LutRow{
        .{ .vgs = 0.3, .vds = 0.9, .vsb = 0, .id = 1e-6, .gm = 2.5e-5, .gds = 1e-7, .cgg = 1e-15, .ft = 0 },
        .{ .vgs = 0.4, .vds = 0.9, .vsb = 0, .id = 1e-5, .gm = 1.5e-4, .gds = 1e-6, .cgg = 5e-15, .ft = 0 },
        .{ .vgs = 0.5, .vds = 0.9, .vsb = 0, .id = 1e-4, .gm = 1e-3,   .gds = 1e-5, .cgg = 1e-14, .ft = 0 },
        .{ .vgs = 0.6, .vds = 0.9, .vsb = 0, .id = 5e-4, .gm = 2e-3,   .gds = 5e-5, .cgg = 2e-14, .ft = 0 },
        .{ .vgs = 0.7, .vds = 0.9, .vsb = 0, .id = 2e-3, .gm = 4e-3,   .gds = 2e-4, .cgg = 5e-14, .ft = 0 },
    };
    var l = Lut{ .rows = &rows, .alloc = testing.allocator };

    // gm/ID = 10 at VGS=0.5 (1e-3/1e-4)
    const vgs = l.findVgsForGmId(10.0, 0.9);
    try testing.expect(vgs != null);
    try testing.expectApproxEqAbs(0.5, vgs.?, 0.05);
    _ = &l;
}

test "Lut VSB-aware lookup" {
    var rows = [_]LutRow{
        .{ .vgs = 0.5, .vds = 0.9, .vsb = 0.0, .id = 1e-4, .gm = 1e-3, .gds = 1e-5, .cgg = 1e-14, .ft = 5e9 },
        .{ .vgs = 0.5, .vds = 0.9, .vsb = 0.2, .id = 8e-5, .gm = 8e-4, .gds = 8e-6, .cgg = 9e-15, .ft = 4e9 },
    };
    var l = Lut{ .rows = &rows, .alloc = testing.allocator };

    // gmOverIdVsb at VSB=0 should pick first row
    const gm_id0 = l.gmOverIdVsb(0.5, 0.9, 0.0);
    try testing.expect(gm_id0 != null);
    try testing.expectApproxEqAbs(10.0, gm_id0.?, 1e-6);

    // gmOverIdVsb at VSB=0.2 should pick second row
    const gm_id2 = l.gmOverIdVsb(0.5, 0.9, 0.2);
    try testing.expect(gm_id2 != null);
    try testing.expectApproxEqAbs(10.0, gm_id2.?, 1e-6); // 8e-4/8e-5 = 10
    _ = &l;
}

test "loadLutFromTsv parses 8-column TSV" {
    const tsv =
        "VGS\tVDS\tVSB\tID\tgm\tgds\tCgg\tft\n" ++
        "0.5\t0.9\t0.0\t1e-4\t1e-3\t1e-5\t1e-14\t5e9\n" ++
        "0.6\t0.9\t0.0\t2e-4\t1.5e-3\t2e-5\t1.5e-14\t8e9\n";
    var l = loadLutFromTsv(testing.allocator, tsv) orelse return error.TestUnexpectedResult;
    defer l.deinit();

    try testing.expectEqual(@as(usize, 2), l.rows.len);
    try testing.expectApproxEqAbs(0.5, l.rows[0].vgs, 1e-10);
    try testing.expectApproxEqAbs(0.6, l.rows[1].vgs, 1e-10);
    try testing.expectApproxEqAbs(5e9, l.rows[0].ft, 1e-3);
}

test "loadLutFromTsv parses legacy 5-column" {
    const tsv =
        "VGS\tVDS\tID\tgm\tgds\n" ++
        "0.5\t0.9\t1e-4\t1e-3\t1e-5\n";
    var l = loadLutFromTsv(testing.allocator, tsv) orelse return error.TestUnexpectedResult;
    defer l.deinit();

    try testing.expectEqual(@as(usize, 1), l.rows.len);
    try testing.expectApproxEqAbs(0.0, l.rows[0].vsb, 1e-10);
    try testing.expectApproxEqAbs(0.0, l.rows[0].cgg, 1e-30);
    try testing.expectApproxEqAbs(0.0, l.rows[0].ft, 1e-10);
}

test "loadLutFromTsv returns null for empty data" {
    try testing.expect(loadLutFromTsv(testing.allocator, "header\n") == null);
    try testing.expect(loadLutFromTsv(testing.allocator, "") == null);
}

test "appendRawToTsv parses raw ngspice output" {
    // Simulate raw wrdata: 5 columns per line (index/VGS, ID, gm, gds, Cgg)
    // Two VGS points at one VDS block
    const raw =
        "0.1000  1.0e-06  2.5e-05  1.0e-07  1.0e-15\n" ++
        "0.2000  1.0e-05  1.5e-04  1.0e-06  5.0e-15\n";

    var out = std.ArrayListUnmanaged(u8){};
    defer out.deinit(testing.allocator);
    appendRawToTsv(raw, 0.0, &out, testing.allocator);

    // Should produce two lines with 8 tab-separated columns each
    var lines = std.mem.splitScalar(u8, out.items, '\n');
    var line_count: usize = 0;
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        line_count += 1;
    }
    try testing.expectEqual(@as(usize, 2), line_count);
}

test "appendRawToTsv detects VDS block boundaries" {
    // VGS wraps back -> new VDS block
    const raw =
        "0.1000  1.0e-06  2.5e-05  1.0e-07  1.0e-15\n" ++
        "0.2000  1.0e-05  1.5e-04  1.0e-06  5.0e-15\n" ++
        "0.1000  1.1e-06  2.6e-05  1.1e-07  1.1e-15\n"; // VGS wraps back

    var out = std.ArrayListUnmanaged(u8){};
    defer out.deinit(testing.allocator);
    appendRawToTsv(raw, 0.0, &out, testing.allocator);

    // Parse back and check VDS values
    var parsed_vds = [3]f64{ 0, 0, 0 };
    var lines = std.mem.splitScalar(u8, out.items, '\n');
    var idx: usize = 0;
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        const v = parseTsvLine8(trimmed) orelse continue;
        if (idx < 3) { parsed_vds[idx] = v[1]; idx += 1; }
    }
    try testing.expectEqual(@as(usize, 3), idx);
    // First block VDS=0.05, second block VDS=0.15
    try testing.expectApproxEqAbs(0.05, parsed_vds[0], 1e-10);
    try testing.expectApproxEqAbs(0.05, parsed_vds[1], 1e-10);
    try testing.expectApproxEqAbs(0.15, parsed_vds[2], 1e-10);
}

test "NgspiceStatus label formatting" {
    var buf: [80]u8 = undefined;

    var not_found = NgspiceStatus{};
    try testing.expectEqualStrings("ngspice: not found", not_found.label(&buf));

    var found = NgspiceStatus{ .found = true };
    const ver = "42";
    @memcpy(found.version[0..ver.len], ver);
    found.version_len = ver.len;
    try testing.expectEqualStrings("ngspice: 42", found.label(&buf));
}

test "lutPath produces correct path" {
    const path = lutPath(testing.allocator, "/home/test", "sky130A", .nmos) orelse
        return error.TestUnexpectedResult;
    defer testing.allocator.free(path);
    try testing.expectEqualStrings(
        "/home/test/.config/Schemify/PDKLoader/sky130A/lut_nmos.tsv",
        path,
    );
}

test "lutPathCorner produces correct path" {
    const path = lutPathCorner(testing.allocator, "/home/test", "sky130A", .pmos, "ff") orelse
        return error.TestUnexpectedResult;
    defer testing.allocator.free(path);
    try testing.expectEqualStrings(
        "/home/test/.config/Schemify/PDKLoader/sky130A/lut_pmos_ff.tsv",
        path,
    );
}
