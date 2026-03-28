//! Turns the circuit inputs into a mathematical function.
//! The mapping of circuit inputs is the function's parameters.
//! If multiple testbenches with target parameters are given, those are the functions that take in the circuit inputs.

const std = @import("std");
const Allocator = std.mem.Allocator;
const backend = @import("backend/backend.zig");

const SpecClass = enum { objective, constraint };

fn countSpecsByClass(specs: []const Specification, comptime class: SpecClass) usize {
    var count: usize = 0;
    for (specs) |s| {
        const matches = switch (class) {
            .objective => s.isObjective(),
            .constraint => s.isConstraint(),
        };
        if (matches) count += 1;
    }
    return count;
}

fn countProblemSpecs(testbenches: []const Testbench, comptime class: SpecClass) usize {
    var count: usize = 0;
    for (testbenches) |tb| {
        count += switch (class) {
            .objective => tb.objectiveCount(),
            .constraint => tb.constraintCount(),
        };
    }
    return count;
}

/// A single tunable parameter within a component
pub const Primitive = struct {
    /// Identifier used in netlist substitution (e.g., "W", "L", "nf")
    name: []const u8,

    /// Optimization bounds
    min: f64,
    max: f64,

    /// Current value (updated during optimization)
    value: f64,

    /// Unit for display/logging (e.g., "m", "Ω", "A")
    unit: []const u8,

    /// Discretization step (null = continuous)
    /// For transistor widths, often constrained to grid
    step: ?f64 = null,

    /// Is this primitive enabled for optimization?
    enabled: bool = true,

    pub fn normalize(self: *const Primitive, val: f64) f64 {
        return (val - self.min) / (self.max - self.min);
    }

    pub fn denormalize(self: *const Primitive, norm: f64) f64 {
        const val = self.min + norm * (self.max - self.min);
        if (self.step) |s| {
            return @round(val / s) * s;
        }
        return val;
    }
};

// ============================================================================
// COMPONENT (a circuit element with primitives)
// ============================================================================

/// A circuit component that contains tunable primitives
pub const Component = struct {
    /// Path to component definition file (schematic, subcircuit, etc.)
    path: []const u8,

    /// Instance name in the netlist (e.g., "M1", "R_load", "XOP1")
    instance: []const u8,

    /// The tunable primitives within this component
    primitives: []Primitive,

    /// Component type identifier (for grouping/matching)
    kind: []const u8,

    pub fn getPrimitive(self: *const Component, name: []const u8) ?*const Primitive {
        for (self.primitives) |*p| {
            if (std.mem.eql(u8, p.name, name)) return p;
        }
        return null;
    }

    pub fn enabledCount(self: *const Component) usize {
        var count: usize = 0;
        for (self.primitives) |p| {
            if (p.enabled) count += 1;
        }
        return count;
    }
};

// ============================================================================
// SPECIFICATION (what we're optimizing for)
// ============================================================================

pub const SpecKind = enum {
    minimize, // Objective: make as small as possible
    maximize, // Objective: make as large as possible
    greater_equal, // Constraint: value >= target
    less_equal, // Constraint: value <= target
    equal, // Constraint: value == target (within tolerance)
    range, // Constraint: min <= value <= max
};

/// A target specification (constraint or objective)
pub const Specification = struct {
    /// Name matching the testbench measurement output
    name: []const u8,

    /// What kind of specification this is
    kind: SpecKind,

    /// Target value (interpretation depends on kind)
    target: f64,

    /// For range constraints: the upper bound (target is lower)
    target_upper: ?f64 = null,

    /// Tolerance for equality constraints
    tolerance: f64 = 1e-6,

    /// Weight for multi-objective optimization
    weight: f64 = 1.0,

    /// Convert measured value to constraint value (negative = satisfied)
    pub fn toConstraint(self: *const Specification, measured: f64) f64 {
        return switch (self.kind) {
            .greater_equal => self.target - measured, // violated if measured < target
            .less_equal => measured - self.target, // violated if measured > target
            .equal => @abs(measured - self.target) - self.tolerance,
            .range => blk: {
                const upper = self.target_upper orelse self.target;
                if (measured < self.target) break :blk self.target - measured;
                if (measured > upper) break :blk measured - upper;
                break :blk -1.0; // satisfied, return negative
            },
            .minimize, .maximize => 0.0, // objectives, not constraints
        };
    }

    pub fn isConstraint(self: *const Specification) bool {
        return switch (self.kind) {
            .minimize, .maximize => false,
            else => true,
        };
    }

    pub fn isObjective(self: *const Specification) bool {
        return !self.isConstraint();
    }
};

// ============================================================================
// TESTBENCH (a function that evaluates parameters)
// ============================================================================

/// Simulator backend type
pub const SimulatorKind = enum {
    ngspice,
    xyce,
    custom,
};

/// A testbench that produces measurements from component parameters
pub const Testbench = struct {
    /// Path to testbench file (SPICE netlist, etc.)
    path: []const u8,

    /// Human-readable name
    name: []const u8,

    /// Which simulator to use
    simulator: SimulatorKind,

    /// Specifications this testbench measures
    specs: []Specification,

    /// Additional simulator arguments
    sim_args: ?[]const []const u8 = null,

    /// Timeout in milliseconds
    timeout_ms: u64 = 60_000,

    /// Fidelity level (for multi-fidelity optimization)
    /// Higher = more accurate but slower
    fidelity: f64 = 1.0,

    pub fn objectiveCount(self: *const Testbench) usize {
        return countSpecsByClass(self.specs, .objective);
    }

    pub fn constraintCount(self: *const Testbench) usize {
        return countSpecsByClass(self.specs, .constraint);
    }
};

// ============================================================================
// OBSERVATION (result of evaluating testbenches)
// ============================================================================

/// Result of running all testbenches at a parameter point
pub const Observation = struct {
    /// Parameter values (normalized [0, 1])
    parameters: []f64,

    /// Objective values (one per objective across all testbenches)
    objectives: []f64,

    /// Constraint values (negative = satisfied)
    constraints: []f64,

    /// Raw measurements keyed by spec name
    measurements: std.StringHashMap(f64),

    /// Was simulation successful?
    valid: bool,

    /// Total simulation time
    elapsed_ns: u64,

    /// Which iteration this was
    iteration: usize,

    pub fn isFeasible(self: *const Observation) bool {
        if (!self.valid) return false;
        for (self.constraints) |c| {
            if (c > 0) return false;
        }
        return true;
    }
};

// ============================================================================
// PROBLEM DEFINITION (the complete optimization setup)
// ============================================================================

/// Complete problem definition: components + testbenches → optimization
pub const Problem = struct {
    /// All components with tunable primitives
    components: []Component,

    /// All testbenches to evaluate
    testbenches: []Testbench,

    /// Allocator for dynamic data
    allocator: Allocator,

    // Cached counts (computed once)
    _param_count: ?usize = null,
    _objective_count: ?usize = null,
    _constraint_count: ?usize = null,

    pub fn init(allocator: Allocator, components: []Component, testbenches: []Testbench) Problem {
        return .{
            .allocator = allocator,
            .components = components,
            .testbenches = testbenches,
        };
    }

    /// Total number of tunable parameters (enabled primitives across all components)
    pub fn parameterCount(self: *Problem) usize {
        if (self._param_count) |c| return c;
        var count: usize = 0;
        for (self.components) |comp| {
            count += comp.enabledCount();
        }
        self._param_count = count;
        return count;
    }

    /// Total number of objectives across all testbenches
    pub fn objectiveCount(self: *Problem) usize {
        if (self._objective_count) |c| return c;
        const count = countProblemSpecs(self.testbenches, .objective);
        self._objective_count = count;
        return count;
    }

    /// Total number of constraints across all testbenches
    pub fn constraintCount(self: *Problem) usize {
        if (self._constraint_count) |c| return c;
        const count = countProblemSpecs(self.testbenches, .constraint);
        self._constraint_count = count;
        return count;
    }

    /// Get bounds as [2][n] array: [0] = mins, [1] = maxs
    pub fn getBounds(self: *Problem) struct { min: []f64, max: []f64 } {
        const n = self.parameterCount();
        const mins = self.allocator.alloc(f64, n) catch unreachable;
        const maxs = self.allocator.alloc(f64, n) catch unreachable;

        var idx: usize = 0;
        for (self.components) |comp| {
            for (comp.primitives) |prim| {
                if (prim.enabled) {
                    mins[idx] = prim.min;
                    maxs[idx] = prim.max;
                    idx += 1;
                }
            }
        }
        return .{ .min = mins, .max = maxs };
    }

    /// Map flat parameter vector back to component primitives
    pub fn applyParameters(self: *Problem, params: []const f64) void {
        var idx: usize = 0;
        for (self.components) |*comp| {
            for (comp.primitives) |*prim| {
                if (prim.enabled) {
                    prim.value = prim.denormalize(params[idx]);
                    idx += 1;
                }
            }
        }
    }

    /// Extract current primitive values to flat parameter vector (normalized)
    pub fn extractParameters(self: *Problem, out: []f64) void {
        var idx: usize = 0;
        for (self.components) |comp| {
            for (comp.primitives) |prim| {
                if (prim.enabled) {
                    out[idx] = prim.normalize(prim.value);
                    idx += 1;
                }
            }
        }
    }
};

// ============================================================================
// CIRCUIT OPTIMIZER (main orchestrator)
// ============================================================================

pub fn CircuitOptimizer(comptime Backend: type) type {
    comptime backend.validateBackend(Backend);

    return struct {
        const Self = @This();

        problem: *Problem,
        be: Backend,
        observations: std.MultiArrayList(Observation),
        allocator: Allocator,
        iteration: usize,

        pub fn init(allocator: Allocator, problem: *Problem, backend_config: Backend.Config) !Self {
            return .{
                .problem = problem,
                .be = try Backend.init(allocator, backend_config),
                .observations = .{},
                .allocator = allocator,
                .iteration = 0,
            };
        }

        pub fn deinit(self: *Self) void {
            self.be.deinit();
            self.observations.deinit(self.allocator);
        }

        /// Run one optimization iteration
        pub fn step(self: *Self) !Observation {
            var candidates: [1][]f64 = undefined;
            _ = try self.be.suggest(1, &candidates);

            self.problem.applyParameters(candidates[0]);

            const obs = try self.evaluate(candidates[0]);
            try self.be.addObservation(obs.parameters, obs.objectives, obs.constraints, obs.valid);
            try self.observations.append(self.allocator, obs);

            self.iteration += 1;
            return obs;
        }

        fn evaluate(_: *Self, _: []const f64) !Observation {
            @panic("evaluate() not implemented — implement testbench runner");
        }

        pub fn best(self: *Self) ?struct { params: []const f64, objectives: []const f64 } {
            return self.be.best();
        }
    };
}

// ============================================================================
// STUB: Testbench Runner Interface
// ============================================================================

/// Interface for testbench execution (to be implemented)
pub const TestbenchRunner = struct {
    /// Run a testbench with given component values
    /// Returns map of measurement name → value
    pub fn run(
        testbench: *const Testbench,
        components: []const Component,
    ) !std.StringHashMap(f64) {
        _ = testbench;
        _ = components;
        // STUB: Implement for your simulator
        // 1. Generate netlist from testbench + component values
        // 2. Run simulator
        // 3. Parse output
        // 4. Return measurements
        @panic("TestbenchRunner.run() not implemented");
    }
};

// ============================================================================
// STUB: Circuit Initializer Interface
// ============================================================================

/// Interface for loading circuit definitions (to be implemented)
pub const CircuitLoader = struct {
    /// Load components from paths
    pub fn loadComponents(
        allocator: Allocator,
        paths: []const []const u8,
    ) ![]Component {
        _ = allocator;
        _ = paths;
        // STUB: Implement for your format
        // 1. Parse schematic/netlist files
        // 2. Extract component instances
        // 3. Identify tunable primitives
        // 4. Return Component array
        @panic("CircuitLoader.loadComponents() not implemented");
    }

    /// Load testbenches from paths
    pub fn loadTestbenches(
        allocator: Allocator,
        paths: []const []const u8,
    ) ![]Testbench {
        _ = allocator;
        _ = paths;
        // STUB: Implement for your format
        // 1. Parse testbench files
        // 2. Extract measurement definitions
        // 3. Map to Specification structs
        // 4. Return Testbench array
        @panic("CircuitLoader.loadTestbenches() not implemented");
    }
};

// ============================================================================
// EXAMPLE USAGE
// ============================================================================

pub fn example() !void {
    const allocator = std.heap.page_allocator;

    // Define components manually (or load via CircuitLoader)
    var m1_primitives = [_]Primitive{
        .{ .name = "W", .min = 120e-9, .max = 10e-6, .value = 1e-6, .unit = "m", .step = 10e-9 },
        .{ .name = "L", .min = 60e-9, .max = 1e-6, .value = 100e-9, .unit = "m", .step = 10e-9 },
        .{ .name = "nf", .min = 1, .max = 20, .value = 1, .unit = "", .step = 1 },
    };

    var m2_primitives = [_]Primitive{
        .{ .name = "W", .min = 120e-9, .max = 10e-6, .value = 1e-6, .unit = "m", .step = 10e-9 },
        .{ .name = "L", .min = 60e-9, .max = 1e-6, .value = 100e-9, .unit = "m", .step = 10e-9 },
    };

    var r_load_primitives = [_]Primitive{
        .{ .name = "R", .min = 100, .max = 100e3, .value = 10e3, .unit = "Ω" },
    };

    var components = [_]Component{
        .{ .path = "lib/nmos.scs", .instance = "M1", .primitives = &m1_primitives, .kind = "nmos" },
        .{ .path = "lib/pmos.scs", .instance = "M2", .primitives = &m2_primitives, .kind = "pmos" },
        .{ .path = "lib/res.scs", .instance = "R_load", .primitives = &r_load_primitives, .kind = "resistor" },
    };

    // Define testbenches with specifications
    var ac_specs = [_]Specification{
        .{ .name = "gain_dB", .kind = .maximize, .target = 0, .weight = 1.0 },
        .{ .name = "phase_margin", .kind = .greater_equal, .target = 60.0 },
        .{ .name = "ugb_Hz", .kind = .greater_equal, .target = 100e6 },
    };

    var dc_specs = [_]Specification{
        .{ .name = "power_W", .kind = .less_equal, .target = 1e-3 },
        .{ .name = "vout_dc", .kind = .range, .target = 0.4, .target_upper = 0.6 },
    };

    var area_specs = [_]Specification{
        .{ .name = "area_um2", .kind = .minimize, .target = 0, .weight = 0.5 },
    };

    var testbenches = [_]Testbench{
        .{ .path = "tb/ac_response.sp", .name = "AC Analysis", .simulator = .ngspice, .specs = &ac_specs },
        .{ .path = "tb/dc_operating.sp", .name = "DC Operating Point", .simulator = .ngspice, .specs = &dc_specs },
        .{ .path = "tb/area_calc.sp", .name = "Area Calculation", .simulator = .ngspice, .specs = &area_specs, .fidelity = 0.1 },
    };

    // Create problem
    var problem = Problem.init(allocator, &components, &testbenches);

    // Print problem summary
    std.debug.print("Parameters: {}\n", .{problem.parameterCount()});
    std.debug.print("Objectives: {}\n", .{problem.objectiveCount()});
    std.debug.print("Constraints: {}\n", .{problem.constraintCount()});

    // The mathematical view:
    // x ∈ ℝ^6 (M1.W, M1.L, M1.nf, M2.W, M2.L, R_load.R)
    // f(x) = [gain_dB(x), area_um2(x)]  ← 2 objectives (from testbenches 1 & 3)
    // c(x) = [60 - PM(x), 100e6 - UGB(x), power(x) - 1e-3, ...]  ← constraints
}
