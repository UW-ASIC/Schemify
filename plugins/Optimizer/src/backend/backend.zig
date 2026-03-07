//! Backend interface for optimization algorithms.
//! Any backend (Bayesian, evolutionary, etc.) must satisfy this interface.

const std = @import("std");
const Allocator = std.mem.Allocator;
const circuit = @import("circuit_function.zig");

// ============================================================================
// BACKEND INTERFACE SPECIFICATION
// ============================================================================

/// Required types that any backend must define
pub const RequiredTypes = struct {
    /// Configuration for initializing the backend
    Config: type,

    /// A candidate point to evaluate
    Candidate: type,
};

/// Required functions that any backend must implement
pub fn BackendFunctions(comptime Self: type, comptime Obs: type) type {
    return struct {
        /// Initialize the backend with problem dimensions and config
        init: *const fn (
            allocator: Allocator,
            n_params: usize,
            n_objectives: usize,
            n_constraints: usize,
            bounds_min: []const f64,
            bounds_max: []const f64,
            config: Self.Config,
        ) anyerror!Self,

        /// Clean up resources
        deinit: *const fn (self: *Self) void,

        /// Add an observation to the model
        addObservation: *const fn (
            self: *Self,
            params: []const f64,
            objectives: []const f64,
            constraints: []const f64,
            valid: bool,
        ) anyerror!void,

        /// Suggest next candidate(s) to evaluate
        suggest: *const fn (
            self: *Self,
            n_candidates: usize,
            out_candidates: [][]f64,
        ) anyerror!usize,

        /// Get the best feasible observation so far
        best: *const fn (self: *Self) ?struct {
            params: []const f64,
            objectives: []const f64,
        },

        /// Get current model uncertainty at a point (optional)
        uncertainty: ?*const fn (self: *Self, params: []const f64) f64,
    };
}

// ============================================================================
// BAYESIAN BACKEND STRUCTURE
// ============================================================================

/// Configuration for Bayesian optimization backend
pub const BayesianConfig = struct {
    /// Number of initial random samples (Latin Hypercube)
    initial_samples: usize = 20,

    /// Acquisition function type
    acquisition: AcquisitionType = .expected_improvement,

    /// Exploration parameter (β for LCB, ξ for EI)
    exploration: f64 = 0.2,

    /// Use TRACE tiered acquisition for constraints
    use_trace: bool = true,

    /// TRACE α parameter (constraint exploration)
    trace_alpha: f64 = 0.2,

    /// Batch size for parallel suggestions
    batch_size: usize = 1,

    /// GP kernel type
    kernel: KernelType = .matern52,

    /// Normalize inputs to [0, 1]
    normalize_inputs: bool = true,

    /// Standardize outputs to zero mean, unit variance
    standardize_outputs: bool = true,
};

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

/// Bayesian optimization backend
/// This is the STRUCTURE - implementation requires GP library
pub const Bayesian = struct {
    const Self = @This();

    pub const Config = BayesianConfig;

    pub const Candidate = struct {
        parameters: []f64,
        acquisition_value: f64,
        predicted_mean: ?[]f64,
        predicted_std: ?[]f64,
    };

    // Problem dimensions
    n_params: usize,
    n_objectives: usize,
    n_constraints: usize,

    // Bounds
    bounds_min: []f64,
    bounds_max: []f64,

    // Configuration
    config: Config,

    // Observation storage (Structure of Arrays for cache efficiency)
    obs_params: std.ArrayList([]f64),
    obs_objectives: std.ArrayList([]f64),
    obs_constraints: std.ArrayList([]f64),
    obs_valid: std.ArrayList(bool),

    // State
    allocator: Allocator,
    iteration: usize,
    best_feasible_idx: ?usize,

    // GP models would be here (opaque pointers to Python/C library)
    // gp_objectives: []GPModel,
    // gp_constraints: []GPModel,

    pub fn init(
        allocator: Allocator,
        n_params: usize,
        n_objectives: usize,
        n_constraints: usize,
        bounds_min: []const f64,
        bounds_max: []const f64,
        config: Config,
    ) !Self {
        const mins = try allocator.dupe(f64, bounds_min);
        const maxs = try allocator.dupe(f64, bounds_max);

        return .{
            .n_params = n_params,
            .n_objectives = n_objectives,
            .n_constraints = n_constraints,
            .bounds_min = mins,
            .bounds_max = maxs,
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
        for (self.obs_params.items) |p| self.allocator.free(p);
        for (self.obs_objectives.items) |o| self.allocator.free(o);
        for (self.obs_constraints.items) |c| self.allocator.free(c);
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

        // Update best feasible
        if (valid) {
            const feasible = blk: {
                for (c) |cv| {
                    if (cv > 0) break :blk false;
                }
                break :blk true;
            };

            if (feasible) {
                const idx = self.obs_params.items.len - 1;
                if (self.best_feasible_idx) |best_idx| {
                    // Compare objectives (assuming single objective for simplicity)
                    if (o[0] < self.obs_objectives.items[best_idx][0]) {
                        self.best_feasible_idx = idx;
                    }
                } else {
                    self.best_feasible_idx = idx;
                }
            }
        }

        self.iteration += 1;

        // Refit GP models here
        // self.fitModels();
    }

    pub fn suggest(
        self: *Self,
        n_candidates: usize,
        out_candidates: [][]f64,
    ) !usize {
        // If not enough observations, return random samples (Latin Hypercube)
        if (self.iteration < self.config.initial_samples) {
            return self.latinHypercubeSamples(n_candidates, out_candidates);
        }

        // Otherwise, optimize acquisition function
        return self.optimizeAcquisition(n_candidates, out_candidates);
    }

    pub fn best(self: *Self) ?struct { params: []const f64, objectives: []const f64 } {
        if (self.best_feasible_idx) |idx| {
            return .{
                .params = self.obs_params.items[idx],
                .objectives = self.obs_objectives.items[idx],
            };
        }
        return null;
    }

    // ========================================================================
    // INTERNAL METHODS (stubs for actual implementation)
    // ========================================================================

    fn latinHypercubeSamples(self: *Self, n: usize, out: [][]f64) usize {
        // STUB: Generate Latin Hypercube samples
        // Use scipy.stats.qmc.LatinHypercube or implement in Zig
        _ = self;
        _ = n;
        _ = out;
        @panic("latinHypercubeSamples not implemented");
    }

    fn optimizeAcquisition(self: *Self, n: usize, out: [][]f64) !usize {
        // STUB: Optimize acquisition function
        // This is where TRACE logic goes
        //
        // 1. Generate candidate pool (random or grid)
        // 2. For each candidate:
        //    a. Predict μ(x), σ(x) for objectives and constraints
        //    b. Compute Level 1 acquisition (fcv1, fcv2) if using TRACE
        //    c. Compute Level 2 acquisition (LCB, PI, EI)
        // 3. Non-dominated sorting for tiered dominance
        // 4. Select top candidates
        _ = self;
        _ = n;
        _ = out;
        @panic("optimizeAcquisition not implemented - needs GP library");
    }

    fn fitModels(self: *Self) void {
        // STUB: Fit GP models to observations
        // This requires a GP library (GPyTorch, GPy, or custom)
        //
        // For each objective and constraint:
        // 1. Normalize inputs if configured
        // 2. Standardize outputs if configured
        // 3. Fit GP (optimize hyperparameters via marginal likelihood)
        _ = self;
        @panic("fitModels not implemented - needs GP library");
    }

    fn predictObjectives(self: *Self, x: []const f64) struct { mean: []f64, std: []f64 } {
        // STUB: GP prediction for objectives
        _ = self;
        _ = x;
        @panic("predictObjectives not implemented");
    }

    fn predictConstraints(self: *Self, x: []const f64) struct { mean: []f64, std: []f64 } {
        // STUB: GP prediction for constraints
        _ = self;
        _ = x;
        @panic("predictConstraints not implemented");
    }
};

// ============================================================================
// TRACE ACQUISITION (for reference)
// ============================================================================

/// TRACE acquisition function components
pub const TraceAcquisition = struct {
    /// Level 1: Feasibility acquisition
    /// fcv1(x) = max{μ_c1(x) - α·σ_c1(x), ..., μ_cC(x) - α·σ_cC(x)}
    pub fn fcv1(
        constraint_means: []const f64,
        constraint_stds: []const f64,
        alpha: f64,
    ) f64 {
        var max_val: f64 = -std.math.inf(f64);
        for (constraint_means, 0..) |mean, i| {
            const adjusted = mean - alpha * constraint_stds[i];
            if (adjusted > max_val) max_val = adjusted;
        }
        return max_val;
    }

    /// Level 1: Feasibility acquisition (boundary distance)
    /// fcv2(x) = min{|μ_c1(x) - α·σ_c1(x)|, ..., |μ_cC(x) - α·σ_cC(x)|}
    pub fn fcv2(
        constraint_means: []const f64,
        constraint_stds: []const f64,
        alpha: f64,
    ) f64 {
        var min_val: f64 = std.math.inf(f64);
        for (constraint_means, 0..) |mean, i| {
            const adjusted = @abs(mean - alpha * constraint_stds[i]);
            if (adjusted < min_val) min_val = adjusted;
        }
        return min_val;
    }

    /// Level 2: Lower Confidence Bound (for minimization)
    pub fn lcb(mean: f64, std_dev: f64, beta: f64) f64 {
        return mean - beta * std_dev;
    }

    /// Level 2: Expected Improvement (for minimization)
    pub fn expectedImprovement(mean: f64, std_dev: f64, best_f: f64, xi: f64) f64 {
        if (std_dev < 1e-10) return 0.0;
        const z = (best_f - mean - xi) / std_dev;
        const cdf = normalCDF(z);
        const pdf = normalPDF(z);
        return (best_f - mean - xi) * cdf + std_dev * pdf;
    }

    /// Level 2: Probability of Improvement
    pub fn probabilityOfImprovement(mean: f64, std_dev: f64, best_f: f64, xi: f64) f64 {
        if (std_dev < 1e-10) return if (mean < best_f - xi) 1.0 else 0.0;
        const z = (best_f - mean - xi) / std_dev;
        return normalCDF(z);
    }

    fn normalCDF(x: f64) f64 {
        return 0.5 * (1.0 + std.math.erf(x / @sqrt(2.0)));
    }

    fn normalPDF(x: f64) f64 {
        return @exp(-0.5 * x * x) / @sqrt(2.0 * std.math.pi);
    }
};

// ============================================================================
// PYTHON BACKEND WRAPPER (if using Python for GP)
// ============================================================================

/// Backend that delegates to Python process via IPC
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
    // process: std.process.Child,  // Python subprocess
    // stdin: std.fs.File.Writer,   // Send commands
    // stdout: std.fs.File.Reader,  // Receive responses

    pub fn init(
        allocator: Allocator,
        n_params: usize,
        n_objectives: usize,
        n_constraints: usize,
        bounds_min: []const f64,
        bounds_max: []const f64,
        config: Config,
    ) !Self {
        _ = n_params;
        _ = n_objectives;
        _ = n_constraints;
        _ = bounds_min;
        _ = bounds_max;
        // STUB: Start Python subprocess, send initialization message
        return .{ .config = config, .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        // STUB: Send quit message, wait for process to exit
        _ = self;
    }

    pub fn addObservation(
        self: *Self,
        params: []const f64,
        objectives: []const f64,
        constraints: []const f64,
        valid: bool,
    ) !void {
        _ = self;
        _ = params;
        _ = objectives;
        _ = constraints;
        _ = valid;
        // STUB: Send JSON message to Python
        // {"type": "observe", "params": [...], "objectives": [...], "constraints": [...]}
    }

    pub fn suggest(self: *Self, n_candidates: usize, out_candidates: [][]f64) !usize {
        _ = self;
        _ = n_candidates;
        _ = out_candidates;
        // STUB: Send suggest request, parse response
        // {"type": "suggest", "n": 1}
        // Response: {"candidates": [[...]]}
        @panic("PythonBackend.suggest not implemented");
    }

    pub fn best(self: *Self) ?struct { params: []const f64, objectives: []const f64 } {
        _ = self;
        // STUB: Query Python for best observation
        return null;
    }
};

// ============================================================================
// LIBRARY SUGGESTIONS FOR IMPLEMENTATION
// ============================================================================

// For Gaussian Process regression, consider:
//
// PYTHON (recommended for full-featured BO):
//   - BoTorch (https://botorch.org) - Meta's production library
//   - GPyTorch (https://gpytorch.ai) - Scalable GP inference
//   - GPy (https://sheffieldml.github.io/GPy/) - Sheffield ML group
//
// C/C++ (for embedding without Python):
//   - libgp (https://github.com/mblum/libgp) - Simple GP library
//   - limbo (https://github.com/resibots/limbo) - BO library in C++
//
// RUST (potential Zig FFI):
//   - friedrich (https://crates.io/crates/friedrich) - GP regression
//
// The key operations you need:
//   1. Cholesky decomposition (for GP posterior)
//   2. L-BFGS-B optimization (for hyperparameters and acquisition)
//   3. Latin Hypercube Sampling (for initialization)
//
// If implementing from scratch in Zig:
//   - Use LAPACK/OpenBLAS via C FFI for linear algebra
//   - Port scipy's L-BFGS-B or use NLopt via C FFI
