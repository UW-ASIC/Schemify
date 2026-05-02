//! Netlist.zig — Schemify schematic → SPICE netlist generation
//!
//! Implements .chn → SPICE (subcircuit wrapping, template expansion, net
//! resolution) and .chn_testbench → SPICE (includes, analyses, measures).

const std = @import("std");
const Allocator = std.mem.Allocator;
const List = std.ArrayListUnmanaged;

const types = @import("../types.zig");
const Property = types.Property;
const Conn = types.Conn;
const Net = types.Net;
const DeviceKind = types.DeviceKind;
const SpiceIF = @import("SpiceIF.zig");
const Backend = SpiceIF.Backend;
const BackendHandle = @import("backend/lib.zig").BackendHandle;
const Devices = @import("../devices/Devices.zig");
const h = @import("../helpers.zig");

// ═════════════════════════════════════════════════════════════════════════════
// Public API
// ═════════════════════════════════════════════════════════════════════════════

/// Emit a SPICE netlist from a Schemify model.
///
/// `model` must expose the same field layout as Schemify.zig (instances MAL,
/// pins MAL, props/conns/nets lists, sym_props, sym_data, etc.).
/// This is intentionally a free function to avoid the circular import.
pub fn emitSpice(
    model: anytype,
    gpa: Allocator,
    backend: Backend,
    pdk: ?*const Devices.Pdk,
) ![]u8 {
    var out = List(u8){};
    errdefer out.deinit(gpa);
    const w = out.writer(gpa);
    const bh = BackendHandle.init(backend);

    // 1. Comment header
    try w.print("* Schemify netlist: {s}\n", .{model.name});

    // 2. .lib / .include
    try emitIncludes(w, gpa, model.sym_props.items);

    // 3. .subckt header
    const needs_subckt = model.stype != .testbench;
    if (needs_subckt) {
        try w.print(".subckt {s}", .{model.name});
        try emitSubcktPorts(w, gpa, model);
        try w.writeByte('\n');
    }

    // 4. PDK preamble
    if (pdk) |p| {
        const preamble = try collectPdkPreamble(gpa, model, p);
        defer gpa.free(preamble);
        try w.writeAll(preamble);
    }

    // 5. .param blocks (testbench)
    if (model.stype == .testbench) try emitTestbenchParams(w, model);

    // 6. Header code blocks
    try emitCodeBlocksForPlace(w, model, gpa, backend, "header");

    // 7. Instance emission
    const sli = model.instances.slice();
    const iname = sli.items(.name);
    const isym = sli.items(.symbol);
    const ikind = sli.items(.kind);
    const ips = sli.items(.prop_start);
    const ipc = sli.items(.prop_count);
    const ics = sli.items(.conn_start);
    const icc = sli.items(.conn_count);
    const ispice = sli.items(.spice_line);

    for (0..model.instances.len) |i| {
        const kind = ikind[i];
        if (kind == .code or kind == .param) continue;

        if (kind.isNonElectrical()) {
            if (kind == .unknown or kind == .generic) {
                const ck_conns = model.conns.items[ics[i]..][0..icc[i]];
                if (ck_conns.len > 0) {
                    const ck_props = model.props.items[ips[i]..][0..ipc[i]];
                    if (resolveSpiceFormat(model, i, ck_props)) |fmt| {
                        try expandSpiceFormat(w, gpa, fmt, iname[i], isym[i], ck_props, ck_conns, model.nets.items, symDataTemplate(model, i));
                        continue;
                    }
                }
            }
            if (ispice[i]) |sl| try emitSpiceLine(w, sl);
            continue;
        }

        const inst_props = model.props.items[ips[i]..][0..ipc[i]];
        const inst_conns = model.conns.items[ics[i]..][0..icc[i]];
        const raw_name = iname[i];
        const sym_name = isym[i];

        // Coupling (no pins)
        if (kind == .coupling and inst_conns.len == 0) {
            if (resolveSpiceFormat(model, i, inst_props)) |fmt| {
                try expandSpiceFormat(w, gpa, fmt, raw_name, sym_name, inst_props, inst_conns, model.nets.items, symDataTemplate(model, i));
                continue;
            }
        }

        if (inst_conns.len == 0) continue;
        if (allConnsZero(inst_conns)) continue;

        // Pre-computed spice_line
        if (ispice[i]) |sl| { try emitSpiceLine(w, sl); continue; }

        // spice_format template
        if (resolveSpiceFormat(model, i, inst_props)) |fmt| {
            try expandSpiceFormat(w, gpa, fmt, raw_name, sym_name, inst_props, inst_conns, model.nets.items, symDataTemplate(model, i));
            continue;
        }

        // PDK lookup
        if (pdk) |p| {
            if (p.find(sym_name)) |ref| {
                if (ref.tier == .prim) {
                    const dev = p.resolvedAt(ref.idx);
                    var nets_buf: [16][]const u8 = undefined;
                    const nets = resolveNetsForDevice(&nets_buf, dev.pin_order, inst_conns);
                    const po = try propsToOverrides(gpa, inst_props);
                    defer gpa.free(po);
                    dev.emitSpice(w, raw_name, nets, po, backend) catch |err| try w.print("* ERROR emitting {s}: {}\n", .{ raw_name, err });
                    continue;
                }
            }
        }

        // Builtin device
        if (Devices.Device.fromBuiltin(kind)) |dev| {
            var nets_buf: [16][]const u8 = undefined;
            const nets = resolveNetsForDevice(&nets_buf, dev.pin_order, inst_conns);
            const po = try propsToOverrides(gpa, inst_props);
            defer gpa.free(po);
            dev.emitSpice(w, raw_name, nets, po, backend) catch |err| try w.print("* ERROR emitting {s}: {}\n", .{ raw_name, err });
            continue;
        }

        // Fallback: subcircuit call
        try emitSubcircuitCall(w, raw_name, sym_name, inst_props, inst_conns);
    }

    // 8. spice_body
    if (@hasField(@TypeOf(model.*), "spice_body")) {
        if (model.spice_body) |sb| if (sb.len > 0) try emitSpiceLine(w, sb);
    }

    // 9. Default code blocks
    try emitCodeBlocksForPlace(w, model, gpa, backend, null);

    // 10. .ends
    if (needs_subckt) try w.writeAll(".ends\n");

    // 11. Analyses
    for (model.sym_props.items) |p| {
        if (std.mem.startsWith(u8, p.key, "analysis.")) {
            const at = p.key["analysis.".len..];
            if (parseAnalysis(at, p.val)) |an| {
                try bh.emitAnalysis(w, an);
            } else |_| {}
        }
    }

    // 12. Measures
    for (model.sym_props.items) |p| {
        if (std.mem.startsWith(u8, p.key, "measure.")) {
            const mn = p.key["measure.".len..];
            try emitMeasure(w, mn, p.val, bh);
        }
    }

    // 13. End code blocks
    try emitCodeBlocksForPlace(w, model, gpa, backend, "end");

    // 14. .end
    try w.writeAll(".end\n");
    return out.toOwnedSlice(gpa);
}

// ═════════════════════════════════════════════════════════════════════════════
// spice_format template expansion
// ═════════════════════════════════════════════════════════════════════════════

fn expandSpiceFormat(
    w: anytype,
    gpa: Allocator,
    raw_fmt: []const u8,
    inst_name: []const u8,
    sym_name: []const u8,
    props: []const Property,
    conns: []const Conn,
    _: []const Net,
    template: ?[]const u8,
) !void {
    // Strip tcleval() wrapper
    const fmt = blk: {
        const t = std.mem.trim(u8, raw_fmt, " \t\r\n\"");
        if (std.mem.startsWith(u8, t, "tcleval(") and t.len > 9 and t[t.len - 1] == ')')
            break :blk t["tcleval(".len .. t.len - 1];
        break :blk raw_fmt;
    };

    var buf = List(u8){};
    defer buf.deinit(gpa);
    const bw = buf.writer(gpa);
    var i: usize = 0;

    while (i < fmt.len) {
        if (fmt[i] == '@' and i + 1 < fmt.len) {
            if (fmt[i + 1] == '@') {
                // @@PIN — pin connection
                const start = i + 2;
                var end = start;
                while (end < fmt.len and (std.ascii.isAlphanumeric(fmt[end]) or fmt[end] == '_' or fmt[end] == '[' or fmt[end] == ']' or fmt[end] == ':')) end += 1;
                const pin_name = fmt[start..end];
                if (resolveConnNet(pin_name, conns)) |net_name|
                    try bw.writeAll(net_name)
                else
                    try bw.writeAll(pin_name);
                i = end;
            } else {
                // @token
                const start = i + 1;
                var end = start;
                while (end < fmt.len and (std.ascii.isAlphanumeric(fmt[end]) or fmt[end] == '_')) end += 1;
                const ident = fmt[start..end];

                if (std.mem.eql(u8, ident, "name")) {
                    try bw.writeAll(inst_name);
                } else if (std.mem.eql(u8, ident, "symname")) {
                    try bw.writeAll(normalizedSymbolName(sym_name));
                } else if (std.mem.eql(u8, ident, "pinlist")) {
                    var first = true;
                    for (conns) |c| {
                        if (!first) try bw.writeByte(' ');
                        first = false;
                        try bw.writeAll(resolveConnNet(c.pin, conns) orelse c.net);
                    }
                } else if (findProp(props, ident)) |val| {
                    if (val.len == 0 or std.mem.eql(u8, ident, "savecurrent"))
                        stripTrailingKeyEquals(&buf)
                    else
                        try bw.writeAll(stripExprWrapper(val));
                } else if (findTemplateDefault(template, ident)) |tpl_val| {
                    if (tpl_val.len == 0 or std.mem.eql(u8, ident, "savecurrent"))
                        stripTrailingKeyEquals(&buf)
                    else
                        try bw.writeAll(stripExprWrapper(tpl_val));
                } else if (resolveConnNet(ident, conns)) |net_name| {
                    try bw.writeAll(net_name);
                } else {
                    stripTrailingKeyEquals(&buf);
                }
                i = end;
            }
        } else if (fmt[i] == '"') {
            i += 1;
        } else if (fmt[i] == '[') {
            var depth: u32 = 1;
            i += 1;
            while (i < fmt.len and depth > 0) : (i += 1) {
                if (fmt[i] == '[') depth += 1;
                if (fmt[i] == ']') depth -= 1;
            }
        } else {
            try bw.writeByte(fmt[i]);
            i += 1;
        }
    }

    // Collapse spaces and emit
    const expanded = std.mem.trim(u8, buf.items, " \t");
    if (expanded.len > 0) {
        var prev_space = false;
        for (expanded) |ch| {
            if (ch == ' ' or ch == '\t') {
                if (!prev_space) try w.writeByte(' ');
                prev_space = true;
            } else { try w.writeByte(ch); prev_space = false; }
        }
        try w.writeByte('\n');
    }
}

fn findTemplateDefault(template: ?[]const u8, key: []const u8) ?[]const u8 {
    const tpl = template orelse return null;
    var pos: usize = 0;
    while (pos < tpl.len) {
        while (pos < tpl.len and (tpl[pos] == ' ' or tpl[pos] == '\t' or tpl[pos] == '\n' or tpl[pos] == '\r')) pos += 1;
        if (pos >= tpl.len) break;
        const ks = pos;
        while (pos < tpl.len and tpl[pos] != '=' and tpl[pos] != ' ' and tpl[pos] != '\t' and tpl[pos] != '\n') pos += 1;
        const tk = tpl[ks..pos];
        if (pos < tpl.len and tpl[pos] == '=') {
            pos += 1;
            const vs = pos;
            if (pos < tpl.len and tpl[pos] == '"') {
                pos += 1;
                while (pos < tpl.len and tpl[pos] != '"') pos += 1;
                if (pos < tpl.len) pos += 1;
            } else while (pos < tpl.len and tpl[pos] != ' ' and tpl[pos] != '\t' and tpl[pos] != '\n') pos += 1;
            const val = tpl[vs..pos];
            if (std.mem.eql(u8, tk, key)) {
                if (val.len >= 2 and val[0] == '"' and val[val.len - 1] == '"') return val[1 .. val.len - 1];
                return val;
            }
        } else {
            if (std.mem.eql(u8, tk, key)) return "";
        }
    }
    return null;
}

fn stripTrailingKeyEquals(buf: *List(u8)) void {
    while (buf.items.len > 0 and (buf.items[buf.items.len - 1] == ' ' or buf.items[buf.items.len - 1] == '\t')) buf.items.len -= 1;
    if (buf.items.len == 0 or buf.items[buf.items.len - 1] != '=') return;
    buf.items.len -= 1;
    while (buf.items.len > 0 and (std.ascii.isAlphanumeric(buf.items[buf.items.len - 1]) or buf.items[buf.items.len - 1] == '_')) buf.items.len -= 1;
    while (buf.items.len > 0 and buf.items[buf.items.len - 1] == ' ') buf.items.len -= 1;
}

fn stripExprWrapper(val: []const u8) []const u8 {
    const t = std.mem.trim(u8, val, " \t");
    const s = if (std.mem.startsWith(u8, t, "expr(")) @as(usize, 5) else if (std.mem.startsWith(u8, t, "expr (")) @as(usize, 6) else return val;
    if (std.mem.lastIndexOfScalar(u8, t, ')')) |end| return std.mem.trim(u8, t[s..end], " \t");
    return val;
}

// ═════════════════════════════════════════════════════════════════════════════
// Subcircuit call emission
// ═════════════════════════════════════════════════════════════════════════════

fn emitSubcircuitCall(w: anytype, inst_name: []const u8, sym_name: []const u8, props: []const Property, conns: []const Conn) !void {
    const prefix = findProp(props, "spice_prefix");
    if (prefix) |pfx| {
        if (pfx.len > 0 and pfx[0] != 'X' and pfx[0] != 'x') {
            try w.writeByte(pfx[0]);
            try w.writeAll(inst_name);
            for (conns) |c| { try w.writeByte(' '); try w.writeAll(resolveConnNet(c.pin, conns) orelse c.net); }
            if (findProp(props, "model")) |m| try w.print(" {s}", .{m});
            for (props) |p| {
                if (std.mem.eql(u8, p.key, "model") or isInstanceMetaProp(p.key)) continue;
                try w.print(" {s}={s}", .{ p.key, p.val });
            }
            try w.writeByte('\n');
            return;
        }
    }
    try w.writeAll("X");
    try w.writeAll(inst_name);
    for (conns) |c| { try w.writeByte(' '); try w.writeAll(resolveConnNet(c.pin, conns) orelse c.net); }
    try w.print(" {s}", .{normalizedSymbolName(sym_name)});
    for (props) |p| { if (isInstanceMetaProp(p.key)) continue; try w.print(" {s}={s}", .{ p.key, p.val }); }
    try w.writeByte('\n');
}

// ═════════════════════════════════════════════════════════════════════════════
// Analysis parsing
// ═════════════════════════════════════════════════════════════════════════════

fn parseFreq(s: []const u8) !f64 {
    if (s.len == 0) return 0.0;
    const lc = s[s.len - 1];
    const mult: f64 = switch (lc) {
        'G' => 1e9, 'M' => 1e6, 'K', 'k' => 1e3, 'U', 'u' => 1e-6,
        'N', 'n' => 1e-9, 'P', 'p' => 1e-12, 'F', 'f' => 1e-15, else => 1.0,
    };
    const ne = if (lc >= 'A' and lc <= 'Z' or lc >= 'a' and lc <= 'z') s.len - 1 else s.len;
    if (ne == 0) return 0.0;
    return try std.fmt.parseFloat(f64, s[0..ne]) * mult;
}

fn parseAnalysis(at: []const u8, params: []const u8) !SpiceIF.Analysis {
    if (std.mem.eql(u8, at, "op")) return .{ .op = .{} };
    if (std.mem.eql(u8, at, "ac")) return .{ .ac = .{
        .sweep = .dec,
        .n_points = try std.fmt.parseInt(u32, extractKV(params, "points_per_dec") orelse "20", 10),
        .f_start = try parseFreq(extractKV(params, "start") orelse "1"),
        .f_stop = try parseFreq(extractKV(params, "stop") orelse "1G"),
    } };
    if (std.mem.eql(u8, at, "tran")) return .{ .tran = .{
        .step = try parseFreq(extractKV(params, "step") orelse "1n"),
        .stop = try parseFreq(extractKV(params, "stop") orelse "1u"),
        .start = try parseFreq(extractKV(params, "start") orelse "0"),
    } };
    if (std.mem.eql(u8, at, "dc")) return .{ .dc = .{
        .src1 = extractKV(params, "source") orelse "V1",
        .start1 = try parseFreq(extractKV(params, "start") orelse "0"),
        .stop1 = try parseFreq(extractKV(params, "stop") orelse "1.8"),
        .step1 = try parseFreq(extractKV(params, "step") orelse "0.01"),
    } };
    if (std.mem.eql(u8, at, "noise")) return .{ .noise = .{
        .output_node = extractKV(params, "output") orelse "V(out)",
        .input_src = extractKV(params, "input") orelse "VIN",
        .sweep = .dec, .n_points = 20, .f_start = 1.0, .f_stop = 1e9,
    } };
    if (std.mem.eql(u8, at, "sens")) return .{ .sens = .{ .output_var = extractKV(params, "output") orelse "V(out)", .mode = .dc } };
    if (std.mem.eql(u8, at, "tf")) return .{ .tf = .{ .output_var = extractKV(params, "output") orelse "V(out)", .input_src = extractKV(params, "input") orelse "VIN" } };
    return error.InvalidAnalysis;
}

fn emitMeasure(w: anytype, name: []const u8, expr: []const u8, bh: BackendHandle) !void {
    const t = std.mem.trim(u8, expr, " \t");
    if (t.len == 0) return;
    const mode: SpiceIF.MeasureMode = if (std.mem.indexOf(u8, t, "freq") != null) .ac else if (std.mem.indexOf(u8, t, "time") != null) .tran else .dc;
    try bh.emitMeasure(w, .{ .name = name, .mode = mode, .kind = .{ .find = .{ .var_name = t, .at = 0 } } });
}

pub fn detectBackend(netlist: []const u8) Backend {
    if (std.mem.indexOf(u8, netlist, "analysis ") != null) return .vacask;
    if (std.mem.indexOf(u8, netlist, ".HB") != null) return .xyce;
    return .ngspice;
}

// ═════════════════════════════════════════════════════════════════════════════
// Private helpers
// ═════════════════��═══════════════════════════════════════════════════════════

fn emitSpiceLine(w: anytype, sl: []const u8) !void {
    try w.writeAll(sl);
    if (sl.len == 0 or sl[sl.len - 1] != '\n') try w.writeByte('\n');
}

fn emitIncludes(w: anytype, gpa: Allocator, sym_props: []const Property) !void {
    var seen = std.StringHashMapUnmanaged(void){};
    defer seen.deinit(gpa);
    for (sym_props) |p| {
        if (!std.mem.eql(u8, p.key, "include") or p.val.len == 0) continue;
        var val = std.mem.trim(u8, p.val, " \t\"");
        if (std.mem.startsWith(u8, val, "tcleval(") and val.len > "tcleval()".len and val[val.len - 1] == ')')
            val = std.mem.trim(u8, val["tcleval(".len .. val.len - 1], " \t\r\n\"");
        if (std.mem.indexOf(u8, val, "$::") != null) continue;
        if (seen.contains(val)) continue;
        try seen.put(gpa, val, {});
        if (std.mem.indexOf(u8, val, "section=")) |si| {
            const path = std.mem.trimRight(u8, val[0..si], " \t");
            try w.print(".lib \"{s}\" {s}\n", .{ path, val[si + "section=".len ..] });
        } else try w.print(".include \"{s}\"\n", .{val});
    }
}

fn emitSubcktPorts(w: anytype, gpa: Allocator, model: anytype) !void {
    var seen = std.StringHashMapUnmanaged(void){};
    defer seen.deinit(gpa);
    const pin_names = model.pins.items(.name);
    const pin_widths = model.pins.items(.width);
    for (0..model.pins.len) |pi| {
        if (pin_widths[pi] > 1) {
            const width: i32 = @intCast(pin_widths[pi]);
            var bit: i32 = width - 1;
            try w.writeByte(' ');
            var first = true;
            while (bit >= 0) : (bit -= 1) { if (!first) try w.writeByte(','); first = false; try w.print("{s}[{d}]", .{ pin_names[pi], bit }); }
        } else {
            if (seen.contains(pin_names[pi])) continue;
            seen.put(gpa, pin_names[pi], {}) catch {};
            try w.print(" {s}", .{pin_names[pi]});
        }
    }
}

fn collectPdkPreamble(gpa: Allocator, model: anytype, pdk: *const Devices.Pdk) ![]u8 {
    var cell_names = List([]const u8){};
    defer cell_names.deinit(gpa);
    const isym = model.instances.items(.symbol);
    for (0..model.instances.len) |i| {
        const sym = isym[i];
        for (cell_names.items) |e| { if (std.mem.eql(u8, e, sym)) break; } else try cell_names.append(gpa, sym);
    }
    return pdk.emitPreamble(gpa, cell_names.items, null);
}

fn emitTestbenchParams(w: anytype, model: anytype) !void {
    for (model.sym_props.items) |p| {
        if (h.isSymPropMetadata(p.key)) continue;
        if (p.val.len > 0 and p.val[0] == '{')
            try w.print(".param {s} = {s}\n", .{ p.key, p.val[1 .. p.val.len - 1] });
    }
}

fn emitCodeBlocksForPlace(w: anytype, model: anytype, gpa: Allocator, backend: Backend, place: ?[]const u8) !void {
    const ikind = model.instances.items(.kind);
    const ips = model.instances.items(.prop_start);
    const ipc = model.instances.items(.prop_count);
    const ispice = model.instances.items(.spice_line);
    for (0..model.instances.len) |i| {
        if (ikind[i] != .code and ikind[i] != .param) continue;
        const cp = model.props.items[ips[i]..][0..ipc[i]];
        if (place) |target| { if (!codePlaceIs(cp, target)) continue; } else if (codePlaceIs(cp, "header") or codePlaceIs(cp, "end")) continue;
        if (!shouldEmitCode(cp, backend)) continue;
        if (ispice[i]) |sl| try emitSpiceLine(w, sl) else try emitCodeValue(w, gpa, cp);
    }
}

fn resolveSpiceFormat(model: anytype, i: usize, props: []const Property) ?[]const u8 {
    return findProp(props, "spice_format") orelse findProp(props, "lvs_format") orelse findProp(props, "format") orelse symDataFormat(model, i);
}

fn symDataFormat(model: anytype, i: usize) ?[]const u8 {
    if (!@hasField(@TypeOf(model.*), "sym_data")) return null;
    if (i >= model.sym_data.items.len) return null;
    const sd = model.sym_data.items[i];
    return sd.lvs_format orelse sd.format;
}

fn symDataTemplate(model: anytype, i: usize) ?[]const u8 {
    if (!@hasField(@TypeOf(model.*), "sym_data")) return null;
    if (i >= model.sym_data.items.len) return null;
    return model.sym_data.items[i].template;
}

fn extractKV(params: []const u8, key: []const u8) ?[]const u8 {
    var it = std.mem.tokenizeAny(u8, params, " \t");
    while (it.next()) |tok| {
        if (std.mem.startsWith(u8, tok, key) and tok.len > key.len and tok[key.len] == '=') return tok[key.len + 1 ..];
    }
    return null;
}

fn normalizedSymbolName(sym: []const u8) []const u8 {
    const base = if (std.mem.lastIndexOfScalar(u8, sym, '/')) |s| sym[s + 1 ..] else sym;
    if (std.mem.endsWith(u8, base, ".sym")) return base[0 .. base.len - 4];
    if (std.mem.endsWith(u8, base, ".chn_prim")) return base[0 .. base.len - 9];
    if (std.mem.endsWith(u8, base, ".chn")) return base[0 .. base.len - 4];
    return base;
}

fn isInstanceMetaProp(key: []const u8) bool {
    const meta = std.StaticStringMap(void).initComptime(.{
        .{ "name", {} }, .{ "spice_prefix", {} }, .{ "spice_format", {} },
        .{ "format", {} }, .{ "lvs_format", {} }, .{ "template", {} },
        .{ "type", {} }, .{ "device_model", {} }, .{ "spice_sym_def", {} }, .{ "savecurrent", {} },
    });
    return meta.has(key);
}

fn findProp(props: []const Property, key: []const u8) ?[]const u8 {
    for (props) |p| if (std.mem.eql(u8, p.key, key)) return p.val;
    return null;
}

fn resolveConnNet(pin_name: []const u8, conns: []const Conn) ?[]const u8 {
    for (conns) |c| if (std.ascii.eqlIgnoreCase(c.pin, pin_name)) return c.net;
    return null;
}

fn resolveNetsForDevice(buf: [][]const u8, pin_order: []const []const u8, conns: []const Conn) []const []const u8 {
    const n = @min(pin_order.len, buf.len);
    for (pin_order[0..n], 0..n) |pin, idx| buf[idx] = resolveConnNet(pin, conns) orelse "0";
    return buf[0..n];
}

fn allConnsZero(conns: []const Conn) bool {
    for (conns) |c| if (!std.mem.eql(u8, c.net, "0")) return false;
    return true;
}

fn propsToOverrides(gpa: Allocator, props: []const Property) ![]const SpiceIF.ParamOverride {
    const o = try gpa.alloc(SpiceIF.ParamOverride, props.len);
    for (props, o) |p, *slot| slot.* = .{ .name = p.key, .value = .{ .expr = stripExprWrapper(p.val) } };
    return o;
}

fn codePlaceIs(props: []const Property, place: []const u8) bool {
    for (props) |p| if (std.mem.eql(u8, p.key, "place")) return std.mem.eql(u8, p.val, place);
    return false;
}

fn shouldEmitCode(props: []const Property, backend: Backend) bool {
    for (props) |p| {
        if (std.mem.eql(u8, p.key, "simulator") and p.val.len > 0) {
            const want: []const u8 = switch (backend) { .ngspice => "ngspice", .xyce => "xyce", .vacask => "vacask" };
            if (!std.mem.eql(u8, p.val, want)) return false;
        }
        if (std.mem.eql(u8, p.key, "spice_ignore") and (std.mem.eql(u8, p.val, "true") or std.mem.eql(u8, p.val, "1"))) return false;
    }
    return true;
}

fn emitCodeValue(w: anytype, gpa: Allocator, props: []const Property) !void {
    for (props) |p| {
        if (!std.mem.eql(u8, p.key, "value") or p.val.len == 0) continue;
        var raw = List(u8){};
        defer raw.deinit(gpa);
        var i: usize = 0;
        while (i < p.val.len) {
            if (p.val[i] == '\\' and i + 1 < p.val.len) {
                const nc = p.val[i + 1];
                if (nc == '\\' and i + 2 < p.val.len and p.val[i + 2] == '"') { try raw.append(gpa, '"'); i += 3; }
                else if (nc == '"') { try raw.append(gpa, '"'); i += 2; }
                else if (nc == '{' or nc == '}') { try raw.append(gpa, nc); i += 2; }
                else { try raw.append(gpa, p.val[i]); i += 1; }
            } else { try raw.append(gpa, p.val[i]); i += 1; }
        }
        var it = std.mem.splitScalar(u8, raw.items, '\n');
        while (it.next()) |ln| {
            const rt = std.mem.trimRight(u8, ln, " \t\r");
            var t = std.mem.trimLeft(u8, rt, " \t");
            const indent = rt[0 .. rt.len - t.len];
            if (std.mem.startsWith(u8, t, "tcleval(") and t.len > "tcleval()".len and t[t.len - 1] == ')')
                t = std.mem.trim(u8, t["tcleval(".len .. t.len - 1], " \t\r\n");
            if (t.len > 0) { try w.writeAll(indent); try w.writeAll(t); }
            try w.writeByte('\n');
        }
        return;
    }
}
