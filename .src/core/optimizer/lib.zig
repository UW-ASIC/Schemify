///! gm/Id MOSFET sizing optimizer.
///!
///! Public API for analog circuit optimization using the gm/Id methodology:
///!
///!   1. Define optimization problem (transistors, specs, constraints)
///!   2. Optionally load characterization data into lookup tables
///!   3. Run optimizer -> get optimal device sizes
///!
///! Usage:
///!   var optimizer = Optimizer.init(&problem, &lookups, .{});
///!   const result = optimizer.run();
///!   // result.devices contains W, L, nf, Vgs, Id, gm, gds, fT per transistor
///!
///! The optimizer works standalone without SPICE for basic gm/Id sizing.
///! For simulation-in-the-loop optimization, provide a SimCallback.

pub const types = @import("types.zig");
pub const gmid = @import("gmid.zig");
pub const sweep = @import("sweep.zig");

// Re-export key types at top level for convenience.
pub const Problem = types.Problem;
pub const Transistor = types.Transistor;
pub const Resistor = types.Resistor;
pub const Parameter = types.Parameter;
pub const Specification = types.Specification;
pub const SpecKind = types.SpecKind;
pub const MosfetKind = types.MosfetKind;
pub const OptimizationResult = types.OptimizationResult;
pub const DeviceResult = types.DeviceResult;
pub const Observation = types.Observation;
pub const GmIdLookup = gmid.GmIdLookup;
pub const CubicSpline = gmid.CubicSpline;
pub const DeviceMetrics = gmid.DeviceMetrics;
pub const SweepEngine = sweep.SweepEngine;
pub const SweepConfig = sweep.SweepConfig;
pub const SimCallback = sweep.SimCallback;

const std = @import("std");
const math = std.math;

// ── Optimizer ────────────────────────────────────────────────────────────────

/// High-level optimizer that orchestrates the full gm/Id flow:
///   characterize (build LUTs) -> sweep (explore design space) -> extract results.
pub const Optimizer = struct {
    problem: *Problem,
    lookups: []const GmIdLookup,
    config: Config,
    result: OptimizationResult = .{},

    pub const Config = struct {
        /// Maximum optimization iterations.
        max_iter: u32 = 50,
        /// Number of initial LHS samples for exploration.
        initial_samples: u32 = 20,
        /// Grid refinement passes after exploration.
        refine_passes: u32 = 3,
        /// Grid points per dimension in refinement.
        refine_grid: u32 = 5,
        /// Shrink factor per refinement pass.
        shrink_factor: f64 = 0.3,
        /// PRNG seed for reproducibility.
        seed: u64 = 42,
        /// Reference drain current for W derivation.
        id_ref: f64 = 10e-6,
        /// External simulation callback (null = analytical-only).
        sim_callback: ?SimCallback = null,
        /// Supply voltage (for power estimates).
        vdd: f64 = 1.8,
    };

    pub fn init(
        problem: *Problem,
        lookups: []const GmIdLookup,
        config: Config,
    ) Optimizer {
        return .{
            .problem = problem,
            .lookups = lookups,
            .config = config,
        };
    }

    /// Run the full optimization and return the result.
    ///
    /// Flow:
    /// 1. Validate problem definition
    /// 2. Run parameter sweep (LHS + adaptive refinement)
    /// 3. Extract best design -> DeviceResult per transistor
    /// 4. Return OptimizationResult with all metrics
    pub fn run(self: *Optimizer) OptimizationResult {
        const n_vars = self.problem.designVarCount();
        if (n_vars == 0) return self.result;

        // Run sweep engine
        var engine = SweepEngine.init(self.problem, self.lookups, .{
            .initial_samples = self.config.initial_samples,
            .max_iter = self.config.max_iter,
            .refine_passes = self.config.refine_passes,
            .refine_grid = self.config.refine_grid,
            .shrink_factor = self.config.shrink_factor,
            .seed = self.config.seed,
            .id_ref = self.config.id_ref,
            .sim_callback = self.config.sim_callback,
        });

        const n_evals = engine.run();

        // Build result
        self.result.iterations = n_evals;
        self.result.feasible_count = engine.feasible_count;
        self.result.n_vars = @intCast(n_vars);
        self.result.n_objectives = @intCast(self.problem.objectiveCount());

        if (engine.bestObservation()) |best| {
            self.result.converged = true;
            @memcpy(
                self.result.best_x[0..n_vars],
                best.x[0..n_vars],
            );
            @memcpy(
                self.result.best_objectives[0..best.n_objectives],
                best.objectives[0..best.n_objectives],
            );

            // Extract device results from best point
            self.extractDeviceResults(best);
        }

        return self.result;
    }

    /// Extract per-device results from the best observation.
    fn extractDeviceResults(self: *Optimizer, best: *const Observation) void {
        self.result.devices = .{};
        for (self.problem.transistors.slice(), 0..) |t, ti| {
            if (ti >= best.n_vars) break;
            const gmid_val = best.x[ti];

            const lookup = if (ti < self.lookups.len) &self.lookups[ti] else &GmIdLookup{};
            const metrics = lookup.computeMetrics(gmid_val, self.config.id_ref);

            var dev = DeviceResult{
                .gmid = gmid_val,
                .W = metrics.W_um * 1e-6, // convert um to meters
                .L = t.L,
                .nf = t.nf,
                .Vgs = metrics.Vgs,
                .Id = metrics.Id,
                .gm = metrics.gm,
                .gds = metrics.gds,
                .fT = metrics.fT,
                .intrinsic_gain = metrics.intrinsic_gain,
            };
            const len: u8 = @intCast(@min(t.instance_len, types.max_name_len));
            @memcpy(dev.instance[0..len], t.instance[0..len]);
            dev.instance_len = len;

            self.result.devices.append(dev);
        }
    }
};

// ── Convenience Functions ────────────────────────────────────────────────────

/// Run a simple single-transistor optimization.
/// Returns the optimal gm/Id ratio and device metrics.
pub fn optimizeSingle(
    kind: MosfetKind,
    L: f64,
    gmid_min: f64,
    gmid_max: f64,
    id_target: f64,
    lookup: *const GmIdLookup,
    target_gain: ?f64,
    target_ft: ?f64,
    max_power: ?f64,
    vdd: f64,
) OptimizationResult {
    var prob = Problem{ .vdd = vdd };

    var t = Transistor{ .kind = kind, .L = L, .gmid_min = gmid_min, .gmid_max = gmid_max };
    t.setInstance("M1");
    prob.transistors.append(t);

    // Add specs based on provided targets
    if (target_gain) |gain| {
        var spec = Specification{ .kind = .greater_equal, .target = gain };
        spec.setName("gain");
        prob.specs.append(spec);
    }

    if (target_ft) |ft| {
        var spec = Specification{ .kind = .greater_equal, .target = ft };
        spec.setName("ft");
        prob.specs.append(spec);
    }

    if (max_power) |pwr| {
        var spec = Specification{ .kind = .less_equal, .target = pwr };
        spec.setName("current");
        prob.specs.append(spec);
    }

    // Always minimize area (secondary objective)
    var area_spec = Specification{ .kind = .minimize, .weight = 0.01 };
    area_spec.setName("w");
    prob.specs.append(area_spec);

    const lookups = [_]GmIdLookup{lookup.*};
    var optimizer = Optimizer.init(&prob, &lookups, .{
        .id_ref = id_target,
        .vdd = vdd,
        .max_iter = 100,
        .initial_samples = 30,
    });

    return optimizer.run();
}

/// Sweep gm/Id and return metrics at each point (for visualization).
/// Fills the output arrays with n_points evenly-spaced samples.
/// Returns number of points written.
pub fn sweepGmId(
    lookup: *const GmIdLookup,
    gmid_min: f64,
    gmid_max: f64,
    id_ref: f64,
    gmid_out: []f64,
    jd_out: []f64,
    vgs_out: []f64,
    av_out: []f64,
    ft_out: []f64,
    gm_out: []f64,
) u32 {
    const n = @min(gmid_out.len, @min(jd_out.len, @min(vgs_out.len, @min(av_out.len, @min(ft_out.len, gm_out.len)))));
    if (n == 0) return 0;

    const step = if (n > 1) (gmid_max - gmid_min) / @as(f64, @floatFromInt(n - 1)) else 0.0;

    for (0..n) |i| {
        const g = gmid_min + @as(f64, @floatFromInt(i)) * step;
        const metrics = lookup.computeMetrics(g, id_ref);
        gmid_out[i] = g;
        jd_out[i] = metrics.W_um; // W in um (derived from Jd)
        vgs_out[i] = metrics.Vgs;
        av_out[i] = metrics.intrinsic_gain;
        ft_out[i] = metrics.fT;
        gm_out[i] = metrics.gm;
    }

    return @intCast(n);
}

// ── Comptime validation ──────────────────────────────────────────────────────

comptime {
    _ = types;
    _ = gmid;
    _ = sweep;
}

// ── Tests ────────────────────────────────────────────────────────────────────

test "Optimizer: full flow with analytical model" {
    var prob = Problem{};

    var t1 = Transistor{ .kind = .nmos, .L = 180e-9, .gmid_min = 5.0, .gmid_max = 20.0 };
    t1.setInstance("M_input");
    t1.setModel("nmos_3p3");
    prob.transistors.append(t1);

    var t2 = Transistor{ .kind = .pmos, .L = 180e-9, .gmid_min = 5.0, .gmid_max = 20.0 };
    t2.setInstance("M_load");
    t2.setModel("pmos_3p3");
    prob.transistors.append(t2);

    // Maximize gain
    var gain_spec = Specification{ .kind = .maximize };
    gain_spec.setName("gain");
    prob.specs.append(gain_spec);

    // fT >= 1 GHz
    var ft_spec = Specification{ .kind = .greater_equal, .target = 1e9 };
    ft_spec.setName("ft");
    prob.specs.append(ft_spec);

    const lookups = [_]GmIdLookup{ GmIdLookup{ .L = 180e-9 }, GmIdLookup{ .L = 180e-9 } };
    var optimizer = Optimizer.init(&prob, &lookups, .{
        .max_iter = 30,
        .initial_samples = 15,
        .seed = 42,
    });

    const result = optimizer.run();
    try std.testing.expect(result.iterations > 0);
    try std.testing.expect(result.devices.len == 2);

    // Both devices should have reasonable dimensions
    for (result.devices.slice()) |d| {
        try std.testing.expect(d.W > 0.0);
        try std.testing.expect(d.Vgs > 0.0);
        try std.testing.expect(d.intrinsic_gain > 0.0);
    }
}

test "Optimizer: single transistor convenience" {
    var lookup = GmIdLookup{ .L = 180e-9 };
    const result = optimizeSingle(
        .nmos,
        180e-9,
        5.0,
        20.0,
        10e-6,
        &lookup,
        50.0, // gain >= 50
        1e9, // fT >= 1 GHz
        null, // no power limit
        1.8,
    );

    try std.testing.expect(result.iterations > 0);
    if (result.devices.len > 0) {
        const d = result.devices.get(0);
        try std.testing.expect(d.gmid >= 5.0);
        try std.testing.expect(d.gmid <= 20.0);
    }
}

test "sweepGmId: produces valid sweep data" {
    var lookup = GmIdLookup{ .L = 180e-9 };
    var gm_arr: [50]f64 = undefined;
    var jd_arr: [50]f64 = undefined;
    var vgs_arr: [50]f64 = undefined;
    var av_arr: [50]f64 = undefined;
    var ft_arr: [50]f64 = undefined;
    var gm_vals: [50]f64 = undefined;

    const n = sweepGmId(
        &lookup,
        3.0, 25.0, 10e-6,
        &gm_arr, &jd_arr, &vgs_arr, &av_arr, &ft_arr, &gm_vals,
    );

    try std.testing.expectEqual(@as(u32, 50), n);
    try std.testing.expectApproxEqAbs(3.0, gm_arr[0], 1e-9);
    try std.testing.expectApproxEqAbs(25.0, gm_arr[49], 0.5);

    // Gain should increase with gm/Id (more weak inversion = higher gain)
    try std.testing.expect(av_arr[49] > av_arr[0]);
}

// Pull in sub-module tests
test {
    _ = types;
    _ = gmid;
    _ = sweep;
}
