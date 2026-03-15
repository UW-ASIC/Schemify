//! Universal SPICE intermediate representation.
//!
//! Typed, data-oriented IR that is a superset of both ngspice and Xyce feature
//! sets. Each IR node carries backend support metadata and can be lowered
//! (transpiled) to either backend's netlist syntax.
//!
//! ```zig
//! var nl = Netlist.init(allocator);
//! defer nl.deinit();
//! try nl.addParam(.{ .name = "Rload", .value = .{ .literal = 10e3 } });
//! try nl.addComponent(.{ .resistor = .{ .name = "R1", .p = "out", .n = "0", .value = .{ .param = "Rload" } } });
//! try nl.addAnalysis(.{ .tran = .{ .step = 1e-6, .stop = 1e-3 } });
//! const text = try nl.emit(.ngspice, allocator);
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;

// ═══════════════════════════════════════════════════════════════════════════
// Backend / support metadata
// ═══════════════════════════════════════════════════════════════════════════

pub const Backend = enum { ngspice, xyce };

pub const Support = enum {
    native,
    emulated,
    unsupported,
};

pub const BackendSupport = struct {
    ngspice: Support,
    xyce: Support,
};

// ═══════════════════════════════════════════════════════════════════════════
// Comptime function-name translation
// ═══════════════════════════════════════════════════════════════════════════

const ExprFuncMap = struct {
    universal: []const u8,
    ngspice: []const u8,
    xyce: []const u8,
};

const expr_func_table = [_]ExprFuncMap{
    .{ .universal = "if",     .ngspice = "ternary_fcn", .xyce = "IF"     },
    .{ .universal = "step",   .ngspice = "u",           .xyce = "stp"    },
    .{ .universal = "min",    .ngspice = "min",          .xyce = "MIN"    },
    .{ .universal = "max",    .ngspice = "max",          .xyce = "MAX"    },
    .{ .universal = "abs",    .ngspice = "abs",          .xyce = "ABS"    },
    .{ .universal = "sqrt",   .ngspice = "sqrt",         .xyce = "SQRT"   },
    .{ .universal = "exp",    .ngspice = "exp",          .xyce = "EXP"    },
    .{ .universal = "ln",     .ngspice = "ln",           .xyce = "LOG"    },
    .{ .universal = "log10",  .ngspice = "log",          .xyce = "LOG10"  },
    .{ .universal = "sin",    .ngspice = "sin",          .xyce = "SIN"    },
    .{ .universal = "cos",    .ngspice = "cos",          .xyce = "COS"    },
    .{ .universal = "tan",    .ngspice = "tan",          .xyce = "TAN"    },
    .{ .universal = "atan",   .ngspice = "atan",         .xyce = "ATAN"   },
    .{ .universal = "atan2",  .ngspice = "atan2",        .xyce = "ATAN2"  },
    .{ .universal = "pow",    .ngspice = "pwr",          .xyce = "PWR"    },
    .{ .universal = "limit",  .ngspice = "limit",        .xyce = "LIMIT"  },
    .{ .universal = "table",  .ngspice = "table",        .xyce = "TABLE"  },
    .{ .universal = "ddt",    .ngspice = "ddt",          .xyce = "DDT"    },
    .{ .universal = "sdt",    .ngspice = "idt",          .xyce = "SDT"    },
    .{ .universal = "agauss", .ngspice = "agauss",       .xyce = "AGAUSS" },
    .{ .universal = "gauss",  .ngspice = "gauss",        .xyce = "GAUSS"  },
    .{ .universal = "aunif",  .ngspice = "aunif",        .xyce = "AUNIF"  },
    .{ .universal = "unif",   .ngspice = "unif",         .xyce = "UNIF"   },
};

/// Comptime lookup: universal function name → backend-specific name.
pub fn translateFunc(comptime name: []const u8, comptime backend: Backend) []const u8 {
    for (expr_func_table) |entry| {
        if (std.mem.eql(u8, entry.universal, name)) {
            return switch (backend) {
                .ngspice => entry.ngspice,
                .xyce => entry.xyce,
            };
        }
    }
    return name;
}

// ═══════════════════════════════════════════════════════════════════════════
// Value types
// ═══════════════════════════════════════════════════════════════════════════

pub const Value = union(enum) {
    literal: f64,
    param: []const u8,
    expr: []const u8, // universal syntax; TODO: run rewrite pass per backend

    pub fn emit(self: Value, writer: anytype) !void {
        switch (self) {
            .literal => |v| try writer.print("{e}", .{v}),
            .param => |name| try writer.print("{{{s}}}", .{name}),
            .expr => |e| try writer.writeAll(e),
        }
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// Source waveform types
// ═══════════════════════════════════════════════════════════════════════════

pub const SrcDC = struct { dc: f64 = 0 };
pub const SrcAC = struct { mag: f64 = 1, phase: f64 = 0 };

pub const SrcSin = struct {
    offset: f64 = 0,
    amplitude: f64,
    freq: f64,
    delay: f64 = 0,
    damping: f64 = 0,
    phase: f64 = 0,
};

pub const SrcPulse = struct {
    v1: f64,
    v2: f64,
    delay: f64 = 0,
    rise: f64 = 0,
    fall: f64 = 0,
    width: f64,
    period: f64,
};

pub const SrcPWL = struct {
    points: []const [2]f64,
};

pub const SrcSFFM = struct {
    offset: f64 = 0,
    amplitude: f64,
    carrier_freq: f64,
    mod_index: f64 = 0,
    signal_freq: f64 = 0,
};

pub const SrcEXP = struct {
    v1: f64,
    v2: f64,
    td1: f64 = 0,
    tau1: f64,
    td2: f64 = 0,
    tau2: f64,
};

/// Pattern source — Xyce native, ngspice emulated via PWL.
pub const SrcPAT = struct {
    vhi: f64,
    vlo: f64 = 0,
    delay: f64 = 0,
    rise: f64 = 0,
    fall: f64 = 0,
    bit_period: f64,
    pattern: []const u8,

    pub const support = BackendSupport{ .ngspice = .emulated, .xyce = .native };
};

pub const SourceWaveform = union(enum) {
    dc: SrcDC,
    ac: SrcAC,
    sin: SrcSin,
    pulse: SrcPulse,
    pwl: SrcPWL,
    sffm: SrcSFFM,
    exp: SrcEXP,
    pat: SrcPAT,
};

pub const IndependentSource = struct {
    name: []const u8,
    kind: enum { voltage, current },
    p: []const u8,
    n: []const u8,
    dc: ?f64 = null,
    ac_mag: ?f64 = null,
    ac_phase: ?f64 = null,
    waveform: ?SourceWaveform = null,
    /// Emit `.save i(<name>)` after the source line (XSchem ammeter convention).
    save_current: bool = false,
};

// ═══════════════════════════════════════════════════════════════════════════
// Passive / active component types
// ═══════════════════════════════════════════════════════════════════════════

pub const Resistor  = struct { name: []const u8, p: []const u8, n: []const u8, value: Value, m: ?[]const u8 = null };
pub const Capacitor = struct { name: []const u8, p: []const u8, n: []const u8, value: Value, ic: ?f64 = null, m: ?[]const u8 = null };
pub const Inductor  = struct { name: []const u8, p: []const u8, n: []const u8, value: Value, ic: ?f64 = null, m: ?[]const u8 = null };

pub const Diode = struct {
    name: []const u8,
    anode: []const u8,
    cathode: []const u8,
    model: []const u8,
};

pub const Mosfet = struct {
    name: []const u8,
    drain: []const u8,
    gate: []const u8,
    source: []const u8,
    bulk: []const u8,
    model: []const u8,
    w: ?Value = null,
    l: ?Value = null,
    m: ?f64 = null,
};

pub const Bjt = struct {
    name: []const u8,
    collector: []const u8,
    base: []const u8,
    emitter: []const u8,
    substrate: ?[]const u8 = null,
    model: []const u8,
};

pub const ParamOverride = struct {
    name: []const u8,
    value: Value,
};

pub const Subcircuit = struct {
    name: []const u8,
    inst_name: []const u8,
    nodes: []const []const u8,
    params: []const ParamOverride,
};

/// Behavioral B-source. Expression in universal syntax.
pub const BehavioralSource = struct {
    name: []const u8,
    kind: enum { voltage, current },
    p: []const u8,
    n: []const u8,
    expr: []const u8,
};

pub const Component = union(enum) {
    resistor: Resistor,
    capacitor: Capacitor,
    inductor: Inductor,
    diode: Diode,
    mosfet: Mosfet,
    bjt: Bjt,
    subcircuit: Subcircuit,
    behavioral: BehavioralSource,
    independent_source: IndependentSource,
    raw: []const u8,
};

// ═══════════════════════════════════════════════════════════════════════════
// Analysis types
// ═══════════════════════════════════════════════════════════════════════════

pub const SweepKind = enum { lin, dec, oct };

pub const AnalysisOP = struct {
    pub const support = BackendSupport{ .ngspice = .native, .xyce = .native };
};

pub const AnalysisDC = struct {
    src1: []const u8,
    start1: f64,
    stop1: f64,
    step1: f64,
    src2: ?[]const u8 = null,
    start2: ?f64 = null,
    stop2: ?f64 = null,
    step2: ?f64 = null,

    pub const support = BackendSupport{ .ngspice = .native, .xyce = .native };
};

pub const AnalysisAC = struct {
    sweep: SweepKind = .dec,
    n_points: u32,
    f_start: f64,
    f_stop: f64,

    pub const support = BackendSupport{ .ngspice = .native, .xyce = .native };
};

pub const AnalysisTran = struct {
    step: f64,
    stop: f64,
    start: f64 = 0,
    max_step: ?f64 = null,
    uic: bool = false,

    pub const support = BackendSupport{ .ngspice = .native, .xyce = .native };
};

pub const AnalysisNoise = struct {
    output_node: []const u8,
    output_ref: ?[]const u8 = null,
    input_src: []const u8,
    sweep: SweepKind = .dec,
    n_points: u32,
    f_start: f64,
    f_stop: f64,
    points_per_summary: ?u32 = null,

    pub const support = BackendSupport{ .ngspice = .native, .xyce = .native };
};

pub const AnalysisSens = struct {
    output_var: []const u8,
    mode: enum { dc, ac, tran, tran_adjoint } = .dc,
    ac_sweep: ?SweepKind = null,
    ac_n_points: ?u32 = null,
    ac_f_start: ?f64 = null,
    ac_f_stop: ?f64 = null,

    pub const support = BackendSupport{ .ngspice = .emulated, .xyce = .native };
};

pub const AnalysisTF = struct {
    output_var: []const u8,
    input_src: []const u8,

    pub const support = BackendSupport{ .ngspice = .native, .xyce = .native };
};

pub const AnalysisPZ = struct {
    in_pos: []const u8,
    in_neg: []const u8,
    out_pos: []const u8,
    out_neg: []const u8,
    tf_type: enum { vol, cur },
    pz_type: enum { pol, zer, pz },

    pub const support = BackendSupport{ .ngspice = .native, .xyce = .unsupported };
};

pub const AnalysisDisto = struct {
    sweep: SweepKind = .dec,
    n_points: u32,
    f_start: f64,
    f_stop: f64,
    f2_over_f1: ?f64 = null,

    pub const support = BackendSupport{ .ngspice = .native, .xyce = .unsupported };
};

pub const AnalysisPSS = struct {
    gfreq: f64,
    tstab: f64,
    fft_points: u32 = 1024,
    harms: u32 = 10,
    sciter: u32 = 150,
    steadycoeff: f64 = 1e-3,

    pub const support = BackendSupport{ .ngspice = .native, .xyce = .unsupported };
};

pub const AnalysisSP = struct {
    sweep: SweepKind = .dec,
    n_points: u32,
    f_start: f64,
    f_stop: f64,

    pub const support = BackendSupport{ .ngspice = .native, .xyce = .native };
};

pub const AnalysisHB = struct {
    freqs: []const f64,
    n_harmonics: u32 = 7,
    startup: bool = false,
    startup_periods: ?u32 = null,

    pub const support = BackendSupport{ .ngspice = .unsupported, .xyce = .native };
};

pub const AnalysisMPDE = struct {
    fast_freqs: []const f64,
    oscsrc: ?[]const u8 = null,

    pub const support = BackendSupport{ .ngspice = .unsupported, .xyce = .native };
};

pub const AnalysisFour = struct {
    freq: f64,
    nodes: []const []const u8,

    pub const support = BackendSupport{ .ngspice = .native, .xyce = .native };
};

pub const Analysis = union(enum) {
    op: AnalysisOP,
    dc: AnalysisDC,
    ac: AnalysisAC,
    tran: AnalysisTran,
    noise: AnalysisNoise,
    sens: AnalysisSens,
    tf: AnalysisTF,
    pz: AnalysisPZ,
    disto: AnalysisDisto,
    pss: AnalysisPSS,
    sp: AnalysisSP,
    hb: AnalysisHB,
    mpde: AnalysisMPDE,
    four: AnalysisFour,

    /// Return backend support metadata by dispatching over the active tag.
    /// Uses comptime inline-for so adding a new variant only requires updating
    /// the union — no second switch to keep in sync.
    pub fn getSupport(self: Analysis) BackendSupport {
        const tag = std.meta.activeTag(self);
        inline for (std.meta.fields(Analysis)) |f| {
            if (@field(std.meta.Tag(Analysis), f.name) == tag) {
                return f.type.support;
            }
        }
        unreachable;
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// Sweep / UQ types
// ═══════════════════════════════════════════════════════════════════════════

pub const StepSweep = struct {
    param: []const u8,
    kind: union(enum) {
        lin: struct { start: f64, stop: f64, step: f64 },
        dec: struct { start: f64, stop: f64, points: u32 },
        oct: struct { start: f64, stop: f64, points: u32 },
        list: struct { values: []const f64 },
    },

    pub const support = BackendSupport{ .ngspice = .emulated, .xyce = .native };
};

pub const Distribution = union(enum) {
    normal: struct { mean: f64, std_dev: f64 },
    uniform: struct { lo: f64, hi: f64 },
    lognormal: struct { mean: f64, std_dev: f64 },
};

pub const SamplingParam = struct {
    name: []const u8,
    dist: Distribution,
};

pub const Sampling = struct {
    num_samples: u32 = 100,
    method: enum { mc, lhs } = .mc,
    params: []const SamplingParam,

    pub const support = BackendSupport{ .ngspice = .emulated, .xyce = .native };
};

pub const EmbeddedSampling = struct {
    num_samples: u32 = 100,
    params: []const SamplingParam,

    pub const support = BackendSupport{ .ngspice = .unsupported, .xyce = .native };
};

pub const PCE = struct {
    order: u32 = 3,
    method: enum { regression, nisp, intrusive } = .regression,
    sample_count: ?u32 = null,
    params: []const SamplingParam,

    pub const support = BackendSupport{ .ngspice = .unsupported, .xyce = .native };
};

pub const DataTable = struct {
    name: []const u8,
    param_names: []const []const u8,
    rows: []const []const f64,

    pub const support = BackendSupport{ .ngspice = .emulated, .xyce = .native };
};

pub const Sweep = union(enum) {
    step: StepSweep,
    sampling: Sampling,
    embedded_sampling: EmbeddedSampling,
    pce: PCE,
    data: DataTable,
};

// ═══════════════════════════════════════════════════════════════════════════
// Measure
// ═══════════════════════════════════════════════════════════════════════════

pub const MeasureMode = enum { tran, ac, dc, noise };

pub const MeasureTrig = struct {
    trig_var: []const u8,
    trig_val: f64,
    targ_var: []const u8,
    targ_val: f64,
    rise: ?u32 = null,
    fall: ?u32 = null,
    cross: ?u32 = null,
};

pub const MeasureFind = struct {
    var_name: []const u8,
    at: f64,
};

pub const MeasureMinMax = struct {
    var_name: []const u8,
    kind: enum { min, max, pp, avg, rms, integ },
    from: ?f64 = null,
    to: ?f64 = null,
};

pub const MeasureWhen = struct {
    var_name: []const u8,
    val: f64,
    rise: ?u32 = null,
    fall: ?u32 = null,
    cross: ?u32 = null,
};

pub const Measure = struct {
    name: []const u8,
    mode: MeasureMode,
    kind: union(enum) {
        trig_targ: MeasureTrig,
        find: MeasureFind,
        min_max: MeasureMinMax,
        when: MeasureWhen,
    },

    pub const support = BackendSupport{ .ngspice = .native, .xyce = .native };
};

// ═══════════════════════════════════════════════════════════════════════════
// Model definition
// ═══════════════════════════════════════════════════════════════════════════

pub const ModelParam = struct {
    name: []const u8,
    value: Value,
};

pub const ModelDef = struct {
    name: []const u8,
    kind: []const u8,
    level: ?u32 = null,
    version: ?[]const u8 = null,
    params: []const ModelParam,
};

// ═══════════════════════════════════════════════════════════════════════════
// Param / Print / Save / Option / Include / Library
// ═══════════════════════════════════════════════════════════════════════════

pub const Param = struct {
    name: []const u8,
    value: Value,
    /// If true, emit as .global_param on Xyce so .STEP/.SAMPLING can modify it.
    global: bool = false,
};

pub const PrintDirective = struct {
    mode: MeasureMode,
    vars: []const []const u8,
    format: ?[]const u8 = null,
};

pub const SaveDirective = struct {
    vars: []const []const u8,
    all: bool = false,
};

pub const Option = struct {
    name: []const u8,
    value: ?Value = null,
};

pub const Include = struct {
    path: []const u8,
};

pub const Library = struct {
    path: []const u8,
    section: ?[]const u8 = null,
};

// ═══════════════════════════════════════════════════════════════════════════
// Netlist — top-level IR container
// ═══════════════════════════════════════════════════════════════════════════

pub const Netlist = struct {
    allocator: Allocator,
    title: []const u8 = "Universal SPICE netlist",

    params:               std.ArrayListUnmanaged(Param)          = .{},
    options:              std.ArrayListUnmanaged(Option)          = .{},
    includes:             std.ArrayListUnmanaged(Include)         = .{},
    libs:                 std.ArrayListUnmanaged(Library)         = .{},
    models:               std.ArrayListUnmanaged(ModelDef)        = .{},
    components:           std.ArrayListUnmanaged(Component)       = .{},
    analyses:             std.ArrayListUnmanaged(Analysis)        = .{},
    sweeps:               std.ArrayListUnmanaged(Sweep)           = .{},
    measures:             std.ArrayListUnmanaged(Measure)         = .{},
    prints:               std.ArrayListUnmanaged(PrintDirective)  = .{},
    saves:                std.ArrayListUnmanaged(SaveDirective)   = .{},
    raw_lines:            std.ArrayListUnmanaged([]const u8)      = .{},
    code_blocks:          std.ArrayListUnmanaged([]const u8)      = .{},
    toplevel_code_blocks: std.ArrayListUnmanaged([]const u8)      = .{},
    tcl_vars:             std.StringHashMapUnmanaged([]const u8)  = .{},

    pub fn init(allocator: Allocator) Netlist {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Netlist) void {
        const a = self.allocator;
        self.params.deinit(a);
        self.options.deinit(a);
        self.includes.deinit(a);
        self.libs.deinit(a);
        self.models.deinit(a);
        self.components.deinit(a);
        self.analyses.deinit(a);
        self.sweeps.deinit(a);
        self.measures.deinit(a);
        self.prints.deinit(a);
        self.saves.deinit(a);
        self.raw_lines.deinit(a);
        self.code_blocks.deinit(a);
        self.toplevel_code_blocks.deinit(a);
        self.tcl_vars.deinit(a);
    }

    // ───────────────────────────────────────────────────────────────────────
    // Builder API
    // ───────────────────────────────────────────────────────────────────────

    pub fn addParam(self: *Netlist, param: Param) !void {
        try self.params.append(self.allocator, param);
    }

    pub fn addOption(self: *Netlist, opt: Option) !void {
        try self.options.append(self.allocator, opt);
    }

    pub fn addInclude(self: *Netlist, inc: Include) !void {
        try self.includes.append(self.allocator, inc);
    }

    pub fn addLib(self: *Netlist, lib: Library) !void {
        try self.libs.append(self.allocator, lib);
    }

    pub fn addModel(self: *Netlist, model: ModelDef) !void {
        try self.models.append(self.allocator, model);
    }

    pub fn addComponent(self: *Netlist, comp: Component) !void {
        try self.components.append(self.allocator, comp);
    }

    /// Sources go into the unified components list to preserve insertion order.
    pub fn addSource(self: *Netlist, src: IndependentSource) !void {
        try self.components.append(self.allocator, .{ .independent_source = src });
    }

    pub fn addAnalysis(self: *Netlist, an: Analysis) !void {
        try self.analyses.append(self.allocator, an);
    }

    pub fn addSweep(self: *Netlist, sw: Sweep) !void {
        try self.sweeps.append(self.allocator, sw);
    }

    pub fn addMeasure(self: *Netlist, meas: Measure) !void {
        try self.measures.append(self.allocator, meas);
    }

    pub fn addPrint(self: *Netlist, p: PrintDirective) !void {
        try self.prints.append(self.allocator, p);
    }

    pub fn addSave(self: *Netlist, s: SaveDirective) !void {
        try self.saves.append(self.allocator, s);
    }

    pub fn addRaw(self: *Netlist, line: []const u8) !void {
        try self.raw_lines.append(self.allocator, line);
    }

    pub fn addCodeBlock(self: *Netlist, block: []const u8) !void {
        try self.code_blocks.append(self.allocator, block);
    }

    pub fn addToplevelCodeBlock(self: *Netlist, block: []const u8) !void {
        for (self.toplevel_code_blocks.items) |existing| {
            if (std.mem.eql(u8, existing, block)) return;
        }
        try self.toplevel_code_blocks.append(self.allocator, block);
    }

    // ───────────────────────────────────────────────────────────────────────
    // Validation
    // ───────────────────────────────────────────────────────────────────────

    pub const Diagnostic = struct {
        feature: []const u8,
        level: enum { warning, err },
        message: []const u8,
    };

    /// Validate the netlist for the target backend.
    ///
    /// Uses `Analysis.getSupport` (inline-for dispatch) rather than a manual
    /// switch, so new analysis variants are automatically covered.
    pub fn validate(self: *const Netlist, backend: Backend) !std.ArrayListUnmanaged(Diagnostic) {
        var diags = std.ArrayListUnmanaged(Diagnostic){};

        for (self.analyses.items) |an| {
            switch (pickSupport(backend, an.getSupport())) {
                .unsupported => try diags.append(self.allocator, .{
                    .feature = @tagName(an),
                    .level = .err,
                    .message = "Analysis not supported on target backend",
                }),
                .emulated => try diags.append(self.allocator, .{
                    .feature = @tagName(an),
                    .level = .warning,
                    .message = "Analysis will be emulated (may differ in fidelity)",
                }),
                .native => {},
            }
        }

        for (self.sweeps.items) |sw| {
            switch (pickSupport(backend, sweepSupport(sw))) {
                .unsupported => try diags.append(self.allocator, .{
                    .feature = @tagName(sw),
                    .level = .err,
                    .message = "Sweep/UQ type not supported on target backend",
                }),
                .emulated => try diags.append(self.allocator, .{
                    .feature = @tagName(sw),
                    .level = .warning,
                    .message = "Sweep/UQ will be emulated via control loops",
                }),
                .native => {},
            }
        }

        return diags;
    }

    // ───────────────────────────────────────────────────────────────────────
    // Emission
    // ───────────────────────────────────────────────────────────────────────

    pub const EmitError = error{
        UnsupportedFeature,
        OutOfMemory,
    } || std.fmt.BufPrintError || Allocator.Error;

    pub fn emit(self: *const Netlist, backend: Backend, allocator: Allocator) EmitError![]u8 {
        var buf = std.ArrayListUnmanaged(u8){};
        errdefer buf.deinit(allocator);
        const writer = buf.writer(allocator);
        try self.emitTo(writer, backend);
        return buf.toOwnedSlice(allocator);
    }

    pub fn emitTo(self: *const Netlist, writer: anytype, backend: Backend) !void {
        try writer.print("{s}\n", .{self.title});

        for (self.includes.items) |inc| {
            try writer.print(".include {s}\n", .{inc.path});
        }
        for (self.libs.items) |lib| {
            try writer.print(".lib {s}", .{lib.path});
            if (lib.section) |s| try writer.print(" {s}", .{s});
            try writer.writeByte('\n');
        }

        for (self.options.items) |opt| {
            try writer.print(".options {s}", .{opt.name});
            if (opt.value) |v| {
                try writer.writeAll("=");
                try v.emit(writer);
            }
            try writer.writeByte('\n');
        }

        for (self.params.items) |p| {
            if (p.global and backend == .xyce) {
                try writer.print(".global_param {s}=", .{p.name});
            } else {
                try writer.print(".param {s}=", .{p.name});
            }
            try p.value.emit(writer);
            try writer.writeByte('\n');
        }

        for (self.models.items) |m| {
            try writer.print(".model {s} {s}", .{ m.name, m.kind });
            if (m.level) |lvl| try writer.print(" level={d}", .{lvl});
            if (m.version) |ver| try writer.print(" version={s}", .{ver});
            if (m.params.len > 0) {
                try writer.writeAll(" (\n");
                for (m.params) |mp| {
                    try writer.print("+ {s}=", .{mp.name});
                    try mp.value.emit(writer);
                    try writer.writeByte('\n');
                }
                try writer.writeAll(")\n");
            } else {
                try writer.writeByte('\n');
            }
        }

        for (self.components.items) |comp| {
            try emitComponent(writer, comp, backend);
        }

        for (self.analyses.items) |an| {
            try emitAnalysis(writer, an, backend);
        }

        for (self.sweeps.items) |sw| {
            try emitSweep(writer, sw, backend);
        }

        for (self.measures.items) |meas| {
            try emitMeasure(writer, meas);
        }

        for (self.prints.items) |p| {
            try emitPrint(writer, p);
        }

        for (self.saves.items) |s| {
            try writer.writeAll(".save");
            if (s.all) {
                try writer.writeAll(" all");
            } else {
                for (s.vars) |v| try writer.print(" {s}", .{v});
            }
            try writer.writeByte('\n');
        }

        // .four is emitted after .tran
        for (self.analyses.items) |an| {
            if (an == .four) {
                try writer.print(".four {e}", .{an.four.freq});
                for (an.four.nodes) |node| try writer.print(" {s}", .{node});
                try writer.writeByte('\n');
            }
        }

        for (self.raw_lines.items) |line| {
            try writer.print("{s}\n", .{line});
        }

        for (self.code_blocks.items) |block| {
            try writer.writeAll("**** begin user architecture code\n");
            const trimmed = std.mem.trimRight(u8, block, "\n\r");
            try writer.print("{s}\n", .{trimmed});
            try writer.writeAll("**** end user architecture code\n");
        }

        if (backend == .ngspice) {
            try emitNgspiceControlSection(writer, self);
        }

        try writer.writeAll(".end\n");
    }

    pub fn emitToplevelCodeBlocks(self: *const Netlist, writer: anytype) !void {
        for (self.toplevel_code_blocks.items) |block| {
            const trimmed = std.mem.trimRight(u8, block, "\n\r");
            try writer.print("{s}\n", .{trimmed});
        }
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// Private helpers
// ═══════════════════════════════════════════════════════════════════════════

/// Select the `Support` value for a given backend from a `BackendSupport` pair.
/// Eliminates the repeated two-arm `switch (backend)` in validation loops.
inline fn pickSupport(backend: Backend, sup: BackendSupport) Support {
    return switch (backend) {
        .ngspice => sup.ngspice,
        .xyce => sup.xyce,
    };
}

/// SPICE keyword for a `MeasureMode` (shared by `.meas` and `.print` emission).
fn measureModeStr(mode: MeasureMode) []const u8 {
    return switch (mode) {
        .tran  => "TRAN",
        .ac    => "AC",
        .dc    => "DC",
        .noise => "NOISE",
    };
}

/// Return backend support for a `Sweep` variant.
/// Uses inline-for dispatch like `Analysis.getSupport` so adding a new Sweep
/// variant only requires declaring its `support` constant — no switch needed.
fn sweepSupport(sw: Sweep) BackendSupport {
    const tag = std.meta.activeTag(sw);
    inline for (std.meta.fields(Sweep)) |f| {
        if (@field(std.meta.Tag(Sweep), f.name) == tag) {
            return f.type.support;
        }
    }
    unreachable;
}

fn sweepStr(k: SweepKind) []const u8 {
    return switch (k) {
        .lin => "lin",
        .dec => "dec",
        .oct => "oct",
    };
}

fn emitComponent(writer: anytype, comp: Component, backend: Backend) !void {
    switch (comp) {
        .resistor => |r| {
            try writer.print("{s} {s} {s} ", .{ r.name, r.p, r.n });
            try r.value.emit(writer);
            if (r.m) |m| try writer.print(" m={s}", .{m});
            try writer.writeByte('\n');
        },
        .capacitor => |cap| {
            try writer.print("{s} {s} {s} ", .{ cap.name, cap.p, cap.n });
            try cap.value.emit(writer);
            if (cap.ic) |ic| try writer.print(" ic={e}", .{ic});
            if (cap.m) |m| try writer.print(" m={s}", .{m});
            try writer.writeByte('\n');
        },
        .inductor => |ind| {
            try writer.print("{s} {s} {s} ", .{ ind.name, ind.p, ind.n });
            try ind.value.emit(writer);
            if (ind.ic) |ic| try writer.print(" ic={e}", .{ic});
            if (ind.m) |m| try writer.print(" m={s}", .{m});
            try writer.writeByte('\n');
        },
        .diode => |d| {
            try writer.print("{s} {s} {s} {s}\n", .{ d.name, d.anode, d.cathode, d.model });
        },
        .mosfet => |m| {
            try writer.print("{s} {s} {s} {s} {s} {s}", .{
                m.name, m.drain, m.gate, m.source, m.bulk, m.model,
            });
            if (m.w) |w| { try writer.writeAll(" W="); try w.emit(writer); }
            if (m.l) |l| { try writer.writeAll(" L="); try l.emit(writer); }
            if (m.m) |mult| try writer.print(" M={d}", .{mult});
            try writer.writeByte('\n');
        },
        .bjt => |b| {
            try writer.print("{s} {s} {s} {s}", .{ b.name, b.collector, b.base, b.emitter });
            if (b.substrate) |sub| try writer.print(" {s}", .{sub});
            try writer.print(" {s}\n", .{b.model});
        },
        .subcircuit => |s| {
            try writer.print("{s}", .{s.inst_name});
            for (s.nodes) |node| try writer.print(" {s}", .{node});
            try writer.print(" {s}", .{s.name});
            for (s.params) |p| {
                try writer.print(" {s}=", .{p.name});
                try p.value.emit(writer);
            }
            try writer.writeByte('\n');
        },
        .behavioral => |b| {
            try writer.print("{s} {s} {s}", .{ b.name, b.p, b.n });
            switch (b.kind) {
                .voltage => try writer.print(" V={s}", .{b.expr}),
                .current => try writer.print(" I={s}", .{b.expr}),
            }
            try writer.writeByte('\n');
        },
        .independent_source => |src| {
            try writer.print("{s} {s} {s}", .{ src.name, src.p, src.n });
            if (src.ac_mag) |ac| {
                if (src.dc) |dc| try writer.print(" {d}", .{dc});
                try writer.print(" ac {d}", .{ac});
                if (src.ac_phase) |ph| try writer.print(" {d}", .{ph});
            } else if (src.dc) |dc| {
                if (dc == 0.0) try writer.writeAll(" 0") else try writer.print(" {d}", .{dc});
            }
            if (src.waveform) |wf| {
                switch (wf) {
                    .sin => |s| {
                        try writer.print(" SIN({e} {e} {e}", .{ s.offset, s.amplitude, s.freq });
                        if (s.delay != 0) try writer.print(" {e}", .{s.delay});
                        if (s.damping != 0) try writer.print(" {e}", .{s.damping});
                        if (s.phase != 0) try writer.print(" {e}", .{s.phase});
                        try writer.writeByte(')');
                    },
                    .pulse => |p| {
                        try writer.print(" PULSE({e} {e} {e} {e} {e} {e} {e})", .{
                            p.v1, p.v2, p.delay, p.rise, p.fall, p.width, p.period,
                        });
                    },
                    .pwl => |pwl| {
                        try writer.writeAll(" PWL(");
                        for (pwl.points, 0..) |pt, i| {
                            if (i > 0) try writer.writeByte(' ');
                            try writer.print("{e} {e}", .{ pt[0], pt[1] });
                        }
                        try writer.writeByte(')');
                    },
                    .exp => |e| {
                        try writer.print(" EXP({e} {e} {e} {e} {e} {e})", .{
                            e.v1, e.v2, e.td1, e.tau1, e.td2, e.tau2,
                        });
                    },
                    .sffm => |s| {
                        try writer.print(" SFFM({e} {e} {e} {e} {e})", .{
                            s.offset, s.amplitude, s.carrier_freq, s.mod_index, s.signal_freq,
                        });
                    },
                    .dc => |d| try writer.print(" dc {e}", .{d.dc}),
                    .ac => |a| try writer.print(" ac {e} {e}", .{ a.mag, a.phase }),
                    .pat => |p| {
                        // TODO: ngspice emulation → convert to PWL
                        try writer.print(" PAT({e} {e} {e} {e} {e} {e} b{s})", .{
                            p.vhi, p.vlo, p.delay, p.rise, p.fall, p.bit_period, p.pattern,
                        });
                    },
                }
            }
            try writer.writeByte('\n');
            if (src.save_current) {
                try writer.writeAll(".save i(");
                for (src.name) |c| try writer.writeByte(std.ascii.toLower(c));
                try writer.writeAll(")\n");
            }
        },
        .raw => |line| try writer.print("{s}\n", .{line}),
    }
    _ = backend; // backend reserved for future per-component dialect differences
}

fn emitAnalysis(writer: anytype, an: Analysis, backend: Backend) !void {
    switch (an) {
        .op => try writer.writeAll(".op\n"),
        .dc => |d| {
            try writer.print(".dc {s} {e} {e} {e}", .{ d.src1, d.start1, d.stop1, d.step1 });
            if (d.src2) |s2| {
                try writer.print(" {s} {e} {e} {e}", .{ s2, d.start2.?, d.stop2.?, d.step2.? });
            }
            try writer.writeByte('\n');
        },
        .ac => |a| {
            try writer.print(".ac {s} {d} {e} {e}\n", .{ sweepStr(a.sweep), a.n_points, a.f_start, a.f_stop });
        },
        .tran => |t| {
            try writer.print(".tran {e} {e}", .{ t.step, t.stop });
            if (t.start != 0) try writer.print(" {e}", .{t.start});
            if (t.max_step) |ms| try writer.print(" {e}", .{ms});
            if (t.uic) try writer.writeAll(" uic");
            try writer.writeByte('\n');
        },
        .noise => |n| {
            try writer.print(".noise V({s}", .{n.output_node});
            if (n.output_ref) |r| try writer.print(",{s}", .{r});
            try writer.print(") {s} {s} {d} {e} {e}", .{
                n.input_src, sweepStr(n.sweep), n.n_points, n.f_start, n.f_stop,
            });
            if (n.points_per_summary) |pts| try writer.print(" {d}", .{pts});
            try writer.writeByte('\n');
        },
        .sens => |s| switch (backend) {
            .ngspice => try writer.print(".sens {s}\n", .{s.output_var}),
            .xyce => switch (s.mode) {
                .dc => try writer.print(".sens objfunc={{{s}}}\n", .{s.output_var}),
                .ac => {
                    try writer.print(".sens acobjfunc={{{s}}}", .{s.output_var});
                    if (s.ac_sweep) |sw| {
                        try writer.print("\n.ac {s} {d} {e} {e}", .{
                            sweepStr(sw), s.ac_n_points.?, s.ac_f_start.?, s.ac_f_stop.?,
                        });
                    }
                    try writer.writeByte('\n');
                },
                .tran, .tran_adjoint => {
                    try writer.print(".sens objfunc={{{s}}}", .{s.output_var});
                    if (s.mode == .tran_adjoint) try writer.writeAll(" adjoint=1");
                    try writer.writeByte('\n');
                },
            },
        },
        .tf => |t| try writer.print(".tf {s} {s}\n", .{ t.output_var, t.input_src }),
        .pz => |p| switch (backend) {
            .ngspice => {
                const tf = switch (p.tf_type) { .vol => "vol", .cur => "cur" };
                const pzt = switch (p.pz_type) { .pol => "pol", .zer => "zer", .pz => "pz" };
                try writer.print(".pz {s} {s} {s} {s} {s} {s}\n", .{
                    p.in_pos, p.in_neg, p.out_pos, p.out_neg, tf, pzt,
                });
            },
            .xyce => {
                try writer.writeAll("* [UNSUPPORTED] .PZ not available in Xyce.\n");
                try writer.writeAll("* Workaround: use dense .AC sweep + external vector fitting.\n");
            },
        },
        .disto => |d| switch (backend) {
            .ngspice => {
                try writer.print(".disto {s} {d} {e} {e}", .{
                    sweepStr(d.sweep), d.n_points, d.f_start, d.f_stop,
                });
                if (d.f2_over_f1) |r| try writer.print(" {e}", .{r});
                try writer.writeByte('\n');
            },
            .xyce => {
                try writer.writeAll("* [UNSUPPORTED] .DISTO not available in Xyce.\n");
                try writer.writeAll("* Workaround: use .HB and extract harmonic magnitudes.\n");
            },
        },
        .pss => |p| switch (backend) {
            .ngspice => try writer.print(".pss {e} {e} {d} {d} {d} {e}\n", .{
                p.gfreq, p.tstab, p.fft_points, p.harms, p.sciter, p.steadycoeff,
            }),
            .xyce => {
                try writer.writeAll("* [EMULATED] .PSS lowered to .HB\n");
                try writer.print(".HB {e}\n", .{p.gfreq});
            },
        },
        .sp => |s| switch (backend) {
            .ngspice => try writer.print(".sp {s} {d} {e} {e}\n", .{
                sweepStr(s.sweep), s.n_points, s.f_start, s.f_stop,
            }),
            .xyce => {
                try writer.writeAll(".LIN sparcalc=1\n");
                try writer.print(".ac {s} {d} {e} {e}\n", .{
                    sweepStr(s.sweep), s.n_points, s.f_start, s.f_stop,
                });
            },
        },
        .hb => |h| switch (backend) {
            .xyce => {
                try writer.writeAll(".HB");
                for (h.freqs) |f| try writer.print(" {e}", .{f});
                try writer.writeByte('\n');
                try writer.print(".options HBINT numfreq={d}", .{h.n_harmonics});
                if (h.startup) {
                    try writer.writeAll(" startup=1");
                    if (h.startup_periods) |p| try writer.print(" startupperiods={d}", .{p});
                }
                try writer.writeByte('\n');
            },
            .ngspice => {
                try writer.writeAll("* [UNSUPPORTED] .HB not available in ngspice.\n");
                if (h.freqs.len == 1) {
                    try writer.writeAll("* Partial workaround: using .PSS (experimental)\n");
                    try writer.print(".pss {e} 0 1024 {d} 150 1e-3\n", .{ h.freqs[0], h.n_harmonics });
                }
            },
        },
        .mpde => switch (backend) {
            .xyce => try writer.writeAll("* TODO: emit .MPDE\n"),
            .ngspice => try writer.writeAll("* [UNSUPPORTED] .MPDE not available in ngspice.\n"),
        },
        .four => {}, // emitted separately after .tran
    }
}

fn emitSweep(writer: anytype, sw: Sweep, backend: Backend) !void {
    switch (sw) {
        .step => |s| switch (backend) {
            .xyce => {
                try writer.print(".STEP {s} ", .{s.param});
                switch (s.kind) {
                    .lin => |lin| try writer.print("{e} {e} {e}", .{ lin.start, lin.stop, lin.step }),
                    .dec => |d| try writer.print("DEC {d} {e} {e}", .{ d.points, d.start, d.stop }),
                    .oct => |o| try writer.print("OCT {d} {e} {e}", .{ o.points, o.start, o.stop }),
                    .list => |l| {
                        try writer.writeAll("LIST");
                        for (l.values) |v| try writer.print(" {e}", .{v});
                    },
                }
                try writer.writeByte('\n');
            },
            .ngspice => {}, // emitted inside .control section
        },
        .sampling => |s| switch (backend) {
            .xyce => {
                try writer.print(".SAMPLING\n+ numsamples={d}\n", .{s.num_samples});
                switch (s.method) {
                    .mc => try writer.writeAll("+ sample_type=mc\n"),
                    .lhs => try writer.writeAll("+ sample_type=lhs\n"),
                }
                for (s.params) |p| {
                    try writer.print("+ param={s} ", .{p.name});
                    switch (p.dist) {
                        .normal    => |n| try writer.print("type=normal mean={e} std_dev={e}",    .{ n.mean, n.std_dev }),
                        .uniform   => |u| try writer.print("type=uniform lo={e} hi={e}",          .{ u.lo,   u.hi      }),
                        .lognormal => |l| try writer.print("type=lognormal mean={e} std_dev={e}", .{ l.mean, l.std_dev }),
                    }
                    try writer.writeByte('\n');
                }
            },
            .ngspice => {}, // emitted in .control section
        },
        .embedded_sampling => switch (backend) {
            .xyce => try writer.writeAll("* TODO: emit .EMBEDDEDSAMPLING\n"),
            .ngspice => try writer.writeAll("* [UNSUPPORTED] .EMBEDDEDSAMPLING not available in ngspice.\n"),
        },
        .pce => switch (backend) {
            .xyce => try writer.writeAll("* TODO: emit .PCE\n"),
            .ngspice => try writer.writeAll("* [UNSUPPORTED] .PCE not available in ngspice.\n"),
        },
        .data => |d| switch (backend) {
            .xyce => {
                try writer.print(".DATA {s}", .{d.name});
                for (d.param_names) |pn| try writer.print(" {s}", .{pn});
                try writer.writeByte('\n');
                for (d.rows) |row| {
                    try writer.writeByte('+');
                    for (row) |v| try writer.print(" {e}", .{v});
                    try writer.writeByte('\n');
                }
                try writer.writeAll(".ENDDATA\n");
            },
            .ngspice => {}, // emitted in .control section
        },
    }
}

fn emitMeasure(writer: anytype, meas: Measure) !void {
    try writer.print(".meas {s} {s} ", .{ measureModeStr(meas.mode), meas.name });
    switch (meas.kind) {
        .trig_targ => |tt| {
            try writer.print("TRIG {s} VAL={e}", .{ tt.trig_var, tt.trig_val });
            if (tt.rise)  |r|  try writer.print(" RISE={d}",  .{r});
            if (tt.fall)  |f|  try writer.print(" FALL={d}",  .{f});
            if (tt.cross) |cr| try writer.print(" CROSS={d}", .{cr});
            try writer.print(" TARG {s} VAL={e}", .{ tt.targ_var, tt.targ_val });
        },
        .find => |f| try writer.print("FIND {s} AT={e}", .{ f.var_name, f.at }),
        .min_max => |mm| {
            // Use tagName + toUpperScalar rather than a manual switch.
            const op_lower = @tagName(mm.kind);
            var op_buf: [8]u8 = undefined;
            const op = std.ascii.upperString(op_buf[0..op_lower.len], op_lower);
            try writer.print("{s} {s}", .{ op, mm.var_name });
            if (mm.from) |f| try writer.print(" FROM={e}", .{f});
            if (mm.to)   |t| try writer.print(" TO={e}",   .{t});
        },
        .when => |w| {
            try writer.print("WHEN {s}={e}", .{ w.var_name, w.val });
            if (w.rise)  |r|  try writer.print(" RISE={d}",  .{r});
            if (w.fall)  |f|  try writer.print(" FALL={d}",  .{f});
            if (w.cross) |cr| try writer.print(" CROSS={d}", .{cr});
        },
    }
    try writer.writeByte('\n');
}

fn emitPrint(writer: anytype, p: PrintDirective) !void {
    try writer.print(".print {s}", .{measureModeStr(p.mode)});
    if (p.format) |fmt| try writer.print(" FORMAT={s}", .{fmt});
    for (p.vars) |v| try writer.print(" {s}", .{v});
    try writer.writeByte('\n');
}

fn emitNgspiceControlSection(writer: anytype, nl: *const Netlist) !void {
    var needs_control = false;
    for (nl.sweeps.items) |sw| {
        switch (sw) {
            .step, .sampling, .data => { needs_control = true; break; },
            else => {},
        }
    }
    if (!needs_control) return;

    try writer.writeAll("\n.control\n");

    for (nl.sweeps.items) |sw| {
        switch (sw) {
            .step => |s| switch (s.kind) {
                .list => |l| {
                    try writer.writeAll("foreach __step_val");
                    for (l.values) |v| try writer.print(" {e}", .{v});
                    try writer.writeByte('\n');
                    try writer.print("  alterparam {s} = $__step_val\n", .{s.param});
                    try writer.writeAll("  reset\n  run\nend\n");
                },
                .lin => |lin| {
                    try writer.print("let __start = {e}\n", .{lin.start});
                    try writer.print("let __stop = {e}\n",  .{lin.stop});
                    try writer.print("let __step = {e}\n",  .{lin.step});
                    try writer.writeAll("let __val = __start\nwhile __val le __stop\n");
                    try writer.print("  alterparam {s} = $&__val\n", .{s.param});
                    try writer.writeAll("  reset\n  run\n  let __val = __val + __step\nend\n");
                },
                .dec, .oct => try writer.writeAll("* TODO: logarithmic step emulation\n"),
            },
            .sampling => |s| {
                try writer.print("let __nsamples = {d}\n", .{s.num_samples});
                try writer.writeAll("let __i = 0\nwhile __i < __nsamples\n");
                for (s.params) |p| {
                    switch (p.dist) {
                        .normal    => |n| try writer.print("  let __rv = {e} + {e} * sgauss(0)\n",              .{ n.mean, n.std_dev }),
                        .uniform   => |u| try writer.print("  let __rv = {e} + ({e} - {e}) * sunif(0)\n",       .{ u.lo,   u.hi, u.lo }),
                        .lognormal => |l| try writer.print("  let __rv = exp({e} + {e} * sgauss(0))\n",         .{ l.mean, l.std_dev }),
                    }
                    try writer.print("  alterparam {s} = $&__rv\n", .{p.name});
                }
                try writer.writeAll("  reset\n  run\n  let __i = __i + 1\nend\n");
            },
            .data => |d| {
                for (d.rows) |row| {
                    for (d.param_names, 0..) |pn, col| {
                        try writer.print("  alterparam {s} = {e}\n", .{ pn, row[col] });
                    }
                    try writer.writeAll("  reset\n  run\n");
                }
            },
            else => {},
        }
    }

    try writer.writeAll(".endc\n");
}

// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

test "Expose struct sizes for universal IR" {
    std.debug.print("Netlist: {d}B\n", .{@sizeOf(Netlist)});
    std.debug.print("Component: {d}B\n", .{@sizeOf(Component)});
    std.debug.print("Analysis: {d}B\n", .{@sizeOf(Analysis)});
    std.debug.print("Sweep: {d}B\n", .{@sizeOf(Sweep)});
}

test "basic netlist emit ngspice" {
    const allocator = std.testing.allocator;
    var nl = Netlist.init(allocator);
    defer nl.deinit();

    try nl.addParam(.{ .name = "Rload", .value = .{ .literal = 10e3 } });
    try nl.addComponent(.{ .resistor = .{ .name = "R1", .p = "out", .n = "0", .value = .{ .param = "Rload" } } });
    try nl.addSource(.{
        .name = "V1",
        .kind = .voltage,
        .p = "in",
        .n = "0",
        .dc = 5.0,
    });
    try nl.addAnalysis(.{ .tran = .{ .step = 1e-6, .stop = 1e-3 } });

    const text = try nl.emit(.ngspice, allocator);
    defer allocator.free(text);

    try std.testing.expect(text.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, text, ".tran") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, ".end") != null);
}

test "comptime func translation" {
    const ng_step = comptime translateFunc("step", .ngspice);
    const xy_step = comptime translateFunc("step", .xyce);
    try std.testing.expectEqualStrings("u", ng_step);
    try std.testing.expectEqualStrings("stp", xy_step);

    const ng_if = comptime translateFunc("if", .ngspice);
    const xy_if = comptime translateFunc("if", .xyce);
    try std.testing.expectEqualStrings("ternary_fcn", ng_if);
    try std.testing.expectEqualStrings("IF", xy_if);
}

test "validate catches unsupported" {
    const allocator = std.testing.allocator;
    var nl = Netlist.init(allocator);
    defer nl.deinit();

    try nl.addAnalysis(.{ .hb = .{ .freqs = &[_]f64{1e9} } });

    var diags = try nl.validate(.ngspice);
    defer diags.deinit(allocator);

    try std.testing.expect(diags.items.len > 0);
    try std.testing.expect(diags.items[0].level == .err);
}
