const std = @import("std");

// ── Device Types ─────────────────────────────────────────────────────────────

pub const MosfetKind = enum(u1) {
    nmos,
    pmos,

    pub fn isNmos(self: MosfetKind) bool {
        return self == .nmos;
    }

    /// Sign convention: NMOS positive Vgs, PMOS negative.
    pub fn vgsSign(self: MosfetKind) f64 {
        return if (self == .nmos) 1.0 else -1.0;
    }
};

/// A MOSFET with FIXED channel length L.
/// Design variable is gm/Id ratio; W is derived from lookup tables.
pub const Transistor = struct {
    /// Instance name in the netlist (e.g. "M1", "M_input").
    instance: [max_name_len]u8 = .{0} ** max_name_len,
    instance_len: u8 = 0,

    /// SPICE model name (e.g. "nmos_3p3", "pmos_3p3").
    model: [max_name_len]u8 = .{0} ** max_name_len,
    model_len: u8 = 0,

    kind: MosfetKind = .nmos,

    /// Fixed channel length in meters.
    L: f64 = 100e-9,

    /// Bounds for gm/Id sweep (V^-1).
    gmid_min: f64 = 3.0, // strong inversion
    gmid_max: f64 = 25.0, // weak inversion

    /// Number of fingers bounds.
    nf_min: u16 = 1,
    nf_max: u16 = 20,
    nf: u16 = 1,

    // ── Derived during optimization (not user-set) ───────────────────────────
    W: f64 = 0.0, // meters
    Vgs: f64 = 0.0, // volts
    Id: f64 = 0.0, // amps

    pub fn instanceSlice(self: *const Transistor) []const u8 {
        return self.instance[0..self.instance_len];
    }

    pub fn modelSlice(self: *const Transistor) []const u8 {
        return self.model[0..self.model_len];
    }

    pub fn setInstance(self: *Transistor, name: []const u8) void {
        const len: u8 = @intCast(@min(name.len, max_name_len));
        @memcpy(self.instance[0..len], name[0..len]);
        self.instance_len = len;
    }

    pub fn setModel(self: *Transistor, name: []const u8) void {
        const len: u8 = @intCast(@min(name.len, max_name_len));
        @memcpy(self.model[0..len], name[0..len]);
        self.model_len = len;
    }
};

/// A tunable resistor in the design.
pub const Resistor = struct {
    instance: [max_name_len]u8 = .{0} ** max_name_len,
    instance_len: u8 = 0,
    R_min: f64 = 100.0, // ohms
    R_max: f64 = 100e3,
    step: f64 = 0.0, // 0 = continuous
    R: f64 = 0.0, // current value

    pub fn instanceSlice(self: *const Resistor) []const u8 {
        return self.instance[0..self.instance_len];
    }

    pub fn setInstance(self: *Resistor, name: []const u8) void {
        const len: u8 = @intCast(@min(name.len, max_name_len));
        @memcpy(self.instance[0..len], name[0..len]);
        self.instance_len = len;
    }
};

/// Generic tunable parameter (bias current, voltage, etc.).
pub const Parameter = struct {
    name: [max_name_len]u8 = .{0} ** max_name_len,
    name_len: u8 = 0,
    instance: [max_name_len]u8 = .{0} ** max_name_len,
    instance_len: u8 = 0,
    min: f64 = 0.0,
    max: f64 = 1.0,
    step: f64 = 0.0,
    value: f64 = 0.0,
    enabled: bool = true,

    pub fn nameSlice(self: *const Parameter) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn instanceSlice(self: *const Parameter) []const u8 {
        return self.instance[0..self.instance_len];
    }

    pub fn setName(self: *Parameter, n: []const u8) void {
        const len: u8 = @intCast(@min(n.len, max_name_len));
        @memcpy(self.name[0..len], n[0..len]);
        self.name_len = len;
    }

    pub fn setInstance(self: *Parameter, n: []const u8) void {
        const len: u8 = @intCast(@min(n.len, max_name_len));
        @memcpy(self.instance[0..len], n[0..len]);
        self.instance_len = len;
    }
};

// ── Specification Types ──────────────────────────────────────────────────────

pub const SpecKind = enum(u3) {
    minimize,
    maximize,
    greater_equal,
    less_equal,
    equal,
    range,

    pub fn isObjective(self: SpecKind) bool {
        return self == .minimize or self == .maximize;
    }

    pub fn isConstraint(self: SpecKind) bool {
        return !self.isObjective();
    }
};

/// A performance specification (objective or constraint).
pub const Specification = struct {
    name: [max_name_len]u8 = .{0} ** max_name_len,
    name_len: u8 = 0,
    kind: SpecKind = .maximize,
    target: f64 = 0.0,
    target_upper: f64 = 0.0, // for .range
    tolerance: f64 = 1e-6, // for .equal
    weight: f64 = 1.0,

    pub fn nameSlice(self: *const Specification) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn setName(self: *Specification, n: []const u8) void {
        const len: u8 = @intCast(@min(n.len, max_name_len));
        @memcpy(self.name[0..len], n[0..len]);
        self.name_len = len;
    }

    /// Convert a measured value to a constraint value.
    /// Negative = satisfied, positive = violated.
    pub fn toConstraint(self: *const Specification, measured: f64) f64 {
        return switch (self.kind) {
            .greater_equal => self.target - measured,
            .less_equal => measured - self.target,
            .equal => @abs(measured - self.target) - self.tolerance,
            .range => blk: {
                const upper = if (self.target_upper > self.target)
                    self.target_upper
                else
                    self.target;
                if (measured < self.target) break :blk self.target - measured;
                if (measured > upper) break :blk measured - upper;
                break :blk -1.0; // satisfied
            },
            .minimize, .maximize => 0.0,
        };
    }
};

// ── Fixed-capacity list ──────────────────────────────────────────────────────

/// Inline fixed-capacity list (no heap allocation).
/// Replaces std.BoundedArray which was removed in Zig 0.15.
pub fn FixedList(comptime T: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();
        items: [capacity]T = undefined,
        len: usize = 0,

        pub fn append(self: *Self, item: T) void {
            std.debug.assert(self.len < capacity);
            self.items[self.len] = item;
            self.len += 1;
        }

        pub fn slice(self: *const Self) []const T {
            return self.items[0..self.len];
        }

        pub fn sliceMut(self: *Self) []T {
            return self.items[0..self.len];
        }

        pub fn get(self: *const Self, idx: usize) T {
            std.debug.assert(idx < self.len);
            return self.items[idx];
        }

        pub fn getPtr(self: *Self, idx: usize) *T {
            std.debug.assert(idx < self.len);
            return &self.items[idx];
        }
    };
}

// ── Optimization Problem ─────────────────────────────────────────────────────

/// Maximum number of design variables (transistors + resistors + parameters).
pub const max_design_vars = 64;

/// Maximum number of objectives + constraints.
pub const max_specs = 64;

/// Maximum length for instance/model/parameter names.
pub const max_name_len = 63;

/// Complete gm/Id optimization problem definition.
///
/// Design variables: gm/Id ratio per transistor + R per resistor + generic params.
/// Fixed: L per transistor (set by user, never optimized).
pub const Problem = struct {
    transistors: FixedList(Transistor, max_design_vars) = .{},
    resistors: FixedList(Resistor, max_design_vars) = .{},
    parameters: FixedList(Parameter, max_design_vars) = .{},
    specs: FixedList(Specification, max_specs) = .{},

    vdd: f64 = 1.8,
    max_iter: u32 = 50,
    initial_samples: u32 = 20,

    /// Count of continuous design variables.
    pub fn designVarCount(self: *const Problem) usize {
        var n: usize = self.transistors.len;
        n += self.resistors.len;
        for (self.parameters.slice()) |p| {
            if (p.enabled) n += 1;
        }
        return n;
    }

    /// Count of objectives (specs that are minimize/maximize).
    pub fn objectiveCount(self: *const Problem) usize {
        var n: usize = 0;
        for (self.specs.slice()) |s| {
            if (s.kind.isObjective()) n += 1;
        }
        return n;
    }

    /// Count of constraints.
    pub fn constraintCount(self: *const Problem) usize {
        var n: usize = 0;
        for (self.specs.slice()) |s| {
            if (s.kind.isConstraint()) n += 1;
        }
        return n;
    }

    /// Fill lower/upper bounds arrays for all continuous design variables.
    /// Returns number of variables written.
    pub fn getBounds(
        self: *const Problem,
        lb: *[max_design_vars]f64,
        ub: *[max_design_vars]f64,
    ) usize {
        var idx: usize = 0;
        for (self.transistors.slice()) |t| {
            lb[idx] = t.gmid_min;
            ub[idx] = t.gmid_max;
            idx += 1;
        }
        for (self.resistors.slice()) |r| {
            lb[idx] = r.R_min;
            ub[idx] = r.R_max;
            idx += 1;
        }
        for (self.parameters.slice()) |p| {
            if (p.enabled) {
                lb[idx] = p.min;
                ub[idx] = p.max;
                idx += 1;
            }
        }
        return idx;
    }

    /// Apply a design vector to the problem components.
    /// x ordering: [gmid_0..gmid_n, R_0..R_m, param_0..param_k]
    pub fn applyDesignVector(self: *Problem, x: []const f64) void {
        var idx: usize = 0;

        // Skip transistor gmid values (they are read directly in the sweep)
        idx += self.transistors.len;

        // Resistors
        for (self.resistors.sliceMut()) |*r| {
            if (idx < x.len) {
                r.R = if (r.step > 0)
                    @round(x[idx] / r.step) * r.step
                else
                    x[idx];
            }
            idx += 1;
        }

        // Parameters
        for (self.parameters.sliceMut()) |*p| {
            if (p.enabled) {
                if (idx < x.len) {
                    p.value = if (p.step > 0)
                        @round(x[idx] / p.step) * p.step
                    else
                        x[idx];
                }
                idx += 1;
            }
        }
    }
};

// ── Optimization Result ──────────────────────────────────────────────────────

/// Performance metrics for a single transistor at its optimal operating point.
pub const DeviceResult = struct {
    instance: [max_name_len]u8 = .{0} ** max_name_len,
    instance_len: u8 = 0,
    gmid: f64 = 0.0, // V^-1
    W: f64 = 0.0, // meters
    L: f64 = 0.0, // meters
    nf: u16 = 1,
    Vgs: f64 = 0.0, // volts
    Id: f64 = 0.0, // amps
    gm: f64 = 0.0, // siemens
    gds: f64 = 0.0, // siemens
    fT: f64 = 0.0, // hertz
    intrinsic_gain: f64 = 0.0, // gm/gds (dimensionless)
    noise_sid: f64 = 0.0, // A^2/Hz drain current noise spectral density

    pub fn instanceSlice(self: *const DeviceResult) []const u8 {
        return self.instance[0..self.instance_len];
    }
};

/// A single observation from one sweep iteration.
pub const Observation = struct {
    x: [max_design_vars]f64 = .{0.0} ** max_design_vars,
    objectives: [max_specs]f64 = .{0.0} ** max_specs,
    constraints: [max_specs]f64 = .{0.0} ** max_specs,
    n_vars: u32 = 0,
    n_objectives: u32 = 0,
    n_constraints: u32 = 0,
    iteration: u32 = 0,
    valid: bool = true,

    pub fn isFeasible(self: *const Observation) bool {
        if (!self.valid) return false;
        for (self.constraints[0..self.n_constraints]) |c| {
            if (c > 0.0) return false;
        }
        return true;
    }

    /// Sum of weighted objectives (for comparison; lower is better).
    pub fn objectiveSum(self: *const Observation) f64 {
        var s: f64 = 0.0;
        for (self.objectives[0..self.n_objectives]) |o| s += o;
        return s;
    }
};

/// Full optimization result.
pub const OptimizationResult = struct {
    devices: FixedList(DeviceResult, max_design_vars) = .{},
    best_x: [max_design_vars]f64 = .{0.0} ** max_design_vars,
    best_objectives: [max_specs]f64 = .{0.0} ** max_specs,
    n_vars: u32 = 0,
    n_objectives: u32 = 0,
    iterations: u32 = 0,
    feasible_count: u32 = 0,
    converged: bool = false,

    /// Total power estimate: sum(Id) * Vdd.
    pub fn totalPower(self: *const OptimizationResult, vdd: f64) f64 {
        var total_id: f64 = 0.0;
        for (self.devices.slice()) |d| {
            total_id += @abs(d.Id);
        }
        return total_id * vdd;
    }

    /// Total area estimate: sum(W * L * nf).
    pub fn totalArea(self: *const OptimizationResult) f64 {
        var area: f64 = 0.0;
        for (self.devices.slice()) |d| {
            area += d.W * d.L * @as(f64, @floatFromInt(d.nf));
        }
        return area;
    }
};

// ── Tests ────────────────────────────────────────────────────────────────────

test "SpecKind.isObjective" {
    try std.testing.expect(SpecKind.minimize.isObjective());
    try std.testing.expect(SpecKind.maximize.isObjective());
    try std.testing.expect(!SpecKind.greater_equal.isObjective());
    try std.testing.expect(!SpecKind.less_equal.isObjective());
    try std.testing.expect(!SpecKind.equal.isObjective());
    try std.testing.expect(!SpecKind.range.isObjective());
}

test "Specification.toConstraint" {
    var spec = Specification{ .kind = .greater_equal, .target = 40.0 };
    // 50 dB gain when we need >= 40 => -10 (satisfied)
    try std.testing.expectApproxEqAbs(-10.0, spec.toConstraint(50.0), 1e-9);
    // 30 dB gain when we need >= 40 => 10 (violated)
    try std.testing.expectApproxEqAbs(10.0, spec.toConstraint(30.0), 1e-9);

    spec.kind = .less_equal;
    spec.target = 1e-3;
    // Power 0.5mW <= 1mW => -0.5e-3 (satisfied)
    try std.testing.expectApproxEqAbs(-0.5e-3, spec.toConstraint(0.5e-3), 1e-12);

    spec.kind = .range;
    spec.target = 10.0;
    spec.target_upper = 20.0;
    try std.testing.expectApproxEqAbs(-1.0, spec.toConstraint(15.0), 1e-9); // in range
    try std.testing.expectApproxEqAbs(5.0, spec.toConstraint(5.0), 1e-9); // below
    try std.testing.expectApproxEqAbs(5.0, spec.toConstraint(25.0), 1e-9); // above
}

test "Problem.getBounds" {
    var prob = Problem{};
    var t = Transistor{};
    t.setInstance("M1");
    t.setModel("nmos_3p3");
    t.gmid_min = 5.0;
    t.gmid_max = 20.0;
    prob.transistors.append(t);

    var r = Resistor{};
    r.setInstance("R1");
    r.R_min = 1e3;
    r.R_max = 50e3;
    prob.resistors.append(r);

    var lb: [max_design_vars]f64 = undefined;
    var ub: [max_design_vars]f64 = undefined;
    const n = prob.getBounds(&lb, &ub);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectApproxEqAbs(5.0, lb[0], 1e-9);
    try std.testing.expectApproxEqAbs(20.0, ub[0], 1e-9);
    try std.testing.expectApproxEqAbs(1e3, lb[1], 1e-9);
    try std.testing.expectApproxEqAbs(50e3, ub[1], 1e-9);
}

test "Problem.applyDesignVector" {
    var prob = Problem{};
    var t = Transistor{};
    t.setInstance("M1");
    prob.transistors.append(t);

    var r = Resistor{};
    r.setInstance("R1");
    r.step = 100.0;
    prob.resistors.append(r);

    const x = [_]f64{ 15.0, 4750.0 };
    prob.applyDesignVector(&x);
    // R should be snapped to step: round(4750/100)*100 = 4800
    try std.testing.expectApproxEqAbs(4800.0, prob.resistors.get(0).R, 1e-9);
}
