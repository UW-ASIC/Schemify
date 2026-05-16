///! gm/Ic lookup tables and interpolation for BJT characterization.
///!
///! This module provides the gm/Ic methodology for BJT sizing:
///! - Cubic spline interpolation over characterization data
///! - Lookup: gm/Ic -> Vbe, Jc (Ic/Ae), beta, gm, fT, rpi, ro
///! - Analytical model fallback (Gummel-Poon simplified)
///!
///! Data flow:
///!   Characterization sweep (external) -> LUT arrays -> cubic spline -> fast lookup
///!
///! The analytical model uses simplified Gummel-Poon equations valid in
///! forward active region.
const std = @import("std");
const math = std.math;
pub const CubicSpline = @import("spline.zig").CubicSpline;
pub const max_lut_points = @import("spline.zig").max_lut_points;

// -- Constants --

/// Thermal voltage at 300K (~26 mV).
const Vt_300K: f64 = 0.02585;

/// Reference saturation current (A). Typical small-signal NPN.
const Is_ref: f64 = 1e-15;

/// Forward current gain (typical for small-signal NPN).
const beta_f: f64 = 200.0;

/// Early voltage (V). Typical for small-signal BJT.
const Va: f64 = 50.0;

/// Reference emitter area (m^2) used for analytical Jc normalization.
const Ae_ref: f64 = 1e-12; // 1 um^2

/// Base-collector capacitance per unit area for fT estimation (F/m^2).
const Cbc_per_area: f64 = 1e-3; // ~1 fF/um^2

// -- Result Structs --

/// Computed metrics for a BJT at a specific operating point.
pub const BjtMetrics = struct {
    Ae: f64 = 0, // emitter area (m^2)
    Vbe: f64 = 0, // volts
    Ic: f64 = 0, // amps
    gm: f64 = 0, // siemens
    beta: f64 = 0, // current gain
    fT: f64 = 0, // hertz
    rpi: f64 = 0, // ohms (base input resistance)
    ro: f64 = 0, // ohms (output resistance)
    gmic: f64 = 0, // design variable
};

/// Physical BJT parameters for circuit instantiation.
pub const PhysicalBjtParams = struct {
    Ae: f64 = 0,
    Vbe: f64 = 0,
    Ic: f64 = 0,
    gm: f64 = 0,
    beta: f64 = 0,
    fT: f64 = 0,
};

// -- GmIcLookup --

/// Interpolation-based gm/Ic lookup for a single BJT (model, geometry) pair.
///
/// Given a gm/Ic target, look up:
/// - Jc:   current density Ic/Ae (A/m^2)
/// - Vbe:  base-emitter voltage
/// - beta: current gain Ic/Ib
/// - fT:   transit frequency
/// - rpi:  small-signal base input resistance (at reference area)
/// - ro:   small-signal output resistance (at reference area)
///
/// All splines use gm/Ic as the independent variable (x-axis).
pub const GmIcLookup = struct {
    /// Spline: gm/Ic -> Jc (Ic/Ae in A/m^2).
    gmic_to_jc: CubicSpline = .{},

    /// Spline: gm/Ic -> Vbe (volts).
    gmic_to_vbe: CubicSpline = .{},

    /// Spline: gm/Ic -> beta (dimensionless).
    gmic_to_beta: CubicSpline = .{},

    /// Spline: gm/Ic -> fT (Hz).
    gmic_to_ft: CubicSpline = .{},

    /// Spline: gm/Ic -> rpi (ohms, at reference area).
    gmic_to_rpi: CubicSpline = .{},

    /// Spline: gm/Ic -> ro (ohms, at reference area).
    gmic_to_ro: CubicSpline = .{},

    /// Valid gm/Ic range from characterization data.
    gmic_min: f64 = 20.0,
    gmic_max: f64 = 45.0,

    /// Reference emitter area used during characterization (m^2).
    ref_area: f64 = 1e-12,

    /// Whether this lookup has been populated with real data.
    populated: bool = false,

    /// Build lookup from raw arrays.
    /// All arrays are indexed by the same gm/Ic sweep points.
    ///
    /// gmic_vals: gm/Ic sweep values (must be sorted ascending).
    /// jc_vals:   corresponding Ic/Ae values (A/m^2).
    /// vbe_vals:  corresponding Vbe values (V).
    /// beta_vals: corresponding current gain values.
    /// ft_vals:   corresponding fT values (Hz).
    /// rpi_vals:  corresponding rpi values (ohms) (optional, pass empty for none).
    /// ro_vals:   corresponding ro values (ohms) (optional).
    pub fn buildFromArrays(
        self: *GmIcLookup,
        gmic_vals: []const f64,
        jc_vals: []const f64,
        vbe_vals: []const f64,
        beta_vals: []const f64,
        ft_vals: []const f64,
        rpi_vals: []const f64,
        ro_vals: []const f64,
    ) void {
        std.debug.assert(gmic_vals.len >= 2);
        std.debug.assert(gmic_vals.len == jc_vals.len);
        std.debug.assert(gmic_vals.len == vbe_vals.len);
        std.debug.assert(gmic_vals.len == beta_vals.len);
        std.debug.assert(gmic_vals.len == ft_vals.len);

        self.gmic_to_jc = CubicSpline.build(gmic_vals, jc_vals);
        self.gmic_to_vbe = CubicSpline.build(gmic_vals, vbe_vals);
        self.gmic_to_beta = CubicSpline.build(gmic_vals, beta_vals);
        self.gmic_to_ft = CubicSpline.build(gmic_vals, ft_vals);

        if (rpi_vals.len == gmic_vals.len) {
            self.gmic_to_rpi = CubicSpline.build(gmic_vals, rpi_vals);
        }
        if (ro_vals.len == gmic_vals.len) {
            self.gmic_to_ro = CubicSpline.build(gmic_vals, ro_vals);
        }

        self.gmic_min = gmic_vals[0];
        self.gmic_max = gmic_vals[gmic_vals.len - 1];
        self.populated = true;
    }

    /// Look up Vbe for a given gm/Ic ratio.
    pub fn lookupVbe(self: *const GmIcLookup, gmic: f64) f64 {
        if (!self.populated) return analyticalVbe(gmic);
        return self.gmic_to_vbe.eval(clampGmic(self, gmic));
    }

    /// Look up current density Jc = Ic/Ae (A/m^2) for a given gm/Ic.
    pub fn lookupJc(self: *const GmIcLookup, gmic: f64) f64 {
        if (!self.populated) return analyticalJc(gmic);
        return self.gmic_to_jc.eval(clampGmic(self, gmic));
    }

    /// Look up current gain beta for a given gm/Ic.
    pub fn lookupBeta(self: *const GmIcLookup, gmic: f64) f64 {
        if (!self.populated) return analyticalBeta(gmic);
        return self.gmic_to_beta.eval(clampGmic(self, gmic));
    }

    /// Look up transit frequency fT (Hz) for a given gm/Ic.
    pub fn lookupFt(self: *const GmIcLookup, gmic: f64) f64 {
        if (!self.populated) return analyticalFt(gmic);
        return self.gmic_to_ft.eval(clampGmic(self, gmic));
    }

    /// Look up rpi (ohms) at reference area for a given gm/Ic.
    pub fn lookupRpi(self: *const GmIcLookup, gmic: f64) f64 {
        if (self.gmic_to_rpi.n < 2) {
            // Derive: rpi = beta / gm = beta / (gmic * Ic)
            // At reference area: Ic = Jc * Ae_ref, gm = gmic * Ic
            // rpi = beta / gm
            const beta = self.lookupBeta(gmic);
            const jc = self.lookupJc(gmic);
            const ic = jc * self.ref_area;
            const gm = gmic * ic;
            return if (@abs(gm) > 1e-30) beta / gm else 1e12;
        }
        return self.gmic_to_rpi.eval(clampGmic(self, gmic));
    }

    /// Look up ro (ohms) at reference area for a given gm/Ic.
    pub fn lookupRo(self: *const GmIcLookup, gmic: f64) f64 {
        if (self.gmic_to_ro.n < 2) {
            // Derive: ro = Va / Ic
            const jc = self.lookupJc(gmic);
            const ic = jc * self.ref_area;
            return if (@abs(ic) > 1e-30) Va / @abs(ic) else 1e12;
        }
        return self.gmic_to_ro.eval(clampGmic(self, gmic));
    }

    /// Compute emitter area (m^2) given gm/Ic ratio and target collector current.
    /// Ae = Ic_target / Jc(gmic)
    pub fn computeAe(self: *const GmIcLookup, gmic: f64, ic_target: f64) f64 {
        const jc = self.lookupJc(gmic);
        if (@abs(jc) < 1e-30) return Ae_ref; // fallback
        return @abs(ic_target / jc);
    }

    /// Compute all device metrics for a given gm/Ic and target current.
    pub fn computeMetrics(
        self: *const GmIcLookup,
        gmic: f64,
        ic_target: f64,
    ) BjtMetrics {
        const jc = self.lookupJc(gmic);
        const ae = if (@abs(jc) < 1e-30) Ae_ref else @abs(ic_target / jc);
        const vbe = self.lookupVbe(gmic);
        const beta = self.lookupBeta(gmic);
        const ft = self.lookupFt(gmic);

        // Scale rpi/ro from reference area to actual area
        // rpi scales inversely with area (more area = more Ic = less rpi)
        // ro scales inversely with area (more area = more Ic = less ro)
        const area_scale = if (self.ref_area > 0) self.ref_area / ae else 1.0;
        const rpi = self.lookupRpi(gmic) * area_scale;
        const ro = self.lookupRo(gmic) * area_scale;

        const gm = gmic * ic_target;

        return .{
            .Ae = ae,
            .Vbe = vbe,
            .Ic = ic_target,
            .gm = gm,
            .beta = beta,
            .fT = ft,
            .rpi = rpi,
            .ro = ro,
            .gmic = gmic,
        };
    }

    /// Convert lookup result to physical parameters for circuit instantiation.
    pub fn toPhysicalParams(self: *const GmIcLookup, gmic: f64, ic_target: f64) PhysicalBjtParams {
        const metrics = self.computeMetrics(gmic, ic_target);
        return .{
            .Ae = metrics.Ae,
            .Vbe = metrics.Vbe,
            .Ic = metrics.Ic,
            .gm = metrics.gm,
            .beta = metrics.beta,
            .fT = metrics.fT,
        };
    }

    fn clampGmic(self: *const GmIcLookup, gmic: f64) f64 {
        return math.clamp(gmic, self.gmic_min, self.gmic_max);
    }
};

// -- Analytical Model (Gummel-Poon simplified) --
//
// These functions provide reasonable estimates when characterization data is
// unavailable. They use simplified Gummel-Poon equations valid in the
// forward active region.
//
// In forward active: gm/Ic = 1/Vt (ideal), so gm/Ic ~ 38.6 V^-1 at 300K.
// Real devices show lower gm/Ic due to high-injection effects, series
// resistance, and Early effect.
//
// Reference: H. Gummel, H. Poon, "An Integral Charge Control Model of
// Bipolar Transistors" (Bell System Technical Journal, 1970).

/// Analytical Jc(gm/Ic) for BJTs.
///
/// In forward active: Ic = Is * exp(Vbe/Vt), gm = Ic/Vt
/// => gm/Ic = 1/Vt (ideal). Deviations at high/low injection.
///
/// Jc decreases as gm/Ic increases (operating at lower current density
/// means more thermal-voltage-limited operation).
pub fn analyticalJc(gmic: f64) f64 {
    // In forward active: gm = Ic/Vt, so gm/Ic = 1/Vt ~ 38.6 at 300K
    // For a given gm/Ic, the effective Vt_eff = 1/gmic
    // Ic = Is * exp(Vbe/Vt), and Vbe = Vt * ln(Ic/Is)
    // Jc = Ic/Ae = (Is/Ae) * exp(Vbe/Vt)
    //
    // As gmic increases toward 1/Vt, the device operates more ideally
    // at lower current densities. At lower gmic, high-injection effects
    // push to higher Jc.
    //
    // Practical model: Jc = Jc_peak * exp(-k * (gmic - gmic_peak))
    // where gmic_peak ~ 1/Vt is the ideal operating point.
    const gmic_ideal = 1.0 / Vt_300K; // ~38.68 V^-1
    const jc_ref: f64 = Is_ref / Ae_ref; // reference current density

    // Inversion coefficient analog: how far from ideal
    const ratio = gmic / gmic_ideal;

    if (ratio >= 1.0) {
        // Near ideal or above: exponentially decreasing Jc
        return jc_ref * @exp(5.0 * (1.0 - ratio));
    }

    // Below ideal (high injection regime): higher Jc
    // Jc increases as gmic decreases (more current, less efficiency)
    const ic_factor = 1.0 / (ratio * ratio);
    return jc_ref * ic_factor;
}

/// Analytical Vbe from gm/Ic.
///
/// From Ic = Is * exp(Vbe/Vt): Vbe = Vt * ln(Ic/Is)
/// Using gm/Ic relationship to derive Vbe.
pub fn analyticalVbe(gmic: f64) f64 {
    // gm = Ic / Vt_eff where Vt_eff = 1/gmic
    // In forward active: Vbe = Vt * ln(Ic/Is)
    // As gmic approaches 1/Vt, Vbe stabilizes around 0.65-0.7V for Si BJTs
    //
    // Higher gmic (more ideal operation) -> lower Ic -> lower Vbe
    // Lower gmic (high injection) -> higher Ic -> higher Vbe
    const gmic_ideal = 1.0 / Vt_300K;
    const ratio = gmic / gmic_ideal;

    // Base Vbe at nominal operating point
    const vbe_nom: f64 = 0.65;

    if (ratio >= 1.0) {
        // Near/above ideal: Vbe decreases (lower current)
        return vbe_nom - Vt_300K * @log(ratio);
    }

    // Below ideal: Vbe increases with higher current
    return vbe_nom + Vt_300K * @log(1.0 / ratio);
}

/// Analytical beta vs gm/Ic.
///
/// In forward active, beta ~ beta_f (constant).
/// At extremes: beta decreases due to high-injection (Kirk effect)
/// or low-injection (recombination) effects.
pub fn analyticalBeta(gmic: f64) f64 {
    const gmic_ideal = 1.0 / Vt_300K;
    const ratio = gmic / gmic_ideal;

    // Beta is approximately constant in mid-range
    // Decreases at high injection (low gmic) and very low injection (high gmic)
    if (ratio < 0.5) {
        // High injection: beta drops due to Kirk effect
        return beta_f * ratio * 2.0;
    }
    if (ratio > 1.2) {
        // Very low injection: beta drops due to recombination
        return beta_f / (1.0 + (ratio - 1.2) * 2.0);
    }

    return beta_f;
}

/// Analytical fT from gm/Ic.
///
/// fT = gm / (2*pi*(Cpi + Cmu))
/// where Cpi = gm*tau_f + Cje, Cmu = Cbc
/// Simplified: fT ~ 1 / (2*pi*(tau_f + Cbc/gm))
pub fn analyticalFt(gmic: f64) f64 {
    // Forward transit time (typical for small-signal NPN)
    const tau_f: f64 = 10e-12; // 10 ps

    // Base-collector capacitance contribution (at reference area)
    const cbc: f64 = Cbc_per_area * Ae_ref; // ~1 fF

    // gm at reference: gm = gmic * Ic, and Ic = Jc * Ae_ref
    const jc = analyticalJc(gmic);
    const ic = jc * Ae_ref;
    const gm = gmic * ic;

    // Cpi = gm * tau_f (diffusion capacitance dominates)
    const cpi = gm * tau_f;

    const c_total = cpi + cbc;
    if (c_total < 1e-30) return 0.0;

    const ft = gm / (2.0 * math.pi * c_total);
    return @min(ft, 500e9); // cap at 500 GHz
}

// -- Tests --

test "analyticalJc: monotonicity" {
    // Jc should decrease as gmic increases (higher gmic = more ideal = lower current density)
    var prev_jc: f64 = math.inf(f64);
    var gmic: f64 = 20.0;
    while (gmic <= 40.0) : (gmic += 0.5) {
        const jc = analyticalJc(gmic);
        try std.testing.expect(jc > 0.0);
        try std.testing.expect(jc < prev_jc);
        prev_jc = jc;
    }
}

test "analyticalVbe: reasonable range" {
    // Vbe should be in a reasonable range for silicon BJTs
    var gmic: f64 = 20.0;
    while (gmic <= 40.0) : (gmic += 2.0) {
        const vbe = analyticalVbe(gmic);
        try std.testing.expect(vbe > 0.4);
        try std.testing.expect(vbe < 0.9);
    }
}

test "analyticalBeta: positive and bounded" {
    var gmic: f64 = 20.0;
    while (gmic <= 40.0) : (gmic += 2.0) {
        const beta = analyticalBeta(gmic);
        try std.testing.expect(beta > 0.0);
        try std.testing.expect(beta <= beta_f * 1.01); // never exceeds beta_f
    }
}

test "analyticalFt: positive" {
    var gmic: f64 = 20.0;
    while (gmic <= 40.0) : (gmic += 2.0) {
        const ft = analyticalFt(gmic);
        try std.testing.expect(ft > 0.0);
        try std.testing.expect(ft <= 500e9);
    }
}

test "GmIcLookup: build and query" {
    // Synthetic characterization data for a small-signal NPN
    const gmic = [_]f64{ 20.0, 23.0, 26.0, 29.0, 32.0, 35.0, 38.0, 40.0 };
    // Jc (A/m^2): decreasing with increasing gm/Ic
    const jc = [_]f64{ 1e7, 5e6, 2e6, 8e5, 3e5, 1e5, 3e4, 1e4 };
    // Vbe: decreasing from high injection to low injection
    const vbe = [_]f64{ 0.78, 0.74, 0.71, 0.68, 0.66, 0.64, 0.62, 0.61 };
    // Beta: roughly constant in mid-range
    const beta = [_]f64{ 120.0, 150.0, 180.0, 200.0, 200.0, 195.0, 180.0, 160.0 };
    // fT: peaks in mid-range, drops at extremes
    const ft = [_]f64{ 30e9, 40e9, 50e9, 55e9, 50e9, 40e9, 25e9, 15e9 };

    var lookup = GmIcLookup{};
    lookup.buildFromArrays(&gmic, &jc, &vbe, &beta, &ft, &.{}, &.{});

    try std.testing.expect(lookup.populated);
    try std.testing.expectApproxEqAbs(20.0, lookup.gmic_min, 1e-9);
    try std.testing.expectApproxEqAbs(40.0, lookup.gmic_max, 1e-9);

    // At knot points
    try std.testing.expectApproxEqAbs(0.68, lookup.lookupVbe(29.0), 1e-6);
    try std.testing.expectApproxEqAbs(8e5, lookup.lookupJc(29.0), 1.0);
    try std.testing.expectApproxEqAbs(200.0, lookup.lookupBeta(29.0), 1e-3);
    try std.testing.expectApproxEqAbs(55e9, lookup.lookupFt(29.0), 1.0);

    // Compute Ae for 1mA target at gm/Ic = 29
    const ae = lookup.computeAe(29.0, 1e-3);
    // Ae = 1e-3 / 8e5 = 1.25e-9 m^2
    try std.testing.expectApproxEqAbs(1.25e-9, ae, 1e-11);

    // Interpolated point: cubic spline may overshoot with widely-spaced data,
    // so just check it's in a reasonable range between neighboring knots.
    const jc_interp = lookup.lookupJc(27.0);
    try std.testing.expect(jc_interp > 0.0);
    try std.testing.expect(jc_interp > jc[3]); // should exceed jc at gmic=29 (8e5)
    try std.testing.expect(jc_interp < jc[0]); // should be less than jc at gmic=20 (1e7)
}

test "GmIcLookup: analytical fallback" {
    var lookup = GmIcLookup{};
    // Not populated, should use analytical model
    try std.testing.expect(!lookup.populated);

    const vbe_val = lookup.lookupVbe(30.0);
    try std.testing.expect(vbe_val > 0.4 and vbe_val < 0.9); // reasonable range

    const jc_val = lookup.lookupJc(30.0);
    try std.testing.expect(jc_val > 0.0); // positive current density

    const beta_val = lookup.lookupBeta(30.0);
    try std.testing.expect(beta_val > 1.0); // gain > 1

    const ft_val = lookup.lookupFt(30.0);
    try std.testing.expect(ft_val > 0.0); // positive fT
}

test "GmIcLookup: toPhysicalParams" {
    var lookup = GmIcLookup{};
    const params = lookup.toPhysicalParams(30.0, 1e-3);

    try std.testing.expect(params.Ae > 0.0);
    try std.testing.expect(params.Vbe > 0.4 and params.Vbe < 0.9);
    try std.testing.expectApproxEqAbs(1e-3, params.Ic, 1e-9);
    try std.testing.expect(params.gm > 0.0);
    try std.testing.expect(params.beta > 1.0);
    try std.testing.expect(params.fT > 0.0);
}

test "GmIcLookup: computeMetrics produces consistent results" {
    var lookup = GmIcLookup{};
    const metrics = lookup.computeMetrics(30.0, 1e-3);

    // gm should equal gmic * Ic
    try std.testing.expectApproxEqAbs(30.0 * 1e-3, metrics.gm, 1e-9);

    // rpi should be beta / gm
    const expected_rpi = metrics.beta / metrics.gm;
    try std.testing.expectApproxEqAbs(expected_rpi, metrics.rpi, expected_rpi * 0.1);

    // ro should be positive
    try std.testing.expect(metrics.ro > 0.0);

    // gmic stored correctly
    try std.testing.expectApproxEqAbs(30.0, metrics.gmic, 1e-9);
}
