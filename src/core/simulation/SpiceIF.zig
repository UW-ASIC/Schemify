//! Universal SPICE intermediate representation, simulator handle, and bridge.
//!
//! Public surface consumed by other modules:
//!
//!   - `Backend`           — simulator selector (ngspice / xyce / hspice / …)
//!   - `Value`             — literal / param / expr discriminated union
//!   - `SpiceComponent`    — typed emittable device; construct via helpers below
//!   - `emitComponent`     — write one SpiceComponent to any writer
//!   - `Netlist`           — full IR container (build + validate + emit whole files)
//!   - `Simulator`         — thin process wrapper
//!   - `SpiceIF`           — Netlist → Simulator bridge
//!   - `RunResult`         — diagnostics + emitted text bundle
//!
//! Devices.zig imports `Backend`, `Value`, `SpiceComponent`, and `emitComponent`
//! to implement `Device.emitSpice(writer, backend)` without depending on Netlist.
//!
//! Schemify.zig imports `Backend` (just the enum) and calls through to the PDK /
//! Device layer, then writes a header/footer itself.

// =============================================================================
// Imports
// =============================================================================

const std = @import("std");
const Allocator = std.mem.Allocator;
const utility = @import("utility");
const Vfs = utility.Vfs;

/// Simulator backend selector.
pub const Backend = enum { ngspice, xyce, vacask };

// =============================================================================
// Public: NetlistMode — sim vs layout targeting
// =============================================================================

/// Controls how the netlist pipeline emits certain blocks.
///   - `.sim`    — behavioural / simulation-oriented (current default)
///   - `.layout` — layout-oriented (gate-level expansion for digital blocks)
pub const NetlistMode = enum { sim, layout };

// =============================================================================
// Public: Value — scalar used in component parameters
// =============================================================================

/// A component parameter value: a bare number, a netlist parameter reference,
/// or an expression string in universal syntax.
pub const Value = union(enum) {
    literal: f64,
    /// Reference to a `.param` name; emitted as `{name}`.
    param: []const u8,
    /// Expression in universal syntax; a rewrite pass is needed per backend
    /// before emission (TODO: per-backend expr rewriter).
    expr: []const u8,

    pub fn emit(self: Value, writer: anytype) !void {
        switch (self) {
            .literal => |v| try writer.print("{e}", .{v}),
            .param => |name| try writer.print("{{{s}}}", .{name}),
            .expr => |e| try writer.writeAll(e),
        }
    }
};

// =============================================================================
// Public: SpiceComponent — the minimal emittable device type
// =============================================================================
//
// Devices.zig builds one of these from a `Device` struct and passes it to
// `emitComponent`.  Schemify builds one per instance from PDK metadata.
//
// The variants mirror the SPICE instance-line prefixes.  New device types
// only need a new variant here + a corresponding arm in `emitComponent`.

pub const ParamOverride = struct {
    name: []const u8,
    value: Value,
};

pub const SpiceComponent = union(enum) {
    // ── Passives ──────────────────────────────────────────────────────────── //
    resistor: struct { name: []const u8, p: []const u8, n: []const u8, value: Value, m: ?[]const u8 = null },
    capacitor: struct { name: []const u8, p: []const u8, n: []const u8, value: Value, ic: ?f64 = null, m: ?[]const u8 = null },
    inductor: struct { name: []const u8, p: []const u8, n: []const u8, value: Value, ic: ?f64 = null, m: ?[]const u8 = null },

    // ── Semiconductors ────────────────────────────────────────────────────── //
    diode: struct { name: []const u8, anode: []const u8, cathode: []const u8, model: []const u8 },
    mosfet: struct {
        name: []const u8,
        drain: []const u8,
        gate: []const u8,
        source: []const u8,
        bulk: []const u8,
        model: []const u8,
        w: ?Value = null,
        l: ?Value = null,
        m: ?f64 = null,
    },
    bjt: struct {
        name: []const u8,
        collector: []const u8,
        base: []const u8,
        emitter: []const u8,
        substrate: ?[]const u8 = null,
        model: []const u8,
    },
    jfet: struct { name: []const u8, drain: []const u8, gate: []const u8, source: []const u8, model: []const u8 },

    // ── Sources ───────────────────────────────────────────────────────────── //
    independent_source: IndependentSource,
    behavioral: struct {
        name: []const u8,
        kind: enum { voltage, current },
        p: []const u8,
        n: []const u8,
        expr: []const u8,
    },
    vcvs: struct { name: []const u8, p: []const u8, n: []const u8, cp: []const u8, cn: []const u8, gain: Value },
    vccs: struct { name: []const u8, p: []const u8, n: []const u8, cp: []const u8, cn: []const u8, gain: Value },
    ccvs: struct { name: []const u8, p: []const u8, n: []const u8, vsrc: []const u8, gain: Value },
    cccs: struct { name: []const u8, p: []const u8, n: []const u8, vsrc: []const u8, gain: Value },

    // ── Hierarchical ──────────────────────────────────────────────────────── //
    subcircuit: struct {
        name: []const u8,
        inst_name: []const u8,
        nodes: []const []const u8,
        params: []const ParamOverride,
        /// Controls whether emitComponent() wraps this in `.subckt`/`.ends`
        /// or leaves it raw (e.g., Verilog-A module reference).
        block_type: enum { subckt, va } = .subckt,
    },

    // ── Escape hatch ──────────────────────────────────────────────────────── //
    /// Pre-formatted SPICE line; emitted verbatim.  Use when no typed variant
    /// exists yet (e.g. transmission lines, switches, K-elements).
    raw: []const u8,
};

// =============================================================================
// Public: emitComponent — write a SpiceComponent to any std.io writer
// =============================================================================

/// Write a single `SpiceComponent` line (or block for subcircuits) to `writer`.
/// For VACASK, emits Spectre-like syntax (parenthesized nodes, keyword types).
/// For ngspice/Xyce, emits standard SPICE syntax.
pub fn emitComponent(writer: anytype, comp: SpiceComponent, backend: Backend) !void {
    if (backend == .vacask) return emitComponentVacask(writer, comp);

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
        .diode => |d| {
            try writer.print("{s} {s} {s} {s}\n", .{ d.name, d.anode, d.cathode, d.model });
        },
        .mosfet => |m| {
            try writer.print("{s} {s} {s} {s} {s} {s}", .{
                m.name, m.drain, m.gate, m.source, m.bulk, m.model,
            });
            if (m.w) |w| {
                try writer.writeAll(" W=");
                try w.emit(writer);
            }
            if (m.l) |l| {
                try writer.writeAll(" L=");
                try l.emit(writer);
            }
            if (m.m) |mult| try writer.print(" M={d}", .{mult});
            try writer.writeByte('\n');
        },
        .bjt => |b| {
            try writer.print("{s} {s} {s} {s}", .{ b.name, b.collector, b.base, b.emitter });
            if (b.substrate) |sub| try writer.print(" {s}", .{sub});
            try writer.print(" {s}\n", .{b.model});
        },
        .jfet => |j| {
            try writer.print("{s} {s} {s} {s} {s}\n", .{ j.name, j.drain, j.gate, j.source, j.model });
        },
        .independent_source => |src| {
            try emitIndependentSource(writer, src);
        },
        .behavioral => |b| {
            try writer.print("{s} {s} {s}", .{ b.name, b.p, b.n });
            switch (b.kind) {
                .voltage => try writer.print(" V={s}", .{b.expr}),
                .current => try writer.print(" I={s}", .{b.expr}),
            }
            try writer.writeByte('\n');
        },
        .vcvs => |e| {
            try writer.print("{s} {s} {s} {s} {s} ", .{ e.name, e.p, e.n, e.cp, e.cn });
            try e.gain.emit(writer);
            try writer.writeByte('\n');
        },
        .vccs => |g| {
            try writer.print("{s} {s} {s} {s} {s} ", .{ g.name, g.p, g.n, g.cp, g.cn });
            try g.gain.emit(writer);
            try writer.writeByte('\n');
        },
        .ccvs => |h| {
            try writer.print("{s} {s} {s} {s} ", .{ h.name, h.p, h.n, h.vsrc });
            try h.gain.emit(writer);
            try writer.writeByte('\n');
        },
        .cccs => |f| {
            try writer.print("{s} {s} {s} {s} ", .{ f.name, f.p, f.n, f.vsrc });
            try f.gain.emit(writer);
            try writer.writeByte('\n');
        },
        .subcircuit => |s| {
            if (s.block_type == .subckt) {
                try writer.print(".subckt {s}", .{s.name});
                for (s.nodes) |node| try writer.print(" {s}", .{node});
                try writer.writeByte('\n');
            }
            try writer.print("{s}", .{s.inst_name});
            for (s.nodes) |node| try writer.print(" {s}", .{node});
            try writer.print(" {s}", .{s.name});
            for (s.params) |p| {
                try writer.print(" {s}=", .{p.name});
                try p.value.emit(writer);
            }
            try writer.writeByte('\n');
            if (s.block_type == .subckt) {
                try writer.writeAll(".ends\n");
            }
        },
        .raw => |line| try writer.print("{s}\n", .{line}),
    }
}

/// VACASK (Spectre-like) component emission.
/// Syntax: `name (nodes...) type [param=value ...]`
fn emitComponentVacask(writer: anytype, comp: SpiceComponent) !void {
    switch (comp) {
        .resistor => |r| {
            try writer.print("{s} ({s} {s}) resistor r=", .{ r.name, r.p, r.n });
            try r.value.emit(writer);
            if (r.m) |m| try writer.print(" m={s}", .{m});
            try writer.writeByte('\n');
        },
        .capacitor => |c| {
            try writer.print("{s} ({s} {s}) capacitor c=", .{ c.name, c.p, c.n });
            try c.value.emit(writer);
            if (c.ic) |ic| try writer.print(" ic={e}", .{ic});
            if (c.m) |m| try writer.print(" m={s}", .{m});
            try writer.writeByte('\n');
        },
        .inductor => |l| {
            try writer.print("{s} ({s} {s}) inductor l=", .{ l.name, l.p, l.n });
            try l.value.emit(writer);
            if (l.ic) |ic| try writer.print(" ic={e}", .{ic});
            if (l.m) |m| try writer.print(" m={s}", .{m});
            try writer.writeByte('\n');
        },
        .diode => |d| {
            try writer.print("{s} ({s} {s}) {s}\n", .{ d.name, d.anode, d.cathode, d.model });
        },
        .mosfet => |m| {
            try writer.print("{s} ({s} {s} {s} {s}) {s}", .{
                m.name, m.drain, m.gate, m.source, m.bulk, m.model,
            });
            if (m.w) |w| {
                try writer.writeAll(" w=");
                try w.emit(writer);
            }
            if (m.l) |l| {
                try writer.writeAll(" l=");
                try l.emit(writer);
            }
            if (m.m) |mult| try writer.print(" m={d}", .{mult});
            try writer.writeByte('\n');
        },
        .bjt => |b| {
            try writer.print("{s} ({s} {s} {s}", .{ b.name, b.collector, b.base, b.emitter });
            if (b.substrate) |sub| try writer.print(" {s}", .{sub});
            try writer.print(") {s}\n", .{b.model});
        },
        .jfet => |j| {
            try writer.print("{s} ({s} {s} {s}) {s}\n", .{ j.name, j.drain, j.gate, j.source, j.model });
        },
        .independent_source => |src| {
            try emitVacaskSource(writer, src);
        },
        .behavioral => |b| {
            // VACASK: behavioral sources require Verilog-A modules (no B-source)
            try writer.writeAll("// [NOTE] Behavioral source requires Verilog-A module in VACASK\n");
            try writer.print("// B-source: {s} ({s} {s}) ", .{ b.name, b.p, b.n });
            switch (b.kind) {
                .voltage => try writer.print("V={s}", .{b.expr}),
                .current => try writer.print("I={s}", .{b.expr}),
            }
            try writer.writeByte('\n');
        },
        .vcvs => |e| {
            try writer.print("{s} ({s} {s} {s} {s}) vcvs gain=", .{ e.name, e.p, e.n, e.cp, e.cn });
            try e.gain.emit(writer);
            try writer.writeByte('\n');
        },
        .vccs => |g| {
            try writer.print("{s} ({s} {s} {s} {s}) vccs gain=", .{ g.name, g.p, g.n, g.cp, g.cn });
            try g.gain.emit(writer);
            try writer.writeByte('\n');
        },
        .ccvs => |h| {
            // VACASK CCVS: 4 terminals (out+, out-, sense+, sense-)
            // IR stores vsrc name — emit as comment with node reference
            try writer.print("{s} ({s} {s}) ccvs vsrc=\"{s}\" gain=", .{ h.name, h.p, h.n, h.vsrc });
            try h.gain.emit(writer);
            try writer.writeByte('\n');
        },
        .cccs => |f| {
            try writer.print("{s} ({s} {s}) cccs vsrc=\"{s}\" gain=", .{ f.name, f.p, f.n, f.vsrc });
            try f.gain.emit(writer);
            try writer.writeByte('\n');
        },
        .subcircuit => |s| {
            try writer.print("{s} (", .{s.inst_name});
            for (s.nodes, 0..) |node, i| {
                if (i > 0) try writer.writeByte(' ');
                try writer.print("{s}", .{node});
            }
            try writer.print(") {s}", .{s.name});
            for (s.params) |p| {
                try writer.print(" {s}=", .{p.name});
                try p.value.emit(writer);
            }
            try writer.writeByte('\n');
        },
        .raw => |line| try writer.print("{s}\n", .{line}),
    }
}

/// VACASK independent source emission (Spectre-like syntax).
/// Uses model names `vsrc`/`isrc` — netlist must declare `model vsrc vsource` etc.
fn emitVacaskSource(writer: anytype, src: IndependentSource) !void {
    const model_name: []const u8 = switch (src.kind) {
        .voltage => "vsrc",
        .current => "isrc",
    };
    try writer.print("{s} ({s} {s}) {s}", .{ src.name, src.p, src.n, model_name });
    if (src.dc) |dc| try writer.print(" dc={e}", .{dc});
    if (src.ac_mag) |ac| {
        try writer.print(" ac={e}", .{ac});
        if (src.ac_phase) |ph| try writer.print(" acphase={e}", .{ph});
    }
    if (src.waveform) |wf| switch (wf) {
        .pulse => |p| try writer.print(
            " type=\"pulse\" v0={e} v1={e} delay={e} rise={e} fall={e} width={e} period={e}",
            .{ p.v1, p.v2, p.delay, p.rise, p.fall, p.width, p.period },
        ),
        .sin => |s| {
            try writer.print(" type=\"sine\" ampl={e} freq={e}", .{ s.amplitude, s.freq });
            if (s.offset != 0) try writer.print(" dc={e}", .{s.offset});
        },
        .pwl => |pwl| {
            try writer.writeAll(" type=\"pwl\" wave=[");
            for (pwl.points, 0..) |pt, i| {
                if (i > 0) try writer.writeAll(", ");
                try writer.print("{e}, {e}", .{ pt[0], pt[1] });
            }
            try writer.writeByte(']');
        },
        .exp => |e| try writer.print(
            " type=\"exp\" v0={e} v1={e} td1={e} tau1={e} td2={e} tau2={e}",
            .{ e.v1, e.v2, e.td1, e.tau1, e.td2, e.tau2 },
        ),
        .sffm => |s| try writer.print(
            " type=\"sffm\" offset={e} ampl={e} carrier={e} mod={e} signal={e}",
            .{ s.offset, s.amplitude, s.carrier_freq, s.mod_index, s.signal_freq },
        ),
        .dc => |d| try writer.print(" dc={e}", .{d.dc}),
        .ac => |a| try writer.print(" ac={e} acphase={e}", .{ a.mag, a.phase }),
        .pat => try writer.writeAll(" // [NOTE] PAT source not supported in VACASK"),
    };
    try writer.writeByte('\n');
}

// =============================================================================
// Private Types — internal to Netlist / SpiceIF
// =============================================================================

// ─────────────────────────────────────────────────────────────────────────────
// Backend support metadata
// ─────────────────────────────────────────────────────────────────────────────

const Support = enum { native, emulated, unsupported };

const BackendSupport = struct {
    ngspice: Support,
    xyce: Support,
    vacask: Support,
};

// ─────────────────────────────────────────────────────────────────────────────
// Comptime function-name translation
// ─────────────────────────────────────────────────────────────────────────────

const ExprFuncMap = struct {
    universal: []const u8,
    ngspice: []const u8,
    xyce: []const u8,
    vacask: []const u8,
};

const expr_func_table = [_]ExprFuncMap{
    .{ .universal = "if", .ngspice = "ternary_fcn", .xyce = "IF", .vacask = "IF" },
    .{ .universal = "step", .ngspice = "u", .xyce = "stp", .vacask = "stp" },
    .{ .universal = "min", .ngspice = "min", .xyce = "MIN", .vacask = "MIN" },
    .{ .universal = "max", .ngspice = "max", .xyce = "MAX", .vacask = "MAX" },
    .{ .universal = "abs", .ngspice = "abs", .xyce = "ABS", .vacask = "ABS" },
    .{ .universal = "sqrt", .ngspice = "sqrt", .xyce = "SQRT", .vacask = "SQRT" },
    .{ .universal = "exp", .ngspice = "exp", .xyce = "EXP", .vacask = "EXP" },
    .{ .universal = "ln", .ngspice = "ln", .xyce = "LOG", .vacask = "LOG" },
    .{ .universal = "log10", .ngspice = "log", .xyce = "LOG10", .vacask = "LOG10" },
    .{ .universal = "sin", .ngspice = "sin", .xyce = "SIN", .vacask = "SIN" },
    .{ .universal = "cos", .ngspice = "cos", .xyce = "COS", .vacask = "COS" },
    .{ .universal = "tan", .ngspice = "tan", .xyce = "TAN", .vacask = "TAN" },
    .{ .universal = "atan", .ngspice = "atan", .xyce = "ATAN", .vacask = "ATAN" },
    .{ .universal = "atan2", .ngspice = "atan2", .xyce = "ATAN2", .vacask = "ATAN2" },
    .{ .universal = "pow", .ngspice = "pwr", .xyce = "PWR", .vacask = "PWR" },
    .{ .universal = "limit", .ngspice = "limit", .xyce = "LIMIT", .vacask = "LIMIT" },
    .{ .universal = "table", .ngspice = "table", .xyce = "TABLE", .vacask = "TABLE" },
    .{ .universal = "ddt", .ngspice = "ddt", .xyce = "DDT", .vacask = "DDT" },
    .{ .universal = "sdt", .ngspice = "idt", .xyce = "SDT", .vacask = "SDT" },
    .{ .universal = "agauss", .ngspice = "agauss", .xyce = "AGAUSS", .vacask = "AGAUSS" },
    .{ .universal = "gauss", .ngspice = "gauss", .xyce = "GAUSS", .vacask = "GAUSS" },
    .{ .universal = "aunif", .ngspice = "aunif", .xyce = "AUNIF", .vacask = "AUNIF" },
    .{ .universal = "unif", .ngspice = "unif", .xyce = "UNIF", .vacask = "UNIF" },
};

/// Comptime lookup: universal function name → backend-specific name.
pub fn translateFunc(comptime name: []const u8, comptime backend: Backend) []const u8 {
    for (expr_func_table) |entry| {
        if (std.mem.eql(u8, entry.universal, name)) {
            return switch (backend) {
                .ngspice => entry.ngspice,
                .xyce => entry.xyce,
                .vacask => entry.vacask,
                // .hspice => entry.hspice,
            };
        }
    }
    return name;
}

// ─────────────────────────────────────────────────────────────────────────────
// Source waveform types
// ─────────────────────────────────────────────────────────────────────────────

const SrcDC = struct { dc: f64 = 0 };
const SrcAC = struct { mag: f64 = 1, phase: f64 = 0 };
const SrcSin = struct { offset: f64 = 0, amplitude: f64, freq: f64, delay: f64 = 0, damping: f64 = 0, phase: f64 = 0 };
const SrcPulse = struct { v1: f64, v2: f64, delay: f64 = 0, rise: f64 = 0, fall: f64 = 0, width: f64, period: f64 };
const SrcPWL = struct { points: []const [2]f64 };
const SrcSFFM = struct { offset: f64 = 0, amplitude: f64, carrier_freq: f64, mod_index: f64 = 0, signal_freq: f64 = 0 };
const SrcEXP = struct { v1: f64, v2: f64, td1: f64 = 0, tau1: f64, td2: f64 = 0, tau2: f64 };

/// Pattern source — Xyce native, ngspice/vacask emulated via PWL.
const SrcPAT = struct {
    vhi: f64,
    vlo: f64 = 0,
    delay: f64 = 0,
    rise: f64 = 0,
    fall: f64 = 0,
    bit_period: f64,
    pattern: []const u8,
    pub const support = BackendSupport{ .ngspice = .emulated, .xyce = .native, .vacask = .unsupported };
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

/// An independent voltage (V) or current (I) source.
/// This type is `pub` so Devices.zig can construct one directly.
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

// ─────────────────────────────────────────────────────────────────────────────
// Internal Netlist-only component aliases (kept private; external code uses
// SpiceComponent instead)
// ─────────────────────────────────────────────────────────────────────────────

// These mirror the original types 1-to-1 so the Netlist IR is unchanged.
// Conversion to SpiceComponent happens in emitComponent (Netlist path).

/// Internal alias — Netlist stores SpiceComponent directly.
const Component = SpiceComponent;

// ─────────────────────────────────────────────────────────────────────────────
// Analysis types
// ─────────────────────────────────────────────────────────────────────────────

pub const SweepKind = enum { lin, dec, oct };

pub const AnalysisOP = struct {
    pub const support = BackendSupport{ .ngspice = .native, .xyce = .native, .vacask = .native };
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
    pub const support = BackendSupport{ .ngspice = .native, .xyce = .native, .vacask = .native };
};
pub const AnalysisAC = struct {
    sweep: SweepKind = .dec,
    n_points: u32,
    f_start: f64,
    f_stop: f64,
    pub const support = BackendSupport{ .ngspice = .native, .xyce = .native, .vacask = .native };
};
pub const AnalysisTran = struct {
    step: f64,
    stop: f64,
    start: f64 = 0,
    max_step: ?f64 = null,
    uic: bool = false,
    pub const support = BackendSupport{ .ngspice = .native, .xyce = .native, .vacask = .native };
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
    pub const support = BackendSupport{ .ngspice = .native, .xyce = .native, .vacask = .native };
};
const AnalysisSens = struct {
    output_var: []const u8,
    mode: enum { dc, ac, tran, tran_adjoint } = .dc,
    ac_sweep: ?SweepKind = null,
    ac_n_points: ?u32 = null,
    ac_f_start: ?f64 = null,
    ac_f_stop: ?f64 = null,
    pub const support = BackendSupport{ .ngspice = .emulated, .xyce = .native, .vacask = .unsupported };
};
const AnalysisTF = struct {
    output_var: []const u8,
    input_src: []const u8,
    pub const support = BackendSupport{ .ngspice = .native, .xyce = .native, .vacask = .native };
};
const AnalysisPZ = struct {
    in_pos: []const u8,
    in_neg: []const u8,
    out_pos: []const u8,
    out_neg: []const u8,
    tf_type: enum { vol, cur },
    pz_type: enum { pol, zer, pz },
    pub const support = BackendSupport{ .ngspice = .native, .xyce = .unsupported, .vacask = .unsupported };
};
const AnalysisDisto = struct {
    sweep: SweepKind = .dec,
    n_points: u32,
    f_start: f64,
    f_stop: f64,
    f2_over_f1: ?f64 = null,
    pub const support = BackendSupport{ .ngspice = .native, .xyce = .unsupported, .vacask = .unsupported };
};
const AnalysisPSS = struct {
    gfreq: f64,
    tstab: f64,
    fft_points: u32 = 1024,
    harms: u32 = 10,
    sciter: u32 = 150,
    steadycoeff: f64 = 1e-3,
    pub const support = BackendSupport{ .ngspice = .native, .xyce = .unsupported, .vacask = .unsupported };
};
const AnalysisSP = struct {
    sweep: SweepKind = .dec,
    n_points: u32,
    f_start: f64,
    f_stop: f64,
    pub const support = BackendSupport{ .ngspice = .native, .xyce = .native, .vacask = .unsupported };
};
const AnalysisHB = struct {
    freqs: []const f64,
    n_harmonics: u32 = 7,
    startup: bool = false,
    startup_periods: ?u32 = null,
    pub const support = BackendSupport{ .ngspice = .unsupported, .xyce = .native, .vacask = .native };
};
const AnalysisMPDE = struct {
    fast_freqs: []const f64,
    oscsrc: ?[]const u8 = null,
    pub const support = BackendSupport{ .ngspice = .unsupported, .xyce = .native, .vacask = .unsupported };
};
const AnalysisFour = struct {
    freq: f64,
    nodes: []const []const u8,
    pub const support = BackendSupport{ .ngspice = .native, .xyce = .native, .vacask = .unsupported };
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

// ─────────────────────────────────────────────────────────────────────────────
// Sweep / UQ types
// ─────────────────────────────────────────────────────────────────────────────

const StepSweep = struct {
    param: []const u8,
    kind: union(enum) {
        lin: struct { start: f64, stop: f64, step: f64 },
        dec: struct { start: f64, stop: f64, points: u32 },
        oct: struct { start: f64, stop: f64, points: u32 },
        list: struct { values: []const f64 },
    },
    pub const support = BackendSupport{ .ngspice = .emulated, .xyce = .native, .vacask = .native };
};

const Distribution = union(enum) {
    normal: struct { mean: f64, std_dev: f64 },
    uniform: struct { lo: f64, hi: f64 },
    lognormal: struct { mean: f64, std_dev: f64 },
};

const SamplingParam = struct { name: []const u8, dist: Distribution };
const Sampling = struct {
    num_samples: u32 = 100,
    method: enum { mc, lhs } = .mc,
    params: []const SamplingParam,
    pub const support = BackendSupport{ .ngspice = .emulated, .xyce = .native, .vacask = .unsupported };
};
const EmbeddedSampling = struct {
    num_samples: u32 = 100,
    params: []const SamplingParam,
    pub const support = BackendSupport{ .ngspice = .unsupported, .xyce = .native, .vacask = .unsupported };
};
const PCE = struct {
    order: u32 = 3,
    method: enum { regression, nisp, intrusive } = .regression,
    sample_count: ?u32 = null,
    params: []const SamplingParam,
    pub const support = BackendSupport{ .ngspice = .unsupported, .xyce = .native, .vacask = .unsupported };
};
const DataTable = struct {
    name: []const u8,
    param_names: []const []const u8,
    rows: []const []const f64,
    pub const support = BackendSupport{ .ngspice = .emulated, .xyce = .native, .vacask = .unsupported };
};

pub const Sweep = union(enum) {
    step: StepSweep,
    sampling: Sampling,
    embedded_sampling: EmbeddedSampling,
    pce: PCE,
    data: DataTable,
};

// ─────────────────────────────────────────────────────────────────────────────
// Measure types
// ─────────────────────────────────────────────────────────────────────────────

pub const MeasureMode = enum { tran, ac, dc, noise };
const MeasureTrig = struct { trig_var: []const u8, trig_val: f64, targ_var: []const u8, targ_val: f64, rise: ?u32 = null, fall: ?u32 = null, cross: ?u32 = null };
const MeasureFind = struct { var_name: []const u8, at: f64 };
const MeasureMinMax = struct { var_name: []const u8, kind: enum { min, max, pp, avg, rms, integ }, from: ?f64 = null, to: ?f64 = null };
const MeasureWhen = struct { var_name: []const u8, val: f64, rise: ?u32 = null, fall: ?u32 = null, cross: ?u32 = null };
pub const Measure = struct {
    name: []const u8,
    mode: MeasureMode,
    kind: union(enum) { trig_targ: MeasureTrig, find: MeasureFind, min_max: MeasureMinMax, when: MeasureWhen },
    pub const support = BackendSupport{ .ngspice = .native, .xyce = .native };
};

// ─────────────────────────────────────────────────────────────────────────────
// Model / Param / Print / Save / Option / Include / Library
// ─────────────────────────────────────────────────────────────────────────────

const ModelParam = struct { name: []const u8, value: Value };
const ModelDef = struct { name: []const u8, kind: []const u8, level: ?u32 = null, version: ?[]const u8 = null, params: []const ModelParam };
const Param = struct { name: []const u8, value: Value, global: bool = false };
const PrintDirective = struct { mode: MeasureMode, vars: []const []const u8, format: ?[]const u8 = null };
const SaveDirective = struct { vars: []const []const u8, all: bool = false };
const Option = struct { name: []const u8, value: ?Value = null };
const Include = struct { path: []const u8 };
const Library = struct { path: []const u8, section: ?[]const u8 = null };

// ─────────────────────────────────────────────────────────────────────────────
// Simulator error set
// ─────────────────────────────────────────────────────────────────────────────

const SimulatorError = error{ SimulatorNotAvailable, LoadNetlistFailed, RunFailed };

// =============================================================================
// Public re-exports
// =============================================================================

pub const Netlist = NetlistType;
pub const Simulator = SimulatorType;
pub const RunResult = RunResultType;

pub const ComponentType = SpiceComponent;

// =============================================================================
// Netlist type
// =============================================================================

const NetlistType = struct {
    allocator: Allocator,
    title: []const u8 = "Universal SPICE netlist",

    params: std.ArrayListUnmanaged(Param) = .{},
    options: std.ArrayListUnmanaged(Option) = .{},
    includes: std.ArrayListUnmanaged(Include) = .{},
    libs: std.ArrayListUnmanaged(Library) = .{},
    models: std.ArrayListUnmanaged(ModelDef) = .{},
    components: std.ArrayListUnmanaged(Component) = .{},
    analyses: std.ArrayListUnmanaged(Analysis) = .{},
    sweeps: std.ArrayListUnmanaged(Sweep) = .{},
    measures: std.ArrayListUnmanaged(Measure) = .{},
    prints: std.ArrayListUnmanaged(PrintDirective) = .{},
    saves: std.ArrayListUnmanaged(SaveDirective) = .{},
    raw_lines: std.ArrayListUnmanaged([]const u8) = .{},
    code_blocks: std.ArrayListUnmanaged([]const u8) = .{},
    toplevel_code_blocks: std.ArrayListUnmanaged([]const u8) = .{},
    tcl_vars: std.StringHashMapUnmanaged([]const u8) = .{},

    pub fn init(allocator: Allocator) NetlistType {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *NetlistType) void {
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

    // ── Builder API ──────────────────────────────────────────────────────── //

    pub fn addParam(self: *NetlistType, param: Param) !void {
        try self.params.append(self.allocator, param);
    }
    pub fn addOption(self: *NetlistType, opt: Option) !void {
        try self.options.append(self.allocator, opt);
    }
    pub fn addInclude(self: *NetlistType, inc: Include) !void {
        try self.includes.append(self.allocator, inc);
    }
    pub fn addLib(self: *NetlistType, lib: Library) !void {
        try self.libs.append(self.allocator, lib);
    }
    pub fn addModel(self: *NetlistType, model: ModelDef) !void {
        try self.models.append(self.allocator, model);
    }
    pub fn addComponent(self: *NetlistType, comp: Component) !void {
        try self.components.append(self.allocator, comp);
    }
    pub fn addSource(self: *NetlistType, src: IndependentSource) !void {
        try self.components.append(self.allocator, .{ .independent_source = src });
    }
    pub fn addAnalysis(self: *NetlistType, an: Analysis) !void {
        try self.analyses.append(self.allocator, an);
    }
    pub fn addSweep(self: *NetlistType, sw: Sweep) !void {
        try self.sweeps.append(self.allocator, sw);
    }
    pub fn addMeasure(self: *NetlistType, meas: Measure) !void {
        try self.measures.append(self.allocator, meas);
    }
    pub fn addPrint(self: *NetlistType, p: PrintDirective) !void {
        try self.prints.append(self.allocator, p);
    }
    pub fn addSave(self: *NetlistType, s: SaveDirective) !void {
        try self.saves.append(self.allocator, s);
    }
    pub fn addRaw(self: *NetlistType, line: []const u8) !void {
        try self.raw_lines.append(self.allocator, line);
    }
    pub fn addCodeBlock(self: *NetlistType, block: []const u8) !void {
        try self.code_blocks.append(self.allocator, block);
    }

    pub fn addToplevelCodeBlock(self: *NetlistType, block: []const u8) !void {
        for (self.toplevel_code_blocks.items) |existing| {
            if (std.mem.eql(u8, existing, block)) return;
        }
        try self.toplevel_code_blocks.append(self.allocator, block);
    }

    // ── Validation ───────────────────────────────────────────────────────── //

    pub const Diagnostic = struct {
        feature: []const u8,
        level: enum { warning, err },
        message: []const u8,
    };

    pub fn validate(self: *const NetlistType, backend: Backend) !std.ArrayListUnmanaged(Diagnostic) {
        var diags = std.ArrayListUnmanaged(Diagnostic){};

        for (self.analyses.items) |an| {
            switch (pickSupport(backend, an.getSupport())) {
                .unsupported => try diags.append(self.allocator, .{ .feature = @tagName(an), .level = .err, .message = "Analysis not supported on target backend" }),
                .emulated => try diags.append(self.allocator, .{ .feature = @tagName(an), .level = .warning, .message = "Analysis will be emulated (may differ in fidelity)" }),
                .native => {},
            }
        }
        for (self.sweeps.items) |sw| {
            switch (pickSupport(backend, sweepSupport(sw))) {
                .unsupported => try diags.append(self.allocator, .{ .feature = @tagName(sw), .level = .err, .message = "Sweep/UQ type not supported on target backend" }),
                .emulated => try diags.append(self.allocator, .{ .feature = @tagName(sw), .level = .warning, .message = "Sweep/UQ will be emulated via control loops" }),
                .native => {},
            }
        }
        return diags;
    }

    // ── Emission ─────────────────────────────────────────────────────────── //

    pub const EmitError = error{ UnsupportedFeature, OutOfMemory } || std.fmt.BufPrintError || Allocator.Error;

    pub fn emit(self: *const NetlistType, backend: Backend, allocator: Allocator) EmitError![]u8 {
        var buf = std.ArrayListUnmanaged(u8){};
        errdefer buf.deinit(allocator);
        try self.emitTo(buf.writer(allocator), backend);
        return buf.toOwnedSlice(allocator);
    }

    pub fn emitTo(self: *const NetlistType, writer: anytype, backend: Backend) !void {
        const bh = @import("backend/lib.zig").BackendHandle.initBackend(backend);

        try writer.print("{s}\n", .{self.title});

        for (self.includes.items) |inc| try writer.print(".include {s}\n", .{inc.path});
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

        for (self.components.items) |comp| try bh.emitNetlistComponent(writer, comp);
        for (self.analyses.items) |an| try bh.emitAnalysis(writer, an);
        for (self.sweeps.items) |sw| try bh.emitSweep(writer, sw);
        for (self.measures.items) |meas| try emitMeasureShared(writer, meas);
        for (self.prints.items) |p| try emitPrintShared(writer, p);

        for (self.saves.items) |s| {
            try writer.writeAll(".save");
            if (s.all) {
                try writer.writeAll(" all");
            } else {
                for (s.vars) |v| try writer.print(" {s}", .{v});
            }
            try writer.writeByte('\n');
        }

        for (self.analyses.items) |an| {
            if (an == .four) {
                try writer.print(".four {e}", .{an.four.freq});
                for (an.four.nodes) |node| try writer.print(" {s}", .{node});
                try writer.writeByte('\n');
            }
        }

        for (self.raw_lines.items) |line| try writer.print("{s}\n", .{line});

        for (self.code_blocks.items) |block| {
            try writer.writeAll("**** begin user architecture code\n");
            try writer.print("{s}\n", .{std.mem.trimRight(u8, block, "\n\r")});
            try writer.writeAll("**** end user architecture code\n");
        }

        if (backend == .ngspice) try bh.emitNgspiceControlSection(writer, self);

        try writer.writeAll(".end\n");
    }

    pub fn emitToplevelCodeBlocks(self: *const NetlistType, writer: anytype) !void {
        for (self.toplevel_code_blocks.items) |block|
            try writer.print("{s}\n", .{std.mem.trimRight(u8, block, "\n\r")});
    }
};

// =============================================================================
// Simulator type
// =============================================================================

const SimulatorType = struct {
    backend: Backend,
    netlist_path: ?[]const u8 = null,

    pub const Error = SimulatorError;
    pub const InitOptions = struct {};

    pub fn init(backend: Backend, _: InitOptions) SimulatorType {
        return .{ .backend = backend };
    }

    pub fn deinit(_: *SimulatorType) void {}

    pub fn loadNetlist(self: *SimulatorType, path: []const u8) void {
        self.netlist_path = path;
    }

    pub fn run(self: *SimulatorType) SimulatorError!void {
        const path = self.netlist_path orelse return error.LoadNetlistFailed;
        const bh = @import("backend/lib.zig").BackendHandle.initBackend(self.backend);
        const result = bh.run(std.heap.page_allocator, path) catch return error.RunFailed;
        if (!result.success) return error.RunFailed;
    }
};

// =============================================================================
// RunResult type
// =============================================================================

const RunResultType = struct {
    diagnostics: std.ArrayListUnmanaged(Netlist.Diagnostic),
    netlist_text: []u8,

    pub fn deinit(self: *RunResultType, allocator: Allocator) void {
        self.diagnostics.deinit(allocator);
        allocator.free(self.netlist_text);
    }
};

// =============================================================================
// Public Type — SpiceIF
// =============================================================================

/// Wraps a `Simulator` and provides a typed `run()` entry point that accepts
/// a `Netlist` instead of a raw SPICE string.
///
/// To add HSpice:
///   - Add `initHSpice` mirroring `initNgspice`.
///   - The run() logic is backend-agnostic — no changes needed there.
pub const SpiceIF = struct {
    sim: Simulator,

    pub const RunError = Netlist.EmitError || SimulatorError;

    pub fn initNgspice(opts: Simulator.InitOptions) SpiceIF {
        return .{ .sim = Simulator.init(.ngspice, opts) };
    }
    pub fn initXyce(opts: Simulator.InitOptions) SpiceIF {
        return .{ .sim = Simulator.init(.xyce, opts) };
    }
    pub fn initVacask(opts: Simulator.InitOptions) SpiceIF {
        return .{ .sim = Simulator.init(.vacask, opts) };
    }

    pub fn deinit(self: *SpiceIF) void {
        self.sim.deinit();
    }

    /// Validate → emit → write temp file → load → run.
    /// Returns diagnostics (warnings for emulated features) and the emitted text.
    pub fn run(self: *SpiceIF, nl: *const Netlist, allocator: Allocator) RunError!RunResult {
        const diags = try nl.validate(self.sim.backend);
        for (diags.items) |d| {
            if (d.level == .err) return error.UnsupportedFeature;
        }

        const text = try nl.emit(self.sim.backend, allocator);
        errdefer allocator.free(text);

        const tmp_path = "/tmp/_schemify_spice_netlist.cir";
        Vfs.writeAll(tmp_path, text) catch return error.RunFailed;
        self.sim.loadNetlist(tmp_path);
        try self.sim.run();

        return .{ .diagnostics = diags, .netlist_text = text };
    }
};

// =============================================================================
// Shared Helper Functions (used by both emitTo and backend modules)
// =============================================================================

inline fn pickSupport(backend: Backend, sup: BackendSupport) Support {
    return switch (backend) {
        .ngspice => sup.ngspice,
        .xyce => sup.xyce,
        .vacask => sup.vacask,
    };
}

pub fn measureModeStr(mode: MeasureMode) []const u8 {
    return switch (mode) {
        .tran => "TRAN",
        .ac => "AC",
        .dc => "DC",
        .noise => "NOISE",
    };
}

fn sweepSupport(sw: Sweep) BackendSupport {
    const tag = std.meta.activeTag(sw);
    inline for (std.meta.fields(Sweep)) |f| {
        if (@field(std.meta.Tag(Sweep), f.name) == tag) return f.type.support;
    }
    unreachable;
}

pub fn sweepStr(k: SweepKind) []const u8 {
    return switch (k) {
        .lin => "lin",
        .dec => "dec",
        .oct => "oct",
    };
}

/// Emit a SPICE independent source line (ngspice/Xyce syntax).
/// Used by `emitComponent(.independent_source)` for non-VACASK backends.
pub fn emitIndependentSource(writer: anytype, src: IndependentSource) !void {
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
            .pulse => |p| try writer.print(" PULSE({e} {e} {e} {e} {e} {e} {e})", .{ p.v1, p.v2, p.delay, p.rise, p.fall, p.width, p.period }),
            .pwl => |pwl| {
                try writer.writeAll(" PWL(");
                for (pwl.points, 0..) |pt, i| {
                    if (i > 0) try writer.writeByte(' ');
                    try writer.print("{e} {e}", .{ pt[0], pt[1] });
                }
                try writer.writeByte(')');
            },
            .exp => |e| try writer.print(" EXP({e} {e} {e} {e} {e} {e})", .{ e.v1, e.v2, e.td1, e.tau1, e.td2, e.tau2 }),
            .sffm => |s| try writer.print(" SFFM({e} {e} {e} {e} {e})", .{ s.offset, s.amplitude, s.carrier_freq, s.mod_index, s.signal_freq }),
            .dc => |d| try writer.print(" dc {e}", .{d.dc}),
            .ac => |a| try writer.print(" ac {e} {e}", .{ a.mag, a.phase }),
            .pat => |p| try writer.print(" PAT({e} {e} {e} {e} {e} {e} b{s})", .{ p.vhi, p.vlo, p.delay, p.rise, p.fall, p.bit_period, p.pattern }),
        }
    }
    try writer.writeByte('\n');
    if (src.save_current) {
        try writer.writeAll(".save i(");
        for (src.name) |c| try writer.writeByte(std.ascii.toLower(c));
        try writer.writeAll(")\n");
    }
}

/// Emit a .meas directive (backend-agnostic, SPICE syntax).
pub fn emitMeasureShared(writer: anytype, meas: Measure) !void {
    try writer.print(".meas {s} {s} ", .{ measureModeStr(meas.mode), meas.name });
    switch (meas.kind) {
        .trig_targ => |tt| {
            try writer.print("TRIG {s} VAL={e}", .{ tt.trig_var, tt.trig_val });
            if (tt.rise) |r| try writer.print(" RISE={d}", .{r});
            if (tt.fall) |f| try writer.print(" FALL={d}", .{f});
            if (tt.cross) |cr| try writer.print(" CROSS={d}", .{cr});
            try writer.print(" TARG {s} VAL={e}", .{ tt.targ_var, tt.targ_val });
        },
        .find => |f| try writer.print("FIND {s} AT={e}", .{ f.var_name, f.at }),
        .min_max => |mm| {
            const op_lower = @tagName(mm.kind);
            var op_buf: [8]u8 = undefined;
            const op = std.ascii.upperString(op_buf[0..op_lower.len], op_lower);
            try writer.print("{s} {s}", .{ op, mm.var_name });
            if (mm.from) |f| try writer.print(" FROM={e}", .{f});
            if (mm.to) |t| try writer.print(" TO={e}", .{t});
        },
        .when => |w| {
            try writer.print("WHEN {s}={e}", .{ w.var_name, w.val });
            if (w.rise) |r| try writer.print(" RISE={d}", .{r});
            if (w.fall) |f| try writer.print(" FALL={d}", .{f});
            if (w.cross) |cr| try writer.print(" CROSS={d}", .{cr});
        },
    }
    try writer.writeByte('\n');
}

/// Emit a .print directive (backend-agnostic, SPICE syntax).
pub fn emitPrintShared(writer: anytype, p: PrintDirective) !void {
    try writer.print(".print {s}", .{measureModeStr(p.mode)});
    if (p.format) |fmt| try writer.print(" FORMAT={s}", .{fmt});
    for (p.vars) |v| try writer.print(" {s}", .{v});
    try writer.writeByte('\n');
}

test "struct sizes" {
    std.debug.print("Netlist:        {d}B\n", .{@sizeOf(Netlist)});
    std.debug.print("Component:      {d}B\n", .{@sizeOf(Component)});
    std.debug.print("SpiceComponent: {d}B\n", .{@sizeOf(SpiceComponent)});
    std.debug.print("Analysis:       {d}B\n", .{@sizeOf(Analysis)});
    std.debug.print("Sweep:          {d}B\n", .{@sizeOf(Sweep)});
    std.debug.print("Simulator:      {d}B\n", .{@sizeOf(Simulator)});
    std.debug.print("RunResult:      {d}B\n", .{@sizeOf(RunResult)});
}

// =============================================================================
// Tests
// =============================================================================

test "basic netlist emit ngspice" {
    const allocator = std.testing.allocator;
    var nl = Netlist.init(allocator);
    defer nl.deinit();

    try nl.addParam(.{ .name = "Rload", .value = .{ .literal = 10e3 } });
    try nl.addComponent(.{ .resistor = .{ .name = "R1", .p = "out", .n = "0", .value = .{ .param = "Rload" } } });
    try nl.addSource(.{ .name = "V1", .kind = .voltage, .p = "in", .n = "0", .dc = 5.0 });
    try nl.addAnalysis(.{ .tran = .{ .step = 1e-6, .stop = 1e-3 } });

    const text = try nl.emit(.ngspice, allocator);
    defer allocator.free(text);
    try std.testing.expect(text.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, text, ".tran") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, ".end") != null);
}

test "emitComponent standalone — resistor" {
    const allocator = std.testing.allocator;
    var buf = std.ArrayListUnmanaged(u8){};
    defer buf.deinit(allocator);

    const comp = SpiceComponent{ .resistor = .{
        .name = "R1",
        .p = "a",
        .n = "b",
        .value = .{ .literal = 1e3 },
    } };
    try emitComponent(buf.writer(allocator), comp, .ngspice);
    const text = buf.items;
    try std.testing.expect(std.mem.startsWith(u8, text, "R1 a b"));
}

test "comptime func translation" {
    try std.testing.expectEqualStrings("u", comptime translateFunc("step", .ngspice));
    try std.testing.expectEqualStrings("stp", comptime translateFunc("step", .xyce));
    try std.testing.expectEqualStrings("ternary_fcn", comptime translateFunc("if", .ngspice));
    try std.testing.expectEqualStrings("IF", comptime translateFunc("if", .xyce));
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
