// convert.zig - Shared XSchemFiles ↔ Schemify conversion logic.
//
// Uses ONLY builder/API interfaces — never directly edits struct fields.
// XSchem → Schemify: uses drawLine, drawRect, drawArc, drawCircle, drawText,
//     drawPin, addWire, addComponent, addGlobal, addSymProp, setSpiceBody,
//     setStype, setName.
// Schemify → XSchem: reads via public accessors (items(), len, etc.).

const std = @import("std");
const core = @import("core");
const types = @import("types.zig");
const tcl = @import("tcl");

const Allocator = std.mem.Allocator;
const XSchemFiles = types.XSchemFiles;
const Schemify = core.Schemify;

// ── Coordinate helpers ────────────────────────────────────────────────────

fn f2i(v: f64) i32 {
    return @intFromFloat(@round(v));
}

fn i2f(v: i32) f64 {
    return @as(f64, @floatFromInt(v));
}

fn layerU8(v: i32) u8 {
    return @intCast(@max(0, @min(255, v)));
}

// ── XSchem → Schemify ────────────────────────────────────────────────────

pub const SymResolver = struct {
    ctx: *anyopaque,
    resolveFn: *const fn (ctx: *anyopaque, sym_path: []const u8) ?XSchemFiles,

    pub fn resolve(self: SymResolver, sym_path: []const u8) ?XSchemFiles {
        return self.resolveFn(self.ctx, sym_path);
    }
};

pub fn mapXSchemToSchemify(
    backing: Allocator,
    schematic: *const XSchemFiles,
    symbol: ?*const XSchemFiles,
    name: []const u8,
    sym_resolver: ?SymResolver,
) Allocator.Error!Schemify {
    var sfy = Schemify.init(backing);
    errdefer sfy.deinit();

    sfy.setName(name);

    if (symbol) |sym| {
        sfy.setStype(if (sym.k_type) |kt|
            (if (std.mem.eql(u8, kt, "subcircuit")) .component else .primitive)
        else
            .component);
    } else if (schematic.k_type) |kt| {
        sfy.setStype(if (std.mem.eql(u8, kt, "subcircuit")) .component else .primitive);
    } else {
        sfy.setStype(.testbench);
    }

    try mapLines(&sfy, schematic);
    try mapRects(&sfy, schematic);
    try mapArcs(&sfy, schematic);
    try mapCircles(&sfy, schematic);
    try mapWires(&sfy, schematic);
    try mapTexts(&sfy, schematic);

    if (symbol) |sym| {
        try mapPins(&sfy, sym);
        try mapKBlock(&sfy, sym);
    } else {
        try mapPins(&sfy, schematic);
        try mapKBlock(&sfy, schematic);
    }

    try mapInstances(&sfy, schematic, sym_resolver);

    if (schematic.s_block) |sb| {
        sfy.setSpiceBody(sb);
    }

    if (sfy.pins.len == 0) {
        try mapPortPins(&sfy);
    }

    return sfy;
}

// ── Element mappers (Schemify builder API only) ──────────────────────────

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
        const x0 = f2i(sl.items(.x0)[i]);
        const y0 = f2i(sl.items(.y0)[i]);
        const x1 = f2i(sl.items(.x1)[i]);
        const y1 = f2i(sl.items(.y1)[i]);
        if (x0 == x1 and y0 == y1) continue;
        try sfy.addWire(.{
            .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1,
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
    const a = sfy.alloc();
    const sl = src.pins.slice();
    const n = src.pins.len;
    if (n == 0) return;

    const entries = try a.alloc(BusEntry, n);
    defer a.free(entries);
    for (0..n) |i| {
        entries[i] = .{
            .name = sl.items(.name)[i],
            .dir = @enumFromInt(@intFromEnum(sl.items(.direction)[i])),
            .x = f2i(sl.items(.x)[i]),
            .y = f2i(sl.items(.y)[i]),
            .num = if (sl.items(.number)[i]) |num| @intCast(num) else null,
        };
    }
    try collapseBusPins(sfy, entries);
}

fn mapKBlock(sfy: *Schemify, sym: *const XSchemFiles) Allocator.Error!void {
    if (sym.k_format) |fmt| try sfy.addSymProp("format", fmt);
    if (sym.k_template) |tmpl| try sfy.addSymProp("template", tmpl);
    if (sym.k_type) |kt| try sfy.addSymProp("type", kt);
    if (sym.k_spice_sym_def) |ssd| sfy.setSpiceSymDef(ssd);
}

fn mapInstances(sfy: *Schemify, src: *const XSchemFiles, sym_resolver: ?SymResolver) Allocator.Error!void {
    const a = sfy.alloc();
    const sl = src.instances.slice();
    for (0..src.instances.len) |i| {
        const xs_ps = sl.items(.prop_start)[i];
        const xs_pc = sl.items(.prop_count)[i];
        const raw_sym = sl.items(.symbol)[i];
        const raw_xs_props = src.props.items[xs_ps..][0..xs_pc];

        const sch_override: []const u8 = blk: {
            for (raw_xs_props) |p| {
                if (std.mem.eql(u8, p.key, "schematic")) break :blk p.value;
            }
            break :blk "";
        };
        const sym_name = if (sch_override.len > 0) stemFromPath(sch_override) else stemFromPath(raw_sym);

        var prop_list = std.ArrayListUnmanaged(core.Prop){};
        const skip_keys = std.StaticStringMap(void).initComptime(.{
            .{ "tclcommand", {} },
            .{ "schematic", {} },
        });
        for (raw_xs_props) |p| {
            if (skip_keys.has(p.key)) continue;
            prop_list.append(a, .{ .key = p.key, .val = p.value }) catch continue;
        }
        const props = try prop_list.toOwnedSlice(a);

        const inst_name = sl.items(.name)[i];
        const inst_x = f2i(sl.items(.x)[i]);
        const inst_y = f2i(sl.items(.y)[i]);
        const inst_rot: u2 = @intCast(@mod(sl.items(.rot)[i], 4));
        const inst_flip = sl.items(.flip)[i];

        var kind = core.DeviceKind.fromStr(sym_name);

        if (sym_resolver) |resolver| {
            if (resolver.resolve(raw_sym)) |resolved_sym| {
                defer {
                    var rs = resolved_sym;
                    rs.deinit();
                }
                var sd: core.SymData = .{};

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

                if (resolved_sym.k_format) |fmt| sd.format = fmt;
                if (resolved_sym.k_template) |tmpl| sd.template = tmpl;

                if (kind == .unknown) {
                    if (resolved_sym.k_type) |kt| {
                        kind = mapXSchemKType(kt, resolved_sym.pins.len);
                    }
                }

                if (resolved_sym.k_global) {
                    for (props) |p| {
                        if (std.mem.eql(u8, p.key, "lab") and p.val.len > 0) {
                            sfy.addGlobal(p.val) catch {};
                            break;
                        }
                    }
                }

                const final_props = if (resolved_sym.k_format) |fmt|
                    evaluateTclFormatOverrides(a, fmt, props, src) catch props
                else
                    props;

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

fn mapPortPins(sfy: *Schemify) Allocator.Error!void {
    const a = sfy.alloc();
    const kinds = sfy.instances.items(.kind);
    const ips = sfy.instances.items(.prop_start);
    const ipc = sfy.instances.items(.prop_count);
    const ixs = sfy.instances.items(.x);
    const iys = sfy.instances.items(.y);

    var entries = std.ArrayListUnmanaged(BusEntry){};
    defer entries.deinit(a);
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
        try entries.append(a, .{
            .name = lab,
            .dir = switch (k) {
                .input_pin => .input,
                .output_pin => .output,
                else => .inout,
            },
            .x = ixs[i],
            .y = iys[i],
        });
    }

    try collapseBusPins(sfy, entries.items);
}

// ── Bus pin helpers ────────────────────────────────────────────────────────

const BusEntry = struct {
    name: []const u8,
    dir: core.PinDir,
    x: i32,
    y: i32,
    num: ?u32 = null,
};

fn collapseBusPins(sfy: *Schemify, entries: []const BusEntry) Allocator.Error!void {
    const a = sfy.alloc();
    const n = entries.len;
    if (n == 0) return;

    const consumed = try a.alloc(bool, n);
    defer a.free(consumed);
    @memset(consumed, false);

    for (0..n) |i| {
        if (consumed[i]) continue;
        const e = entries[i];

        if (splitBusPin(e.name)) |parts| {
            var min_idx: u32 = parts.idx;
            var max_idx: u32 = parts.idx;
            var count: u32 = 1;
            for (0..n) |j| {
                if (j == i or consumed[j]) continue;
                const pj = splitBusPin(entries[j].name) orelse continue;
                if (!std.mem.eql(u8, parts.base, pj.base)) continue;
                if (entries[j].dir != e.dir) continue;
                count += 1;
                if (pj.idx < min_idx) min_idx = pj.idx;
                if (pj.idx > max_idx) max_idx = pj.idx;
            }
            const width = max_idx - min_idx + 1;
            if (count == width and width > 1) {
                consumed[i] = true;
                for (0..n) |j| {
                    if (j == i or consumed[j]) continue;
                    const pj = splitBusPin(entries[j].name) orelse continue;
                    if (std.mem.eql(u8, parts.base, pj.base) and entries[j].dir == e.dir)
                        consumed[j] = true;
                }
                try sfy.drawPin(.{
                    .name = parts.base,
                    .x = e.x, .y = e.y,
                    .dir = e.dir,
                    .num = null,
                    .width = @intCast(width),
                });
                continue;
            }
        }

        consumed[i] = true;
        try sfy.drawPin(.{
            .name = e.name, .x = e.x, .y = e.y, .dir = e.dir,
            .num = if (e.num) |pn| @as(u16, @intCast(pn)) else null,
        });
    }
}

fn splitBusPin(name: []const u8) ?struct { base: []const u8, idx: u32 } {
    if (name.len < 4 or name[name.len - 1] != ']') return null;
    const open = std.mem.lastIndexOfScalar(u8, name, '[') orelse return null;
    const idx = std.fmt.parseInt(u32, name[open + 1 .. name.len - 1], 10) catch return null;
    return .{ .base = name[0..open], .idx = idx };
}

// ── General helpers ───────────────────────────────────────────────────────

fn findPropValue(props: []const core.Prop, key: []const u8) []const u8 {
    for (props) |p| {
        if (std.mem.eql(u8, p.key, key)) return p.val;
    }
    return "";
}

fn stemFromPath(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".sym") or std.mem.endsWith(u8, path, ".sch"))
        return path[0 .. path.len - 4];
    return path;
}

fn mapXSchemKType(kt: []const u8, pin_count: usize) core.DeviceKind {
    const dk = core.DeviceKind.fromStr(kt);
    if (dk != .unknown) return dk;
    if (std.mem.eql(u8, kt, "nmos")) return if (pin_count >= 4) .nmos4 else .nmos3;
    if (std.mem.eql(u8, kt, "pmos")) return if (pin_count >= 4) .pmos4 else .pmos3;

    const ktype_map = std.StaticStringMap(core.DeviceKind).initComptime(.{
        .{ "subcircuit", .subckt },
        .{ "primitive", .subckt },
        .{ "label", .lab_pin },
        .{ "show_label", .lab_pin },
        .{ "ipin", .input_pin },
        .{ "opin", .output_pin },
        .{ "iopin", .inout_pin },
        .{ "bus_tap", .lab_pin },
        .{ "netlist_commands", .code },
        .{ "netlist_options", .code },
        .{ "architecture", .code },
        .{ "timescale", .code },
        .{ "verilog_preprocessor", .code },
        .{ "logo", .title },
        .{ "launcher", .launcher },
        .{ "noconn", .noconn },
        .{ "probe", .probe },
        .{ "scope", .probe },
        .{ "stop", .annotation },
        .{ "connector", .annotation },
        .{ "short", .generic },
        .{ "coupler", .coupling },
        .{ "vcvs", .vcvs },
        .{ "vccs", .vccs },
        .{ "vcr", .resistor },
        .{ "source", .behavioral },
        .{ "switch", .vswitch },
        .{ "isource_only_for_hspice", .isource },
        .{ "polarized_capacitor", .capacitor },
        .{ "poly_resistor", .resistor },
        .{ "parax_cap", .capacitor },
        .{ "crystal", .capacitor },
        .{ "delay", .generic },
        .{ "delay_eldo", .generic },
        .{ "analog_delay", .generic },
        .{ "flash", .generic },
        .{ "ic", .generic },
        .{ "jumper", .generic },
    });
    return ktype_map.get(kt) orelse .unknown;
}

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
        .{ "nmos4", .nmos4 },
        .{ "nmos4_depl", .nmos4_depl },
        .{ "nmos-sub", .nmos_sub },
        .{ "rnmos4", .rnmos4 },
        .{ "pmos4", .pmos4 },
        .{ "pmos-sub", .pmos_sub },
        .{ "pmoshv4", .pmoshv4 },
        .{ "npn", .npn },
        .{ "pnp", .pnp },
        .{ "njfet", .njfet },
        .{ "pjfet", .pjfet },
        .{ "diode", .diode },
        .{ "led", .diode },
        .{ "zener", .zener },
        .{ "lvsdiode", .diode },
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
        .{ "k", .coupling },
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
        .{ "short", .generic },
        .{ "package_not_shown", .annotation },
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
        .{ "res_xhigh_po", .resistor },
        .{ "res_xh_dnwell", .resistor },
        .{ "res_generic", .resistor },
        .{ "cap_mim_m3_1", .capacitor },
        .{ "cap_mim_m3_2", .capacitor },
        .{ "cap_var_hvt", .capacitor },
        .{ "cap_var_lvt", .capacitor },
    });
    if (map.get(stem)) |kind| return kind;
    if (matchFetPrefix(stem)) |kind| return kind;
    return .unknown;
}

fn matchFetPrefix(stem: []const u8) ?core.DeviceKind {
    const prefixes = .{
        .{ "nfet3_", core.DeviceKind.nmos3 },
        .{ "nfet_", core.DeviceKind.nmos4 },
        .{ "pfet3_", core.DeviceKind.pmos3 },
        .{ "pfet_", core.DeviceKind.pmos4 },
    };
    inline for (prefixes) |entry| {
        if (std.mem.startsWith(u8, stem, entry[0])) return entry[1];
    }
    return null;
}

// ── Tcl format evaluation ─────────────────────────────────────────────────

fn evaluateTclFormatOverrides(
    a: Allocator,
    format: []const u8,
    props: []const core.Prop,
    src: *const XSchemFiles,
) ![]const core.Prop {
    const trimmed = std.mem.trim(u8, format, " \t\r\n\"");
    if (!std.mem.startsWith(u8, trimmed, "tcleval(") or
        trimmed.len <= "tcleval()".len or
        trimmed[trimmed.len - 1] != ')')
        return props;

    const inner = trimmed["tcleval(".len .. trimmed.len - 1];
    if (std.mem.indexOfScalar(u8, inner, '[') == null) return props;

    var interp = tcl.Tcl.init(a);
    defer interp.deinit();

    const text_sl = src.texts.slice();
    for (0..src.texts.len) |ti| {
        const content = text_sl.items(.content)[ti];
        registerProcsFromText(&interp, content);
    }

    for (src.props.items) |p| {
        registerProcsFromText(&interp, p.value);
    }

    for (props) |p| {
        if (std.mem.eql(u8, p.key, "name")) continue;
        interp.setVar(p.key, p.val) catch {};
    }

    var extra_pairs: std.ArrayListUnmanaged(core.Prop) = .{};
    var pos: usize = 0;
    while (pos < inner.len) {
        if (inner[pos] == '[') {
            var depth: u32 = 1;
            const cmd_start = pos + 1;
            pos += 1;
            while (pos < inner.len and depth > 0) : (pos += 1) {
                if (inner[pos] == '[') depth += 1;
                if (inner[pos] == ']') depth -= 1;
            }
            const cmd_content = inner[cmd_start .. pos - 1];
            const expanded = expandAtTokens(a, cmd_content, props) catch continue;
            const result = interp.eval(expanded) catch continue;
            parseKeyValuePairs(a, result, &extra_pairs) catch {};
        } else {
            pos += 1;
        }
    }

    if (extra_pairs.items.len == 0) return props;

    const extended = try a.alloc(core.Prop, props.len + extra_pairs.items.len);
    @memcpy(extended[0..props.len], props);
    @memcpy(extended[props.len..], extra_pairs.items);
    return extended;
}

fn expandAtTokens(a: Allocator, input: []const u8, props: []const core.Prop) ![]const u8 {
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

fn registerProcsFromText(interp: *tcl.Tcl, text: []const u8) void {
    var search = text;
    while (std.mem.indexOf(u8, search, "proc ")) |idx| {
        if (idx > 0 and (std.ascii.isAlphanumeric(search[idx - 1]) or search[idx - 1] == '_')) {
            search = search[idx + 5 ..];
            continue;
        }
        const proc_start = search[idx..];
        const unescaped = unescapeXSchemTcl(interp.evaluator.arena.allocator(), proc_start) catch {
            search = search[idx + 5 ..];
            continue;
        };
        interp.defineProc(unescaped) catch {};
        search = search[idx + 5 ..];
    }
}

fn unescapeXSchemTcl(a: Allocator, input: []const u8) ![]const u8 {
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
                try buf.append(a, '}');
                break;
            }
        }
        try buf.append(a, input[i]);
        i += 1;
    }
    return buf.items;
}

// ── Schemify → XSchemFiles ─────────────────────────────────────────────────

pub fn mapSchemifyToXSchem(backing: Allocator, sfy: *const Schemify) Allocator.Error!XSchemFiles {
    var xs = XSchemFiles.init(backing);
    errdefer xs.deinit();
    const arena = xs.arena.allocator();

    xs.name = sfy.name;
    xs.file_type = if (sfy.stype == .component or sfy.stype == .primitive) .symbol else .schematic;

    // Geometry
    const lines = sfy.lines.slice();
    for (0..sfy.lines.len) |i| {
        try xs.lines.append(arena, .{
            .layer = @intCast(lines.items(.layer)[i]),
            .x0 = i2f(lines.items(.x0)[i]),
            .y0 = i2f(lines.items(.y0)[i]),
            .x1 = i2f(lines.items(.x1)[i]),
            .y1 = i2f(lines.items(.y1)[i]),
        });
    }

    const rects = sfy.rects.slice();
    for (0..sfy.rects.len) |i| {
        try xs.rects.append(arena, .{
            .layer = @intCast(rects.items(.layer)[i]),
            .x0 = i2f(rects.items(.x0)[i]),
            .y0 = i2f(rects.items(.y0)[i]),
            .x1 = i2f(rects.items(.x1)[i]),
            .y1 = i2f(rects.items(.y1)[i]),
        });
    }

    const arcs = sfy.arcs.slice();
    for (0..sfy.arcs.len) |i| {
        try xs.arcs.append(arena, .{
            .layer = @intCast(arcs.items(.layer)[i]),
            .cx = i2f(arcs.items(.cx)[i]),
            .cy = i2f(arcs.items(.cy)[i]),
            .radius = i2f(arcs.items(.radius)[i]),
            .start_angle = @as(f64, @floatFromInt(arcs.items(.start_angle)[i])),
            .sweep_angle = @as(f64, @floatFromInt(arcs.items(.sweep_angle)[i])),
        });
    }

    const circles = sfy.circles.slice();
    for (0..sfy.circles.len) |i| {
        try xs.circles.append(arena, .{
            .layer = @intCast(circles.items(.layer)[i]),
            .cx = i2f(circles.items(.cx)[i]),
            .cy = i2f(circles.items(.cy)[i]),
            .radius = i2f(circles.items(.radius)[i]),
        });
    }

    const wires = sfy.wires.slice();
    for (0..sfy.wires.len) |i| {
        try xs.wires.append(arena, .{
            .x0 = i2f(wires.items(.x0)[i]),
            .y0 = i2f(wires.items(.y0)[i]),
            .x1 = i2f(wires.items(.x1)[i]),
            .y1 = i2f(wires.items(.y1)[i]),
            .net_name = wires.items(.net_name)[i],
            .bus = wires.items(.bus)[i],
        });
    }

    const texts = sfy.texts.slice();
    for (0..sfy.texts.len) |i| {
        try xs.texts.append(arena, .{
            .content = texts.items(.content)[i],
            .x = i2f(texts.items(.x)[i]),
            .y = i2f(texts.items(.y)[i]),
            .layer = @intCast(texts.items(.layer)[i]),
            .size = @as(f64, @floatFromInt(texts.items(.size)[i])) / 25.0,
            .rotation = @intCast(@mod(@as(u32, texts.items(.rotation)[i]), 16)),
        });
    }

    // Pins
    const pins = sfy.pins.slice();
    for (0..sfy.pins.len) |i| {
        try xs.pins.append(arena, .{
            .name = pins.items(.name)[i],
            .x = i2f(pins.items(.x)[i]),
            .y = i2f(pins.items(.y)[i]),
            .direction = @enumFromInt(@intFromEnum(pins.items(.dir)[i])),
            .number = @intCast(pins.items(.num)[i] orelse 0),
        });
    }

    // Instances
    const instances = sfy.instances.slice();
    for (0..sfy.instances.len) |i| {
        const prop_start: u32 = @intCast(xs.props.items.len);
        const inst_props = sfy.props.items[instances.items(.prop_start)[i]..][0..instances.items(.prop_count)[i]];
        for (inst_props) |p| {
            try xs.props.append(arena, .{ .key = p.key, .value = p.val });
        }
        const prop_count: u16 = @intCast(inst_props.len);
        try xs.instances.append(arena, .{
            .name = instances.items(.name)[i],
            .symbol = instances.items(.symbol)[i],
            .x = i2f(instances.items(.x)[i]),
            .y = i2f(instances.items(.y)[i]),
            .rot = @intCast(instances.items(.rot)[i]),
            .flip = instances.items(.flip)[i],
            .prop_start = prop_start,
            .prop_count = prop_count,
        });
    }

    // K-block
    for (sfy.sym_props.items) |p| {
        if (std.mem.eql(u8, p.key, "type")) { xs.k_type = p.val; }
        else if (std.mem.eql(u8, p.key, "format")) { xs.k_format = p.val; }
        else if (std.mem.eql(u8, p.key, "template")) { xs.k_template = p.val; }
        else if (std.mem.eql(u8, p.key, "extra")) { xs.k_extra = p.val; }
        else if (std.mem.eql(u8, p.key, "global")) { xs.k_global = std.mem.eql(u8, p.val, "true"); }
        else if (std.mem.eql(u8, p.key, "spice_sym_def")) { xs.k_spice_sym_def = p.val; }
    }

    // S-block
    xs.s_block = sfy.spice_body;

    return xs;
}
