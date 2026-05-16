const std = @import("std");

// ── Device Types ─────────────────────────────────────────────────────────────

pub const DeviceType = enum(u2) {
    mosfet,
    bjt,
    resistor,
    parameter,
};

pub const MosfetKind = enum(u1) {
    nmos,
    pmos,

    pub fn isNmos(self: MosfetKind) bool {
        return self == .nmos;
    }

    pub fn vgsSign(self: MosfetKind) f64 {
        return if (self == .nmos) 1.0 else -1.0;
    }
};

pub const Mosfet = struct {
    instance: [max_name_len]u8 = .{0} ** max_name_len,
    instance_len: u8 = 0,

    model: [max_name_len]u8 = .{0} ** max_name_len,
    model_len: u8 = 0,

    kind: MosfetKind = .nmos,

    L: f64 = 100e-9,

    gmid_min: f64 = 3.0,
    gmid_max: f64 = 25.0,

    nf_min: u16 = 1,
    nf_max: u16 = 20,
    nf: u16 = 1,

    match_group: u8 = 0,

    // ── Derived during optimization (not user-set) ───────────────────────────
    W: f64 = 0.0,
    Vgs: f64 = 0.0,
    Id: f64 = 0.0,

    pub fn instanceSlice(self: *const Mosfet) []const u8 {
        return self.instance[0..self.instance_len];
    }

    pub fn modelSlice(self: *const Mosfet) []const u8 {
        return self.model[0..self.model_len];
    }

    pub fn setInstance(self: *Mosfet, name: []const u8) void {
        const len: u8 = @intCast(@min(name.len, max_name_len));
        @memcpy(self.instance[0..len], name[0..len]);
        self.instance_len = len;
    }

    pub fn setModel(self: *Mosfet, name: []const u8) void {
        const len: u8 = @intCast(@min(name.len, max_name_len));
        @memcpy(self.model[0..len], name[0..len]);
        self.model_len = len;
    }
};

pub const BjtKind = enum(u1) {
    npn,
    pnp,
};

pub const Bjt = struct {
    instance: [max_name_len]u8 = .{0} ** max_name_len,
    instance_len: u8 = 0,

    model: [max_name_len]u8 = .{0} ** max_name_len,
    model_len: u8 = 0,

    kind: BjtKind = .npn,

    gmic_min: f64 = 1.0,
    gmic_max: f64 = 50.0,

    emitter_area_min: f64 = 1.0,
    emitter_area_max: f64 = 100.0,

    match_group: u8 = 0,

    // ── Derived during optimization ──────────────────────────────────────────
    emitter_area: f64 = 0.0,
    gmic: f64 = 0.0,
    Vbe: f64 = 0.0,
    Ic: f64 = 0.0,
    beta: f64 = 0.0,

    pub fn instanceSlice(self: *const Bjt) []const u8 {
        return self.instance[0..self.instance_len];
    }

    pub fn modelSlice(self: *const Bjt) []const u8 {
        return self.model[0..self.model_len];
    }

    pub fn setInstance(self: *Bjt, name: []const u8) void {
        const len: u8 = @intCast(@min(name.len, max_name_len));
        @memcpy(self.instance[0..len], name[0..len]);
        self.instance_len = len;
    }

    pub fn setModel(self: *Bjt, name: []const u8) void {
        const len: u8 = @intCast(@min(name.len, max_name_len));
        @memcpy(self.model[0..len], name[0..len]);
        self.model_len = len;
    }
};

pub const Resistor = struct {
    instance: [max_name_len]u8 = .{0} ** max_name_len,
    instance_len: u8 = 0,

    w_min: f64 = 0.5e-6,
    w_max: f64 = 50e-6,
    l_min: f64 = 0.5e-6,
    l_max: f64 = 100e-6,

    w: f64 = 0.0,
    l: f64 = 0.0,

    pub fn instanceSlice(self: *const Resistor) []const u8 {
        return self.instance[0..self.instance_len];
    }

    pub fn setInstance(self: *Resistor, name: []const u8) void {
        const len: u8 = @intCast(@min(name.len, max_name_len));
        @memcpy(self.instance[0..len], name[0..len]);
        self.instance_len = len;
    }
};

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

// ── Match Groups ─────────────────────────────────────────────────────────────

pub const MatchGroup = struct {
    id: u8,
    primary_idx: u16,
    device_type: DeviceType,
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

pub const Specification = struct {
    name: [max_name_len]u8 = .{0} ** max_name_len,
    name_len: u8 = 0,
    measurement_name: [max_name_len]u8 = .{0} ** max_name_len,
    measurement_name_len: u8 = 0,
    kind: SpecKind = .maximize,
    target: f64 = 0.0,
    target_upper: f64 = 0.0,
    tolerance: f64 = 1e-6,
    weight: f64 = 1.0,

    pub fn nameSlice(self: *const Specification) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn setName(self: *Specification, n: []const u8) void {
        const len: u8 = @intCast(@min(n.len, max_name_len));
        @memcpy(self.name[0..len], n[0..len]);
        self.name_len = len;
    }

    pub fn measurementSlice(self: *const Specification) []const u8 {
        if (self.measurement_name_len > 0) return self.measurement_name[0..self.measurement_name_len];
        return self.nameSlice();
    }

    pub fn setMeasurementName(self: *Specification, n: []const u8) void {
        const len: u8 = @intCast(@min(n.len, max_name_len));
        @memcpy(self.measurement_name[0..len], n[0..len]);
        self.measurement_name_len = len;
    }

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
                break :blk -1.0;
            },
            .minimize, .maximize => 0.0,
        };
    }
};

// ── Fixed-capacity list ──────────────────────────────────────────────────────

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

// ── Constants ────────────────────────────────────────────────────────────────

pub const max_design_vars = 64;
pub const max_specs = 64;
pub const max_name_len = 63;
pub const max_population = 200;

// ── NSGA-II Types ────────────────────────────────────────────────────────────

pub const StopCondition = enum(u2) {
    max_generations,
    user_cancelled,
    all_specs_satisfied,
};

pub const Individual = struct {
    x: [max_design_vars]f64 = .{0.0} ** max_design_vars,
    objectives: [max_specs]f64 = .{0.0} ** max_specs,
    constraints: [max_specs]f64 = .{0.0} ** max_specs,
    rank: u16 = 0,
    crowding_distance: f64 = 0,
    feasible: bool = false,
    n_vars: u32 = 0,
    n_objectives: u32 = 0,
    n_constraints: u32 = 0,
    valid: bool = true,

    /// True if self dominates other: self <= other on all objectives AND
    /// self < other on at least one.
    pub fn dominates(self: *const Individual, other: *const Individual) bool {
        const n = self.n_objectives;
        var dominated_any = false;
        for (self.objectives[0..n], other.objectives[0..n]) |s, o| {
            if (s > o) return false;
            if (s < o) dominated_any = true;
        }
        return dominated_any;
    }

    pub fn isFeasible(self: *const Individual) bool {
        if (!self.valid) return false;
        for (self.constraints[0..self.n_constraints]) |c| {
            if (c > 0.0) return false;
        }
        return true;
    }
};

pub const ParetoFront = struct {
    individuals: [max_population]Individual = undefined,
    len: u32 = 0,

    pub fn topN(self: *const ParetoFront, n: u32) []const Individual {
        const count = @min(n, self.len);
        return self.individuals[0..count];
    }

    pub fn sortByRank(self: *ParetoFront) void {
        std.mem.sort(Individual, self.individuals[0..self.len], {}, struct {
            fn lessThan(_: void, a: Individual, b: Individual) bool {
                if (a.rank != b.rank) return a.rank < b.rank;
                return a.crowding_distance > b.crowding_distance;
            }
        }.lessThan);
    }
};

pub const NsgaResult = struct {
    front: ParetoFront = .{},
    generations: u32 = 0,
    feasible_ratio: f64 = 0,
    best_feasible_idx: ?u32 = null,
    stop_reason: StopCondition = .max_generations,
};

// ── Optimization Problem ─────────────────────────────────────────────────────

pub const Problem = struct {
    mosfets: FixedList(Mosfet, max_design_vars) = .{},
    bjts: FixedList(Bjt, 64) = .{},
    resistors: FixedList(Resistor, max_design_vars) = .{},
    parameters: FixedList(Parameter, max_design_vars) = .{},
    specs: FixedList(Specification, max_specs) = .{},
    match_groups: FixedList(MatchGroup, 16) = .{},

    vdd: f64 = 1.8,
    max_iter: u32 = 50,
    initial_samples: u32 = 20,

    /// Count of continuous design variables.
    /// Grouped devices share one variable; resistors contribute 2 (W and L).
    pub fn designVarCount(self: *const Problem) usize {
        var n: usize = 0;

        // Mosfets: 1 per unique match_group, 1 per ungrouped device
        n += countGroupedVars(Mosfet, self.mosfets.slice(), self.match_groups.slice(), .mosfet);

        // BJTs: 1 per unique match_group, 1 per ungrouped device
        n += countGroupedVars(Bjt, self.bjts.slice(), self.match_groups.slice(), .bjt);

        // Resistors: 2 per device (W and L)
        n += self.resistors.len * 2;

        // Parameters: 1 per enabled parameter
        for (self.parameters.slice()) |p| {
            if (p.enabled) n += 1;
        }
        return n;
    }

    pub fn objectiveCount(self: *const Problem) usize {
        var n: usize = 0;
        for (self.specs.slice()) |s| {
            if (s.kind.isObjective()) n += 1;
        }
        return n;
    }

    pub fn constraintCount(self: *const Problem) usize {
        var n: usize = 0;
        for (self.specs.slice()) |s| {
            if (s.kind.isConstraint()) n += 1;
        }
        return n;
    }

    /// Fill lower/upper bounds arrays for all continuous design variables.
    /// Ordering: [mosfet gmid (grouped), bjt gmic (grouped), resistor W/L pairs, parameters].
    /// Returns number of variables written.
    pub fn getBounds(
        self: *const Problem,
        lb: *[max_design_vars]f64,
        ub: *[max_design_vars]f64,
    ) usize {
        var idx: usize = 0;

        // Mosfets (grouped)
        idx = emitGroupedBounds(
            Mosfet,
            self.mosfets.slice(),
            self.match_groups.slice(),
            .mosfet,
            lb,
            ub,
            idx,
            struct {
                fn bounds(m: Mosfet) [2]f64 {
                    return .{ m.gmid_min, m.gmid_max };
                }
            }.bounds,
        );

        // BJTs (grouped)
        idx = emitGroupedBounds(
            Bjt,
            self.bjts.slice(),
            self.match_groups.slice(),
            .bjt,
            lb,
            ub,
            idx,
            struct {
                fn bounds(b: Bjt) [2]f64 {
                    return .{ b.gmic_min, b.gmic_max };
                }
            }.bounds,
        );

        // Resistors: W then L per device
        for (self.resistors.slice()) |r| {
            lb[idx] = r.w_min;
            ub[idx] = r.w_max;
            idx += 1;
            lb[idx] = r.l_min;
            ub[idx] = r.l_max;
            idx += 1;
        }

        // Parameters
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
    /// x ordering: [mosfet gmid (grouped), bjt gmic (grouped), resistor W/L pairs, parameters].
    pub fn applyDesignVector(self: *Problem, x: []const f64) void {
        var idx: usize = 0;

        // Mosfets — skip grouped vars (read directly by sweep)
        idx += countGroupedVars(Mosfet, self.mosfets.slice(), self.match_groups.slice(), .mosfet);

        // BJTs — skip grouped vars (read directly by sweep)
        idx += countGroupedVars(Bjt, self.bjts.slice(), self.match_groups.slice(), .bjt);

        // Resistors: W then L
        for (self.resistors.sliceMut()) |*r| {
            if (idx < x.len) r.w = x[idx];
            idx += 1;
            if (idx < x.len) r.l = x[idx];
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

// ── Grouping helpers (file-scoped) ───────────────────────────────────────────

fn countGroupedVars(
    comptime T: type,
    devices: []const T,
    groups: []const MatchGroup,
    device_type: DeviceType,
) usize {
    var n: usize = 0;
    var seen_groups: [256]bool = .{false} ** 256;
    for (devices, 0..) |d, i| {
        if (d.match_group != 0) {
            if (isPrimary(groups, device_type, d.match_group, @intCast(i))) {
                if (!seen_groups[d.match_group]) {
                    seen_groups[d.match_group] = true;
                    n += 1;
                }
            }
        } else {
            n += 1;
        }
    }
    return n;
}

fn emitGroupedBounds(
    comptime T: type,
    devices: []const T,
    groups: []const MatchGroup,
    device_type: DeviceType,
    lb: *[max_design_vars]f64,
    ub: *[max_design_vars]f64,
    start_idx: usize,
    comptime boundsOf: fn (T) [2]f64,
) usize {
    var idx = start_idx;
    var seen_groups: [256]bool = .{false} ** 256;
    for (devices, 0..) |d, i| {
        if (d.match_group != 0) {
            if (isPrimary(groups, device_type, d.match_group, @intCast(i))) {
                if (!seen_groups[d.match_group]) {
                    seen_groups[d.match_group] = true;
                    const b = boundsOf(d);
                    lb[idx] = b[0];
                    ub[idx] = b[1];
                    idx += 1;
                }
            }
        } else {
            const b = boundsOf(d);
            lb[idx] = b[0];
            ub[idx] = b[1];
            idx += 1;
        }
    }
    return idx;
}

fn isPrimary(groups: []const MatchGroup, device_type: DeviceType, group_id: u8, device_idx: u16) bool {
    for (groups) |g| {
        if (g.id == group_id and g.device_type == device_type) {
            return g.primary_idx == device_idx;
        }
    }
    // No explicit group entry — treat first device encountered as primary.
    return true;
}

// ── Optimization Result ──────────────────────────────────────────────────────

pub const DeviceResult = struct {
    instance: [max_name_len]u8 = .{0} ** max_name_len,
    instance_len: u8 = 0,
    device_type: DeviceType = .mosfet,

    // MOSFET fields
    gmid: f64 = 0.0,
    W: f64 = 0.0,
    L: f64 = 0.0,
    nf: u16 = 1,
    Vgs: f64 = 0.0,
    Id: f64 = 0.0,
    gm: f64 = 0.0,
    gds: f64 = 0.0,
    fT: f64 = 0.0,
    intrinsic_gain: f64 = 0.0,
    noise_sid: f64 = 0.0,

    // BJT fields
    emitter_area: f64 = 0.0,
    gmic: f64 = 0.0,
    Vbe: f64 = 0.0,
    Ic: f64 = 0.0,
    beta: f64 = 0.0,

    pub fn instanceSlice(self: *const DeviceResult) []const u8 {
        return self.instance[0..self.instance_len];
    }
};

pub const DiscoveredMeasurement = struct {
    name: [max_name_len]u8 = .{0} ** max_name_len,
    name_len: u8 = 0,
    unit: [16]u8 = .{0} ** 16,
    unit_len: u8 = 0,

    pub fn nameSlice(self: *const DiscoveredMeasurement) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn unitSlice(self: *const DiscoveredMeasurement) []const u8 {
        return self.unit[0..self.unit_len];
    }
};

// ── Linked Testbench Types ───────────────────────────────────────────────────

pub const LinkedTestbench = struct {
    path: [max_path_len]u8 = .{0} ** max_path_len,
    path_len: u16 = 0,
    index: u32 = 0,

    pub fn pathSlice(self: *const LinkedTestbench) []const u8 {
        return self.path[0..self.path_len];
    }
};

const max_path_len = 512;

pub const max_linked_testbenches = 16;

pub const TbMeasurement = struct {
    name: [max_name_len]u8 = .{0} ** max_name_len,
    name_len: u8 = 0,
    value: f64 = 0.0,
    unit: [16]u8 = .{0} ** 16,
    unit_len: u8 = 0,
    valid: bool = false,

    pub fn nameSlice(self: *const TbMeasurement) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn unitSlice(self: *const TbMeasurement) []const u8 {
        return self.unit[0..self.unit_len];
    }

    pub const Measurement = struct {
        name: []const u8 = &.{},
        value: f64 = 0.0,
        unit: []const u8 = &.{},
        valid: bool = false,
    };

    pub fn toMeasurement(self: *const TbMeasurement) Measurement {
        return .{
            .name = self.nameSlice(),
            .value = self.value,
            .unit = self.unitSlice(),
            .valid = self.valid,
        };
    }

    pub fn fromMeasurement(m: anytype) TbMeasurement {
        var tb = TbMeasurement{ .value = m.value, .valid = m.valid };
        const nlen: u8 = @intCast(@min(m.name.len, max_name_len));
        @memcpy(tb.name[0..nlen], m.name[0..nlen]);
        tb.name_len = nlen;
        const ulen: u8 = @intCast(@min(m.unit.len, 16));
        @memcpy(tb.unit[0..ulen], m.unit[0..ulen]);
        tb.unit_len = ulen;
        return tb;
    }
};

pub const max_measurements = 64;

pub const TbRunResult = struct {
    measurements: [max_measurements]TbMeasurement = undefined,
    n_measurements: u32 = 0,
    success: bool = false,

    pub fn findMeasurement(self: *const TbRunResult, name: []const u8) ?f64 {
        for (self.measurements[0..self.n_measurements]) |m| {
            if (m.valid and std.ascii.eqlIgnoreCase(m.nameSlice(), name)) {
                return m.value;
            }
        }
        return null;
    }
};

pub fn getLinkedTestbenches(
    sym_props: anytype,
    out: *[max_linked_testbenches]LinkedTestbench,
) u32 {
    var count: u32 = 0;
    const prefix = "testbench.";
    for (sym_props) |p| {
        if (!std.mem.startsWith(u8, p.key, prefix)) continue;
        const idx_str = p.key[prefix.len..];
        const idx = std.fmt.parseInt(u32, idx_str, 10) catch continue;
        if (count >= max_linked_testbenches) break;
        var tb = LinkedTestbench{ .index = idx };
        const plen: u16 = @intCast(@min(p.val.len, max_path_len));
        @memcpy(tb.path[0..plen], p.val[0..plen]);
        tb.path_len = plen;
        out[count] = tb;
        count += 1;
    }
    return count;
}

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
    try std.testing.expectApproxEqAbs(-10.0, spec.toConstraint(50.0), 1e-9);
    try std.testing.expectApproxEqAbs(10.0, spec.toConstraint(30.0), 1e-9);

    spec.kind = .less_equal;
    spec.target = 1e-3;
    try std.testing.expectApproxEqAbs(-0.5e-3, spec.toConstraint(0.5e-3), 1e-12);

    spec.kind = .range;
    spec.target = 10.0;
    spec.target_upper = 20.0;
    try std.testing.expectApproxEqAbs(-1.0, spec.toConstraint(15.0), 1e-9);
    try std.testing.expectApproxEqAbs(5.0, spec.toConstraint(5.0), 1e-9);
    try std.testing.expectApproxEqAbs(5.0, spec.toConstraint(25.0), 1e-9);
}

test "Problem.getBounds: mosfet + resistor W/L" {
    var prob = Problem{};
    var m = Mosfet{};
    m.setInstance("M1");
    m.setModel("nmos_3p3");
    m.gmid_min = 5.0;
    m.gmid_max = 20.0;
    prob.mosfets.append(m);

    var r = Resistor{};
    r.setInstance("R1");
    r.w_min = 1e-6;
    r.w_max = 10e-6;
    r.l_min = 2e-6;
    r.l_max = 50e-6;
    prob.resistors.append(r);

    var lb: [max_design_vars]f64 = undefined;
    var ub: [max_design_vars]f64 = undefined;
    const n = prob.getBounds(&lb, &ub);
    try std.testing.expectEqual(@as(usize, 3), n); // 1 mosfet + 2 (W,L)
    try std.testing.expectApproxEqAbs(5.0, lb[0], 1e-9);
    try std.testing.expectApproxEqAbs(20.0, ub[0], 1e-9);
    try std.testing.expectApproxEqAbs(1e-6, lb[1], 1e-15);
    try std.testing.expectApproxEqAbs(10e-6, ub[1], 1e-15);
    try std.testing.expectApproxEqAbs(2e-6, lb[2], 1e-15);
    try std.testing.expectApproxEqAbs(50e-6, ub[2], 1e-15);
}

test "Problem.applyDesignVector: resistor W/L" {
    var prob = Problem{};
    var m = Mosfet{};
    m.setInstance("M1");
    prob.mosfets.append(m);

    var r = Resistor{};
    r.setInstance("R1");
    prob.resistors.append(r);

    // x: [gmid, W, L]
    const x = [_]f64{ 15.0, 5e-6, 10e-6 };
    prob.applyDesignVector(&x);
    try std.testing.expectApproxEqAbs(5e-6, prob.resistors.get(0).w, 1e-15);
    try std.testing.expectApproxEqAbs(10e-6, prob.resistors.get(0).l, 1e-15);
}

test "designVarCount: with match groups" {
    var prob = Problem{};

    // Two mosfets in same match group (1 var), one ungrouped (1 var)
    var m0 = Mosfet{};
    m0.setInstance("M0");
    m0.match_group = 1;
    prob.mosfets.append(m0);

    var m1 = Mosfet{};
    m1.setInstance("M1");
    m1.match_group = 1;
    prob.mosfets.append(m1);

    var m2 = Mosfet{};
    m2.setInstance("M2");
    prob.mosfets.append(m2);

    prob.match_groups.append(.{ .id = 1, .primary_idx = 0, .device_type = .mosfet });

    // One resistor => 2 vars (W, L)
    var r = Resistor{};
    r.setInstance("R1");
    prob.resistors.append(r);

    // One enabled parameter => 1 var
    var p = Parameter{};
    p.setName("Ibias");
    p.enabled = true;
    prob.parameters.append(p);

    // Total: 1 (group) + 1 (ungrouped) + 2 (resistor) + 1 (param) = 5
    try std.testing.expectEqual(@as(usize, 5), prob.designVarCount());
}

test "getBounds: with match groups" {
    var prob = Problem{};

    var m0 = Mosfet{};
    m0.setInstance("M0");
    m0.match_group = 1;
    m0.gmid_min = 5.0;
    m0.gmid_max = 20.0;
    prob.mosfets.append(m0);

    var m1 = Mosfet{};
    m1.setInstance("M1");
    m1.match_group = 1;
    m1.gmid_min = 3.0;
    m1.gmid_max = 25.0;
    prob.mosfets.append(m1);

    prob.match_groups.append(.{ .id = 1, .primary_idx = 0, .device_type = .mosfet });

    var lb: [max_design_vars]f64 = undefined;
    var ub: [max_design_vars]f64 = undefined;
    const n = prob.getBounds(&lb, &ub);
    // Only 1 variable from the group (primary M0's bounds)
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectApproxEqAbs(5.0, lb[0], 1e-9);
    try std.testing.expectApproxEqAbs(20.0, ub[0], 1e-9);
}

test "Individual.dominates" {
    var a = Individual{ .n_objectives = 2 };
    a.objectives[0] = 1.0;
    a.objectives[1] = 2.0;

    var b = Individual{ .n_objectives = 2 };
    b.objectives[0] = 2.0;
    b.objectives[1] = 3.0;

    // a <= b on all, a < b on both => a dominates b
    try std.testing.expect(a.dominates(&b));
    try std.testing.expect(!b.dominates(&a));

    // Equal on all => no domination
    var c = Individual{ .n_objectives = 2 };
    c.objectives[0] = 1.0;
    c.objectives[1] = 2.0;
    try std.testing.expect(!a.dominates(&c));
    try std.testing.expect(!c.dominates(&a));

    // Mixed: a better on one, worse on another => no domination
    var d = Individual{ .n_objectives = 2 };
    d.objectives[0] = 0.5;
    d.objectives[1] = 3.0;
    try std.testing.expect(!a.dominates(&d));
    try std.testing.expect(!d.dominates(&a));
}

test "Individual.isFeasible" {
    var ind = Individual{ .n_constraints = 2, .valid = true };
    ind.constraints[0] = -1.0;
    ind.constraints[1] = -0.5;
    try std.testing.expect(ind.isFeasible());

    // One violated constraint
    ind.constraints[1] = 0.1;
    try std.testing.expect(!ind.isFeasible());

    // Invalid individual
    ind.constraints[1] = -0.5;
    ind.valid = false;
    try std.testing.expect(!ind.isFeasible());

    // Zero constraints, valid => feasible
    var ind2 = Individual{ .n_constraints = 0, .valid = true };
    try std.testing.expect(ind2.isFeasible());
}

test "getLinkedTestbenches: extracts testbench props" {
    const PropPair = struct { key: []const u8, val: []const u8 };
    const props = [_]PropPair{
        .{ .key = "type", .val = "subcircuit" },
        .{ .key = "testbench.0", .val = "/home/user/tb_ac.py" },
        .{ .key = "testbench.1", .val = "/home/user/tb_tran.py" },
        .{ .key = "description", .val = "5-T OTA" },
        .{ .key = "testbench.3", .val = "/home/user/tb_noise.py" },
    };

    var out: [max_linked_testbenches]LinkedTestbench = undefined;
    const count = getLinkedTestbenches(&props, &out);
    try std.testing.expectEqual(@as(u32, 3), count);
    try std.testing.expectEqualStrings("/home/user/tb_ac.py", out[0].pathSlice());
    try std.testing.expectEqual(@as(u32, 0), out[0].index);
    try std.testing.expectEqualStrings("/home/user/tb_tran.py", out[1].pathSlice());
    try std.testing.expectEqual(@as(u32, 1), out[1].index);
    try std.testing.expectEqualStrings("/home/user/tb_noise.py", out[2].pathSlice());
    try std.testing.expectEqual(@as(u32, 3), out[2].index);
}

test "getLinkedTestbenches: empty when no testbench props" {
    const PropPair = struct { key: []const u8, val: []const u8 };
    const props = [_]PropPair{
        .{ .key = "type", .val = "subcircuit" },
        .{ .key = "format", .val = "@name @pinlist" },
    };

    var out: [max_linked_testbenches]LinkedTestbench = undefined;
    const count = getLinkedTestbenches(&props, &out);
    try std.testing.expectEqual(@as(u32, 0), count);
}

test "TbRunResult.findMeasurement" {
    var result = TbRunResult{};
    result.n_measurements = 2;
    result.measurements[0] = blk: {
        var m_ = TbMeasurement{ .value = 42.5, .valid = true };
        const name = "gain_db";
        @memcpy(m_.name[0..name.len], name);
        m_.name_len = name.len;
        break :blk m_;
    };
    result.measurements[1] = blk: {
        var m_ = TbMeasurement{ .value = 1.5e9, .valid = true };
        const name = "f_ugb";
        @memcpy(m_.name[0..name.len], name);
        m_.name_len = name.len;
        break :blk m_;
    };
    result.success = true;

    try std.testing.expectApproxEqAbs(42.5, result.findMeasurement("GAIN_DB").?, 1e-9);
    try std.testing.expectApproxEqAbs(1.5e9, result.findMeasurement("f_ugb").?, 1e-9);
    try std.testing.expect(result.findMeasurement("nonexistent") == null);
}

test "Specification.measurementSlice: falls back to name" {
    var spec = Specification{};
    spec.setName("gain");
    try std.testing.expectEqualStrings("gain", spec.measurementSlice());

    spec.setMeasurementName("A_dc");
    try std.testing.expectEqualStrings("A_dc", spec.measurementSlice());
}

test "TbMeasurement round-trip conversion" {
    const Meas = TbMeasurement.Measurement;
    const m_ = Meas{ .name = "gain_db", .value = 42.5, .unit = "dB", .valid = true };
    const tb = TbMeasurement.fromMeasurement(m_);
    try std.testing.expectEqualStrings("gain_db", tb.nameSlice());
    try std.testing.expectApproxEqAbs(42.5, tb.value, 1e-9);
    try std.testing.expectEqualStrings("dB", tb.unitSlice());
    try std.testing.expect(tb.valid);

    const back = tb.toMeasurement();
    try std.testing.expectEqualStrings("gain_db", back.name);
    try std.testing.expectApproxEqAbs(42.5, back.value, 1e-9);
    try std.testing.expectEqualStrings("dB", back.unit);
    try std.testing.expect(back.valid);
}

test "TbMeasurement.fromMeasurement: truncation" {
    const Meas = TbMeasurement.Measurement;
    const long_name = "a" ** 100;
    const long_unit = "X" ** 30;
    const m_ = Meas{ .name = long_name, .value = 1.0, .unit = long_unit, .valid = true };
    const tb = TbMeasurement.fromMeasurement(m_);
    try std.testing.expectEqual(@as(u8, max_name_len), tb.name_len);
    try std.testing.expectEqual(@as(u8, 16), tb.unit_len);
    try std.testing.expectEqualStrings("a" ** max_name_len, tb.nameSlice());
    try std.testing.expectEqualStrings("X" ** 16, tb.unitSlice());
}
