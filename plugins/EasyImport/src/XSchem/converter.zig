// converter.zig - XSchem Schematic → core.Schemify conversion.
//
// Maps XSchem DOD elements (f64 coords) to Schemify DOD elements (i32 coords)
// using the Schemify high-level builder API (drawLine, drawRect, addComponent, etc.)
// instead of directly writing to MultiArrayLists. This ensures that all inputs
// pass through Schemify's validation/normalization path.

const std = @import("std");
const core = @import("core");
const Schemify = core.Schemify;
const types = @import("types.zig");
const XSchemFiles = types.XSchemFiles;
const tcl = @import("tcl");

const Allocator = std.mem.Allocator;

fn f2i(v: f64) i32 {
    return @intFromFloat(@round(v));
}

fn layerU8(v: i32) u8 {
    return @intCast(@max(0, @min(255, v)));
}

/// Resolves an XSchem symbol name (e.g. "nmos4.sym", "devices/res.sym") to a
/// parsed XSchemFiles. The resolver owns the returned data; caller must deinit.
pub const SymResolver = struct {
    ctx: *anyopaque,
    resolveFn: *const fn (ctx: *anyopaque, sym_path: []const u8) ?XSchemFiles,

    pub fn resolve(self: SymResolver, sym_path: []const u8) ?XSchemFiles {
        return self.resolveFn(self.ctx, sym_path);
    }
};

/// Convert an XSchem Schematic (and optional symbol) into a core.Schemify object.
/// The symbol provides external interface (pins, K-block) while the schematic
/// provides internal implementation (instances, wires, geometry).
/// If sym_resolver is provided, instance symbols are resolved to populate
/// sym_data (pin positions) and DeviceKind for net connectivity.
pub fn convert(
    backing: Allocator,
    schematic: *const XSchemFiles,
    symbol: ?*const XSchemFiles,
    name: []const u8,
    sym_resolver: ?SymResolver,
) Allocator.Error!Schemify {
    var sfy = Schemify.init(backing);
    errdefer sfy.deinit();

    sfy.setName(name);

    // Determine stype from symbol K-block (prefer symbol, fall back to schematic)
    if (symbol) |sym| {
        sfy.setStype(if (sym.k_type) |kt|
            (if (std.mem.eql(u8, kt, "subcircuit")) .component else .primitive)
        else
            .component);
    } else if (schematic.k_type) |kt| {
        // Some .sch files have their own K-block (e.g. bus_keeper.sch with
        // type=subcircuit). Use it when no .sym is available.
        sfy.setStype(if (std.mem.eql(u8, kt, "subcircuit")) .component else .primitive);
    } else {
        sfy.setStype(.testbench);
    }

    // Map geometry from schematic
    try mapLines(&sfy, schematic);
    try mapRects(&sfy, schematic);
    try mapArcs(&sfy, schematic);
    try mapCircles(&sfy, schematic);
    try mapWires(&sfy, schematic);
    try mapTexts(&sfy, schematic);

    // Pins come from symbol (external interface) or schematic (testbench)
    if (symbol) |sym| {
        try mapPins(&sfy, sym);
        try mapKBlock(&sfy, sym);
    } else {
        try mapPins(&sfy, schematic);
        // Also map K-block from schematic if it has one (e.g. .sch files
        // used as symbols that have their own K-block with type/format/template)
        try mapKBlock(&sfy, schematic);
    }

    // Instances, properties, and sym_data from schematic
    try mapInstances(&sfy, schematic, sym_resolver);

    // Map S-block (raw SPICE body) from schematic
    if (schematic.s_block) |sb| {
        sfy.spice_body = sb;
    }

    // Generate subckt ports from ipin/opin/iopin instances (if no B 5 pins exist)
    if (sfy.pins.len == 0) {
        try mapPortPins(&sfy);
    }

    return sfy;
}

// ── Element mapping helpers ──────────────────────────────────────────────

fn mapLines(sfy: *Schemify, src: *const XSchemFiles) Allocator.Error!void {
    const sl = src.lines.slice();
    for (0..src.lines.len) |i| {
        try sfy.drawLine(.{
            .layer = layerU8(sl.items(.layer)[i]),
            .x0 = f2i(sl.items(.x0)[i]),
            .y0 = f2i(sl.items(.y0)[i]),
            .x1 = f2i(sl.items(.x1)[i]),
            .y1 = f2i(sl.items(.y1)[i]),
        });
    }
}

fn mapRects(sfy: *Schemify, src: *const XSchemFiles) Allocator.Error!void {
    const sl = src.rects.slice();
    for (0..src.rects.len) |i| {
        try sfy.drawRect(.{
            .layer = layerU8(sl.items(.layer)[i]),
            .x0 = f2i(sl.items(.x0)[i]),
            .y0 = f2i(sl.items(.y0)[i]),
            .x1 = f2i(sl.items(.x1)[i]),
            .y1 = f2i(sl.items(.y1)[i]),
        });
    }
}

fn mapArcs(sfy: *Schemify, src: *const XSchemFiles) Allocator.Error!void {
    const sl = src.arcs.slice();
    for (0..src.arcs.len) |i| {
        try sfy.drawArc(.{
            .layer = layerU8(sl.items(.layer)[i]),
            .cx = f2i(sl.items(.cx)[i]),
            .cy = f2i(sl.items(.cy)[i]),
            .radius = f2i(sl.items(.radius)[i]),
            .start_angle = @intFromFloat(@round(sl.items(.start_angle)[i])),
            .sweep_angle = @intFromFloat(@round(sl.items(.sweep_angle)[i])),
        });
    }
}

fn mapCircles(sfy: *Schemify, src: *const XSchemFiles) Allocator.Error!void {
    const sl = src.circles.slice();
    for (0..src.circles.len) |i| {
        try sfy.drawCircle(.{
            .layer = layerU8(sl.items(.layer)[i]),
            .cx = f2i(sl.items(.cx)[i]),
            .cy = f2i(sl.items(.cy)[i]),
            .radius = f2i(sl.items(.radius)[i]),
        });
    }
}

fn mapWires(sfy: *Schemify, src: *const XSchemFiles) Allocator.Error!void {
    const sl = src.wires.slice();
    for (0..src.wires.len) |i| {
        try sfy.addWire(.{
            .x0 = f2i(sl.items(.x0)[i]),
            .y0 = f2i(sl.items(.y0)[i]),
            .x1 = f2i(sl.items(.x1)[i]),
            .y1 = f2i(sl.items(.y1)[i]),
            .net_name = sl.items(.net_name)[i],
            .bus = sl.items(.bus)[i],
        });
    }
}

fn mapTexts(sfy: *Schemify, src: *const XSchemFiles) Allocator.Error!void {
    const sl = src.texts.slice();
    for (0..src.texts.len) |i| {
        try sfy.drawText(.{
            .content = sl.items(.content)[i],
            .x = f2i(sl.items(.x)[i]),
            .y = f2i(sl.items(.y)[i]),
            .layer = layerU8(sl.items(.layer)[i]),
            .size = @intFromFloat(@round(sl.items(.size)[i] * 25.0)),
            .rotation = @intCast(@mod(sl.items(.rotation)[i], 4)),
        });
    }
}

fn mapPins(sfy: *Schemify, src: *const XSchemFiles) Allocator.Error!void {
    const sl = src.pins.slice();
    for (0..src.pins.len) |i| {
        try sfy.drawPin(.{
            .name = sl.items(.name)[i],
            .x = f2i(sl.items(.x)[i]),
            .y = f2i(sl.items(.y)[i]),
            .dir = @enumFromInt(@intFromEnum(sl.items(.direction)[i])),
            .num = if (sl.items(.number)[i]) |n| @intCast(n) else null,
        });
    }
}

fn mapInstances(sfy: *Schemify, src: *const XSchemFiles, sym_resolver: ?SymResolver) Allocator.Error!void {
    const a = sfy.alloc();

    const sl = src.instances.slice();
    for (0..src.instances.len) |i| {
        const xs_ps = sl.items(.prop_start)[i];
        const xs_pc = sl.items(.prop_count)[i];

        // Build Prop slice from XSchem props (key→key, value→val).
        // addComponent dupes these into the arena.
        const props = try a.alloc(core.Prop, xs_pc);
        for (src.props.items[xs_ps..][0..xs_pc], 0..) |p, pi| {
            props[pi] = .{ .key = p.key, .val = p.value };
        }

        // Extract symbol stem name (strip path and .sym extension)
        const raw_sym = sl.items(.symbol)[i];
        // If the instance has a `schematic` property, use its stem as the
        // symbol name. XSchem uses this attribute to assign a unique subcircuit
        // name when multiple instances share the same symbol but have different
        // parameter overrides (e.g. schematic=test_evaluated_param2.sch).
        const sch_override = findPropValue(props, "schematic");
        const sym_name = if (sch_override.len > 0) stemFromPath(sch_override) else stemFromPath(raw_sym);

        // Common fields shared by both resolved and unresolved paths
        const inst_name = sl.items(.name)[i];
        const inst_x = f2i(sl.items(.x)[i]);
        const inst_y = f2i(sl.items(.y)[i]);
        const inst_rot: u2 = @intCast(@mod(sl.items(.rot)[i], 4));
        const inst_flip = sl.items(.flip)[i];

        // Resolve DeviceKind from symbol name
        var kind = core.DeviceKind.fromStr(sym_name);

        // Detect label-type instances early (before symbol resolution) using
        // stem name.  If the stem is a known label type, inject a zero-length
        // wire at the instance position with the `lab` property as net name.
        // This ensures that the resolveNets union-find sees the label position
        // and connects it to nearby device pins and wires.
        const is_stem_label = isLabelStem(sym_name);
        if (is_stem_label) {
            const lab = findPropValue(props, "lab");
            if (lab.len > 0) {
                try sfy.addWire(.{
                    .x0 = inst_x,
                    .y0 = inst_y,
                    .x1 = inst_x,
                    .y1 = inst_y,
                    .net_name = lab,
                });
            }
        }

        // Try to resolve symbol for pin positions and K-block metadata.
        // addComponent must be called while resolved_sym is still alive,
        // because sym_data strings point into it and are duped by the builder.
        if (sym_resolver) |resolver| {
            if (resolver.resolve(raw_sym)) |resolved_sym| {
                defer {
                    var rs = resolved_sym;
                    rs.deinit();
                }
                var sd: core.SymData = .{};

                // Extract pins as PinRef entries
                if (resolved_sym.pins.len > 0) {
                    const pin_sl = resolved_sym.pins.slice();
                    const pin_refs = try a.alloc(core.PinRef, resolved_sym.pins.len);
                    for (0..resolved_sym.pins.len) |pi| {
                        pin_refs[pi] = .{
                            .name = pin_sl.items(.name)[pi],
                            .dir = @enumFromInt(@intFromEnum(pin_sl.items(.direction)[pi])),
                            .x = f2i(pin_sl.items(.x)[pi]),
                            .y = f2i(pin_sl.items(.y)[pi]),
                        };
                    }
                    sd.pins = pin_refs;
                }

                // Extract format/template from resolved symbol's K-block
                if (resolved_sym.k_format) |fmt|
                    sd.format = fmt;
                if (resolved_sym.k_template) |tmpl|
                    sd.template = tmpl;

                // Refine DeviceKind from K-block type if still unknown
                if (kind == .unknown) {
                    if (resolved_sym.k_type) |kt| {
                        kind = mapXSchemKType(kt, resolved_sym.pins.len);
                    }
                }

                // Register global nets from symbols with global=true (e.g., vdd.sym, gnd.sym)
                if (resolved_sym.k_global) {
                    for (props) |p| {
                        if (std.mem.eql(u8, p.key, "lab") and p.val.len > 0) {
                            try sfy.addGlobal(p.val);
                            break;
                        }
                    }
                }

                // Evaluate tcleval() format strings to compute subcircuit
                // parameter overrides (e.g. calc_rc computes Res/Cap from L/W).
                // The computed key=value pairs are merged into instance props.
                const final_props = if (resolved_sym.k_format) |fmt|
                    evaluateTclFormatOverrides(a, fmt, props, src) catch props
                else
                    props;

                // Call addComponent while resolved_sym is alive so strings
                // in sd are valid when appendSymData dupes them.
                _ = try sfy.addComponent(.{
                    .name = inst_name,
                    .symbol = sym_name,
                    .kind = kind,
                    .x = inst_x,
                    .y = inst_y,
                    .rot = inst_rot,
                    .flip = inst_flip,
                    .props = final_props,
                    .sym_data = sd,
                });
                continue;
            }
        }

        // No resolver or symbol not found — try stem mapping as fallback
        if (kind == .unknown) {
            kind = mapXSchemStem(sym_name);
        }
        _ = try sfy.addComponent(.{
            .name = inst_name,
            .symbol = sym_name,
            .kind = kind,
            .x = inst_x,
            .y = inst_y,
            .rot = inst_rot,
            .flip = inst_flip,
            .props = props,
        });
    }
}

/// Convert ipin/opin/iopin instances into subckt port pins.
/// De-duplicates by lab name so each unique port appears exactly once.
fn mapPortPins(sfy: *Schemify) Allocator.Error!void {
    const a = sfy.alloc();
    const kinds = sfy.instances.items(.kind);
    const ips = sfy.instances.items(.prop_start);
    const ipc = sfy.instances.items(.prop_count);
    const ixs = sfy.instances.items(.x);
    const iys = sfy.instances.items(.y);

    // Collect unique port names in order, de-duplicating
    var seen = std.StringHashMapUnmanaged(void){};
    defer seen.deinit(a);

    for (0..sfy.instances.len) |i| {
        const k = kinds[i];
        if (k != .input_pin and k != .output_pin and k != .inout_pin) continue;
        const inst_props = sfy.props.items[ips[i]..][0..ipc[i]];
        const lab = findPropValue(inst_props, "lab");
        if (lab.len == 0) continue;
        if (seen.contains(lab)) continue;
        seen.put(a, lab, {}) catch {};

        const dir: core.PinDir = switch (k) {
            .input_pin => .input,
            .output_pin => .output,
            else => .inout,
        };
        try sfy.drawPin(.{
            .name = lab,
            .x = ixs[i],
            .y = iys[i],
            .dir = dir,
        });
    }
}

fn mapKBlock(sfy: *Schemify, sym: *const XSchemFiles) Allocator.Error!void {
    if (sym.k_format) |fmt| try sfy.addSymProp("format", fmt);
    if (sym.k_template) |tmpl| try sfy.addSymProp("template", tmpl);
    if (sym.k_type) |kt| try sfy.addSymProp("type", kt);
    if (sym.k_spice_sym_def) |ssd| sfy.spice_sym_def = ssd;
}

/// Map an XSchem K-block `type` string to a DeviceKind.
/// Handles standard XSchem types: "resistor", "nmos", "subcircuit", etc.
fn mapXSchemKType(kt: []const u8, pin_count: usize) core.DeviceKind {
    // Direct DeviceKind enum match (handles resistor, capacitor, vsource, npn, etc.)
    const dk = core.DeviceKind.fromStr(kt);
    if (dk != .unknown) return dk;

    // XSchem type strings that don't have a direct DeviceKind enum match
    if (std.mem.eql(u8, kt, "subcircuit")) return .subckt;
    if (std.mem.eql(u8, kt, "primitive")) return .subckt;
    if (std.mem.eql(u8, kt, "nmos")) return if (pin_count >= 4) .nmos4 else .nmos3;
    if (std.mem.eql(u8, kt, "pmos")) return if (pin_count >= 4) .pmos4 else .pmos3;
    if (std.mem.eql(u8, kt, "label")) return .lab_pin;
    if (std.mem.eql(u8, kt, "show_label")) return .lab_pin;
    if (std.mem.eql(u8, kt, "ipin")) return .input_pin;
    if (std.mem.eql(u8, kt, "opin")) return .output_pin;
    if (std.mem.eql(u8, kt, "iopin")) return .inout_pin;
    // Code / directive blocks
    if (std.mem.eql(u8, kt, "netlist_commands")) return .code;
    if (std.mem.eql(u8, kt, "netlist_options")) return .code;
    if (std.mem.eql(u8, kt, "architecture")) return .code;
    if (std.mem.eql(u8, kt, "timescale")) return .code;
    if (std.mem.eql(u8, kt, "verilog_preprocessor")) return .code;
    // Non-electrical / UI / annotation
    if (std.mem.eql(u8, kt, "logo")) return .title;
    if (std.mem.eql(u8, kt, "launcher")) return .launcher;
    if (std.mem.eql(u8, kt, "noconn")) return .noconn;
    if (std.mem.eql(u8, kt, "probe")) return .probe;
    if (std.mem.eql(u8, kt, "scope")) return .probe;
    if (std.mem.eql(u8, kt, "stop")) return .annotation;
    if (std.mem.eql(u8, kt, "bus_tap")) return .lab_pin;
    if (std.mem.eql(u8, kt, "short")) return .generic;
    // Coupling
    if (std.mem.eql(u8, kt, "coupler")) return .coupling;
    // Controlled sources
    if (std.mem.eql(u8, kt, "vcvs")) return .vcvs;
    if (std.mem.eql(u8, kt, "vccs")) return .vccs;
    if (std.mem.eql(u8, kt, "vcr")) return .resistor;
    if (std.mem.eql(u8, kt, "source")) return .behavioral;
    if (std.mem.eql(u8, kt, "switch")) return .vswitch;
    // Passive variants
    if (std.mem.eql(u8, kt, "polarized_capacitor")) return .capacitor;
    if (std.mem.eql(u8, kt, "poly_resistor")) return .resistor;
    if (std.mem.eql(u8, kt, "parax_cap")) return .capacitor;
    if (std.mem.eql(u8, kt, "crystal")) return .capacitor;
    // Active variants
    if (std.mem.eql(u8, kt, "delay")) return .generic;
    if (std.mem.eql(u8, kt, "delay_eldo")) return .generic;
    if (std.mem.eql(u8, kt, "analog_delay")) return .generic;
    if (std.mem.eql(u8, kt, "flash")) return .generic;
    if (std.mem.eql(u8, kt, "ic")) return .generic;
    if (std.mem.eql(u8, kt, "connector")) return .annotation;
    if (std.mem.eql(u8, kt, "jumper")) return .generic;
    if (std.mem.eql(u8, kt, "isource_only_for_hspice")) return .isource;
    return .unknown;
}

/// Map an XSchem symbol stem name (e.g. "res", "capa") to a DeviceKind.
/// Used as a fallback when the symbol file cannot be resolved.
fn mapXSchemStem(stem: []const u8) core.DeviceKind {
    const map = std.StaticStringMap(core.DeviceKind).initComptime(.{
        .{ "res", .resistor },
        .{ "res_ac", .resistor },
        .{ "connect", .resistor },
        .{ "var_res", .var_resistor },
        .{ "res3", .resistor3 },
        .{ "capa", .capacitor },
        .{ "capa-2", .capacitor },
        .{ "real_capa", .capacitor },
        .{ "parax_cap", .capacitor },
        .{ "crystal", .capacitor },
        .{ "ind", .inductor },
        .{ "nmos", .nmos3 },
        .{ "nmos3", .nmos3 },
        .{ "nmos4", .nmos4 },
        .{ "nmos4_depl", .nmos4_depl },
        .{ "nmos-sub", .nmos_sub },
        .{ "rnmos4", .rnmos4 },
        .{ "pmos", .pmos3 },
        .{ "pmos3", .pmos3 },
        .{ "pmos4", .pmos4 },
        .{ "pmoshv4", .pmoshv4 },
        .{ "pmos-sub", .pmos_sub },
        .{ "npn", .npn },
        .{ "pnp", .pnp },
        .{ "njfet", .njfet },
        .{ "pjfet", .pjfet },
        .{ "diode", .diode },
        .{ "led", .diode },
        .{ "zener", .zener },
        .{ "vsource", .vsource },
        .{ "vsource_arith", .vsource },
        .{ "vsource_pwl", .vsource },
        .{ "sqwsource", .sqwsource },
        .{ "isource", .isource },
        .{ "isource_arith", .isource },
        .{ "isource_table", .isource },
        .{ "isource_pwl", .isource },
        .{ "ammeter", .ammeter },
        .{ "vcvs", .vcvs },
        .{ "vccs", .vccs },
        .{ "ccvs", .ccvs },
        .{ "cccs", .cccs },
        .{ "bsource", .behavioral },
        .{ "asrc", .behavioral },
        .{ "switch_ngspice", .vswitch },
        .{ "ipin", .input_pin },
        .{ "opin", .output_pin },
        .{ "iopin", .inout_pin },
        .{ "lab_pin", .lab_pin },
        .{ "lab_wire", .lab_pin },
        .{ "lab_show", .lab_pin },
        .{ "bus_connect", .lab_pin },
        .{ "bus_connect_nolab", .lab_pin },
        .{ "bus_tap", .lab_pin },
        .{ "gnd", .gnd },
        .{ "vdd", .vdd },
        .{ "noconn", .noconn },
        .{ "title", .title },
        .{ "title-2", .title },
        .{ "title-3", .title },
        .{ "launcher", .launcher },
        .{ "code_shown", .code },
        .{ "code", .code },
        .{ "simulator_commands", .code },
        .{ "simulator_commands_shown", .code },
        .{ "netlist_options", .code },
        .{ "arch_declarations", .code },
        .{ "architecture", .code },
        .{ "spice_probe", .probe },
        .{ "spice_probe_vdiff", .probe_diff },
        .{ "ngspice_probe", .probe },
        .{ "ngspice_get_value", .probe },
        .{ "ngspice_get_expr", .probe },
        .{ "device_param_probe", .probe },
        .{ "k", .coupling },
        .{ "short", .generic },
        .{ "package_not_shown", .annotation },
    });
    return map.get(stem) orelse .unknown;
}

/// Strip extension from a symbol path, preserving relative directory:
///   "sky130_tests/adder_1bit.sym" → "sky130_tests/adder_1bit"
///   "devices/res.sym"             → "devices/res"
///   "nmos4.sym"                   → "nmos4"
///   "nmos4"                       → "nmos4"
fn stemFromPath(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".sym"))
        return path[0 .. path.len - 4];
    if (std.mem.endsWith(u8, path, ".sch"))
        return path[0 .. path.len - 4];
    return path;
}

/// Returns true if this stem name is a label-like symbol whose `lab` property
/// should inject a net name at its pin position.
fn isLabelStem(stem: []const u8) bool {
    const label_stems = std.StaticStringMap(void).initComptime(.{
        .{ "lab_pin", {} },
        .{ "lab_wire", {} },
        .{ "lab_show", {} },
        .{ "bus_connect", {} },
        .{ "bus_connect_nolab", {} },
        .{ "gnd", {} },
        .{ "vdd", {} },
        .{ "ipin", {} },
        .{ "opin", {} },
        .{ "iopin", {} },
    });
    return label_stems.has(stem);
}

/// Find the value of a property by key in a Prop slice.
fn findPropValue(props: []const core.Prop, key: []const u8) []const u8 {
    for (props) |p| {
        if (std.mem.eql(u8, p.key, key)) return p.val;
    }
    return "";
}

// ── Tcl format evaluation ────────────────────────────────────────────────

/// Evaluate tcleval() format strings containing `[...]` Tcl commands to
/// compute subcircuit parameter overrides.  Returns an extended props slice
/// with computed key=value pairs appended, or the original props if
/// evaluation is not applicable or fails.
fn evaluateTclFormatOverrides(
    a: Allocator,
    format: []const u8,
    props: []const core.Prop,
    src: *const XSchemFiles,
) ![]const core.Prop {
    // Only process tcleval() formats
    const trimmed = std.mem.trim(u8, format, " \t\r\n\"");
    if (!std.mem.startsWith(u8, trimmed, "tcleval(") or
        trimmed.len <= "tcleval()".len or
        trimmed[trimmed.len - 1] != ')')
        return props;

    const inner = trimmed["tcleval(".len .. trimmed.len - 1];

    // Check for [...] Tcl command blocks in the format
    if (std.mem.indexOfScalar(u8, inner, '[') == null) return props;

    // Extract proc definitions from schematic text blocks.
    // XSchem embeds Tcl proc definitions in T (text) elements and in
    // component instance properties (e.g. title.sym author= attribute).
    var interp = tcl.Tcl.init(a);
    defer interp.deinit();

    // Search text blocks for proc definitions
    const text_sl = src.texts.slice();
    for (0..src.texts.len) |ti| {
        const content = text_sl.items(.content)[ti];
        registerProcsFromText(&interp, content);
    }

    // Search instance properties for embedded proc definitions
    // (e.g. title.sym "author" property often contains proc defs)
    for (src.props.items) |p| {
        registerProcsFromText(&interp, p.value);
    }

    // Set instance property values as Tcl variables so the Tcl command
    // can access them (e.g. $L, $W, or via @-token expansion within tcleval).
    for (props) |p| {
        if (std.mem.eql(u8, p.key, "name")) continue;
        interp.setVar(p.key, p.val) catch {};
    }

    // Find and evaluate [cmd ...] blocks in the format.
    // First expand @-tokens to their values from instance props,
    // then evaluate the resulting Tcl expression.
    var extra_pairs: std.ArrayListUnmanaged(core.Prop) = .{};
    var pos: usize = 0;
    while (pos < inner.len) {
        if (inner[pos] == '[') {
            // Find matching ]
            var depth: u32 = 1;
            const cmd_start = pos + 1;
            pos += 1;
            while (pos < inner.len and depth > 0) : (pos += 1) {
                if (inner[pos] == '[') depth += 1;
                if (inner[pos] == ']') depth -= 1;
            }
            const cmd_content = inner[cmd_start .. pos - 1];

            // Expand @-tokens in the command using instance props
            const expanded = expandAtTokens(a, cmd_content, props) catch continue;

            // Evaluate the expanded Tcl command
            const result = interp.eval(expanded) catch continue;

            // Parse result for key=value pairs (e.g. "Res=240000 Cap=5e-14")
            parseKeyValuePairs(a, result, &extra_pairs) catch {};
        } else {
            pos += 1;
        }
    }

    if (extra_pairs.items.len == 0) return props;

    // Build extended props: original props + computed pairs
    const extended = try a.alloc(core.Prop, props.len + extra_pairs.items.len);
    @memcpy(extended[0..props.len], props);
    @memcpy(extended[props.len..], extra_pairs.items);
    return extended;
}

/// Expand @-tokens in a string using instance property values.
/// E.g., "calc_rc @L @W" with props L=1e-4, W=0.5e-6 becomes "calc_rc 1e-4 0.5e-6".
fn expandAtTokens(a: Allocator, input: []const u8, props: []const core.Prop) ![]const u8 {
    // Fast path: no @ tokens
    if (std.mem.indexOfScalar(u8, input, '@') == null) return input;

    var buf: std.ArrayListUnmanaged(u8) = .{};
    var pos: usize = 0;
    while (pos < input.len) {
        if (input[pos] == '@' and pos + 1 < input.len) {
            const start = pos + 1;
            var end = start;
            while (end < input.len and (std.ascii.isAlphanumeric(input[end]) or input[end] == '_'))
                end += 1;
            const ident = input[start..end];
            const val = findPropValue(props, ident);
            if (val.len > 0) {
                try buf.appendSlice(a, val);
            } else {
                // Keep the @token as-is if no prop matches
                try buf.append(a, '@');
                try buf.appendSlice(a, ident);
            }
            pos = end;
        } else {
            try buf.append(a, input[pos]);
            pos += 1;
        }
    }
    return buf.items;
}

/// Parse a string of space-separated key=value pairs into Prop entries.
fn parseKeyValuePairs(
    a: Allocator,
    input: []const u8,
    list: *std.ArrayListUnmanaged(core.Prop),
) !void {
    var toks = std.mem.tokenizeAny(u8, input, " \t\n\r");
    while (toks.next()) |tok| {
        if (std.mem.indexOfScalar(u8, tok, '=')) |eq| {
            const key = tok[0..eq];
            const val = tok[eq + 1 ..];
            if (key.len > 0 and val.len > 0) {
                try list.append(a, .{
                    .key = try a.dupe(u8, key),
                    .val = try a.dupe(u8, val),
                });
            }
        }
    }
}

/// Search a text string for Tcl `proc` definitions and register them
/// in the interpreter.  Handles XSchem's escaped braces in text blocks
/// (e.g., `\{` → `{` and `\}` → `}`).
fn registerProcsFromText(interp: *tcl.Tcl, text: []const u8) void {
    // Look for "proc " keyword
    var search = text;
    while (std.mem.indexOf(u8, search, "proc ")) |idx| {
        // Walk backwards to check this isn't in the middle of a word
        if (idx > 0 and (std.ascii.isAlphanumeric(search[idx - 1]) or search[idx - 1] == '_')) {
            search = search[idx + 5 ..];
            continue;
        }
        // Try to extract the full proc definition
        const proc_start = search[idx..];
        // Unescape XSchem text block escapes (\{ → {, \} → })
        const unescaped = unescapeXSchemTcl(interp.evaluator.arena.allocator(), proc_start) catch {
            search = search[idx + 5 ..];
            continue;
        };
        // Try to evaluate the proc definition
        interp.defineProc(unescaped) catch {};
        search = search[idx + 5 ..];
    }
}

/// Unescape XSchem text block Tcl escapes: \{ → {, \} → }, \\ → \
fn unescapeXSchemTcl(a: Allocator, input: []const u8) ![]const u8 {
    // Fast path: no escapes
    if (std.mem.indexOfScalar(u8, input, '\\') == null) return input;

    var buf: std.ArrayListUnmanaged(u8) = .{};
    var i: usize = 0;
    var brace_depth: i32 = 0;
    while (i < input.len) {
        if (input[i] == '\\' and i + 1 < input.len) {
            const next = input[i + 1];
            if (next == '{' or next == '}' or next == '\\' or next == '"') {
                try buf.append(a, next);
                if (next == '{') brace_depth += 1;
                if (next == '}') brace_depth -= 1;
                i += 2;
                continue;
            }
        }
        if (input[i] == '{') brace_depth += 1;
        if (input[i] == '}') {
            brace_depth -= 1;
            if (brace_depth < 0) {
                // End of the outermost block — stop here
                try buf.append(a, '}');
                break;
            }
        }
        try buf.append(a, input[i]);
        i += 1;
    }
    return buf.items;
}
