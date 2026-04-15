//! Gm/ID-aware cross-PDK device resizing.
//!
//! Algorithm (per MOSFET):
//!   1. Read instance W, L, nf, model from schematic properties
//!   2. Run a single-point ngspice operating-point sim on the source PDK
//!      to extract the ACTUAL bias: VGS, VDS, VSB, ID, gm, gds, Cgg, ft
//!      (NOT a hardcoded VDD/2 estimate)
//!   3. Compute the source operating-point signature:
//!        gm/ID  — inversion level (must be preserved)
//!        ID/W   — current density  (must be preserved)
//!        VDS/VDD — headroom fraction
//!        ft     — unity-gain frequency (for sanity check)
//!   4. In the target PDK LUT, use bilinear interpolation at
//!      VDS = VDS/VDD_src * VDD_dst to find the VGS that yields the SAME gm/ID
//!   5. At that (VGS, VDS) in the target LUT read ID/W_dst via bilinear interp
//!   6. Compute:  W' = (ID_src * nf_src) / (ID/W_dst * nf')
//!               L' = snap(L_src * (Lmin_dst / Lmin_src), discrete_lengths)
//!               nf' = ceil(W_total / max_finger_w) if W_total > max_finger_w
//!   7. Sanity check: ft_dst from actual Cgg in target LUT, flag if |ft_ratio-1| > 30%
//!
//! For BJTs:   record IC, beta, fT from source OP sim.
//!             If target PDK has no BJT models -> status = .unresizable.
//!             If both source and target IS are known, scale emitter area.
//!             Otherwise preserve IC (carry through area, flag for review).
//!
//! For passives (R, C, L): carry through unchanged (status = .passthrough).
//!
//! For controlled sources, pins, code blocks: skip entirely.

const std = @import("std");
const lut = @import("lut.zig");

const Allocator = std.mem.Allocator;

// ── VT flavor support ───────────────────────────────────────────────────── //

pub const VtFlavor = enum {
    standard,
    low_vt,
    high_vt,
    ultra_low_vt,
};

/// Maps a source VT flavor to the closest available target VT flavor.
/// Returns the mapped flavor and whether it was an exact match.
pub const VtMapResult = struct {
    flavor: VtFlavor,
    exact:  bool,
};

/// Per-PDK VT availability flags. True means the flavor exists in that PDK.
pub const VtAvailability = struct {
    standard:     bool = true,
    low_vt:       bool = false,
    high_vt:      bool = false,
    ultra_low_vt: bool = false,

    pub fn has(self: VtAvailability, f: VtFlavor) bool {
        return switch (f) {
            .standard     => self.standard,
            .low_vt       => self.low_vt,
            .high_vt      => self.high_vt,
            .ultra_low_vt => self.ultra_low_vt,
        };
    }
};

/// Known VT availability per PDK.
pub const SKY130_VT = VtAvailability{
    .standard     = true,  // sky130_fd_pr__nfet_01v8
    .low_vt       = true,  // sky130_fd_pr__nfet_01v8_lvt
    .high_vt      = true,  // sky130_fd_pr__nfet_01v8_hvt
    .ultra_low_vt = false,
};

pub const GF180_VT = VtAvailability{
    .standard     = true,  // nfet_03v3 / nfet_06v0
    .low_vt       = true,  // nfet_03v3_dss (low-VT variant)
    .high_vt      = false,
    .ultra_low_vt = false,
};

/// Find the closest VT flavor in the target PDK.
pub fn mapVtFlavor(src: VtFlavor, dst_avail: VtAvailability) VtMapResult {
    // Exact match
    if (dst_avail.has(src)) return .{ .flavor = src, .exact = true };

    // Fallback priority: try nearby flavors, then standard
    const fallbacks: []const []const VtFlavor = &.{
        // standard -> (always exists by convention)
        &.{.standard},
        // low_vt -> standard, ultra_low_vt
        &.{ .standard, .ultra_low_vt },
        // high_vt -> standard
        &.{.standard},
        // ultra_low_vt -> low_vt, standard
        &.{ .low_vt, .standard },
    };
    const idx: usize = @intFromEnum(src);
    if (idx < fallbacks.len) {
        for (fallbacks[idx]) |candidate| {
            if (dst_avail.has(candidate)) return .{ .flavor = candidate, .exact = false };
        }
    }

    // Ultimate fallback
    return .{ .flavor = .standard, .exact = false };
}

// ── Device types ────────────────────────────────────────────────────────── //

pub const DeviceType = enum {
    nmos,
    pmos,
    npn,
    pnp,
    resistor,
    capacitor,
    inductor,
    other,
};

// ── Instance input ──────────────────────────────────────────────────────── //

/// A device instance extracted from the schematic.
pub const DeviceInstance = struct {
    name: []const u8,
    dev_type: DeviceType,

    // MOSFET fields
    w:  f64 = 0, // meters
    l:  f64 = 0, // meters
    nf: u16 = 1,

    // VT flavor (multi-VT support)
    vt_flavor: VtFlavor = .standard,

    // BJT fields
    area:   f64 = 1.0, // emitter area multiplier
    bjt_is: f64 = 0,   // saturation current of source PDK BJT (0 = unknown)

    // Passive fields
    value: f64 = 0, // ohms / farads / henrys

    // Actual bias from OP simulation (filled by extractBias)
    vgs: f64 = 0,
    vds: f64 = 0,
    vsb: f64 = 0,
    id:  f64 = 0,
    gm:  f64 = 0,
    gds: f64 = 0,
    ft:  f64 = 0,

    // BJT bias
    ic: f64 = 0,
    beta: f64 = 0,

    bias_valid: bool = false,
};

// ── Remap entry (output) ────────────────────────────────────────────────── //

pub const RemapEntry = struct {
    name:     [64]u8  = [_]u8{0} ** 64,
    name_len: u8      = 0,
    dev_type: DeviceType = .other,

    // Source values
    old_w:     f64 = 0,
    old_l:     f64 = 0,
    old_nf:    u16 = 1,
    old_value: f64 = 0,
    old_area:  f64 = 1.0,

    // Target values
    new_w:     f64 = 0,
    new_l:     f64 = 0,
    new_nf:    u16 = 1,
    new_value: f64 = 0,
    new_area:  f64 = 1.0,

    // Preserved operating point
    gm_id:    f64 = 0,
    ft_ratio: f64 = 1.0, // ft_dst / ft_src

    // VT mapping result
    dst_vt_flavor: VtFlavor = .standard,
    vt_exact:      bool = true,

    status:   Status = .ok,
    warnings: Warnings = .{},

    pub const Status = enum {
        ok,          // successfully remapped
        no_match,    // could not find equivalent in target LUT
        no_bias,     // OP sim failed, no bias data
        unresizable, // device type not in target PDK (e.g. BJT in CMOS)
        passthrough, // passive — carried through unchanged
        skipped,     // non-electrical, ignored
    };

    pub const Warnings = packed struct {
        ft_deviation:   bool = false, // |ft_ratio - 1| > 0.3
        nf_adjusted:    bool = false, // nf was increased for finger width
        vt_fallback:    bool = false, // VT flavor was approximated
        bjt_area_guess: bool = false, // BJT area carried through (no IS data)
        _pad: u4 = 0,
    };

    pub fn nameSlice(self: *const RemapEntry) []const u8 {
        return self.name[0..self.name_len];
    }
};

pub const RemapResult = struct {
    entries: []RemapEntry,
    alloc:   Allocator,

    pub fn deinit(self: *RemapResult) void {
        self.alloc.free(self.entries);
    }

    pub fn countByStatus(self: *const RemapResult, s: RemapEntry.Status) u32 {
        var n: u32 = 0;
        for (self.entries) |e| if (e.status == s) { n += 1; };
        return n;
    }
};

// ── Bilinear interpolation ──────────────────────────────────────────────── //

/// Result of a bilinear interpolation at a (VGS, VDS) point.
pub const InterpResult = struct {
    id:  f64,
    gm:  f64,
    gds: f64,
    cgg: f64,
};

/// 2D bilinear interpolation on the VGS x VDS grid.
///
/// The LUT rows are sorted by VGS (outer sweep) and VDS (inner sweep).
/// We find the 4 surrounding grid points and interpolate ID, gm, gds, Cgg.
/// Falls back to nearest-neighbor if the point is outside the grid or
/// the grid is too sparse to bracket.
pub fn bilinearInterp(rows: []const lut.LutRow, vgs: f64, vds: f64) ?InterpResult {
    if (rows.len == 0) return null;

    // Collect unique sorted VGS and VDS values from the grid
    // We scan rows to find the two VGS values bracketing our target
    // and the two VDS values bracketing our target.
    var vgs_lo: f64 = -std.math.inf(f64);
    var vgs_hi: f64 = std.math.inf(f64);
    var vds_lo: f64 = -std.math.inf(f64);
    var vds_hi: f64 = std.math.inf(f64);

    for (rows) |row| {
        // VGS bracket
        if (row.vgs <= vgs and row.vgs > vgs_lo) vgs_lo = row.vgs;
        if (row.vgs >= vgs and row.vgs < vgs_hi) vgs_hi = row.vgs;
        // VDS bracket
        if (row.vds <= vds and row.vds > vds_lo) vds_lo = row.vds;
        if (row.vds >= vds and row.vds < vds_hi) vds_hi = row.vds;
    }

    // If we couldn't bracket, fall back to nearest
    if (vgs_lo == -std.math.inf(f64) or vgs_hi == std.math.inf(f64) or
        vds_lo == -std.math.inf(f64) or vds_hi == std.math.inf(f64))
    {
        return nearestInterp(rows, vgs, vds);
    }

    // Find the 4 corner rows: (vgs_lo, vds_lo), (vgs_lo, vds_hi),
    //                          (vgs_hi, vds_lo), (vgs_hi, vds_hi)
    const q11 = findRow(rows, vgs_lo, vds_lo) orelse return nearestInterp(rows, vgs, vds);
    const q12 = findRow(rows, vgs_lo, vds_hi) orelse return nearestInterp(rows, vgs, vds);
    const q21 = findRow(rows, vgs_hi, vds_lo) orelse return nearestInterp(rows, vgs, vds);
    const q22 = findRow(rows, vgs_hi, vds_hi) orelse return nearestInterp(rows, vgs, vds);

    // Interpolation weights
    const dv_gs = vgs_hi - vgs_lo;
    const dv_ds = vds_hi - vds_lo;

    // Degenerate cases (exact grid point)
    if (dv_gs < 1e-15 and dv_ds < 1e-15) {
        return .{ .id = q11.id, .gm = q11.gm, .gds = q11.gds, .cgg = q11.cgg };
    }

    const t = if (dv_gs > 1e-15) (vgs - vgs_lo) / dv_gs else 0.0;
    const u = if (dv_ds > 1e-15) (vds - vds_lo) / dv_ds else 0.0;

    return .{
        .id  = bilerp(q11.id,  q12.id,  q21.id,  q22.id,  t, u),
        .gm  = bilerp(q11.gm,  q12.gm,  q21.gm,  q22.gm,  t, u),
        .gds = bilerp(q11.gds, q12.gds, q21.gds, q22.gds, t, u),
        .cgg = bilerp(q11.cgg, q12.cgg, q21.cgg, q22.cgg, t, u),
    };
}

/// Standard bilinear interpolation formula.
/// q11 = (lo,lo), q12 = (lo,hi), q21 = (hi,lo), q22 = (hi,hi)
/// t = weight along first axis (VGS), u = weight along second axis (VDS)
fn bilerp(q11: f64, q12: f64, q21: f64, q22: f64, t: f64, u: f64) f64 {
    return q11 * (1 - t) * (1 - u) +
           q12 * (1 - t) * u +
           q21 * t * (1 - u) +
           q22 * t * u;
}

/// Find the exact row matching (vgs, vds) within grid tolerance.
fn findRow(rows: []const lut.LutRow, vgs: f64, vds: f64) ?lut.LutRow {
    const tol = 1e-6; // 1uV tolerance for grid matching
    for (rows) |row| {
        if (@abs(row.vgs - vgs) < tol and @abs(row.vds - vds) < tol) return row;
    }
    return null;
}

/// Nearest-neighbor fallback for interpolation.
fn nearestInterp(rows: []const lut.LutRow, vgs: f64, vds: f64) ?InterpResult {
    var best_dist: f64 = std.math.inf(f64);
    var best: ?lut.LutRow = null;
    for (rows) |row| {
        const d = (row.vgs - vgs) * (row.vgs - vgs) + (row.vds - vds) * (row.vds - vds);
        if (d < best_dist) {
            best_dist = d;
            best = row;
        }
    }
    const b = best orelse return null;
    return .{ .id = b.id, .gm = b.gm, .gds = b.gds, .cgg = b.cgg };
}

/// Find VGS that yields a target gm/ID at a given VDS, using bilinear interpolation.
/// Sweeps VGS across the grid range and finds the closest match.
fn findVgsForGmIdInterp(rows: []const lut.LutRow, target_gm_id: f64, vds: f64) ?f64 {
    if (rows.len == 0) return null;

    // Find VGS range from the LUT
    var vgs_min: f64 = std.math.inf(f64);
    var vgs_max: f64 = -std.math.inf(f64);
    for (rows) |row| {
        if (row.vgs < vgs_min) vgs_min = row.vgs;
        if (row.vgs > vgs_max) vgs_max = row.vgs;
    }
    if (vgs_min >= vgs_max) return null;

    // Sweep VGS in fine steps and find the one closest to target gm/ID
    const n_steps: usize = 200;
    const step = (vgs_max - vgs_min) / @as(f64, @floatFromInt(n_steps));
    var best_dist: f64 = std.math.inf(f64);
    var best_vgs: f64 = 0;

    for (0..n_steps + 1) |i| {
        const v = vgs_min + step * @as(f64, @floatFromInt(i));
        const interp = bilinearInterp(rows, v, vds) orelse continue;
        if (@abs(interp.id) < 1e-15) continue;
        const gm_id = interp.gm / interp.id;
        const dist = @abs(gm_id - target_gm_id);
        if (dist < best_dist) {
            best_dist = dist;
            best_vgs = v;
        }
    }

    return if (best_dist < std.math.inf(f64)) best_vgs else null;
}

// ── L grid snapping ─────────────────────────────────────────────────────── //

/// Snap a length value to the nearest discrete L in the grid.
/// If the grid is empty, returns the input value unchanged.
pub fn snapToGrid(l: f64, grid: []const f64) f64 {
    if (grid.len == 0) return l;
    var best = grid[0];
    var best_dist = @abs(l - grid[0]);
    for (grid[1..]) |g| {
        const dist = @abs(l - g);
        if (dist < best_dist) {
            best_dist = dist;
            best = g;
        }
    }
    return best;
}

// ── Core remap algorithm ────────────────────────────────────────────────── //

pub fn computeRemap(
    alloc: Allocator,
    instances: []const DeviceInstance,
    src_params: lut.PdkParams,
    dst_params: lut.PdkParams,
    src_nmos: *const lut.Lut,
    src_pmos: *const lut.Lut,
    dst_nmos: *const lut.Lut,
    dst_pmos: *const lut.Lut,
    dst_has_bjt: bool,
    dst_vt: VtAvailability,
) ?RemapResult {
    var entries = std.ArrayListUnmanaged(RemapEntry){};

    for (instances) |inst| {
        var entry = RemapEntry{ .dev_type = inst.dev_type };
        setEntryName(&entry, inst.name);

        switch (inst.dev_type) {
            .nmos, .pmos => remapMosfet(&entry, &inst, src_params, dst_params,
                if (inst.dev_type == .nmos) src_nmos else src_pmos,
                if (inst.dev_type == .nmos) dst_nmos else dst_pmos,
                dst_vt),

            .npn, .pnp => remapBjt(&entry, &inst, src_params, dst_params, dst_has_bjt),

            .resistor, .capacitor, .inductor => {
                entry.old_value = inst.value;
                entry.new_value = inst.value;
                entry.status = .passthrough;
            },

            .other => { entry.status = .skipped; },
        }

        entries.append(alloc, entry) catch continue;
    }

    return .{
        .entries = entries.toOwnedSlice(alloc) catch { entries.deinit(alloc); return null; },
        .alloc = alloc,
    };
}

fn remapMosfet(
    entry: *RemapEntry,
    inst: *const DeviceInstance,
    src_params: lut.PdkParams,
    dst_params: lut.PdkParams,
    src_lut: *const lut.Lut,
    dst_lut: *const lut.Lut,
    dst_vt: VtAvailability,
) void {
    _ = src_lut; // reserved for future source-side interpolation

    entry.old_w  = inst.w;
    entry.old_l  = inst.l;
    entry.old_nf = inst.nf;

    // Multi-VT mapping
    const vt_map = mapVtFlavor(inst.vt_flavor, dst_vt);
    entry.dst_vt_flavor = vt_map.flavor;
    entry.vt_exact = vt_map.exact;
    if (!vt_map.exact) entry.warnings.vt_fallback = true;

    if (!inst.bias_valid) {
        entry.status = .no_bias;
        entry.new_w  = inst.w;
        entry.new_l  = inst.l;
        entry.new_nf = inst.nf;
        return;
    }

    // Step 3: Extract source operating-point signature from actual bias
    const src_gm_id = if (@abs(inst.id) > 1e-15) inst.gm / inst.id else {
        entry.status = .no_match;
        copyOldToNew(entry, inst);
        return;
    };
    const src_id_w = inst.id / (inst.w * @as(f64, @floatFromInt(inst.nf)));
    const src_headroom = if (src_params.vdd > 0) inst.vds / src_params.vdd else 0.5;

    entry.gm_id = src_gm_id;

    // Step 4: Find VGS in target LUT at proportional VDS headroom (bilinear interp)
    const dst_vds = src_headroom * dst_params.vdd;
    const dst_vgs = findVgsForGmIdInterp(dst_lut.rows, src_gm_id, dst_vds) orelse {
        entry.status = .no_match;
        copyOldToNew(entry, inst);
        return;
    };

    // Step 5: Read ID/W at the matched operating point (bilinear interp)
    const dst_interp = bilinearInterp(dst_lut.rows, dst_vgs, dst_vds) orelse {
        entry.status = .no_match;
        copyOldToNew(entry, inst);
        return;
    };
    const dst_id_w = dst_interp.id / 1.0e-6; // W=1u in LUT sweep netlist

    // Step 6a: Compute new L with grid snapping
    const l_scaled = inst.l * (dst_params.l_min / src_params.l_min);
    entry.new_l = snapToGrid(l_scaled, dst_params.discrete_lengths);

    // Step 6b: Compute new W total (preserving total drain current)
    const nf_f = @as(f64, @floatFromInt(inst.nf));
    const id_total = @abs(src_id_w) * inst.w * nf_f;
    const new_w_total = if (@abs(dst_id_w) > 1e-15) id_total / @abs(dst_id_w) else inst.w * nf_f;

    // Step 6c: nf optimization — split into fingers if W exceeds max_finger_w
    if (dst_params.max_finger_w > 0 and new_w_total > dst_params.max_finger_w) {
        const nf_raw = new_w_total / dst_params.max_finger_w;
        const nf_ceil = @ceil(nf_raw);
        const nf_int: u16 = if (nf_ceil > 1.0 and nf_ceil <= 65535.0)
            @intFromFloat(nf_ceil)
        else
            inst.nf;
        entry.new_nf = nf_int;
        entry.new_w = new_w_total / @as(f64, @floatFromInt(nf_int));
        entry.warnings.nf_adjusted = true;
    } else {
        entry.new_nf = inst.nf;
        entry.new_w = new_w_total / nf_f;
    }

    // Clamp W to [Lmin, 100u]
    entry.new_w = @max(dst_params.l_min, @min(100.0e-6, entry.new_w));

    // Step 7: ft sanity check using actual Cgg from target LUT
    if (inst.ft > 0) {
        if (dst_interp.cgg > 1e-30) {
            // Compute ft from target LUT data: ft = gm / (2 * pi * Cgg)
            const two_pi = 2.0 * std.math.pi;
            const ft_dst = dst_interp.gm / (two_pi * dst_interp.cgg);
            entry.ft_ratio = ft_dst / inst.ft;
        } else {
            // No Cgg data — fall back to rough 1/L approximation
            const l_ratio = entry.new_l / inst.l;
            entry.ft_ratio = 1.0 / l_ratio;
        }
        if (@abs(entry.ft_ratio - 1.0) > 0.3) {
            entry.warnings.ft_deviation = true;
        }
    }

    entry.status = .ok;
}

fn remapBjt(
    entry: *RemapEntry,
    inst: *const DeviceInstance,
    src_params: lut.PdkParams,
    dst_params: lut.PdkParams,
    dst_has_bjt: bool,
) void {
    entry.old_area = inst.area;

    if (!dst_has_bjt) {
        entry.status = .unresizable;
        entry.new_area = inst.area;
        return;
    }

    if (!inst.bias_valid) {
        entry.status = .no_bias;
        entry.new_area = inst.area;
        return;
    }

    // Determine source and target IS values
    const src_is = inst.bjt_is;
    const dst_is = switch (inst.dev_type) {
        .npn => dst_params.bjt_is_npn,
        .pnp => dst_params.bjt_is_pnp,
        else => 0.0,
    };
    _ = src_params; // reserved; source IS comes from the device instance

    if (src_is > 0 and dst_is > 0) {
        // Both IS values known: scale area to preserve IC
        // IC = area * IS * (exp(VBE/VT) - 1), so area_dst = area_src * IS_src / IS_dst
        entry.new_area = inst.area * (src_is / dst_is);
    } else {
        // Unknown IS — carry through area and flag for manual review
        entry.new_area = inst.area;
        entry.warnings.bjt_area_guess = true;
    }

    entry.gm_id = if (@abs(inst.ic) > 1e-15) inst.gm / inst.ic else 0;
    entry.status = .ok;
}

fn copyOldToNew(entry: *RemapEntry, inst: *const DeviceInstance) void {
    entry.new_w  = inst.w;
    entry.new_l  = inst.l;
    entry.new_nf = inst.nf;
}

fn setEntryName(entry: *RemapEntry, name: []const u8) void {
    const n: u8 = @intCast(@min(name.len, 64));
    @memcpy(entry.name[0..n], name[0..n]);
    entry.name_len = n;
}

// ── Tests ───────────────────────────────────────────────────────────────── //

test "snapToGrid picks nearest" {
    const grid = [_]f64{ 0.15e-6, 0.18e-6, 0.25e-6, 0.5e-6, 1.0e-6 };
    // Exact match
    try std.testing.expectApproxEqAbs(0.15e-6, snapToGrid(0.15e-6, &grid), 1e-18);
    // Between 0.18 and 0.25, closer to 0.18
    try std.testing.expectApproxEqAbs(0.18e-6, snapToGrid(0.20e-6, &grid), 1e-18);
    // Between 0.25 and 0.5, closer to 0.25
    try std.testing.expectApproxEqAbs(0.25e-6, snapToGrid(0.30e-6, &grid), 1e-18);
    // Way above grid -> picks largest
    try std.testing.expectApproxEqAbs(1.0e-6, snapToGrid(2.0e-6, &grid), 1e-18);
    // Empty grid -> returns input
    try std.testing.expectApproxEqAbs(0.42e-6, snapToGrid(0.42e-6, &[_]f64{}), 1e-18);
}

test "bilinearInterp returns result for single row" {
    var rows = [_]lut.LutRow{.{
        .vgs = 0.5, .vds = 0.9, .vsb = 0, .id = 1e-4, .gm = 1e-3, .gds = 1e-5, .cgg = 1e-14, .ft = 0,
    }};
    const result = bilinearInterp(&rows, 0.5, 0.9);
    try std.testing.expect(result != null);
    try std.testing.expectApproxEqAbs(1e-4, result.?.id, 1e-18);
}

test "bilinearInterp interpolates between 4 points" {
    var rows = [_]lut.LutRow{
        .{ .vgs = 0.4, .vds = 0.8, .vsb = 0, .id = 1.0, .gm = 10.0, .gds = 0.1, .cgg = 1e-14, .ft = 0 },
        .{ .vgs = 0.4, .vds = 1.0, .vsb = 0, .id = 2.0, .gm = 20.0, .gds = 0.2, .cgg = 2e-14, .ft = 0 },
        .{ .vgs = 0.6, .vds = 0.8, .vsb = 0, .id = 3.0, .gm = 30.0, .gds = 0.3, .cgg = 3e-14, .ft = 0 },
        .{ .vgs = 0.6, .vds = 1.0, .vsb = 0, .id = 4.0, .gm = 40.0, .gds = 0.4, .cgg = 4e-14, .ft = 0 },
    };
    // Midpoint: VGS=0.5, VDS=0.9 -> average of all 4 = 2.5
    const result = bilinearInterp(&rows, 0.5, 0.9);
    try std.testing.expect(result != null);
    try std.testing.expectApproxEqAbs(2.5, result.?.id, 1e-10);
    try std.testing.expectApproxEqAbs(25.0, result.?.gm, 1e-10);
}

test "mapVtFlavor exact match" {
    const result = mapVtFlavor(.high_vt, SKY130_VT);
    try std.testing.expect(result.exact);
    try std.testing.expectEqual(VtFlavor.high_vt, result.flavor);
}

test "mapVtFlavor fallback" {
    // GF180 has no high_vt, should fall back to standard
    const result = mapVtFlavor(.high_vt, GF180_VT);
    try std.testing.expect(!result.exact);
    try std.testing.expectEqual(VtFlavor.standard, result.flavor);
}

test "mapVtFlavor ultra_low_vt falls back to low_vt" {
    const avail = VtAvailability{ .standard = true, .low_vt = true, .high_vt = false, .ultra_low_vt = false };
    const result = mapVtFlavor(.ultra_low_vt, avail);
    try std.testing.expect(!result.exact);
    try std.testing.expectEqual(VtFlavor.low_vt, result.flavor);
}

test "findVgsForGmIdInterp finds correct VGS" {
    // 2x2 grid: VGS={0.4, 0.6}, VDS={0.8, 1.0}
    // gm/ID at (0.4, 0.9) ~ 15, at (0.6, 0.9) ~ 4
    var rows = [_]lut.LutRow{
        .{ .vgs = 0.4, .vds = 0.8, .vsb = 0, .id = 1e-5, .gm = 1.5e-4, .gds = 1e-6, .cgg = 1e-15, .ft = 0 },
        .{ .vgs = 0.4, .vds = 1.0, .vsb = 0, .id = 1.2e-5, .gm = 1.8e-4, .gds = 1.2e-6, .cgg = 1.1e-15, .ft = 0 },
        .{ .vgs = 0.6, .vds = 0.8, .vsb = 0, .id = 5e-4, .gm = 2e-3, .gds = 5e-5, .cgg = 2e-14, .ft = 0 },
        .{ .vgs = 0.6, .vds = 1.0, .vsb = 0, .id = 6e-4, .gm = 2.4e-3, .gds = 6e-5, .cgg = 2.2e-14, .ft = 0 },
    };
    // target gm/ID ~ 15, VDS=0.9 -> should find VGS near 0.4
    const vgs = findVgsForGmIdInterp(&rows, 15.0, 0.9);
    try std.testing.expect(vgs != null);
    try std.testing.expect(vgs.? >= 0.38 and vgs.? <= 0.46);
}

test "computeRemap MOSFET with synthetic LUT" {
    const alloc = std.testing.allocator;

    // Build a small synthetic LUT: VGS from 0.3..0.7, VDS=0.45 and 0.9
    // Simulates a typical NMOS gm/ID characteristic
    const tsv =
        "VGS\tVDS\tVSB\tID\tgm\tgds\tCgg\tft\n" ++
        "0.3\t0.45\t0.0\t1e-6\t2.5e-5\t1e-7\t1e-15\t4e9\n" ++
        "0.4\t0.45\t0.0\t1e-5\t1.5e-4\t1e-6\t5e-15\t4.8e9\n" ++
        "0.5\t0.45\t0.0\t1e-4\t1e-3\t1e-5\t1e-14\t1.6e10\n" ++
        "0.6\t0.45\t0.0\t5e-4\t2e-3\t5e-5\t2e-14\t1.6e10\n" ++
        "0.7\t0.45\t0.0\t2e-3\t4e-3\t2e-4\t5e-14\t1.3e10\n" ++
        "0.3\t0.90\t0.0\t1.1e-6\t2.6e-5\t1.1e-7\t1e-15\t4.1e9\n" ++
        "0.4\t0.90\t0.0\t1.1e-5\t1.6e-4\t1.1e-6\t5e-15\t5.1e9\n" ++
        "0.5\t0.90\t0.0\t1.1e-4\t1.1e-3\t1.1e-5\t1e-14\t1.75e10\n" ++
        "0.6\t0.90\t0.0\t5.5e-4\t2.2e-3\t5.5e-5\t2e-14\t1.75e10\n" ++
        "0.7\t0.90\t0.0\t2.2e-3\t4.4e-3\t2.2e-4\t5e-14\t1.4e10\n";

    var src_nmos = lut.loadLutFromTsv(alloc, tsv) orelse return error.TestUnexpectedResult;
    defer src_nmos.deinit();
    var dst_nmos = lut.loadLutFromTsv(alloc, tsv) orelse return error.TestUnexpectedResult;
    defer dst_nmos.deinit();

    // Use same LUT for pmos (just needs to be non-empty for the test)
    var src_pmos = lut.loadLutFromTsv(alloc, tsv) orelse return error.TestUnexpectedResult;
    defer src_pmos.deinit();
    var dst_pmos = lut.loadLutFromTsv(alloc, tsv) orelse return error.TestUnexpectedResult;
    defer dst_pmos.deinit();

    const src_params = lut.SKY130_PARAMS;
    const dst_params = lut.GF180_PARAMS;

    const instances = [_]DeviceInstance{
        .{ .name = "M1", .dev_type = .nmos, .w = 1.0e-6, .l = 0.15e-6, .nf = 2,
           .vgs = 0.5, .vds = 0.9, .id = 1e-4, .gm = 1e-3, .gds = 1e-5,
           .ft = 5e9, .bias_valid = true },
        .{ .name = "R1", .dev_type = .resistor, .value = 10e3 },
        .{ .name = "M3", .dev_type = .nmos, .w = 1.0e-6, .l = 0.15e-6, .nf = 1,
           .bias_valid = false }, // no bias
        .{ .name = "Q1", .dev_type = .npn, .area = 1.0, .bjt_is = 1e-15,
           .ic = 1e-3, .gm = 0.04, .bias_valid = true },
    };

    var result = computeRemap(
        alloc, &instances, src_params, dst_params,
        &src_nmos, &src_pmos, &dst_nmos, &dst_pmos,
        false, // dst has no BJT
        GF180_VT,
    ) orelse return error.TestUnexpectedResult;
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 4), result.entries.len);

    // M1: biased NMOS -> should be .ok with new W/L computed
    const m1 = result.entries[0];
    try std.testing.expectEqual(RemapEntry.Status.ok, m1.status);
    try std.testing.expect(m1.new_w > 0);
    try std.testing.expect(m1.new_l > 0);
    // L should be snapped to gf180 grid (scaled from 0.15u by Lmin ratio)
    try std.testing.expect(m1.new_l >= dst_params.l_min);

    // R1: passive -> passthrough
    try std.testing.expectEqual(RemapEntry.Status.passthrough, result.entries[1].status);
    try std.testing.expectApproxEqAbs(10e3, result.entries[1].new_value, 1e-6);

    // M3: no bias data -> no_bias
    try std.testing.expectEqual(RemapEntry.Status.no_bias, result.entries[2].status);

    // Q1: NPN but target has no BJT -> unresizable
    try std.testing.expectEqual(RemapEntry.Status.unresizable, result.entries[3].status);
}

test "computeRemap BJT with IS scaling" {
    const alloc = std.testing.allocator;

    const tsv =
        "VGS\tVDS\tVSB\tID\tgm\tgds\tCgg\tft\n" ++
        "0.5\t0.9\t0.0\t1e-4\t1e-3\t1e-5\t1e-14\t5e9\n";

    var nmos = lut.loadLutFromTsv(alloc, tsv) orelse return error.TestUnexpectedResult;
    defer nmos.deinit();
    var pmos = lut.loadLutFromTsv(alloc, tsv) orelse return error.TestUnexpectedResult;
    defer pmos.deinit();

    var dst_params = lut.SKY130_PARAMS;
    dst_params.bjt_is_npn = 2e-15; // target PDK has BJT with known IS

    const instances = [_]DeviceInstance{
        .{ .name = "Q1", .dev_type = .npn, .area = 1.0, .bjt_is = 1e-15,
           .ic = 1e-3, .gm = 0.04, .bias_valid = true },
    };

    var result = computeRemap(
        alloc, &instances, lut.SKY130_PARAMS, dst_params,
        &nmos, &pmos, &nmos, &pmos,
        true, SKY130_VT,
    ) orelse return error.TestUnexpectedResult;
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.entries.len);
    const q1 = result.entries[0];
    try std.testing.expectEqual(RemapEntry.Status.ok, q1.status);
    // area_dst = area_src * IS_src / IS_dst = 1.0 * 1e-15 / 2e-15 = 0.5
    try std.testing.expectApproxEqAbs(0.5, q1.new_area, 1e-6);
    try std.testing.expect(!q1.warnings.bjt_area_guess);
}

test "computeRemap BJT without IS flags for review" {
    const alloc = std.testing.allocator;

    const tsv =
        "VGS\tVDS\tVSB\tID\tgm\tgds\tCgg\tft\n" ++
        "0.5\t0.9\t0.0\t1e-4\t1e-3\t1e-5\t1e-14\t5e9\n";

    var nmos = lut.loadLutFromTsv(alloc, tsv) orelse return error.TestUnexpectedResult;
    defer nmos.deinit();
    var pmos = lut.loadLutFromTsv(alloc, tsv) orelse return error.TestUnexpectedResult;
    defer pmos.deinit();

    var dst_params = lut.SKY130_PARAMS;
    dst_params.bjt_is_npn = 0; // target IS unknown

    const instances = [_]DeviceInstance{
        .{ .name = "Q2", .dev_type = .npn, .area = 2.0, .bjt_is = 0, // source IS also unknown
           .ic = 1e-3, .gm = 0.04, .bias_valid = true },
    };

    var result = computeRemap(
        alloc, &instances, lut.SKY130_PARAMS, dst_params,
        &nmos, &pmos, &nmos, &pmos,
        true, SKY130_VT,
    ) orelse return error.TestUnexpectedResult;
    defer result.deinit();

    const q2 = result.entries[0];
    try std.testing.expectEqual(RemapEntry.Status.ok, q2.status);
    // Area carried through unchanged
    try std.testing.expectApproxEqAbs(2.0, q2.new_area, 1e-6);
    try std.testing.expect(q2.warnings.bjt_area_guess);
}

test "RemapResult countByStatus" {
    const alloc = std.testing.allocator;
    var entries = try alloc.alloc(RemapEntry, 4);
    defer alloc.free(entries);
    entries[0] = .{ .status = .ok };
    entries[1] = .{ .status = .ok };
    entries[2] = .{ .status = .passthrough };
    entries[3] = .{ .status = .no_match };

    const result = RemapResult{ .entries = entries, .alloc = alloc };
    try std.testing.expectEqual(@as(u32, 2), result.countByStatus(.ok));
    try std.testing.expectEqual(@as(u32, 1), result.countByStatus(.passthrough));
    try std.testing.expectEqual(@as(u32, 1), result.countByStatus(.no_match));
    try std.testing.expectEqual(@as(u32, 0), result.countByStatus(.no_bias));
}

test "RemapEntry nameSlice" {
    var entry = RemapEntry{};
    setEntryName(&entry, "M1_test");
    try std.testing.expectEqualStrings("M1_test", entry.nameSlice());
}

test "RemapEntry nameSlice truncates at 64" {
    var entry = RemapEntry{};
    const long_name = "A" ** 100;
    setEntryName(&entry, long_name);
    try std.testing.expectEqual(@as(u8, 64), entry.name_len);
}

test "Warnings packed struct layout" {
    var w = RemapEntry.Warnings{};
    try std.testing.expect(!w.ft_deviation);
    try std.testing.expect(!w.nf_adjusted);
    try std.testing.expect(!w.vt_fallback);
    try std.testing.expect(!w.bjt_area_guess);

    w.ft_deviation = true;
    w.nf_adjusted = true;
    try std.testing.expect(w.ft_deviation);
    try std.testing.expect(w.nf_adjusted);
    try std.testing.expect(!w.vt_fallback);
}
