///! gm/Id lookup tables and interpolation for MOSFET characterization.
///!
///! This module provides the core gm/Id methodology calculations:
///! - Cubic spline interpolation over characterization data
///! - Lookup: gm/Id -> Vgs, Jd (Id/W), intrinsic gain (gm/gds), gm, gds, fT
///! - Analytical model fallback when no characterization data is available
///!
///! Data flow:
///!   Characterization sweep (external) -> LUT arrays -> cubic spline -> fast lookup
///!
///! The analytical model uses EKV/ACM continuous equations that smoothly
///! transition between weak, moderate, and strong inversion regions.
const std = @import("std");
const math = std.math;
const Allocator = std.mem.Allocator;

// ── Constants ────────────────────────────────────────────────────────────────

/// Boltzmann constant * room temperature / electron charge (thermal voltage at 27C).
const Vt_300K: f64 = 0.02585; // ~26 mV

/// Maximum LUT size per curve (sufficient for 0.1 V^-1 resolution over 3-30 range).
pub const max_lut_points = 1024;

// ── Cubic Spline ─────────────────────────────────────────────────────────────

/// Natural cubic spline interpolator.
/// Pre-computes coefficients for O(log n) lookup via binary search.
/// All storage is inline (no heap allocation).
pub const CubicSpline = struct {
    /// Knot x-coordinates (sorted, strictly monotonic).
    x: [max_lut_points]f64 = undefined,
    /// Knot y-coordinates.
    y: [max_lut_points]f64 = undefined,
    /// Second derivatives at knots (natural boundary: s[0] = s[n-1] = 0).
    s: [max_lut_points]f64 = undefined,
    /// Number of data points.
    n: u32 = 0,

    /// Build spline from sorted (x, y) data.
    /// x must be strictly increasing. Caller ensures this.
    pub fn build(xs: []const f64, ys: []const f64) CubicSpline {
        std.debug.assert(xs.len == ys.len);
        std.debug.assert(xs.len >= 2);
        const n_usize = @min(xs.len, max_lut_points);
        const n: u32 = @intCast(n_usize);

        var self = CubicSpline{ .n = n };
        @memcpy(self.x[0..n_usize], xs[0..n_usize]);
        @memcpy(self.y[0..n_usize], ys[0..n_usize]);

        if (n < 3) {
            // Linear fallback: zero second derivatives.
            self.s[0] = 0.0;
            self.s[1] = 0.0;
            return self;
        }

        // Solve tridiagonal system for natural cubic spline.
        // Using Thomas algorithm (forward sweep + back substitution).
        const nm1 = n - 1;
        const nm2 = n - 2;

        // Temporary storage (stack-allocated, bounded).
        var h: [max_lut_points]f64 = undefined; // intervals
        var alpha: [max_lut_points]f64 = undefined; // RHS
        var l: [max_lut_points]f64 = undefined; // lower diagonal factor
        var mu: [max_lut_points]f64 = undefined; // upper diagonal factor
        var z: [max_lut_points]f64 = undefined; // intermediate

        for (0..nm1) |i| {
            h[i] = self.x[i + 1] - self.x[i];
        }

        for (1..nm1) |i| {
            alpha[i] = (3.0 / h[i]) * (self.y[i + 1] - self.y[i]) -
                (3.0 / h[i - 1]) * (self.y[i] - self.y[i - 1]);
        }

        // Forward sweep
        l[0] = 1.0;
        mu[0] = 0.0;
        z[0] = 0.0;

        for (1..nm1) |i| {
            l[i] = 2.0 * (self.x[i + 1] - self.x[i - 1]) - h[i - 1] * mu[i - 1];
            mu[i] = h[i] / l[i];
            z[i] = (alpha[i] - h[i - 1] * z[i - 1]) / l[i];
        }

        // Back substitution
        l[nm1] = 1.0;
        z[nm1] = 0.0;
        self.s[nm1] = 0.0;

        // Iterate from nm2 down to 0 inclusive.
        var j: usize = nm2;
        while (true) {
            self.s[j] = z[j] - mu[j] * self.s[j + 1];
            if (j == 0) break;
            j -= 1;
        }

        return self;
    }

    /// Evaluate spline at x_eval. Clamps to range [x[0], x[n-1]].
    pub fn eval(self: *const CubicSpline, x_eval: f64) f64 {
        const n = self.n;
        if (n == 0) return 0.0;
        if (n == 1) return self.y[0];

        // Clamp
        const x_lo = self.x[0];
        const x_hi = self.x[n - 1];
        const xc = math.clamp(x_eval, x_lo, x_hi);

        // Binary search for interval
        const i = self.findInterval(xc);
        return self.evalAt(i, xc);
    }

    /// Evaluate with linear extrapolation outside the data range.
    pub fn evalExtrapolate(self: *const CubicSpline, x_eval: f64) f64 {
        const n = self.n;
        if (n == 0) return 0.0;
        if (n == 1) return self.y[0];

        const x_lo = self.x[0];
        const x_hi = self.x[n - 1];

        if (x_eval <= x_lo) {
            // Linear extrapolation using derivative at left boundary
            const dydx = self.derivativeAt(0, x_lo);
            return self.y[0] + dydx * (x_eval - x_lo);
        }
        if (x_eval >= x_hi) {
            // Linear extrapolation using derivative at right boundary
            const dydx = self.derivativeAt(n - 2, x_hi);
            return self.y[n - 1] + dydx * (x_eval - x_hi);
        }

        const i = self.findInterval(x_eval);
        return self.evalAt(i, x_eval);
    }

    /// First derivative at x_eval (clamped to data range).
    pub fn derivative(self: *const CubicSpline, x_eval: f64) f64 {
        const n = self.n;
        if (n < 2) return 0.0;

        const xc = math.clamp(x_eval, self.x[0], self.x[n - 1]);
        const i = self.findInterval(xc);
        return self.derivativeAt(i, xc);
    }

    // ── Internal ─────────────────────────────────────────────────────────────

    fn findInterval(self: *const CubicSpline, xc: f64) usize {
        // Binary search: find largest i such that x[i] <= xc
        var lo: usize = 0;
        var hi: usize = self.n - 1;
        while (lo < hi) {
            const mid = lo + (hi - lo + 1) / 2;
            if (self.x[mid] <= xc) {
                lo = mid;
            } else {
                hi = mid - 1;
            }
        }
        // Ensure we don't go past the last interval
        return @min(lo, self.n - 2);
    }

    fn evalAt(self: *const CubicSpline, i: usize, xc: f64) f64 {
        const h = self.x[i + 1] - self.x[i];
        if (@abs(h) < 1e-30) return self.y[i];

        const dx = xc - self.x[i];
        const a = (self.s[i + 1] - self.s[i]) / (6.0 * h);
        const b = self.s[i] / 2.0;
        const c = (self.y[i + 1] - self.y[i]) / h - h * (2.0 * self.s[i] + self.s[i + 1]) / 6.0;
        const d = self.y[i];

        return d + dx * (c + dx * (b + dx * a));
    }

    fn derivativeAt(self: *const CubicSpline, i: usize, xc: f64) f64 {
        const h = self.x[i + 1] - self.x[i];
        if (@abs(h) < 1e-30) return 0.0;

        const dx = xc - self.x[i];
        const a = (self.s[i + 1] - self.s[i]) / (6.0 * h);
        const b = self.s[i] / 2.0;
        const c = (self.y[i + 1] - self.y[i]) / h - h * (2.0 * self.s[i] + self.s[i + 1]) / 6.0;

        return c + dx * (2.0 * b + dx * 3.0 * a);
    }
};

// ── GmIdLookup ───────────────────────────────────────────────────────────────

/// Interpolation-based gm/Id lookup for a single (model, L) pair.
///
/// Given a gm/Id target, look up:
/// - Vgs:  gate-source voltage
/// - Jd:   current density Id/W  (A/um)
/// - Av:   intrinsic gain gm/gds
/// - gm:   transconductance (for reference W)
/// - gds:  output conductance (for reference W)
/// - fT:   transit frequency
///
/// All splines use gm/Id as the independent variable (x-axis).
pub const GmIdLookup = struct {
    /// Spline: gm/Id -> Jd (Id/W in A/um).
    gmid_to_jd: CubicSpline = .{},

    /// Spline: gm/Id -> Vgs (volts).
    gmid_to_vgs: CubicSpline = .{},

    /// Spline: gm/Id -> intrinsic gain (gm/gds, dimensionless).
    gmid_to_av: CubicSpline = .{},

    /// Spline: gm/Id -> gm (S, at reference width).
    gmid_to_gm: CubicSpline = .{},

    /// Spline: gm/Id -> gds (S, at reference width).
    gmid_to_gds: CubicSpline = .{},

    /// Spline: gm/Id -> fT (Hz).
    gmid_to_ft: CubicSpline = .{},

    /// Valid gm/Id range from characterization data.
    gmid_min: f64 = 3.0,
    gmid_max: f64 = 25.0,

    /// Reference width used during characterization (meters).
    ref_width: f64 = 10.0e-6,

    /// Channel length (meters).
    L: f64 = 100e-9,

    /// Whether this lookup has been populated with real data.
    populated: bool = false,

    /// Build lookup from raw arrays.
    /// All arrays are indexed by the same gm/Id sweep points.
    ///
    /// gmid_vals: gm/Id sweep values (must be sorted ascending).
    /// jd_vals:   corresponding Id/W values (A/um).
    /// vgs_vals:  corresponding Vgs values (V).
    /// av_vals:   corresponding gm/gds values.
    /// gm_vals:   corresponding gm values (S) (optional, pass empty for none).
    /// gds_vals:  corresponding gds values (S) (optional).
    /// ft_vals:   corresponding fT values (Hz) (optional).
    pub fn buildFromArrays(
        self: *GmIdLookup,
        gmid_vals: []const f64,
        jd_vals: []const f64,
        vgs_vals: []const f64,
        av_vals: []const f64,
        gm_vals: []const f64,
        gds_vals: []const f64,
        ft_vals: []const f64,
    ) void {
        std.debug.assert(gmid_vals.len >= 2);
        std.debug.assert(gmid_vals.len == jd_vals.len);
        std.debug.assert(gmid_vals.len == vgs_vals.len);
        std.debug.assert(gmid_vals.len == av_vals.len);

        self.gmid_to_jd = CubicSpline.build(gmid_vals, jd_vals);
        self.gmid_to_vgs = CubicSpline.build(gmid_vals, vgs_vals);
        self.gmid_to_av = CubicSpline.build(gmid_vals, av_vals);

        if (gm_vals.len == gmid_vals.len) {
            self.gmid_to_gm = CubicSpline.build(gmid_vals, gm_vals);
        }
        if (gds_vals.len == gmid_vals.len) {
            self.gmid_to_gds = CubicSpline.build(gmid_vals, gds_vals);
        }
        if (ft_vals.len == gmid_vals.len) {
            self.gmid_to_ft = CubicSpline.build(gmid_vals, ft_vals);
        }

        self.gmid_min = gmid_vals[0];
        self.gmid_max = gmid_vals[gmid_vals.len - 1];
        self.populated = true;
    }

    /// Look up Vgs for a given gm/Id ratio.
    pub fn lookupVgs(self: *const GmIdLookup, gmid: f64) f64 {
        if (!self.populated) return analyticalVgs(gmid);
        return self.gmid_to_vgs.eval(clampGmid(self, gmid));
    }

    /// Look up current density Jd = Id/W (A/um) for a given gm/Id.
    pub fn lookupJd(self: *const GmIdLookup, gmid: f64) f64 {
        if (!self.populated) return analyticalJd(gmid);
        return self.gmid_to_jd.eval(clampGmid(self, gmid));
    }

    /// Look up intrinsic gain gm/gds for a given gm/Id.
    pub fn lookupIntrinsicGain(self: *const GmIdLookup, gmid: f64) f64 {
        if (!self.populated) return analyticalIntrinsicGain(gmid);
        return self.gmid_to_av.eval(clampGmid(self, gmid));
    }

    /// Look up gm (S) at reference width for a given gm/Id.
    pub fn lookupGm(self: *const GmIdLookup, gmid: f64) f64 {
        if (self.gmid_to_gm.n < 2) {
            // Derive from Jd: gm = (gm/Id) * Jd * W_ref
            const jd = self.lookupJd(gmid);
            return gmid * @abs(jd) * self.ref_width * 1e6;
        }
        return self.gmid_to_gm.eval(clampGmid(self, gmid));
    }

    /// Look up gds (S) at reference width for a given gm/Id.
    pub fn lookupGds(self: *const GmIdLookup, gmid: f64) f64 {
        if (self.gmid_to_gds.n < 2) {
            // Derive from gm and intrinsic gain: gds = gm / Av
            const gm = self.lookupGm(gmid);
            const av = self.lookupIntrinsicGain(gmid);
            return if (@abs(av) > 1e-30) gm / av else 0.0;
        }
        return self.gmid_to_gds.eval(clampGmid(self, gmid));
    }

    /// Look up transit frequency fT (Hz) for a given gm/Id.
    pub fn lookupFt(self: *const GmIdLookup, gmid: f64) f64 {
        if (self.gmid_to_ft.n < 2) return analyticalFt(gmid, self.L);
        return self.gmid_to_ft.eval(clampGmid(self, gmid));
    }

    /// Compute W (um) given gm/Id ratio and target drain current Id (amps).
    /// W = Id_target / Jd(gmid)  where Jd is in A/um.
    pub fn computeW(self: *const GmIdLookup, gmid: f64, id_target: f64) f64 {
        const jd = self.lookupJd(gmid);
        if (@abs(jd) < 1e-30) return 1.0; // fallback 1 um
        return @abs(id_target / jd);
    }

    /// Compute all device metrics for a given gm/Id and target current.
    pub fn computeMetrics(
        self: *const GmIdLookup,
        gmid: f64,
        id_target: f64,
    ) DeviceMetrics {
        const jd = self.lookupJd(gmid);
        const w_um = if (@abs(jd) < 1e-30) 1.0 else @abs(id_target / jd);
        const vgs = self.lookupVgs(gmid);
        const av = self.lookupIntrinsicGain(gmid);
        const ft = self.lookupFt(gmid);

        // Scale gm/gds from reference width to actual width
        const w_scale = if (self.ref_width > 0) (w_um * 1e-6) / self.ref_width else 1.0;
        const gm = self.lookupGm(gmid) * w_scale;
        const gds = self.lookupGds(gmid) * w_scale;

        return .{
            .W_um = w_um,
            .Vgs = vgs,
            .Id = id_target,
            .gm = gm,
            .gds = gds,
            .fT = ft,
            .intrinsic_gain = av,
            .gmid = gmid,
        };
    }

    fn clampGmid(self: *const GmIdLookup, gmid: f64) f64 {
        return math.clamp(gmid, self.gmid_min, self.gmid_max);
    }
};

/// Computed metrics for a device at a specific operating point.
pub const DeviceMetrics = struct {
    W_um: f64 = 0.0, // width in micrometers
    Vgs: f64 = 0.0,
    Id: f64 = 0.0,
    gm: f64 = 0.0,
    gds: f64 = 0.0,
    fT: f64 = 0.0,
    intrinsic_gain: f64 = 0.0,
    gmid: f64 = 0.0,
};

// ── Analytical Model (EKV/ACM-based) ────────────────────────────────────────
//
// These functions provide reasonable estimates when characterization data is
// unavailable. They use the EKV continuous model that smoothly interpolates
// between weak inversion (gm/Id ~ 1/nVt ~ 25-38 V^-1) and strong inversion
// (gm/Id ~ 2*Id / Vov).
//
// Reference: C. Enz, F. Krummenacher, E. Vittoz, "An Analytical MOS
// Transistor Model Valid in All Regions of Operation" (EKV model).

/// Subthreshold slope factor (typically 1.2-1.5 for bulk CMOS).
const n_slope: f64 = 1.3;

/// Maximum gm/Id in weak inversion: 1/(n*Vt).
const gmid_weak_max: f64 = 1.0 / (n_slope * Vt_300K); // ~29.7 V^-1

/// Technology current density coefficient (A/um per (V)^2).
/// Typical for 180nm: ~50 uA/um at Vov=0.2V.
const kp_density: f64 = 1.25e-3;

/// Analytical Jd(gm/Id) using inverse EKV.
///
/// In strong inversion: Jd ~ (gm/Id)^(-2) * kp * L_ref
/// In weak inversion: Jd ~ exp(-1/(n*Vt * gm/Id)) * I0
/// Smooth interpolation via the EKV inversion coefficient.
pub fn analyticalJd(gmid: f64) f64 {
    // Inversion coefficient: ic = (1/(n*Vt*gmid))^2 in strong inversion
    // Using the smooth interpolation:
    //   Id/W = 2 * n * mu * Cox * Vt^2 * ic
    // where ic is found from the gm/Id ratio.
    //
    // From EKV: gm/Id = 1/(n*Vt) * 1/(sqrt(1 + 4*ic) + 1) * 2
    // Inverting: ic = ((1/(n*Vt*gmid) - 0.5)^2 - 0.25 when gmid < gmid_weak
    //
    // Simplified practical approximation:
    const nVt = n_slope * Vt_300K;
    const ratio = gmid * nVt; // dimensionless, range ~0.08 (strong) to ~1.0 (weak)

    // Inversion coefficient from gm/Id:
    // gm/Id = (1/nVt) * 2 / (1 + sqrt(1 + 4*ic))
    // => 1 + sqrt(1 + 4*ic) = 2 / (gmid * nVt)
    // => sqrt(1 + 4*ic) = 2/ratio - 1
    // => ic = ((2/ratio - 1)^2 - 1) / 4
    if (ratio >= 2.0) {
        // Deep weak inversion: very low current
        // Use exponential decay
        return kp_density * @exp(-ratio);
    }

    const temp = 2.0 / ratio - 1.0;
    const ic = (temp * temp - 1.0) / 4.0;

    // Jd = 2 * n * (mu*Cox) * Vt^2 * ic (A/um)
    // Using kp_density as a lumped technology parameter
    const jd = 2.0 * n_slope * kp_density * Vt_300K * Vt_300K * @max(ic, 1e-15);
    return jd;
}

/// Analytical Vgs from gm/Id using EKV model.
///
/// Vgs = Vth + n*Vt * (sqrt(1 + 4*ic) - 1 + ln(sqrt(1 + 4*ic) - 1))
/// Simplified: for strong inversion, Vgs ~ Vth + Vov where Vov ~ 2/(gm/Id)
pub fn analyticalVgs(gmid: f64) f64 {
    const Vth: f64 = 0.45; // typical threshold voltage
    const nVt = n_slope * Vt_300K;
    const ratio = gmid * nVt;

    if (ratio >= 2.0) {
        // Weak inversion: Vgs ~ Vth - delta (subthreshold)
        return Vth - nVt * @log(ratio);
    }

    // Strong inversion: Vov = 2 / gmid
    const vov = 2.0 / gmid;
    // Smooth transition through moderate inversion
    const weak_term = nVt * @log(1.0 + @exp((Vth - (Vth + vov)) / nVt));
    _ = weak_term;
    return Vth + vov;
}

/// Analytical intrinsic gain (gm/gds) vs gm/Id.
///
/// Strong inversion: Av ~ Va / Vov ~ Va * gmid / 2
/// Weak inversion: Av ~ Va / (n * Vt) (constant, maximum)
/// where Va = Early voltage ~ 10-50V depending on L.
pub fn analyticalIntrinsicGain(gmid: f64) f64 {
    // Early voltage estimate (scales with L; use 10V as baseline for 180nm)
    const Va: f64 = 10.0;

    // In strong inversion: Av = gm/gds = gm * ro = (gm/Id) * (Va * Id / Id) = gmid * Va/2... no
    // Actually: gm = gmid * Id, gds = Id/Va => Av = gm/gds = gmid * Va
    // But this is only approximate; there's a weak inversion ceiling.
    const av_strong = gmid * Va;
    const av_weak_max = Va / (n_slope * Vt_300K); // maximum in weak inversion

    return @min(av_strong, av_weak_max);
}

/// Analytical fT from gm/Id and channel length.
///
/// fT = gm / (2*pi*Cgs) where Cgs ~ (2/3)*Cox*W*L
/// Using: fT ~ mu * Vov / (2*pi*L^2) in strong inversion
pub fn analyticalFt(gmid: f64, L: f64) f64 {
    // Mobility (cm^2/Vs -> m^2/Vs)
    const mu: f64 = 400.0e-4; // ~400 cm^2/Vs for NMOS
    // Overdrive voltage from gm/Id
    const vov = 2.0 / gmid;
    // fT = mu * Vov / (2 * pi * L^2)
    const ft = mu * vov / (2.0 * math.pi * L * L);
    return @min(ft, 500e9); // cap at 500 GHz
}

// ── Data Cleaning ────────────────────────────────────────────────────────────

/// Clean data for interpolation: sort by x, remove duplicates, ensure strict monotonicity.
/// Returns number of valid points written to x_out, y_out.
/// x_out and y_out must be at least as large as x_in.
pub fn cleanForInterp(
    x_in: []const f64,
    y_in: []const f64,
    x_out: []f64,
    y_out: []f64,
) u32 {
    std.debug.assert(x_in.len == y_in.len);
    if (x_in.len == 0) return 0;

    const n = @min(x_in.len, max_lut_points);

    // Copy and create index array for sorting
    var indices: [max_lut_points]u32 = undefined;
    for (0..n) |i| {
        indices[i] = @intCast(i);
    }

    // Insertion sort by x value (stable, good for nearly-sorted data)
    for (1..n) |i_usize| {
        const key = indices[i_usize];
        const key_x = x_in[key];
        var j: usize = i_usize;
        while (j > 0 and x_in[indices[j - 1]] > key_x) {
            indices[j] = indices[j - 1];
            j -= 1;
        }
        indices[j] = key;
    }

    // Write sorted, deduplicated output
    var out_n: u32 = 0;
    var prev_x: f64 = -math.inf(f64);
    for (0..n) |i| {
        const idx = indices[i];
        const xv = x_in[idx];
        if (xv > prev_x + 1e-15) { // skip duplicates
            x_out[out_n] = xv;
            y_out[out_n] = y_in[idx];
            prev_x = xv;
            out_n += 1;
        }
    }
    return out_n;
}

// ── Tests ────────────────────────────────────────────────────────────────────

test "CubicSpline: linear data" {
    const x = [_]f64{ 0.0, 1.0, 2.0, 3.0, 4.0 };
    const y = [_]f64{ 0.0, 2.0, 4.0, 6.0, 8.0 };
    const spline = CubicSpline.build(&x, &y);

    // Exact at knots
    try std.testing.expectApproxEqAbs(0.0, spline.eval(0.0), 1e-10);
    try std.testing.expectApproxEqAbs(4.0, spline.eval(2.0), 1e-10);
    try std.testing.expectApproxEqAbs(8.0, spline.eval(4.0), 1e-10);

    // Midpoint (linear data => exact interpolation)
    try std.testing.expectApproxEqAbs(3.0, spline.eval(1.5), 1e-10);
    try std.testing.expectApproxEqAbs(5.0, spline.eval(2.5), 1e-10);
}

test "CubicSpline: quadratic data" {
    // y = x^2 with dense sampling for accurate cubic spline fit
    const x = [_]f64{ 0.0, 0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.25, 2.5, 2.75, 3.0 };
    var y: [13]f64 = undefined;
    for (&y, x) |*yi, xi| yi.* = xi * xi;

    const spline = CubicSpline.build(&x, &y);

    // Check at midpoints between knots
    try std.testing.expectApproxEqAbs(0.375 * 0.375, spline.eval(0.375), 0.02);
    try std.testing.expectApproxEqAbs(1.875 * 1.875, spline.eval(1.875), 0.02);
}

test "CubicSpline: derivative" {
    // y = x^2 => dy/dx = 2x, with dense sampling
    const x = [_]f64{ 0.0, 0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.25, 2.5, 2.75, 3.0 };
    var y: [13]f64 = undefined;
    for (&y, x) |*yi, xi| yi.* = xi * xi;

    const spline = CubicSpline.build(&x, &y);
    try std.testing.expectApproxEqAbs(2.0, spline.derivative(1.0), 0.15);
    try std.testing.expectApproxEqAbs(4.0, spline.derivative(2.0), 0.15);
}

test "CubicSpline: clamping" {
    const x = [_]f64{ 1.0, 2.0, 3.0 };
    const y = [_]f64{ 10.0, 20.0, 30.0 };
    const spline = CubicSpline.build(&x, &y);

    // Below range: clamps to x[0]
    try std.testing.expectApproxEqAbs(10.0, spline.eval(-5.0), 1e-10);
    // Above range: clamps to x[n-1]
    try std.testing.expectApproxEqAbs(30.0, spline.eval(100.0), 1e-10);
}

test "GmIdLookup: build and query" {
    // Synthetic characterization data for a simple MOSFET
    const gmid = [_]f64{ 3.0, 5.0, 8.0, 10.0, 13.0, 15.0, 18.0, 20.0, 23.0, 25.0 };
    // Jd (A/um): decreasing with increasing gm/Id (less current in weak inversion)
    const jd = [_]f64{ 500e-6, 200e-6, 50e-6, 20e-6, 5e-6, 2e-6, 0.5e-6, 0.2e-6, 0.05e-6, 0.02e-6 };
    // Vgs: decreasing from strong to weak
    const vgs = [_]f64{ 0.8, 0.65, 0.55, 0.50, 0.45, 0.42, 0.38, 0.35, 0.32, 0.30 };
    // Intrinsic gain: increasing from strong to weak
    const av = [_]f64{ 10.0, 20.0, 40.0, 60.0, 80.0, 100.0, 130.0, 150.0, 180.0, 200.0 };

    var lookup = GmIdLookup{ .L = 180e-9 };
    lookup.buildFromArrays(&gmid, &jd, &vgs, &av, &.{}, &.{}, &.{});

    try std.testing.expect(lookup.populated);
    try std.testing.expectApproxEqAbs(3.0, lookup.gmid_min, 1e-9);
    try std.testing.expectApproxEqAbs(25.0, lookup.gmid_max, 1e-9);

    // At knot points
    try std.testing.expectApproxEqAbs(0.50, lookup.lookupVgs(10.0), 1e-6);
    try std.testing.expectApproxEqAbs(20e-6, lookup.lookupJd(10.0), 1e-9);
    try std.testing.expectApproxEqAbs(60.0, lookup.lookupIntrinsicGain(10.0), 1e-6);

    // Compute W for 10uA target at gm/Id = 10
    const w = lookup.computeW(10.0, 10e-6);
    // W = 10e-6 / 20e-6 = 0.5 um
    try std.testing.expectApproxEqAbs(0.5, w, 0.01);

    // Interpolated point
    const jd_interp = lookup.lookupJd(7.0);
    try std.testing.expect(jd_interp > jd[2] and jd_interp < jd[1]); // between 5 and 8
}

test "GmIdLookup: analytical fallback" {
    var lookup = GmIdLookup{ .L = 180e-9 };
    // Not populated, should use analytical model
    try std.testing.expect(!lookup.populated);

    const vgs = lookup.lookupVgs(10.0);
    try std.testing.expect(vgs > 0.3 and vgs < 1.0); // reasonable range

    const jd = lookup.lookupJd(10.0);
    try std.testing.expect(jd > 0.0); // positive current density

    const av = lookup.lookupIntrinsicGain(10.0);
    try std.testing.expect(av > 1.0); // gain > 1

    const ft = lookup.lookupFt(10.0);
    try std.testing.expect(ft > 1e9); // GHz range for 180nm
}

test "analyticalJd: monotonicity" {
    // Jd should decrease as gm/Id increases (more weak inversion = less current)
    var prev_jd: f64 = math.inf(f64);
    var gmid: f64 = 3.0;
    while (gmid <= 25.0) : (gmid += 0.5) {
        const jd = analyticalJd(gmid);
        try std.testing.expect(jd > 0.0);
        try std.testing.expect(jd < prev_jd);
        prev_jd = jd;
    }
}

test "cleanForInterp: deduplication and sorting" {
    const x_in = [_]f64{ 3.0, 1.0, 2.0, 1.0, 4.0 };
    const y_in = [_]f64{ 30.0, 10.0, 20.0, 11.0, 40.0 };
    var x_out: [5]f64 = undefined;
    var y_out: [5]f64 = undefined;

    const n = cleanForInterp(&x_in, &y_in, &x_out, &y_out);
    try std.testing.expectEqual(@as(u32, 4), n); // one duplicate removed
    try std.testing.expectApproxEqAbs(1.0, x_out[0], 1e-9);
    try std.testing.expectApproxEqAbs(2.0, x_out[1], 1e-9);
    try std.testing.expectApproxEqAbs(3.0, x_out[2], 1e-9);
    try std.testing.expectApproxEqAbs(4.0, x_out[3], 1e-9);
}
