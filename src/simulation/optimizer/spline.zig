///! Cubic spline interpolation and data cleaning utilities.
///!
///! Provides natural cubic spline interpolation with O(log n) lookup via
///! binary search. All storage is inline (no heap allocation).
const std = @import("std");
const math = std.math;

/// Maximum LUT size per curve (sufficient for 0.1 V^-1 resolution over 3-30 range).
pub const max_lut_points = 1024;

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

    // -- Internal --

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

// -- Tests --

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
