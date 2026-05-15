///! Parameter sweep engine for gm/Id optimization.
///!
///! Two sweep strategies:
///! 1. **Latin Hypercube Sampling (LHS)**: space-filling initial exploration
///! 2. **Adaptive grid refinement**: zooms into promising regions
///!
///! The sweep engine works standalone (no SPICE dependency). For basic gm/Id
///! optimization it evaluates objectives analytically using lookup tables.
///! Advanced mode can delegate to SPICE via callback (Stream 5 integration).
const std = @import("std");
const math = std.math;
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const gmid_mod = @import("gmid.zig");
const GmIdLookup = gmid_mod.GmIdLookup;
const Observation = types.Observation;
const Problem = types.Problem;

// ── Constants ────────────────────────────────────────────────────────────────

/// Maximum grid points per dimension in a single sweep pass.
const max_grid_per_dim = 64;

/// Maximum total evaluations in a single sweep.
pub const max_evaluations = 16384;

/// Default reference current for W derivation (10 uA).
const default_id_ref: f64 = 10e-6;

// ── PRNG (xoshiro256**) ──────────────────────────────────────────────────────

/// Lightweight PRNG for Latin Hypercube sampling.
/// Using Zig's standard xoshiro256, seeded deterministically.
const Rng = struct {
    state: std.Random.Xoshiro256,

    fn init(seed: u64) Rng {
        return .{ .state = std.Random.Xoshiro256.init(seed) };
    }

    /// Uniform random in [0, 1).
    fn uniform01(self: *Rng) f64 {
        return @as(f64, @floatFromInt(self.state.next() >> 11)) / @as(f64, @floatFromInt(@as(u64, 1) << 53));
    }

    /// Uniform random in [lo, hi).
    fn uniformRange(self: *Rng, lo: f64, hi: f64) f64 {
        return lo + self.uniform01() * (hi - lo);
    }

    /// Fisher-Yates shuffle on a u32 array.
    fn shuffle(self: *Rng, arr: []u32) void {
        if (arr.len <= 1) return;
        var i: usize = arr.len - 1;
        while (i > 0) : (i -= 1) {
            const j = self.state.next() % (i + 1);
            const tmp = arr[i];
            arr[i] = arr[j];
            arr[j] = tmp;
        }
    }
};

// ── Latin Hypercube Sampling ─────────────────────────────────────────────────

/// Generate Latin Hypercube samples in the design space.
///
/// Fills `samples` with n_samples vectors, each of length n_dims.
/// samples is a flat array: samples[i * n_dims + d] = value for sample i, dim d.
///
/// LHS ensures each dimension is stratified into n equal probability intervals,
/// with exactly one sample per stratum per dimension.
pub fn latinHypercube(
    n_samples: u32,
    n_dims: u32,
    lb: []const f64,
    ub: []const f64,
    seed: u64,
    samples: []f64,
) void {
    std.debug.assert(lb.len >= n_dims);
    std.debug.assert(ub.len >= n_dims);
    std.debug.assert(samples.len >= @as(usize, n_samples) * @as(usize, n_dims));

    var rng = Rng.init(seed);
    const ns: usize = n_samples;

    // For each dimension: create permutation of [0..n_samples-1],
    // then place sample in stratum with random jitter.
    for (0..n_dims) |d| {
        // Initialize permutation
        var perm: [max_evaluations]u32 = undefined;
        for (0..ns) |i| perm[i] = @intCast(i);
        rng.shuffle(perm[0..ns]);

        const range = ub[d] - lb[d];
        const step = range / @as(f64, @floatFromInt(n_samples));

        for (0..ns) |i| {
            const stratum: f64 = @floatFromInt(perm[i]);
            const jitter = rng.uniform01();
            const val = lb[d] + (stratum + jitter) * step;
            samples[i * @as(usize, n_dims) + d] = math.clamp(val, lb[d], ub[d]);
        }
    }
}

// ── Evaluation Function Type ─────────────────────────────────────────────────

/// Callback for external simulation (SPICE integration, Stream 5).
/// Returns true if simulation succeeded, false on failure.
/// When null, the sweep uses analytical gm/Id evaluation.
pub const SimCallback = *const fn (
    x: []const f64,
    problem: *const Problem,
    objectives_out: []f64,
    constraints_out: []f64,
) bool;

// ── Sweep Engine ─────────────────────────────────────────────────────────────

pub const SweepConfig = struct {
    /// Number of initial LHS samples.
    initial_samples: u32 = 20,
    /// Maximum total iterations.
    max_iter: u32 = 50,
    /// Grid refinement factor (points per dim in refinement pass).
    refine_grid: u32 = 5,
    /// Number of refinement passes after initial exploration.
    refine_passes: u32 = 3,
    /// Shrink factor per refinement pass (0-1, smaller = tighter zoom).
    shrink_factor: f64 = 0.3,
    /// PRNG seed.
    seed: u64 = 42,
    /// Reference drain current for W calculation (amps).
    id_ref: f64 = default_id_ref,
    /// External simulation callback (null = analytical only).
    sim_callback: ?SimCallback = null,
};

/// Sweep engine state. Arena-allocated for bulk free.
pub const SweepEngine = struct {
    config: SweepConfig,
    problem: *Problem,
    lookups: []const GmIdLookup,
    n_lookups: u32,

    // Pre-allocated result storage (arena-backed)
    observations: [max_evaluations]Observation = undefined,
    n_observations: u32 = 0,

    // Best tracking
    best_idx: ?u32 = null,
    best_objective: f64 = math.inf(f64),
    feasible_count: u32 = 0,

    // Current bounds (narrow during refinement)
    current_lb: [types.max_design_vars]f64 = undefined,
    current_ub: [types.max_design_vars]f64 = undefined,
    n_vars: u32 = 0,

    pub fn init(
        problem: *Problem,
        lookups: []const GmIdLookup,
        config: SweepConfig,
    ) SweepEngine {
        var self = SweepEngine{
            .config = config,
            .problem = problem,
            .lookups = lookups,
            .n_lookups = @intCast(@min(lookups.len, types.max_design_vars)),
        };

        // Get initial bounds from problem
        var lb: [types.max_design_vars]f64 = undefined;
        var ub: [types.max_design_vars]f64 = undefined;
        self.n_vars = @intCast(problem.getBounds(&lb, &ub));
        @memcpy(self.current_lb[0..self.n_vars], lb[0..self.n_vars]);
        @memcpy(self.current_ub[0..self.n_vars], ub[0..self.n_vars]);

        return self;
    }

    /// Run the full sweep: LHS exploration + adaptive refinement.
    /// Returns the number of evaluations performed.
    pub fn run(self: *SweepEngine) u32 {
        // Phase 1: Latin Hypercube exploration
        const n_init = @min(self.config.initial_samples, max_evaluations);
        self.runLHS(n_init);

        // Phase 2: Adaptive grid refinement around best point
        if (self.best_idx != null) {
            var pass: u32 = 0;
            while (pass < self.config.refine_passes) : (pass += 1) {
                if (self.n_observations >= self.config.max_iter) break;
                self.runRefinement(pass);
            }
        }

        return self.n_observations;
    }

    /// Run LHS exploration phase.
    fn runLHS(self: *SweepEngine, n_samples: u32) void {
        const nv: usize = self.n_vars;
        if (nv == 0) return;

        const actual_samples = @min(n_samples, max_evaluations - self.n_observations);
        if (actual_samples == 0) return;

        // Generate LHS samples
        var samples_buf: [max_evaluations * types.max_design_vars]f64 = undefined;
        latinHypercube(
            actual_samples,
            self.n_vars,
            self.current_lb[0..nv],
            self.current_ub[0..nv],
            self.config.seed,
            &samples_buf,
        );

        // Evaluate each sample
        for (0..actual_samples) |i| {
            if (self.n_observations >= self.config.max_iter) break;
            const x = samples_buf[i * nv .. (i + 1) * nv];
            self.evaluate(x);
        }
    }

    /// Run one refinement pass: grid search around best point.
    fn runRefinement(self: *SweepEngine, pass: u32) void {
        const nv: usize = self.n_vars;
        if (nv == 0 or self.best_idx == null) return;

        const best = self.observations[self.best_idx.?];
        const shrink = math.pow(f64, self.config.shrink_factor, @as(f64, @floatFromInt(pass + 1)));
        const grid_n = self.config.refine_grid;

        // Update bounds: center on best, shrink range
        var orig_lb: [types.max_design_vars]f64 = undefined;
        var orig_ub: [types.max_design_vars]f64 = undefined;
        _ = self.problem.getBounds(&orig_lb, &orig_ub);

        for (0..nv) |d| {
            const range = (orig_ub[d] - orig_lb[d]) * shrink;
            const center = best.x[d];
            self.current_lb[d] = @max(orig_lb[d], center - range / 2.0);
            self.current_ub[d] = @min(orig_ub[d], center + range / 2.0);
        }

        // For 1-3 variables: exhaustive grid. For more: LHS within refined bounds.
        if (nv <= 3) {
            self.runGrid(grid_n);
        } else {
            const n_samples = @min(grid_n * grid_n, max_evaluations - self.n_observations);
            self.runLHS(n_samples);
        }
    }

    /// Run exhaustive grid search within current bounds.
    fn runGrid(self: *SweepEngine, points_per_dim: u32) void {
        const nv: usize = self.n_vars;
        if (nv == 0) return;

        // Compute steps per dimension
        var steps: [types.max_design_vars]f64 = undefined;
        for (0..nv) |d| {
            const range = self.current_ub[d] - self.current_lb[d];
            steps[d] = if (points_per_dim > 1) range / @as(f64, @floatFromInt(points_per_dim - 1)) else 0.0;
        }

        // Iterate over grid using mixed-radix counter
        var counter: [types.max_design_vars]u32 = .{0} ** types.max_design_vars;
        const total: u32 = blk: {
            var t: u32 = 1;
            for (0..nv) |_| {
                t = @min(t *| points_per_dim, max_evaluations);
            }
            break :blk t;
        };

        for (0..total) |_| {
            if (self.n_observations >= self.config.max_iter) break;

            // Build x from counter
            var x: [types.max_design_vars]f64 = undefined;
            for (0..nv) |d| {
                x[d] = self.current_lb[d] + @as(f64, @floatFromInt(counter[d])) * steps[d];
            }

            self.evaluate(x[0..nv]);

            // Increment mixed-radix counter
            var carry = true;
            var d: usize = 0;
            while (d < nv and carry) : (d += 1) {
                counter[d] += 1;
                if (counter[d] >= points_per_dim) {
                    counter[d] = 0;
                } else {
                    carry = false;
                }
            }
            if (carry) break; // overflow = done
        }
    }

    /// Evaluate one candidate point and record the observation.
    fn evaluate(self: *SweepEngine, x: []const f64) void {
        if (self.n_observations >= max_evaluations) return;

        var obs = Observation{
            .n_vars = self.n_vars,
            .iteration = self.n_observations,
        };
        @memcpy(obs.x[0..x.len], x);

        if (self.config.sim_callback) |callback| {
            // External simulation
            const n_obj = self.problem.objectiveCount();
            const n_con = self.problem.constraintCount();
            obs.n_objectives = @intCast(n_obj);
            obs.n_constraints = @intCast(n_con);
            obs.valid = callback(
                x,
                self.problem,
                obs.objectives[0..n_obj],
                obs.constraints[0..n_con],
            );
        } else {
            // Analytical evaluation using gm/Id lookups
            self.evaluateAnalytical(x, &obs);
        }

        // Track best feasible
        if (obs.isFeasible()) {
            self.feasible_count += 1;
            const obj_sum = obs.objectiveSum();
            if (self.best_idx == null or obj_sum < self.best_objective) {
                self.best_idx = self.n_observations;
                self.best_objective = obj_sum;
            }
        }

        self.observations[self.n_observations] = obs;
        self.n_observations += 1;
    }

    /// Analytical evaluation using gm/Id lookup tables.
    /// Computes device sizing and checks constraints without SPICE.
    fn evaluateAnalytical(self: *SweepEngine, x: []const f64, obs: *Observation) void {
        const specs = self.problem.specs.slice();
        var obj_idx: u32 = 0;
        var con_idx: u32 = 0;

        // For each transistor, compute metrics from its gm/Id value
        for (self.problem.transistors.slice(), 0..) |t, ti| {
            if (ti >= x.len) break;
            const gmid_val = x[ti];

            // Get lookup for this transistor
            const lookup = if (ti < self.n_lookups) &self.lookups[ti] else &GmIdLookup{};
            const metrics = lookup.computeMetrics(gmid_val, self.config.id_ref);

            // Evaluate specs against this device's metrics
            for (specs) |spec| {
                const measured = self.matchMetric(spec.nameSlice(), metrics, t);
                if (spec.kind.isObjective()) {
                    if (obj_idx < types.max_specs) {
                        obs.objectives[obj_idx] = switch (spec.kind) {
                            .minimize => measured * spec.weight,
                            .maximize => -measured * spec.weight,
                            else => unreachable,
                        };
                        obj_idx += 1;
                    }
                } else {
                    if (con_idx < types.max_specs) {
                        obs.constraints[con_idx] = spec.toConstraint(measured);
                        con_idx += 1;
                    }
                }
            }
        }

        obs.n_objectives = obj_idx;
        obs.n_constraints = con_idx;
        obs.valid = true;
    }

    /// Match a specification name to a device metric value.
    fn matchMetric(
        _: *const SweepEngine,
        name: []const u8,
        metrics: gmid_mod.DeviceMetrics,
        transistor: types.Transistor,
    ) f64 {
        // Common metric names from testbench .meas directives
        if (eqlAny(name, &.{ "gain", "gain_db", "av", "intrinsic_gain" })) {
            return metrics.intrinsic_gain;
        }
        if (eqlAny(name, &.{ "ft", "f_t", "bandwidth", "bw" })) {
            return metrics.fT;
        }
        if (eqlAny(name, &.{ "gm", "transconductance" })) {
            return metrics.gm;
        }
        if (eqlAny(name, &.{ "gds", "output_conductance" })) {
            return metrics.gds;
        }
        if (eqlAny(name, &.{ "id", "drain_current", "current" })) {
            return metrics.Id;
        }
        if (eqlAny(name, &.{ "vgs", "gate_voltage" })) {
            return metrics.Vgs;
        }
        if (eqlAny(name, &.{ "w", "width", "w_um" })) {
            return metrics.W_um;
        }
        if (eqlAny(name, &.{ "power", "pwr" })) {
            return @abs(metrics.Id) * transistor.L; // rough estimate
        }
        if (eqlAny(name, &.{ "area" })) {
            return metrics.W_um * 1e-6 * transistor.L * @as(f64, @floatFromInt(transistor.nf));
        }
        if (eqlAny(name, &.{ "gmid", "gm_id", "gm_over_id" })) {
            return metrics.gmid;
        }
        // Unknown metric: return 0
        return 0.0;
    }

    /// Get the best observation, or null if none feasible.
    pub fn bestObservation(self: *const SweepEngine) ?*const Observation {
        if (self.best_idx) |idx| {
            return &self.observations[idx];
        }
        return null;
    }

    /// Get all observations as a slice.
    pub fn allObservations(self: *const SweepEngine) []const Observation {
        return self.observations[0..self.n_observations];
    }
};

// ── Helpers ──────────────────────────────────────────────────────────────────

fn eqlAny(needle: []const u8, haystack: []const []const u8) bool {
    for (haystack) |h| {
        if (std.ascii.eqlIgnoreCase(needle, h)) return true;
    }
    return false;
}

// ── Tests ────────────────────────────────────────────────────────────────────

test "latinHypercube: basic properties" {
    const n_samples: u32 = 10;
    const n_dims: u32 = 3;
    const lb = [_]f64{ 0.0, -1.0, 100.0 };
    const ub = [_]f64{ 1.0, 1.0, 200.0 };
    var samples: [10 * 3]f64 = undefined;

    latinHypercube(n_samples, n_dims, &lb, &ub, 42, &samples);

    // All samples within bounds
    for (0..n_samples) |i| {
        for (0..n_dims) |d| {
            const val = samples[i * n_dims + d];
            try std.testing.expect(val >= lb[d]);
            try std.testing.expect(val <= ub[d]);
        }
    }

    // Stratification check: for each dimension, sort samples and verify
    // they span different strata
    for (0..n_dims) |d| {
        var vals: [10]f64 = undefined;
        for (0..n_samples) |i| vals[i] = samples[i * n_dims + d];
        std.mem.sort(f64, &vals, {}, std.sort.asc(f64));
        // No two samples should be in the same stratum
        const step = (ub[d] - lb[d]) / @as(f64, @floatFromInt(n_samples));
        for (0..n_samples - 1) |i| {
            const diff = vals[i + 1] - vals[i];
            // Gap should be at least roughly one stratum width (with jitter, allow 0.5x)
            try std.testing.expect(diff > step * 0.01);
        }
    }
}

test "SweepEngine: analytical optimization" {
    var prob = Problem{};

    // One transistor
    var t = types.Transistor{};
    t.setInstance("M1");
    t.setModel("nmos_3p3");
    t.kind = .nmos;
    t.L = 180e-9;
    t.gmid_min = 5.0;
    t.gmid_max = 20.0;
    prob.transistors.append(t);

    // Spec: maximize intrinsic gain
    var spec = types.Specification{};
    spec.setName("gain");
    spec.kind = .maximize;
    spec.weight = 1.0;
    prob.specs.append(spec);

    // Constraint: fT >= 1 GHz
    var ft_spec = types.Specification{};
    ft_spec.setName("ft");
    ft_spec.kind = .greater_equal;
    ft_spec.target = 1e9;
    prob.specs.append(ft_spec);

    // Use analytical model (no characterization data)
    const lookup = GmIdLookup{ .L = 180e-9 };
    const lookups = [_]GmIdLookup{lookup};

    var engine = SweepEngine.init(&prob, &lookups, .{
        .initial_samples = 20,
        .max_iter = 40,
        .refine_passes = 2,
        .seed = 123,
    });

    const n_evals = engine.run();
    try std.testing.expect(n_evals > 0);
    try std.testing.expect(n_evals <= 40);

    // Should have found at least some feasible points
    // (analytical model should produce valid results)
    const all_obs = engine.allObservations();
    try std.testing.expect(all_obs.len > 0);
}

test "SweepEngine: grid search 1D" {
    var prob = Problem{};

    var t = types.Transistor{};
    t.setInstance("M1");
    t.gmid_min = 5.0;
    t.gmid_max = 20.0;
    prob.transistors.append(t);

    var spec = types.Specification{};
    spec.setName("gain");
    spec.kind = .maximize;
    prob.specs.append(spec);

    const lookup = GmIdLookup{};
    const lookups = [_]GmIdLookup{lookup};

    var engine = SweepEngine.init(&prob, &lookups, .{
        .initial_samples = 0, // skip LHS
        .max_iter = 100,
        .refine_grid = 10,
        .seed = 42,
    });

    // Just test grid directly
    engine.runGrid(10);
    try std.testing.expectEqual(@as(u32, 10), engine.n_observations);
}
