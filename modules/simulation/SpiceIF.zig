//! SpiceIF.zig — Universal SPICE intermediate representation
//!
//! Public surface:
//!   - Backend           — simulator selector (ngspice / xyce / vacask)
//!   - Value             — literal / param / expr discriminated union
//!   - SpiceComponent    — typed emittable device
//!   - emitComponent     — write one SpiceComponent to any writer
//!   - Analysis / Sweep / Measure — simulation control types
//!   - NetlistMode       — sim vs layout targeting
//!   - Netlist           — full IR container (build + validate + emit)

const std = @import("std");
const Allocator = std.mem.Allocator;
const List = std.ArrayListUnmanaged;

// ═════════════════════════════════════════════════════════════════════════════
// Backend & mode
// ═════════════════════════���═══════════════════════════════════════════════════


// ════���══════════════════════════════════��═════════════════════════════════════
// Value — scalar used in component parameters
// ═════════════════════��═══════════════════════════════════════════════════════

pub const Value = union(enum) {
    literal: f64,
    param: []const u8,
    expr: []const u8,

    pub fn emit(self: Value, writer: anytype) !void {
        switch (self) {
            .literal => |v| try writer.print("{e}", .{v}),
            .param => |name| try writer.print("{{{s}}}", .{name}),
            .expr => |e| try writer.writeAll(e),
        }
    }
};

pub const ParamOverride = struct {
    name: []const u8,
    value: Value,
};

// ═══════��══════════════════════════════════════════════════���══════════════════
// SpiceComponent — typed emittable device
// ═══════════════════════��══════════════════════════��══════════════════════════

pub const SpiceComponent = union(enum) {
    resistor: struct { name: []const u8, p: []const u8, n: []const u8, value: Value, m: ?[]const u8 = null },
    capacitor: struct { name: []const u8, p: []const u8, n: []const u8, value: Value, ic: ?f64 = null, m: ?[]const u8 = null },
    inductor: struct { name: []const u8, p: []const u8, n: []const u8, value: Value, ic: ?f64 = null, m: ?[]const u8 = null },
    diode: struct { name: []const u8, anode: []const u8, cathode: []const u8, model: []const u8 },
    mosfet: struct {
        name: []const u8, drain: []const u8, gate: []const u8, source: []const u8, bulk: []const u8, model: []const u8,
        w: ?Value = null, l: ?Value = null, m: ?f64 = null,
    },
    bjt: struct { name: []const u8, collector: []const u8, base: []const u8, emitter: []const u8, substrate: ?[]const u8 = null, model: []const u8 },
    jfet: struct { name: []const u8, drain: []const u8, gate: []const u8, source: []const u8, model: []const u8 },
    independent_source: IndependentSource,
    behavioral: struct { name: []const u8, kind: enum { voltage, current }, p: []const u8, n: []const u8, expr: []const u8 },
    vcvs: struct { name: []const u8, p: []const u8, n: []const u8, cp: []const u8, cn: []const u8, gain: Value },
    vccs: struct { name: []const u8, p: []const u8, n: []const u8, cp: []const u8, cn: []const u8, gain: Value },
    ccvs: struct { name: []const u8, p: []const u8, n: []const u8, vsrc: []const u8, gain: Value },
    cccs: struct { name: []const u8, p: []const u8, n: []const u8, vsrc: []const u8, gain: Value },
    subcircuit: struct {
        name: []const u8, inst_name: []const u8, nodes: []const []const u8, params: []const ParamOverride,
        block_type: enum { subckt, va } = .subckt,
    },
    raw: []const u8,
};

// ══════════════════════════════════════════════════════��══════════════════════
// emitComponent — write a SpiceComponent to any writer
// ═════════��══════════════════════════��══════════════════════════════════��═════

pub fn emitComponent(writer: anytype, comp: SpiceComponent) !void {
    switch (comp) {
        .resistor => |r| {
            try writer.print("{s} {s} {s} ", .{ r.name, r.p, r.n });
            try r.value.emit(writer);
            if (r.m) |m| try writer.print(" m={s}", .{m});
            try writer.writeByte('\n');
        },
        .capacitor => |c| {
            try writer.print("{s} {s} {s} ", .{ c.name, c.p, c.n });
            try c.value.emit(writer);
            if (c.ic) |ic| try writer.print(" ic={e}", .{ic});
            if (c.m) |m| try writer.print(" m={s}", .{m});
            try writer.writeByte('\n');
        },
        .inductor => |l| {
            try writer.print("{s} {s} {s} ", .{ l.name, l.p, l.n });
            try l.value.emit(writer);
            if (l.ic) |ic| try writer.print(" ic={e}", .{ic});
            if (l.m) |m| try writer.print(" m={s}", .{m});
            try writer.writeByte('\n');
        },
        .diode => |d| try writer.print("{s} {s} {s} {s}\n", .{ d.name, d.anode, d.cathode, d.model }),
        .mosfet => |m| {
            try writer.print("{s} {s} {s} {s} {s} {s}", .{ m.name, m.drain, m.gate, m.source, m.bulk, m.model });
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
        .jfet => |j| try writer.print("{s} {s} {s} {s} {s}\n", .{ j.name, j.drain, j.gate, j.source, j.model }),
        .independent_source => |src| try emitIndependentSource(writer, src),
        .behavioral => |b| {
            try writer.print("{s} {s} {s}", .{ b.name, b.p, b.n });
            switch (b.kind) { .voltage => try writer.print(" V={s}", .{b.expr}), .current => try writer.print(" I={s}", .{b.expr}) }
            try writer.writeByte('\n');
        },
        .vcvs => |e| { try writer.print("{s} {s} {s} {s} {s} ", .{ e.name, e.p, e.n, e.cp, e.cn }); try e.gain.emit(writer); try writer.writeByte('\n'); },
        .vccs => |g| { try writer.print("{s} {s} {s} {s} {s} ", .{ g.name, g.p, g.n, g.cp, g.cn }); try g.gain.emit(writer); try writer.writeByte('\n'); },
        .ccvs => |h| { try writer.print("{s} {s} {s} {s} ", .{ h.name, h.p, h.n, h.vsrc }); try h.gain.emit(writer); try writer.writeByte('\n'); },
        .cccs => |f| { try writer.print("{s} {s} {s} {s} ", .{ f.name, f.p, f.n, f.vsrc }); try f.gain.emit(writer); try writer.writeByte('\n'); },
        .subcircuit => |s| {
            if (s.block_type == .subckt) { try writer.print(".subckt {s}", .{s.name}); for (s.nodes) |n| try writer.print(" {s}", .{n}); try writer.writeByte('\n'); }
            try writer.print("{s}", .{s.inst_name});
            for (s.nodes) |n| try writer.print(" {s}", .{n});
            try writer.print(" {s}", .{s.name});
            for (s.params) |p| { try writer.print(" {s}=", .{p.name}); try p.value.emit(writer); }
            try writer.writeByte('\n');
            if (s.block_type == .subckt) try writer.writeAll(".ends\n");
        },
        .raw => |line| try writer.print("{s}\n", .{line}),
    }
}


// ═════════════════════════════════════════════════════════════════════════════
// Source waveforms
// ════════════════════���════════════════════════════════════════════════════════

const SrcDC = struct { dc: f64 = 0 };
const SrcAC = struct { mag: f64 = 1, phase: f64 = 0 };
const SrcSin = struct { offset: f64 = 0, amplitude: f64, freq: f64, delay: f64 = 0, damping: f64 = 0, phase: f64 = 0 };
const SrcPulse = struct { v1: f64, v2: f64, delay: f64 = 0, rise: f64 = 0, fall: f64 = 0, width: f64, period: f64 };
const SrcPWL = struct { points: []const [2]f64 };
const SrcSFFM = struct { offset: f64 = 0, amplitude: f64, carrier_freq: f64, mod_index: f64 = 0, signal_freq: f64 = 0 };
const SrcEXP = struct { v1: f64, v2: f64, td1: f64 = 0, tau1: f64, td2: f64 = 0, tau2: f64 };
const SrcPAT = struct { vhi: f64, vlo: f64 = 0, delay: f64 = 0, rise: f64 = 0, fall: f64 = 0, bit_period: f64, pattern: []const u8 };

pub const SourceWaveform = union(enum) {
    dc: SrcDC, ac: SrcAC, sin: SrcSin, pulse: SrcPulse, pwl: SrcPWL,
    sffm: SrcSFFM, exp: SrcEXP, pat: SrcPAT,
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
    save_current: bool = false,
};

pub fn emitIndependentSource(writer: anytype, src: IndependentSource) !void {
    const prefix: u8 = switch (src.kind) { .voltage => 'V', .current => 'I' };
    try writer.writeByte(prefix);
    try writer.writeAll(src.name);
    try writer.print(" {s} {s}", .{ src.p, src.n });
    if (src.dc) |dc| try writer.print(" {e}", .{dc});
    if (src.ac_mag) |ac| {
        try writer.print(" ac {e}", .{ac});
        if (src.ac_phase) |ph| try writer.print(" {e}", .{ph});
    }
    if (src.waveform) |wf| switch (wf) {
        .pulse => |p| try writer.print(" PULSE({e} {e} {e} {e} {e} {e} {e})", .{ p.v1, p.v2, p.delay, p.rise, p.fall, p.width, p.period }),
        .sin => |s| try writer.print(" SIN({e} {e} {e} {e} {e} {e})", .{ s.offset, s.amplitude, s.freq, s.delay, s.damping, s.phase }),
        .pwl => |pwl| { try writer.writeAll(" PWL("); for (pwl.points, 0..) |pt, i| { if (i > 0) try writer.writeByte(' '); try writer.print("{e} {e}", .{ pt[0], pt[1] }); } try writer.writeByte(')'); },
        .exp => |e| try writer.print(" EXP({e} {e} {e} {e} {e} {e})", .{ e.v1, e.v2, e.td1, e.tau1, e.td2, e.tau2 }),
        .sffm => |s| try writer.print(" SFFM({e} {e} {e} {e} {e})", .{ s.offset, s.amplitude, s.carrier_freq, s.mod_index, s.signal_freq }),
        .dc => |d| try writer.print(" {e}", .{d.dc}),
        .ac => |a| try writer.print(" ac {e} {e}", .{ a.mag, a.phase }),
        .pat => try writer.writeAll(" /* PAT not supported */"),
    };
    try writer.writeByte('\n');
    if (src.save_current) try writer.print(".save i({s})\n", .{src.name});
}


// ══════════════════════���════════════════════════════════��═════════════════════
// Analysis types
// ���══════════════════��═════════════════════════════════════════════════════════

pub const SweepKind = enum { lin, dec, oct };

pub fn sweepStr(k: SweepKind) []const u8 {
    return switch (k) { .lin => "lin", .dec => "dec", .oct => "oct" };
}

pub const AnalysisOP = struct {};
pub const AnalysisDC = struct {
    src1: []const u8, start1: f64, stop1: f64, step1: f64,
    src2: ?[]const u8 = null, start2: ?f64 = null, stop2: ?f64 = null, step2: ?f64 = null,
};
pub const AnalysisAC = struct { sweep: SweepKind = .dec, n_points: u32, f_start: f64, f_stop: f64 };
pub const AnalysisTran = struct { step: f64, stop: f64, start: f64 = 0, max_step: ?f64 = null, uic: bool = false };
pub const AnalysisNoise = struct {
    output_node: []const u8, output_ref: ?[]const u8 = null, input_src: []const u8,
    sweep: SweepKind = .dec, n_points: u32, f_start: f64, f_stop: f64, points_per_summary: ?u32 = null,
};
pub const AnalysisSens = struct {
    output_var: []const u8, mode: enum { dc, ac, tran, tran_adjoint } = .dc,
    ac_sweep: ?SweepKind = null, ac_n_points: ?u32 = null, ac_f_start: ?f64 = null, ac_f_stop: ?f64 = null,
};
pub const AnalysisTF = struct { output_var: []const u8, input_src: []const u8 };
pub const AnalysisPZ = struct {
    in_pos: []const u8, in_neg: []const u8, out_pos: []const u8, out_neg: []const u8,
    tf_type: enum { vol, cur }, pz_type: enum { pol, zer, pz },
};
pub const AnalysisDisto = struct { sweep: SweepKind = .dec, n_points: u32, f_start: f64, f_stop: f64, f2_over_f1: ?f64 = null };
pub const AnalysisPSS = struct { gfreq: f64, tstab: f64, fft_points: u32 = 1024, harms: u32 = 10, sciter: u32 = 150, steadycoeff: f64 = 1e-3 };
pub const AnalysisSP = struct { sweep: SweepKind = .dec, n_points: u32, f_start: f64, f_stop: f64 };
pub const AnalysisHB = struct { freqs: []const f64, n_harmonics: u32 = 7, startup: bool = false, startup_periods: ?u32 = null };
pub const AnalysisMPDE = struct { fast_freqs: []const f64, oscsrc: ?[]const u8 = null };
pub const AnalysisFour = struct { freq: f64, nodes: []const []const u8 };

pub const Analysis = union(enum) {
    op: AnalysisOP, dc: AnalysisDC, ac: AnalysisAC, tran: AnalysisTran,
    noise: AnalysisNoise, sens: AnalysisSens, tf: AnalysisTF, pz: AnalysisPZ,
    disto: AnalysisDisto, pss: AnalysisPSS, sp: AnalysisSP, hb: AnalysisHB,
    mpde: AnalysisMPDE, four: AnalysisFour,
};

// ═══��════════════════════════════════════════════════════════════���════════════
// Sweep / UQ types
// ══════════════════════════════════════════════════════��══════════════════════

pub const StepSweep = struct {
    param: []const u8,
    kind: union(enum) {
        lin: struct { start: f64, stop: f64, step: f64 },
        dec: struct { start: f64, stop: f64, points: u32 },
        oct: struct { start: f64, stop: f64, points: u32 },
        list: struct { values: []const f64 },
    },
};

pub const Distribution = union(enum) {
    normal: struct { mean: f64, std_dev: f64 },
    uniform: struct { lo: f64, hi: f64 },
    lognormal: struct { mean: f64, std_dev: f64 },
};

pub const SamplingParam = struct { name: []const u8, dist: Distribution };
pub const Sampling = struct { num_samples: u32 = 100, method: enum { mc, lhs } = .mc, params: []const SamplingParam };
pub const EmbeddedSampling = struct { num_samples: u32 = 100, params: []const SamplingParam };
pub const PCE = struct { order: u32 = 3, method: enum { regression, nisp, intrusive } = .regression, sample_count: ?u32 = null, params: []const SamplingParam };
pub const DataTable = struct { name: []const u8, param_names: []const []const u8, rows: []const []const f64 };

pub const Sweep = union(enum) {
    step: StepSweep, sampling: Sampling, embedded_sampling: EmbeddedSampling, pce: PCE, data: DataTable,
};

// ═��══════════════════════════════���══════════════════════════════���═════════════
// Measure types
// ═════════════════��═══════════════════════════════════════════════════════════

pub const MeasureMode = enum { tran, ac, dc, noise };
const MeasureTrig = struct { trig_var: []const u8, trig_val: f64, targ_var: []const u8, targ_val: f64, rise: ?u32 = null, fall: ?u32 = null, cross: ?u32 = null };
const MeasureFind = struct { var_name: []const u8, at: f64 };
const MeasureMinMax = struct { var_name: []const u8, kind: enum { min, max, pp, avg, rms, integ }, from: ?f64 = null, to: ?f64 = null };
const MeasureWhen = struct { var_name: []const u8, val: f64, rise: ?u32 = null, fall: ?u32 = null, cross: ?u32 = null };

pub const Measure = struct {
    name: []const u8,
    mode: MeasureMode,
    kind: union(enum) { trig_targ: MeasureTrig, find: MeasureFind, min_max: MeasureMinMax, when: MeasureWhen },
};

pub fn emitMeasureShared(writer: anytype, meas: Measure) !void {
    try writer.print(".meas {s} {s} ", .{ @tagName(meas.mode), meas.name });
    switch (meas.kind) {
        .trig_targ => |t| {
            try writer.print("TRIG {s}={e} TARG {s}={e}", .{ t.trig_var, t.trig_val, t.targ_var, t.targ_val });
            if (t.rise) |r| try writer.print(" RISE={d}", .{r});
            if (t.fall) |f| try writer.print(" FALL={d}", .{f});
            if (t.cross) |c| try writer.print(" CROSS={d}", .{c});
        },
        .find => |f| try writer.print("FIND {s} AT={e}", .{ f.var_name, f.at }),
        .min_max => |m| {
            try writer.print("{s} {s}", .{ @tagName(m.kind), m.var_name });
            if (m.from) |from| try writer.print(" FROM={e}", .{from});
            if (m.to) |to| try writer.print(" TO={e}", .{to});
        },
        .when => |w| {
            try writer.print("WHEN {s}={e}", .{ w.var_name, w.val });
            if (w.rise) |r| try writer.print(" RISE={d}", .{r});
            if (w.fall) |f| try writer.print(" FALL={d}", .{f});
            if (w.cross) |c| try writer.print(" CROSS={d}", .{c});
        },
    }
    try writer.writeByte('\n');
}

// ══════════════════════════════════��═══════════════════════���══════════════════
// Model / Param / Print / other directives
// ═════════════════════���═══════════════════════════════════════════════════════

const ModelParam = struct { name: []const u8, value: Value };
const ModelDef = struct { name: []const u8, kind: []const u8, level: ?u32 = null, version: ?[]const u8 = null, params: []const ModelParam };
const Param = struct { name: []const u8, value: Value, global: bool = false };
pub const PrintDirective = struct { mode: MeasureMode, vars: []const []const u8, format: ?[]const u8 = null };
const SaveDirective = struct { vars: []const []const u8, all: bool = false };
const Option = struct { name: []const u8, value: ?Value = null };
const Include = struct { path: []const u8 };
const Library = struct { path: []const u8, section: ?[]const u8 = null };

pub fn emitPrintShared(writer: anytype, p: PrintDirective) !void {
    try writer.print(".print {s}", .{@tagName(p.mode)});
    for (p.vars) |v| try writer.print(" {s}", .{v});
    try writer.writeByte('\n');
}

// ═════════════════════════════════════════════════════════════════════════════
// Netlist — full IR container
// ═════════════════════════════════════════════════════════════════════════════

pub const Netlist = struct {
    title: []const u8 = "Universal SPICE netlist",
    params: List(Param) = .{},
    options: List(Option) = .{},
    includes: List(Include) = .{},
    libs: List(Library) = .{},
    models: List(ModelDef) = .{},
    components: List(SpiceComponent) = .{},
    analyses: List(Analysis) = .{},
    sweeps: List(Sweep) = .{},
    measures: List(Measure) = .{},
    prints: List(PrintDirective) = .{},
    saves: List(SaveDirective) = .{},
    raw_lines: List([]const u8) = .{},
    code_blocks: List([]const u8) = .{},
    toplevel_code_blocks: List([]const u8) = .{},

    pub fn deinit(self: *Netlist, a: Allocator) void {
        self.params.deinit(a); self.options.deinit(a); self.includes.deinit(a);
        self.libs.deinit(a); self.models.deinit(a); self.components.deinit(a);
        self.analyses.deinit(a); self.sweeps.deinit(a); self.measures.deinit(a);
        self.prints.deinit(a); self.saves.deinit(a); self.raw_lines.deinit(a);
        self.code_blocks.deinit(a); self.toplevel_code_blocks.deinit(a);
    }

    // Builder API
    pub fn addParam(self: *Netlist, a: Allocator, p: Param) !void { try self.params.append(a, p); }
    pub fn addAnalysis(self: *Netlist, a: Allocator, an: Analysis) !void { try self.analyses.append(a, an); }
    pub fn addComponent(self: *Netlist, a: Allocator, c: SpiceComponent) !void { try self.components.append(a, c); }
    pub fn addSource(self: *Netlist, a: Allocator, src: IndependentSource) !void { try self.components.append(a, .{ .independent_source = src }); }
    pub fn addSweep(self: *Netlist, a: Allocator, sw: Sweep) !void { try self.sweeps.append(a, sw); }
    pub fn addMeasure(self: *Netlist, a: Allocator, m: Measure) !void { try self.measures.append(a, m); }
    pub fn addRaw(self: *Netlist, a: Allocator, line: []const u8) !void { try self.raw_lines.append(a, line); }

    pub fn emit(self: *const Netlist, a: Allocator) ![]u8 {
        var buf = List(u8){};
        errdefer buf.deinit(a);
        try self.emitTo(buf.writer(a));
        return buf.toOwnedSlice(a);
    }

    pub fn emitTo(self: *const Netlist, writer: anytype) !void {
        try writer.print("{s}\n", .{self.title});
        for (self.includes.items) |inc| try writer.print(".include {s}\n", .{inc.path});
        for (self.libs.items) |lib| { try writer.print(".lib {s}", .{lib.path}); if (lib.section) |s| try writer.print(" {s}", .{s}); try writer.writeByte('\n'); }
        for (self.options.items) |opt| { try writer.print(".options {s}", .{opt.name}); if (opt.value) |v| { try writer.writeAll("="); try v.emit(writer); } try writer.writeByte('\n'); }
        for (self.params.items) |p| {
            try writer.print(".param {s}=", .{p.name});
            try p.value.emit(writer);
            try writer.writeByte('\n');
        }
        for (self.models.items) |m| {
            try writer.print(".model {s} {s}", .{ m.name, m.kind });
            if (m.level) |lvl| try writer.print(" level={d}", .{lvl});
            if (m.version) |ver| try writer.print(" version={s}", .{ver});
            if (m.params.len > 0) { try writer.writeAll(" (\n"); for (m.params) |mp| { try writer.print("+ {s}=", .{mp.name}); try mp.value.emit(writer); try writer.writeByte('\n'); } try writer.writeAll(")\n"); } else try writer.writeByte('\n');
        }
        for (self.components.items) |c| try emitComponent(writer, c);
        for (self.analyses.items) |an| try emitAnalysisNgspice(writer, an);
        for (self.measures.items) |m| try emitMeasureShared(writer, m);
        for (self.prints.items) |p| try emitPrintShared(writer, p);
        for (self.saves.items) |s| { try writer.writeAll(".save"); if (s.all) try writer.writeAll(" all") else for (s.vars) |v| try writer.print(" {s}", .{v}); try writer.writeByte('\n'); }
        for (self.analyses.items) |an| if (an == .four) { try writer.print(".four {e}", .{an.four.freq}); for (an.four.nodes) |n| try writer.print(" {s}", .{n}); try writer.writeByte('\n'); };
        for (self.raw_lines.items) |line| try writer.print("{s}\n", .{line});
        for (self.code_blocks.items) |blk| { try writer.writeAll("**** begin user architecture code\n"); try writer.print("{s}\n", .{std.mem.trimRight(u8, blk, "\n\r")}); try writer.writeAll("**** end user architecture code\n"); }
        try emitNgspiceControlSection(writer, self);
        try writer.writeAll(".end\n");
    }
};

// ═════════════════════════════════════════════════════════════════════════════
// ngspice emission
// ═════════════════════════════════════════════════════════════════════════════

pub fn emitAnalysisNgspice(writer: anytype, an: Analysis) !void {
    switch (an) {
        .op => try writer.writeAll(".op\n"),
        .dc => |d| {
            try writer.print(".dc {s} {e} {e} {e}", .{ d.src1, d.start1, d.stop1, d.step1 });
            if (d.src2) |s2| try writer.print(" {s} {e} {e} {e}", .{ s2, d.start2.?, d.stop2.?, d.step2.? });
            try writer.writeByte('\n');
        },
        .ac => |a| try writer.print(".ac {s} {d} {e} {e}\n", .{ sweepStr(a.sweep), a.n_points, a.f_start, a.f_stop }),
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
            try writer.print(") {s} {s} {d} {e} {e}", .{ n.input_src, sweepStr(n.sweep), n.n_points, n.f_start, n.f_stop });
            if (n.points_per_summary) |pts| try writer.print(" {d}", .{pts});
            try writer.writeByte('\n');
        },
        .sens => |s| try writer.print(".sens {s}\n", .{s.output_var}),
        .tf => |t| try writer.print(".tf {s} {s}\n", .{ t.output_var, t.input_src }),
        .pz => |p| {
            const tf = switch (p.tf_type) { .vol => "vol", .cur => "cur" };
            const pzt = switch (p.pz_type) { .pol => "pol", .zer => "zer", .pz => "pz" };
            try writer.print(".pz {s} {s} {s} {s} {s} {s}\n", .{ p.in_pos, p.in_neg, p.out_pos, p.out_neg, tf, pzt });
        },
        .disto => |d| {
            try writer.print(".disto {s} {d} {e} {e}", .{ sweepStr(d.sweep), d.n_points, d.f_start, d.f_stop });
            if (d.f2_over_f1) |r| try writer.print(" {e}", .{r});
            try writer.writeByte('\n');
        },
        .pss => |p| try writer.print(".pss {e} {e} {d} {d} {d} {e}\n", .{ p.gfreq, p.tstab, p.fft_points, p.harms, p.sciter, p.steadycoeff }),
        .sp => |s| try writer.print(".sp {s} {d} {e} {e}\n", .{ sweepStr(s.sweep), s.n_points, s.f_start, s.f_stop }),
        .hb => {
            try writer.writeAll("* [UNSUPPORTED] .HB not available in ngspice.\n");
            if (an.hb.freqs.len == 1) {
                try writer.writeAll("* Partial workaround: using .PSS (experimental)\n");
                try writer.print(".pss {e} 0 1024 {d} 150 1e-3\n", .{ an.hb.freqs[0], an.hb.n_harmonics });
            }
        },
        .mpde => try writer.writeAll("* [UNSUPPORTED] .MPDE not available in ngspice.\n"),
        .four => {},
    }
}

fn emitNgspiceControlSection(writer: anytype, nl: *const Netlist) !void {
    var has_sweeps = false;
    for (nl.sweeps.items) |sw| switch (sw) {
        .step, .sampling, .data => { has_sweeps = true; break; },
        else => {},
    };
    if (nl.analyses.items.len == 0 and !has_sweeps) return;

    try writer.writeAll("\n.control\n");
    if (!has_sweeps) {
        try writer.writeAll("run\nprint all\n.endc\n");
        return;
    }

    for (nl.sweeps.items) |sw| switch (sw) {
        .step => |s| switch (s.kind) {
            .list => |l| {
                try writer.writeAll("foreach __step_val");
                for (l.values) |v| try writer.print(" {e}", .{v});
                try writer.writeByte('\n');
                try writer.print("  alterparam {s} = $__step_val\n  reset\n  run\nend\n", .{s.param});
            },
            .lin => |lin| {
                try writer.print("let __start = {e}\nlet __stop = {e}\nlet __step = {e}\n", .{ lin.start, lin.stop, lin.step });
                try writer.writeAll("let __val = __start\nwhile __val le __stop\n");
                try writer.print("  alterparam {s} = $&__val\n  reset\n  run\n  let __val = __val + __step\nend\n", .{s.param});
            },
            .dec, .oct => try writer.writeAll("* TODO: logarithmic step emulation\n"),
        },
        .sampling => |s| {
            try writer.print("let __nsamples = {d}\nlet __i = 0\nwhile __i < __nsamples\n", .{s.num_samples});
            for (s.params) |p| {
                switch (p.dist) {
                    .normal => |n| try writer.print("  let __rv = {e} + {e} * sgauss(0)\n", .{ n.mean, n.std_dev }),
                    .uniform => |u| try writer.print("  let __rv = {e} + ({e} - {e}) * sunif(0)\n", .{ u.lo, u.hi, u.lo }),
                    .lognormal => |l| try writer.print("  let __rv = exp({e} + {e} * sgauss(0))\n", .{ l.mean, l.std_dev }),
                }
                try writer.print("  alterparam {s} = $&__rv\n", .{p.name});
            }
            try writer.writeAll("  reset\n  run\n  let __i = __i + 1\nend\n");
        },
        .data => |d| {
            for (d.rows) |row| {
                for (d.param_names, 0..) |pn, col| try writer.print("  alterparam {s} = {e}\n", .{ pn, row[col] });
                try writer.writeAll("  reset\n  run\n");
            }
        },
        else => {},
    };
    try writer.writeAll(".endc\n");
}

// ═══════════════���═══════════════════════════��═════════════════════════════════
// Tests
// ══════════════════════════════════════════════════��══════════════════════════

test "Value.emit literal" {
    var buf: [32]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try (Value{ .literal = 1.5 }).emit(fbs.writer());
    try std.testing.expect(fbs.getWritten().len > 0);
}

test "Value.emit param" {
    var buf: [32]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try (Value{ .param = "W" }).emit(fbs.writer());
    try std.testing.expectEqualStrings("{W}", fbs.getWritten());
}
