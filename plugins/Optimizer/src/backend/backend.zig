//! Backend interface for optimization algorithms.
//! Any backend (Bayesian, evolutionary, etc.) must satisfy this interface.
//! Conformance is checked at comptime via validateBackend — zero vtable, zero fn ptrs.

const std = @import("std");
const Allocator = std.mem.Allocator;

// ============================================================================
// COMPTIME DUCK-TYPE VALIDATION
// ============================================================================

/// Call this inside a comptime block (or at the top of a generic fn) to
/// assert that B implements the optimizer backend contract:
///
///   pub const Config     : type
///   pub const Candidate  : type
///   pub fn init(Allocator, ...) !B
///   pub fn deinit(*B) void
///   pub fn addObservation(*B, ...) !void
///   pub fn suggest(*B, usize, [][]f64) !usize
///   pub fn best(*B) ?struct{...}
pub fn validateBackend(comptime B: type) void {
    inline for ([_][]const u8{ "Config", "Candidate" }) |name| {
        if (!@hasDecl(B, name)) @compileError(@typeName(B) ++ " missing: pub const " ++ name);
    }
    inline for ([_][]const u8{ "init", "deinit", "addObservation", "suggest", "best" }) |name| {
        if (!@hasDecl(B, name)) @compileError(@typeName(B) ++ " missing: pub fn " ++ name);
        if (@typeInfo(@TypeOf(@field(B, name))) != .@"fn")
            @compileError(@typeName(B) ++ "." ++ name ++ " must be a fn");
    }
}

// ============================================================================
// CONFIGURATION TYPES (shared across backends)
// ============================================================================

pub const AcquisitionType = enum {
    expected_improvement,
    probability_of_improvement,
    lower_confidence_bound,
    thompson_sampling,
    knowledge_gradient,
};

pub const KernelType = enum {
    squared_exponential,
    matern32,
    matern52,
    rational_quadratic,
};

/// Configuration for Bayesian optimization backend
pub const BayesianConfig = struct {
    initial_samples: usize = 20,
    acquisition: AcquisitionType = .expected_improvement,
    exploration: f64 = 0.2,
    use_trace: bool = true,
    trace_alpha: f64 = 0.2,
    batch_size: usize = 1,
    kernel: KernelType = .matern52,
    normalize_inputs: bool = true,
    standardize_outputs: bool = true,
};

// ============================================================================
// BAYESIAN BACKEND
// ============================================================================

pub const Bayesian = struct {
    const Self = @This();

    pub const Config = BayesianConfig;

    pub const Candidate = struct {
        parameters: []f64,
        acquisition_value: f64,
        predicted_mean: ?[]f64,
        predicted_std: ?[]f64,
    };

    n_params: usize,
    n_objectives: usize,
    n_constraints: usize,
    bounds_min: []f64,
    bounds_max: []f64,
    config: Config,
    // Observation storage — separate slices (SoA) for cache-friendly GP fitting
    obs_params: std.ArrayList([]f64),
    obs_objectives: std.ArrayList([]f64),
    obs_constraints: std.ArrayList([]f64),
    obs_valid: std.ArrayList(bool),
    allocator: Allocator,
    iteration: usize,
    best_feasible_idx: ?usize,

    pub fn init(
        allocator: Allocator,
        n_params: usize,
        n_objectives: usize,
        n_constraints: usize,
        bounds_min: []const f64,
        bounds_max: []const f64,
        config: Config,
    ) !Self {
        return .{
            .n_params = n_params,
            .n_objectives = n_objectives,
            .n_constraints = n_constraints,
            .bounds_min = try allocator.dupe(f64, bounds_min),
            .bounds_max = try allocator.dupe(f64, bounds_max),
            .config = config,
            .obs_params = std.ArrayList([]f64).init(allocator),
            .obs_objectives = std.ArrayList([]f64).init(allocator),
            .obs_constraints = std.ArrayList([]f64).init(allocator),
            .obs_valid = std.ArrayList(bool).init(allocator),
            .allocator = allocator,
            .iteration = 0,
            .best_feasible_idx = null,
        };
    }

    pub fn deinit(self: *Self) void {
        inline for (.{ self.obs_params.items, self.obs_objectives.items, self.obs_constraints.items }) |slices| {
            for (slices) |values| self.allocator.free(values);
        }
        self.obs_params.deinit();
        self.obs_objectives.deinit();
        self.obs_constraints.deinit();
        self.obs_valid.deinit();
        self.allocator.free(self.bounds_min);
        self.allocator.free(self.bounds_max);
    }

    pub fn addObservation(
        self: *Self,
        params: []const f64,
        objectives: []const f64,
        constraints: []const f64,
        valid: bool,
    ) !void {
        const p = try self.allocator.dupe(f64, params);
        const o = try self.allocator.dupe(f64, objectives);
        const c = try self.allocator.dupe(f64, constraints);

        try self.obs_params.append(p);
        try self.obs_objectives.append(o);
        try self.obs_constraints.append(c);
        try self.obs_valid.append(valid);

        if (valid) {
            const feasible = for (c) |cv| {
                if (cv > 0) break false;
            } else true;

            if (feasible) {
                const idx = self.obs_params.items.len - 1;
                if (self.best_feasible_idx) |best_idx| {
                    if (o[0] < self.obs_objectives.items[best_idx][0])
                        self.best_feasible_idx = idx;
                } else {
                    self.best_feasible_idx = idx;
                }
            }
        }

        self.iteration += 1;
    }

    pub fn suggest(self: *Self, n_candidates: usize, out_candidates: [][]f64) !usize {
        if (self.iteration < self.config.initial_samples)
            return self.latinHypercubeSamples(n_candidates, out_candidates);
        return self.optimizeAcquisition(n_candidates, out_candidates);
    }

    pub fn best(self: *Self) ?struct { params: []const f64, objectives: []const f64 } {
        const idx = self.best_feasible_idx orelse return null;
        return .{
            .params = self.obs_params.items[idx],
            .objectives = self.obs_objectives.items[idx],
        };
    }

    // ── private stubs ──────────────────────────────────────────────────────

    fn latinHypercubeSamples(_: *Self, _: usize, _: [][]f64) usize {
        @panic("latinHypercubeSamples not implemented");
    }

    fn optimizeAcquisition(_: *Self, _: usize, _: [][]f64) !usize {
        @panic("optimizeAcquisition not implemented — needs GP library");
    }
};

// ============================================================================
// PYTHON BACKEND WRAPPER
// ============================================================================

pub const PythonBackend = struct {
    const Self = @This();

    pub const Config = struct {
        python_path: []const u8 = "python3",
        script_path: []const u8 = "optimizer/bayesian.py",
        use_gpu: bool = false,
    };

    pub const Candidate = struct {
        parameters: []f64,
    };

    config: Config,
    allocator: Allocator,

    pub fn init(
        allocator: Allocator,
        _: usize,
        _: usize,
        _: usize,
        _: []const f64,
        _: []const f64,
        config: Config,
    ) !Self {
        return .{ .config = config, .allocator = allocator };
    }

    pub fn deinit(_: *Self) void {}

    pub fn addObservation(
        _: *Self,
        _: []const f64,
        _: []const f64,
        _: []const f64,
        _: bool,
    ) !void {}

    pub fn suggest(_: *Self, _: usize, _: [][]f64) !usize {
        @panic("PythonBackend.suggest not implemented");
    }

    pub fn best(_: *Self) ?struct { params: []const f64, objectives: []const f64 } {
        return null;
    }
};

// ============================================================================
// TRACE ACQUISITION
// ============================================================================

pub const TraceAcquisition = struct {
    pub fn fcv1(constraint_means: []const f64, constraint_stds: []const f64, alpha: f64) f64 {
        var max_val: f64 = -std.math.inf(f64);
        for (constraint_means, 0..) |mean, i| {
            const v = mean - alpha * constraint_stds[i];
            if (v > max_val) max_val = v;
        }
        return max_val;
    }

    pub fn fcv2(constraint_means: []const f64, constraint_stds: []const f64, alpha: f64) f64 {
        var min_val: f64 = std.math.inf(f64);
        for (constraint_means, 0..) |mean, i| {
            const v = @abs(mean - alpha * constraint_stds[i]);
            if (v < min_val) min_val = v;
        }
        return min_val;
    }

    pub fn lcb(mean: f64, std_dev: f64, beta: f64) f64 {
        return mean - beta * std_dev;
    }

    pub fn expectedImprovement(mean: f64, std_dev: f64, best_f: f64, xi: f64) f64 {
        if (std_dev < 1e-10) return 0.0;
        const z = (best_f - mean - xi) / std_dev;
        return (best_f - mean - xi) * normalCDF(z) + std_dev * normalPDF(z);
    }

    pub fn probabilityOfImprovement(mean: f64, std_dev: f64, best_f: f64, xi: f64) f64 {
        if (std_dev < 1e-10) return if (mean < best_f - xi) 1.0 else 0.0;
        return normalCDF((best_f - mean - xi) / std_dev);
    }

    fn normalCDF(x: f64) f64 {
        return 0.5 * (1.0 + std.math.erf(x / @sqrt(2.0)));
    }
    fn normalPDF(x: f64) f64 {
        return @exp(-0.5 * x * x) / @sqrt(2.0 * std.math.pi);
    }
};
