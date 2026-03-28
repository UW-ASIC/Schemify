const std = @import("std");
const Allocator = std.mem.Allocator;
const List = std.ArrayListUnmanaged;

const sch = @import("Schemify.zig");
const Schemify = sch.Schemify;
const Prop = sch.Prop;
const Conn = sch.Conn;
const Net = sch.Net;
const Backend = @import("SpiceIF.zig").Backend;
const NetlistMode = @import("SpiceIF.zig").NetlistMode;
const Devices = @import("Devices.zig");
const YosysJson = @import("YosysJson.zig");
const Vfs = @import("utility").Vfs;

pub const Netlist = struct {
    /// Emit a SPICE netlist from the Schemify model.
    ///
    /// Implements Arch.md Section 8:
    ///   8.1 .chn → SPICE (subcircuit wrapping, template expansion, net resolution)
    ///   8.2 .chn_testbench → SPICE (includes, analyses, measures)
    pub fn emitSpice(
        self: *const Schemify,
        gpa: Allocator,
        backend: Backend,
        pdk: ?*const Devices.Pdk,
        mode: NetlistMode,
    ) ![]u8 {
        var out = List(u8){};
        errdefer out.deinit(gpa);
        const w = out.writer(gpa);

        // ── 1. Comment header ───────────────────────────────────────────────
        try w.print("* Schemify netlist: {s}\n", .{self.name});

        // ── 2. .lib includes (Arch.md 6 — testbench includes) ───────────────
        var seen_includes = std.StringHashMapUnmanaged(void){};
        defer seen_includes.deinit(gpa);
        for (self.sym_props.items) |p| {
            if (std.mem.eql(u8, p.key, "include") and p.val.len > 0) {
                // Format: "path" section=corner  OR  just "path"
                var val = std.mem.trim(u8, p.val, " \t\"");
                // Strip tcleval() wrapper if present
                if (std.mem.startsWith(u8, val, "tcleval(") and
                    val.len > "tcleval()".len and val[val.len - 1] == ')')
                {
                    val = std.mem.trim(u8, val["tcleval(".len .. val.len - 1], " \t\r\n\"");
                }
                // Skip includes with unresolved Tcl variables ($::...)
                if (std.mem.indexOf(u8, val, "$::") != null) continue;
                // Deduplicate includes
                if (seen_includes.contains(val)) continue;
                try seen_includes.put(gpa, val, {});
                if (std.mem.indexOf(u8, val, "section=")) |sec_idx| {
                    const path = std.mem.trimRight(u8, val[0..sec_idx], " \t");
                    const section = val[sec_idx + "section=".len ..];
                    try w.print(".lib \"{s}\" {s}\n", .{ path, section });
                } else {
                    try w.print(".include \"{s}\"\n", .{val});
                }
            }
        }

        // ── 3. .subckt header (Arch.md 8.1 step 1) ─────────────────────────
        const needs_subckt = self.stype != .testbench;
        if (needs_subckt) {
            try w.print(".subckt {s}", .{self.name});
            const pin_names = self.pins.items(.name);
            const pin_widths = self.pins.items(.width);
            // De-duplicate port names (XSchem doublepin symbols have multiple
            // pins with the same name but only emit each name once in the
            // .subckt header).
            var seen_ports = std.StringHashMapUnmanaged(void){};
            defer seen_ports.deinit(gpa);
            for (0..self.pins.len) |pi| {
                if (pin_widths[pi] > 1) {
                    // Bus pin: expand to individual bits, comma-separated
                    const width: i32 = @intCast(pin_widths[pi]);
                    var bit: i32 = width - 1;
                    try w.writeByte(' ');
                    var first_bit = true;
                    while (bit >= 0) : (bit -= 1) {
                        if (!first_bit) try w.writeByte(',');
                        first_bit = false;
                        try w.print("{s}[{d}]", .{ pin_names[pi], bit });
                    }
                } else if (parseTokenBusRange(pin_names[pi])) |bus| {
                    const step: i32 = if (bus.first > bus.last) -1 else 1;
                    var idx = bus.first;
                    try w.writeByte(' ');
                    var first_bit = true;
                    while (true) {
                        if (!first_bit) try w.writeByte(',');
                        first_bit = false;
                        try w.print("{s}[{d}]", .{ bus.prefix, idx });
                        if (idx == bus.last) break;
                        idx += step;
                    }
                } else {
                    if (seen_ports.contains(pin_names[pi])) continue;
                    seen_ports.put(gpa, pin_names[pi], {}) catch {};
                    try w.print(" {s}", .{pin_names[pi]});
                }
            }
            try w.writeByte('\n');
        }

        // ── 4. PDK preamble ─────────────────────────────────────────────────
        if (pdk) |p| {
            var cell_names = List([]const u8){};
            defer cell_names.deinit(gpa);
            const isym = self.instances.items(.symbol);
            for (0..self.instances.len) |i| {
                const sym = isym[i];
                for (cell_names.items) |existing| {
                    if (std.mem.eql(u8, existing, sym)) break;
                } else {
                    try cell_names.append(gpa, sym);
                }
            }
            const preamble = try p.emitPreamble(gpa, cell_names.items, null);
            defer gpa.free(preamble);
            try w.writeAll(preamble);
        }

        // ── 5. .param blocks (Arch.md params with expressions) ──────────────
        // Emit SYMBOL params as .param if the schematic is a testbench
        // (component params become subcircuit parameters via .subckt header).
        if (self.stype == .testbench) {
            for (self.sym_props.items) |p| {
                if (isSymPropMetadata(p.key)) continue;
                if (p.val.len > 0 and p.val[0] == '{') {
                    // Expression param
                    try w.print(".param {s} = {s}\n", .{ p.key, p.val[1 .. p.val.len - 1] });
                }
            }
        }

        const sli = self.instances.slice();
        const iname = sli.items(.name);
        const isym = sli.items(.symbol);
        const ikind = sli.items(.kind);
        const ips = sli.items(.prop_start);
        const ipc = sli.items(.prop_count);
        const ics = sli.items(.conn_start);
        const icc = sli.items(.conn_count);
        const ispice = sli.items(.spice_line);

        // ── 6. Header code blocks ───────────────────────────────────────────
        try emitCodeBlocksForPlace(w, self, backend, "header");

        // ── 7. Instance emission (Arch.md 8.1 steps 2-3) ───────────────────
        //
        // For each instance:
        //   a) If spice_line is pre-computed, emit directly (legacy xschem path)
        //   b) Try spice_format template expansion (Arch.md .chn_prim path)
        //   c) Try PDK device lookup
        //   d) Try builtin device emission
        //   e) Fallback: emit subcircuit call X<name> <nets> <symbol> <params>
        for (0..self.instances.len) |i| {
            const kind = ikind[i];

            if (kind == .code or kind == .param) continue;
            if (kind.isNonElectrical()) {
                // Unknown/generic kinds with connections and a format string
                // are XSchem primitives that should emit via format expansion.
                if (kind == .unknown or kind == .generic) {
                    const ck_conns = self.conns.items[ics[i]..][0..icc[i]];
                    if (ck_conns.len > 0 and !allConnsZero(ck_conns, self.nets.items)) {
                        const ck_props = self.props.items[ips[i]..][0..ipc[i]];
                        const fmt = findProp(ck_props, "spice_format") orelse
                            findProp(ck_props, "lvs_format") orelse
                            findProp(ck_props, "format") orelse
                            (if (i < self.sym_data.items.len) (self.sym_data.items[i].lvs_format orelse self.sym_data.items[i].format) else null) orelse
                            findSymPropFormat(self, isym[i]);
                        if (fmt) |f| {
                            const tpl = if (i < self.sym_data.items.len) self.sym_data.items[i].template else null;
                            // Try bus instance multiplication first
                            if (!try emitBusExpanded(w, gpa, iname[i], isym[i], ck_props, ck_conns, self.nets.items, f, tpl, false)) {
                                try expandSpiceFormat(w, f, iname[i], isym[i], ck_props, ck_conns, self.nets.items, tpl);
                            }
                            continue;
                        }
                    }
                }
                // Probes: emit .save directives if pre-computed
                if (ispice[i]) |sl| try emitSpiceLine(w, sl);
                continue;
            }

            const inst_props = self.props.items[ips[i]..][0..ipc[i]];
            const inst_conns = self.conns.items[ics[i]..][0..icc[i]];
            const raw_name = iname[i];
            const sym_name = isym[i];

            // Coupling elements (K) have no pins/connections but still need
            // format expansion: `@name @L1 @L2 @K` uses only property refs.
            if (kind == .coupling and inst_conns.len == 0) {
                const fmt = findProp(inst_props, "format") orelse
                    (if (i < self.sym_data.items.len) (self.sym_data.items[i].lvs_format orelse self.sym_data.items[i].format) else null) orelse
                    findSymPropFormat(self, sym_name);
                if (fmt) |f| {
                    const tpl = if (i < self.sym_data.items.len) self.sym_data.items[i].template else null;
                    try expandSpiceFormat(w, f, raw_name, sym_name, inst_props, inst_conns, self.nets.items, tpl);
                    continue;
                }
            }

            // Skip instances with no connections, or where all connections
            // resolve to "0" (unconnected pins from .sym internal instances).
            // XSchem treats these as black-box primitives and does not emit them.
            if (inst_conns.len == 0) continue;
            if (allConnsZero(inst_conns, self.nets.items)) continue;

            // (a) Pre-computed spice_line
            if (ispice[i]) |sl| {
                try emitSpiceLine(w, sl);
                continue;
            }

            // (b) spice_format template (Arch.md Section 5.2)
            // Check instance props first, then sym_data lvs_format/format, then sym_props.
            // Prefer lvs_format over format (XSchem defaults to LVS netlisting mode).
            const spice_fmt = findProp(inst_props, "spice_format") orelse
                findProp(inst_props, "lvs_format") orelse
                findProp(inst_props, "format") orelse
                (if (i < self.sym_data.items.len) (self.sym_data.items[i].lvs_format orelse self.sym_data.items[i].format) else null) orelse
                findSymPropFormat(self, sym_name);
            if (spice_fmt) |fmt| {
                const tpl = if (i < self.sym_data.items.len) self.sym_data.items[i].template else null;
                // Try bus instance multiplication first
                if (try emitBusExpanded(w, gpa, raw_name, sym_name, inst_props, inst_conns, self.nets.items, fmt, tpl, false)) {
                    // Bus expansion handled emission
                } else {
                    try expandSpiceFormat(w, fmt, raw_name, sym_name, inst_props, inst_conns, self.nets.items, tpl);
                }
                // savecurrent=true → emit `.save i(<name>)` after the instance line
                const sc_val = findProp(inst_props, "savecurrent") orelse
                    findTemplateDefault(tpl, "savecurrent");
                if (sc_val) |sc| {
                    if (std.mem.eql(u8, sc, "true")) {
                        try w.print(".save i({s})\n", .{raw_name});
                    }
                }
                continue;
            }

            // (c) PDK lookup
            if (pdk) |p| {
                if (p.find(sym_name)) |ref| {
                    switch (ref.tier) {
                        .prim => {
                            const dev = p.resolvedAt(ref.idx);
                            var nets_buf: [16][]const u8 = undefined;
                            const nets = resolveNetsForDevice(&nets_buf, dev.pin_order, inst_conns, self.nets.items);
                            const po = try propsToParamOverrides(gpa, inst_props);
                            defer gpa.free(po);
                            dev.emitSpice(w, raw_name, nets, po, backend) catch |err| {
                                try w.print("* ERROR emitting {s}: {}\n", .{ raw_name, err });
                            };
                            continue;
                        },
                        .comp => {
                            const comp = p.getComponent(ref.idx);
                            var nets_buf: [32][]const u8 = undefined;
                            const nets = resolveNetsForDevice(&nets_buf, comp.pin_order, inst_conns, self.nets.items);
                            const po = try propsToParamOverrides(gpa, inst_props);
                            defer gpa.free(po);
                            const sc = Devices.SpiceComponent{ .subcircuit = .{
                                .name = comp.cell_name,
                                .inst_name = raw_name,
                                .nodes = nets,
                                .params = po,
                            } };
                            try Devices.emitComponent(w, sc, backend);
                            continue;
                        },
                        .tb => continue,
                        .unregistered => {},
                    }
                }
            }

            // (d) Builtin device from DeviceKind
            if (Devices.Device.fromBuiltin(kind)) |dev| {
                var nets_buf: [16][]const u8 = undefined;
                const nets = resolveNetsForDevice(&nets_buf, dev.pin_order, inst_conns, self.nets.items);
                const po = try propsToParamOverrides(gpa, inst_props);
                defer gpa.free(po);
                dev.emitSpice(w, raw_name, nets, po, backend) catch |err| {
                    try w.print("* ERROR emitting {s}: {}\n", .{ raw_name, err });
                };
                continue;
            }

            // (e) Fallback: subcircuit call (Arch.md 8.1 step 3)
            // Try bus instance multiplication first
            if (!try emitBusExpanded(w, gpa, raw_name, sym_name, inst_props, inst_conns, self.nets.items, null, null, true)) {
                try emitSubcircuitCall(w, raw_name, sym_name, inst_props, inst_conns, self.nets.items);
            }
        }

        // ── 8. spice_body (raw user SPICE) ──────────────────────────────────
        if (self.spice_body) |sb| {
            if (sb.len > 0) try emitSpiceLine(w, sb);
        }

        // ── 9. Default code blocks ──────────────────────────────────────────
        try emitCodeBlocksForPlace(w, self, backend, null);

        // ── 10. Digital blocks (Arch.md TODO.md) ────────────────────────────
        if (self.digital) |dig| {
            try emitDigitalBlock(w, self, &dig, backend, mode, gpa);
        }

        // ── 11. .ends ───────────────────────────────────────────────────────
        if (needs_subckt) {
            try w.writeAll(".ends\n");
        }

        // ── 12. Inline subcircuit definitions ───────────────────────────────
        if (self.inline_spice) |is| {
            if (is.len > 0) try emitSpiceLine(w, is);
        }

        // ── 13. spice_sym_def blocks ────────────────────────────────────────
        {
            var seen_sym_def = std.StringHashMapUnmanaged(void){};
            defer seen_sym_def.deinit(gpa);
            for (0..self.instances.len) |i| {
                if (ikind[i] == .code or ikind[i] == .param) continue;
                if (ikind[i].isNonElectrical()) continue;
                if (i >= self.sym_data.items.len) continue;
                const sd = self.sym_data.items[i];
                var raw_ssd: ?[]const u8 = null;
                for (sd.props) |sp| {
                    if (std.mem.eql(u8, sp.key, "spice_sym_def")) {
                        raw_ssd = sp.val;
                        break;
                    }
                }
                const ssd_raw = raw_ssd orelse continue;
                var ssd = std.mem.trim(u8, ssd_raw, " \t\r\n\"");
                if (std.mem.startsWith(u8, ssd, "tcleval(") and
                    ssd.len > "tcleval()".len and ssd[ssd.len - 1] == ')')
                {
                    ssd = std.mem.trim(u8, ssd["tcleval(".len .. ssd.len - 1], " \t\r\n");
                }
                if (std.mem.indexOf(u8, ssd, "$") != null) continue;
                if (ssd.len == 0) continue;
                if (seen_sym_def.contains(isym[i])) continue;
                try seen_sym_def.put(gpa, isym[i], {});
                try emitSpiceLine(w, ssd);
            }
        }

        // ── 14. .GLOBAL directives ──────────────────────────────────────────
        for (self.globals.items) |gn| {
            // Skip "0" — SPICE ground node is always implicitly global.
            if (std.mem.eql(u8, gn, "0")) continue;
            try w.print(".GLOBAL {s}\n", .{gn});
        }

        // ── 15. Device model blocks ─────────────────────────────────────────
        var seen_dm = std.StringHashMapUnmanaged(void){};
        defer {
            var kit = seen_dm.keyIterator();
            while (kit.next()) |k| gpa.free(k.*);
            seen_dm.deinit(gpa);
        }
        for (0..self.instances.len) |i| {
            if (ikind[i] == .code or ikind[i] == .param) continue;
            if (ikind[i].isNonElectrical()) continue;
            try emitDeviceModelBlock(w, gpa, self.props.items[ips[i]..][0..ipc[i]], &seen_dm);
        }

        // ── 16. Analyses (Arch.md 8.2 step 3) ──────────────────────────────
        for (self.sym_props.items) |p| {
            if (std.mem.startsWith(u8, p.key, "analysis.")) {
                const analysis_type = p.key["analysis.".len..];
                try emitAnalysis(w, analysis_type, p.val, backend);
            }
        }

        // ── 17. Measures (Arch.md 8.2 step 4) ──────────────────────────────
        for (self.sym_props.items) |p| {
            if (std.mem.startsWith(u8, p.key, "measure.")) {
                const meas_name = p.key["measure.".len..];
                try emitMeasure(w, meas_name, p.val);
            }
        }

        // ── 18. End code blocks ─────────────────────────────────────────────
        try emitCodeBlocksForPlace(w, self, backend, "end");

        // ── 19. .end ────────────────────────────────────────────────────────
        try w.writeAll(".end\n");
        return out.toOwnedSlice(gpa);
    }
};

// =============================================================================
// spice_format template expansion (Arch.md Section 5.2)
// =============================================================================

/// Expand a spice_format template.
/// XSchem format conventions:
///   `@name`    → instance name (with SPICE prefix prepended)
///   `@@PIN`    → pin connection (resolve pin name to net via conns)
///   `@pinlist` → all pin connections in order
///   `@symname` → symbol/subcircuit name (without path or .sym extension)
///   `@prop`    → property value from instance props
///
/// When `@prop` resolves to an empty string or is not found, and the output
/// already contains a preceding `key=` pattern, the entire `key=` is removed
/// (XSchem omits unresolved key=value pairs from the output).
fn expandSpiceFormat(
    w: anytype,
    raw_fmt: []const u8,
    inst_name: []const u8,
    sym_name: []const u8,
    props: []const Prop,
    conns: []const Conn,
    all_nets: []const Net,
    template: ?[]const u8,
) !void {
    // Strip tcleval(...) wrapper if present — we can't evaluate Tcl,
    // but we can still do @-token expansion on the inner format string.
    const fmt = blk: {
        const trimmed = std.mem.trim(u8, raw_fmt, " \t\r\n\"");
        if (std.mem.startsWith(u8, trimmed, "tcleval(") and trimmed.len > 9 and trimmed[trimmed.len - 1] == ')') {
            break :blk trimmed["tcleval(".len .. trimmed.len - 1];
        }
        break :blk raw_fmt;
    };

    // First pass: expand into a temporary buffer so we can strip empty key= pairs.
    var buf = List(u8){};
    defer buf.deinit(std.heap.page_allocator);
    const bw = buf.writer(std.heap.page_allocator);

    var had_tcl_skip = false;
    var i: usize = 0;
    while (i < fmt.len) {
        if (fmt[i] == '@' and i + 1 < fmt.len) {
            if (fmt[i + 1] == '@') {
                // @@ token: pin connection reference
                const start = i + 2;
                var end = start;
                while (end < fmt.len and (std.ascii.isAlphanumeric(fmt[end]) or
                    fmt[end] == '_' or fmt[end] == '[' or fmt[end] == ']' or
                    fmt[end] == ':')) : (end += 1)
                {}
                const pin_name = fmt[start..end];
                if (pin_name.len > 0) {
                    if (resolveConnNet(pin_name, conns, all_nets)) |net_name| {
                        try writeNetForPin(bw, net_name, pin_name);
                    } else {
                        try writeNetExpanded(bw, pin_name);
                    }
                }
                i = end;
            } else {
                // Single @ token: name, pinlist, or property
                const start = i + 1;
                var end = start;
                while (end < fmt.len and (std.ascii.isAlphanumeric(fmt[end]) or fmt[end] == '_')) : (end += 1) {}
                const ident = fmt[start..end];

                if (std.mem.eql(u8, ident, "name")) {
                    try bw.writeAll(inst_name);
                } else if (std.mem.eql(u8, ident, "symname")) {
                    try bw.writeAll(normalizedSymbolName(sym_name));
                } else if (std.mem.eql(u8, ident, "pinlist")) {
                    // Emit unique pin connections (deduplicate by pin name).
                    // XSchem symbols may have duplicate pin names for multiple
                    // physical connections to the same electrical node.
                    var first_pin = true;
                    for (conns, 0..) |c, ci| {
                        // Skip if this pin name appeared earlier in the list
                        var dup = false;
                        for (conns[0..ci]) |prev| {
                            if (std.mem.eql(u8, prev.pin, c.pin)) {
                                dup = true;
                                break;
                            }
                        }
                        if (dup) continue;
                        if (!first_pin) try bw.writeByte(' ');
                        first_pin = false;
                        const net = resolveConnNet(c.pin, conns, all_nets) orelse c.net;
                        try writeNetForPin(bw, net, c.pin);
                    }
                } else if (findProp(props, ident)) |val| {
                    if (val.len == 0) {
                        // Empty property: backtrack to remove preceding `key=`
                        stripTrailingKeyEquals(&buf);
                    } else if (std.mem.eql(u8, ident, "savecurrent")) {
                        // XSchem boolean token: never emitted in the format line.
                        // Strip preceding "savecurrent=" if present.
                        stripTrailingKeyEquals(&buf);
                    } else {
                        try bw.writeAll(stripExprWrapper(val));
                    }
                } else if (findTemplateDefault(template, ident)) |tpl_val| {
                    // Property has a default in the symbol template
                    if (tpl_val.len == 0 or std.mem.eql(u8, ident, "savecurrent")) {
                        // Empty or special boolean token: strip preceding key=
                        stripTrailingKeyEquals(&buf);
                    } else {
                        try bw.writeAll(stripExprWrapper(tpl_val));
                    }
                } else if (resolveConnNet(ident, conns, all_nets)) |net_name| {
                    // Fallback: try as pin name (some formats use single-@ for pins)
                    try bw.writeAll(net_name);
                } else {
                    // Unresolved token — backtrack to remove preceding `key=`
                    stripTrailingKeyEquals(&buf);
                }
                i = end;
            }
        } else if (fmt[i] == '"') {
            // Skip quotes in format string
            i += 1;
        } else if (fmt[i] == '[') {
            // Skip Tcl command brackets [...] — we can't evaluate Tcl,
            // so discard the entire bracketed sub-command.
            // The converter pre-evaluates Tcl and stores results as instance
            // props, so we emit unreferenced instance props after the loop.
            had_tcl_skip = true;
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

    // When [cmd] blocks were skipped, the converter may have pre-evaluated
    // the Tcl and stored computed values as instance props (e.g. Res, Cap).
    // Emit any instance props NOT referenced by @-tokens in the format and
    // not meta-props (name, format, spice_prefix, spice_format).
    if (had_tcl_skip) {
        for (props) |p| {
            if (isInstanceMetaProp(p.key)) continue;
            if (p.val.len == 0) continue;
            // Skip props that appear as @-tokens anywhere in the format
            if (isTokenInFormat(fmt, p.key)) continue;
            try bw.writeByte(' ');
            try bw.writeAll(p.key);
            try bw.writeByte('=');
            try bw.writeAll(p.val);
        }
    }

    // Collapse multiple consecutive spaces to one and trim trailing whitespace.
    const expanded = std.mem.trim(u8, buf.items, " \t");
    if (expanded.len > 0) {
        var prev_space = false;
        for (expanded) |ch| {
            if (ch == ' ' or ch == '\t') {
                if (!prev_space) try w.writeByte(' ');
                prev_space = true;
            } else {
                try w.writeByte(ch);
                prev_space = false;
            }
        }
        try w.writeByte('\n');
    }
}

/// Look up a key in the symbol template string and return its default value.
/// Template format: key=value pairs separated by spaces, tabs, or newlines.
/// Values may be quoted with double quotes (e.g. `value="some string"`).
/// Returns null if the key is not found.
fn findTemplateDefault(template: ?[]const u8, key: []const u8) ?[]const u8 {
    const tpl = template orelse return null;
    var pos: usize = 0;
    while (pos < tpl.len) {
        // Skip leading whitespace (spaces, tabs, newlines, carriage returns)
        while (pos < tpl.len and (tpl[pos] == ' ' or tpl[pos] == '\t' or tpl[pos] == '\n' or tpl[pos] == '\r')) : (pos += 1) {}
        if (pos >= tpl.len) break;

        // Find the key portion (up to '=' or whitespace)
        const key_start = pos;
        while (pos < tpl.len and tpl[pos] != '=' and tpl[pos] != ' ' and tpl[pos] != '\t' and tpl[pos] != '\n' and tpl[pos] != '\r') : (pos += 1) {}

        const tpl_key = tpl[key_start..pos];

        if (pos < tpl.len and tpl[pos] == '=') {
            pos += 1; // skip '='
            // Parse the value
            const val_start = pos;
            if (pos < tpl.len and tpl[pos] == '"') {
                // Quoted value — find closing quote
                pos += 1;
                while (pos < tpl.len and tpl[pos] != '"') : (pos += 1) {}
                if (pos < tpl.len) pos += 1; // skip closing quote
            } else {
                // Unquoted value — up to next whitespace
                while (pos < tpl.len and tpl[pos] != ' ' and tpl[pos] != '\t' and tpl[pos] != '\n' and tpl[pos] != '\r') : (pos += 1) {}
            }
            const val = tpl[val_start..pos];

            if (std.mem.eql(u8, tpl_key, key)) {
                // Strip surrounding quotes if present
                if (val.len >= 2 and val[0] == '"' and val[val.len - 1] == '"') {
                    return val[1 .. val.len - 1];
                }
                return val;
            }
        } else {
            // No '=' — standalone key with no value; skip
            if (std.mem.eql(u8, tpl_key, key)) return "";
        }
    }
    return null;
}

/// Remove a trailing `key=` (or ` key=`) pattern from the buffer.
/// Called when `@prop` resolves to empty, so the dangling `key=` is removed.
fn stripTrailingKeyEquals(buf: *List(u8)) void {
    // Strip trailing whitespace first
    while (buf.items.len > 0 and (buf.items[buf.items.len - 1] == ' ' or buf.items[buf.items.len - 1] == '\t')) {
        buf.items.len -= 1;
    }
    // Check if the buffer ends with `=`
    if (buf.items.len == 0 or buf.items[buf.items.len - 1] != '=') return;
    // Remove `=` and the preceding key identifier (alnum + underscore)
    buf.items.len -= 1;
    while (buf.items.len > 0 and (std.ascii.isAlphanumeric(buf.items[buf.items.len - 1]) or buf.items[buf.items.len - 1] == '_')) {
        buf.items.len -= 1;
    }
    // Remove leading space before the key
    while (buf.items.len > 0 and buf.items[buf.items.len - 1] == ' ') {
        buf.items.len -= 1;
    }
}

/// Resolve a pin name to its net name via the conns list.
fn resolveConnNet(pin_name: []const u8, conns: []const Conn, _: []const Net) ?[]const u8 {
    for (conns) |c| {
        if (pinNameMatch(c.pin, pin_name)) {
            return c.net;
        }
    }
    return null;
}

/// Write a net name to the buffer, expanding bus ranges into individual bits.
/// e.g. "AA[3:0]" → "AA[3] AA[2] AA[1] AA[0]"
///      "DIN[4..1]" → "DIN4 DIN3 DIN2 DIN1"
///      "VCC" → "VCC" (scalar, no expansion)
fn writeNetExpanded(bw: anytype, net_name: []const u8) !void {
    if (parseBusRange(net_name)) |bus| {
        try writeBusExpansion(bw, bus);
    } else {
        try bw.writeAll(net_name);
    }
}

/// Write individual bits of a BusRange.
fn writeBusExpansion(bw: anytype, bus: BusRange) !void {
    const step: i32 = if (bus.first > bus.last) -1 else 1;
    var idx = bus.first;
    var first = true;
    while (true) {
        if (!first) try bw.writeByte(' ');
        first = false;
        if (bus.dot_sep) {
            try bw.print("{s}{d}", .{ bus.prefix, idx });
        } else {
            try bw.print("{s}[{d}]", .{ bus.prefix, idx });
        }
        if (idx == bus.last) break;
        idx += step;
    }
}

/// Write a net name expanded to match a pin's bus width.
/// When the pin name has a bus range (e.g., A[3:0]) and the net is scalar
/// (e.g., net3), XSchem auto-expands the net to net3[3] net3[2] net3[1] net3[0]
/// to match the pin width. If the net already has a bus range, it is expanded
/// as-is (standard behavior). If the pin has no bus range, the net is written
/// as-is.
fn writeNetForPin(bw: anytype, net_name: []const u8, pin_name: []const u8) !void {
    if (parseBusRange(net_name)) |bus| {
        // Net has its own bus range — expand it directly
        try writeBusExpansion(bw, bus);
    } else if (parseBusRange(pin_name)) |pin_bus| {
        // Scalar net on bus pin — auto-expand using pin's range
        try writeBusExpansion(bw, .{
            .prefix = net_name,
            .first = pin_bus.first,
            .last = pin_bus.last,
            .width = pin_bus.width,
            .dot_sep = false, // auto-expanded nets use bracket notation
        });
    } else {
        try bw.writeAll(net_name);
    }
}

// =============================================================================
// Subcircuit call emission (Arch.md 8.1 step 3)
// =============================================================================

/// Emit: X<name> <net1> <net2> ... <subckt_name> [param=val ...]
fn emitSubcircuitCall(
    w: anytype,
    inst_name: []const u8,
    sym_name: []const u8,
    props: []const Prop,
    conns: []const Conn,
    all_nets: []const Net,
) !void {
    // Determine prefix — use spice_prefix from props or default to 'X'
    const prefix = findProp(props, "spice_prefix");
    if (prefix) |pfx| {
        if (pfx.len > 0 and pfx[0] != 'X' and pfx[0] != 'x') {
            // Non-X prefix means this is a primitive with known pin order
            // but no spice_format — emit name + nets + model
            try w.writeByte(pfx[0]);
            try w.writeAll(inst_name);
            for (conns) |c| {
                const net = resolveConnNet(c.pin, conns, all_nets) orelse c.net;
                try w.writeByte(' ');
                try writeNetForPin(w, net, c.pin);
            }
            // Model name is typically the last param or "model" key
            if (findProp(props, "model")) |model| {
                try w.print(" {s}", .{model});
            }
            for (props) |p| {
                if (std.mem.eql(u8, p.key, "model") or isInstanceMetaProp(p.key)) continue;
                try w.print(" {s}={s}", .{ p.key, p.val });
            }
            try w.writeByte('\n');
            return;
        }
    }

    // Standard subcircuit call
    try w.writeAll("X");
    try w.writeAll(inst_name);
    for (conns, 0..) |c, ci| {
        // Skip duplicate pin names (same electrical node)
        var dup = false;
        for (conns[0..ci]) |prev| {
            if (std.mem.eql(u8, prev.pin, c.pin)) {
                dup = true;
                break;
            }
        }
        if (dup) continue;
        const net = resolveConnNet(c.pin, conns, all_nets) orelse c.net;
        try w.writeByte(' ');
        try writeNetForPin(w, net, c.pin);
    }
    try w.print(" {s}", .{normalizedSymbolName(sym_name)});
    // Param overrides
    for (props) |p| {
        if (isInstanceMetaProp(p.key)) continue;
        try w.print(" {s}={s}", .{ p.key, p.val });
    }
    try w.writeByte('\n');
}

// =============================================================================
// Analysis emission (Arch.md Section 8.2 step 3)
// =============================================================================

fn emitAnalysis(w: anytype, analysis_type: []const u8, params: []const u8, backend: Backend) !void {
    _ = backend;
    if (std.mem.eql(u8, analysis_type, "op")) {
        try w.writeAll(".op\n");
        return;
    }

    try w.print(".{s}", .{analysis_type});

    // Parse key=value pairs from the params string
    if (params.len > 0) {
        if (std.mem.eql(u8, analysis_type, "ac")) {
            // .ac dec <points_per_dec> <start> <stop>
            const start_val = extractKV(params, "start") orelse "1";
            const stop_val = extractKV(params, "stop") orelse "1G";
            const ppd = extractKV(params, "points_per_dec") orelse "20";
            try w.print(" dec {s} {s} {s}", .{ ppd, start_val, stop_val });
        } else if (std.mem.eql(u8, analysis_type, "tran")) {
            const step_val = extractKV(params, "step") orelse "1n";
            const stop_val = extractKV(params, "stop") orelse "1u";
            try w.print(" {s} {s}", .{ step_val, stop_val });
            if (extractKV(params, "start")) |sv| try w.print(" {s}", .{sv});
        } else if (std.mem.eql(u8, analysis_type, "dc")) {
            const src = extractKV(params, "source") orelse "";
            const start_val = extractKV(params, "start") orelse "0";
            const stop_val = extractKV(params, "stop") orelse "1.8";
            const step_val = extractKV(params, "step") orelse "0.01";
            try w.print(" {s} {s} {s} {s}", .{ src, start_val, stop_val, step_val });
        } else if (std.mem.eql(u8, analysis_type, "noise")) {
            const output_val = extractKV(params, "output") orelse "V(out)";
            const input_val = extractKV(params, "input") orelse "VIN";
            try w.print(" {s} {s} dec 20 1 1G", .{ output_val, input_val });
        } else {
            // Generic: emit raw params
            try w.print(" {s}", .{params});
        }
    }
    try w.writeByte('\n');
}

// =============================================================================
// Measure emission (Arch.md Section 8.2 step 4)
// =============================================================================

fn emitMeasure(w: anytype, name: []const u8, expr: []const u8) !void {
    // Arch.md measure format: "find dB(V(out)/V(inp)) at freq=1"
    // SPICE format: ".meas ac dc_gain find dB(V(out)/V(inp)) at=1"
    const trimmed = std.mem.trim(u8, expr, " \t");
    if (trimmed.len == 0) return;

    // Detect analysis type from expression context
    const analysis = if (std.mem.indexOf(u8, trimmed, "freq") != null)
        "ac"
    else if (std.mem.indexOf(u8, trimmed, "time") != null)
        "tran"
    else
        "dc";

    try w.print(".meas {s} {s} {s}\n", .{ analysis, name, trimmed });
}

// =============================================================================
// Digital block emission (Arch.md TODO.md)
// =============================================================================

fn emitDigitalBlock(w: anytype, self: *const Schemify, dig: *const sch.DigitalConfig, backend: Backend, mode: NetlistMode, gpa: Allocator) !void {
    switch (mode) {
        .sim => {
            // Simulation mode: behavioural model emission (existing behaviour)
            switch (dig.language) {
                .verilog => {
                    // Behavioral Verilog: emit as VerilogA include or inline
                    if (dig.behavioral.source) |src| {
                        if (dig.behavioral.mode == .file) {
                            try w.print("* Verilog behavioral model: {s}\n", .{src});
                            switch (backend) {
                                .xyce => {
                                    // Xyce YDIG instance
                                    try w.print("YDIG_{s} ", .{self.name});
                                    const pin_names = self.pins.items(.name);
                                    for (0..self.pins.len) |pi| {
                                        try w.print("{s} ", .{pin_names[pi]});
                                    }
                                    try w.print("{s}\n", .{self.name});
                                },
                                .ngspice => {
                                    // ngspice: .include the compiled model
                                    try w.print(".include {s}\n", .{src});
                                },
                            }
                        } else {
                            // Inline source: emit as comment block
                            try w.writeAll("* Begin inline Verilog\n");
                            var line_it = std.mem.splitScalar(u8, src, '\n');
                            while (line_it.next()) |line| {
                                try w.print("* {s}\n", .{line});
                            }
                            try w.writeAll("* End inline Verilog\n");
                        }
                    }
                },
                .xspice => {
                    // XSPICE digital: emit A-device instance
                    if (dig.behavioral.source) |src| {
                        try w.print("A_{s} ", .{self.name});
                        const pin_names = self.pins.items(.name);
                        for (0..self.pins.len) |pi| {
                            try w.print("{s} ", .{pin_names[pi]});
                        }
                        try w.print("{s}\n", .{src});
                    }
                },
                .xyce_digital => {
                    // Xyce native digital co-simulation
                    if (dig.behavioral.source) |src| {
                        try w.print("YDIG_{s} ", .{self.name});
                        const pin_names = self.pins.items(.name);
                        for (0..self.pins.len) |pi| {
                            try w.print("{s} ", .{pin_names[pi]});
                        }
                        try w.print("{s}\n", .{src});
                    }
                },
                .vhdl => {
                    if (dig.behavioral.source) |src| {
                        try w.print("* VHDL model: {s}\n", .{src});
                    }
                },
            }
        },
        .layout => {
            // Layout mode: gate-level expansion via synthesized yosys JSON
            const synth_source = dig.synthesized.source orelse {
                try w.print("* WARNING: no synthesized source for layout-mode digital block {s}\n", .{self.name});
                return;
            };

            // Read the synthesized JSON file from disk.
            const json_text = Vfs.readAlloc(gpa, synth_source) catch |err| {
                try w.print("* ERROR: could not read synthesized JSON '{s}': {}\n", .{ synth_source, err });
                return;
            };
            defer gpa.free(json_text);

            // Parse the yosys JSON netlist.
            var module = YosysJson.parse(json_text, null, gpa) catch |err| {
                try w.print("* ERROR: failed to parse yosys JSON '{s}': {}\n", .{ synth_source, err });
                return;
            };
            defer YosysJson.deinit(&module, gpa);

            // Determine supply pins.
            // Priority: explicit supply_map entries, then auto-detect from module ports.
            const supply_names = &[_][]const u8{ "VDD", "VSS", "VPWR", "VGND", "VNB", "VPB" };
            var supply_pins = List([]const u8){};
            defer supply_pins.deinit(gpa);

            if (dig.synthesized.supply_map.items.len > 0) {
                // Use explicit supply_map entries (val = mapped pin name).
                for (dig.synthesized.supply_map.items) |entry| {
                    try supply_pins.append(gpa, entry.val);
                }
            } else {
                // Auto-detect: scan module ports for known supply pin names.
                for (module.ports) |port| {
                    for (supply_names) |sn| {
                        if (std.ascii.eqlIgnoreCase(port.name, sn)) {
                            try supply_pins.append(gpa, port.name);
                            break;
                        }
                    }
                }
            }

            if (supply_pins.items.len == 0) {
                try w.print("* WARNING: no supply pins detected for digital block {s}\n", .{self.name});
            }

            // Emit gate-level SPICE from the parsed module.
            YosysJson.emitGateLevelSpice(w, &module, self.name, supply_pins.items, gpa) catch |err| {
                try w.print("* ERROR: failed to emit gate-level SPICE for {s}: {}\n", .{ self.name, err });
                return;
            };
        },
    }
}

// =============================================================================
// Private helpers
// =============================================================================

fn emitSpiceLine(w: anytype, sl: []const u8) !void {
    try w.writeAll(sl);
    if (sl.len == 0 or sl[sl.len - 1] != '\n') try w.writeByte('\n');
}

fn emitCodeBlocksForPlace(
    w: anytype,
    self: *const Schemify,
    backend: Backend,
    place: ?[]const u8,
) !void {
    emitCodeBlocksForPlaceFiltered(w, self, backend, place, self.skip_toplevel_code) catch {};
}

fn emitCodeBlocksForPlaceFiltered(
    w: anytype,
    self: *const Schemify,
    backend: Backend,
    place: ?[]const u8,
    skip_toplevel_only: bool,
) !void {
    const ikind = self.instances.items(.kind);
    const ips = self.instances.items(.prop_start);
    const ipc = self.instances.items(.prop_count);
    const ispice = self.instances.items(.spice_line);

    for (0..self.instances.len) |i| {
        const kind = ikind[i];
        if (kind != .code and kind != .param) continue;
        const cp = self.props.items[ips[i]..][0..ipc[i]];

        if (place) |target| {
            if (!codePlaceIs(cp, target)) continue;
        } else if (codePlaceIs(cp, "header") or codePlaceIs(cp, "end")) {
            continue;
        }

        if (!shouldEmitCode(cp, backend)) continue;

        // When emitting as a sub-schematic (inline subcircuit), skip
        // code blocks that have only_toplevel=true (the default for code.sym).
        if (skip_toplevel_only) {
            if (isOnlyToplevel(cp)) continue;
        }

        if (ispice[i]) |sl| {
            try emitSpiceLine(w, sl);
        } else {
            try emitCodeValue(w, cp);
        }
    }
}

/// Emit template parameters (key=value) to the `.subckt` header line.
/// Parses the template string for key=value pairs and emits all except
/// "name" and other non-parameter keys (like spice_ignore, verilog_ignore).
fn emitTemplateParams(w: anytype, template: []const u8) !void {
    const skip_keys = std.StaticStringMap(void).initComptime(.{
        .{ "name", {} },
        .{ "spice_ignore", {} },
        .{ "verilog_ignore", {} },
        .{ "vhdl_ignore", {} },
        .{ "device", {} },
        .{ "footprint", {} },
        .{ "sig_type", {} },
        .{ "lab", {} },
        .{ "extra", {} },
        .{ "extra_pinnumber", {} },
    });

    var pos: usize = 0;
    const s = template;
    while (pos < s.len) {
        // Skip whitespace
        while (pos < s.len and (s[pos] == ' ' or s[pos] == '\t' or s[pos] == '\n' or s[pos] == '\r'))
            pos += 1;
        if (pos >= s.len) break;

        // Find key (up to '=')
        const key_start = pos;
        while (pos < s.len and s[pos] != '=' and s[pos] != ' ' and s[pos] != '\t' and s[pos] != '\n')
            pos += 1;
        if (pos >= s.len or s[pos] != '=') continue;
        const key = s[key_start..pos];
        pos += 1; // skip '='

        // Parse value (quoted or bare)
        var val_start = pos;
        var val_end = pos;
        if (pos < s.len and (s[pos] == '"' or s[pos] == '\'')) {
            const q = s[pos];
            pos += 1;
            val_start = pos;
            while (pos < s.len and s[pos] != q) {
                if (s[pos] == '\\' and pos + 1 < s.len) pos += 1;
                pos += 1;
            }
            val_end = pos;
            if (pos < s.len) pos += 1; // skip closing quote
        } else {
            while (pos < s.len and s[pos] != ' ' and s[pos] != '\t' and s[pos] != '\n' and s[pos] != '\r')
                pos += 1;
            val_end = pos;
        }
        const val = s[val_start..val_end];

        // Skip meta keys
        if (skip_keys.has(key)) continue;
        if (key.len == 0) continue;

        // Emit as " KEY=VALUE"
        try w.print(" {s}={s}", .{ key, val });
    }
}

fn normalizedSymbolName(sym_name: []const u8) []const u8 {
    const base = if (std.mem.lastIndexOfScalar(u8, sym_name, '/')) |slash|
        sym_name[slash + 1 ..]
    else
        sym_name;

    if (std.mem.endsWith(u8, base, ".sym")) return base[0 .. base.len - 4];
    if (std.mem.endsWith(u8, base, ".chn_prim")) return base[0 .. base.len - 9];
    if (std.mem.endsWith(u8, base, ".chn")) return base[0 .. base.len - 4];
    if (std.mem.endsWith(u8, base, ".sch")) return base[0 .. base.len - 4];
    return base;
}

fn isInstanceMetaProp(key: []const u8) bool {
    return std.mem.eql(u8, key, "name") or
        std.mem.eql(u8, key, "spice_prefix") or
        std.mem.eql(u8, key, "spice_format") or
        std.mem.eql(u8, key, "format");
}

/// Check whether a property key appears as an @-token anywhere in the format
/// string (e.g., "@L" or "@W"). This includes tokens inside [...] brackets.
/// Special tokens like "pinlist" and "symname" are always considered present.
fn isTokenInFormat(fmt: []const u8, key: []const u8) bool {
    // Special format-only tokens are never instance data props
    if (std.mem.eql(u8, key, "pinlist") or std.mem.eql(u8, key, "symname")) return true;

    var pos: usize = 0;
    while (pos < fmt.len) {
        if (fmt[pos] == '@' and pos + 1 < fmt.len and fmt[pos + 1] != '@') {
            const start = pos + 1;
            var end = start;
            while (end < fmt.len and (std.ascii.isAlphanumeric(fmt[end]) or fmt[end] == '_')) : (end += 1) {}
            const ident = fmt[start..end];
            if (std.mem.eql(u8, ident, key)) return true;
            pos = end;
        } else {
            pos += 1;
        }
    }
    return false;
}

fn codePlaceIs(props: []const Prop, place: []const u8) bool {
    for (props) |p| {
        if (std.mem.eql(u8, p.key, "place")) return std.mem.eql(u8, p.val, place);
    }
    return false;
}

fn isOnlyToplevel(props: []const Prop) bool {
    for (props) |p| {
        if (std.mem.eql(u8, p.key, "only_toplevel")) {
            return std.mem.eql(u8, p.val, "true") or std.mem.eql(u8, p.val, "1");
        }
    }
    // Default: code blocks are only_toplevel=true unless explicitly set to false
    return true;
}

fn shouldEmitCode(props: []const Prop, backend: Backend) bool {
    for (props) |p| {
        if (std.mem.eql(u8, p.key, "simulator") and p.val.len > 0) {
            const want: []const u8 = switch (backend) {
                .ngspice => "ngspice",
                .xyce => "xyce",
            };
            if (!std.mem.eql(u8, p.val, want)) return false;
        }
        // spice_ignore=true or spice_ignore=1 → skip this code block
        if (std.mem.eql(u8, p.key, "spice_ignore")) {
            if (std.mem.eql(u8, p.val, "true") or std.mem.eql(u8, p.val, "1")) return false;
        }
    }
    return true;
}

fn findProp(props: []const Prop, key: []const u8) ?[]const u8 {
    for (props) |p| {
        if (std.mem.eql(u8, p.key, key)) return p.val;
    }
    return null;
}

/// Look up spice_format from the sym_props of the Schemify model
/// (set when parsing .chn_prim SYMBOL section).
fn findSymPropFormat(self: *const Schemify, sym_name: []const u8) ?[]const u8 {
    _ = sym_name;
    for (self.sym_props.items) |p| {
        if (std.mem.eql(u8, p.key, "spice_format")) return p.val;
    }
    return null;
}

fn isSymPropMetadata(key: []const u8) bool {
    return std.mem.eql(u8, key, "description") or
        std.mem.eql(u8, key, "spice_prefix") or
        std.mem.eql(u8, key, "spice_format") or
        std.mem.eql(u8, key, "spice_lib") or
        std.mem.startsWith(u8, key, "include") or
        std.mem.startsWith(u8, key, "ann.") or
        std.mem.startsWith(u8, key, "analysis.") or
        std.mem.startsWith(u8, key, "measure.");
}

/// Extract a value from "key1=val1  key2=val2 ..." format.
fn extractKV(params: []const u8, key: []const u8) ?[]const u8 {
    var it = std.mem.tokenizeAny(u8, params, " \t");
    while (it.next()) |tok| {
        if (std.mem.startsWith(u8, tok, key)) {
            if (tok.len > key.len and tok[key.len] == '=') {
                return tok[key.len + 1 ..];
            }
        }
    }
    return null;
}

fn emitCodeValue(w: anytype, props: []const Prop) !void {
    for (props) |p| {
        if (std.mem.eql(u8, p.key, "value") and p.val.len > 0) {
            var raw = List(u8){};
            defer raw.deinit(std.heap.page_allocator);
            var i: usize = 0;
            while (i < p.val.len) {
                if (p.val[i] == '\\' and i + 1 < p.val.len) {
                    const nc = p.val[i + 1];
                    if (nc == '\\' and i + 2 < p.val.len and p.val[i + 2] == '"') {
                        // Raw `\\"` (from pre-unescaped source) → `"`
                        try raw.append(std.heap.page_allocator, '"');
                        i += 3;
                    } else if (nc == '"') {
                        // `\"` (from unescaped source where `\\"` became `\"`) → `"`
                        try raw.append(std.heap.page_allocator, '"');
                        i += 2;
                    } else if (nc == '{' or nc == '}') {
                        try raw.append(std.heap.page_allocator, nc);
                        i += 2;
                    } else {
                        try raw.append(std.heap.page_allocator, p.val[i]);
                        i += 1;
                    }
                } else {
                    try raw.append(std.heap.page_allocator, p.val[i]);
                    i += 1;
                }
            }

            var it = std.mem.splitScalar(u8, raw.items, '\n');
            while (it.next()) |ln| {
                const tl = std.mem.trimLeft(u8, ln, " \t");
                if (tl.len > 0 and tl[0] == '?') {
                    try w.writeAll("?\n");
                } else {
                    // Preserve leading whitespace (important for .control blocks
                    // where indented lines must not be parsed as SPICE instances).
                    // Only trim trailing whitespace.
                    const rt = std.mem.trimRight(u8, ln, " \t\r");
                    // Strip tcleval() wrappers on the trimmed content.
                    var t = std.mem.trimLeft(u8, rt, " \t");
                    const indent = rt[0 .. rt.len - t.len];
                    if (std.mem.startsWith(u8, t, "tcleval(") and
                        t.len > "tcleval()".len and t[t.len - 1] == ')')
                    {
                        t = std.mem.trim(u8, t["tcleval(".len .. t.len - 1], " \t\r\n");
                    }
                    if (std.mem.startsWith(u8, t, ".include ")) {
                        const target = std.mem.trim(u8, t[".include ".len..], " \t\r");
                        if (std.mem.endsWith(u8, target, ".save")) {
                            try w.writeAll("?\n");
                            continue;
                        }
                    }
                    if (t.len > 0) {
                        try w.writeAll(indent);
                        try w.writeAll(t);
                    }
                    try w.writeByte('\n');
                }
            }
            return;
        }
    }
}

fn emitDeviceModelBlock(
    w: anytype,
    gpa: Allocator,
    props: []const Prop,
    seen: *std.StringHashMapUnmanaged(void),
) !void {
    var raw_dm: ?[]const u8 = null;
    for (props) |p| {
        if (std.ascii.eqlIgnoreCase(p.key, "device_model")) {
            raw_dm = p.val;
            break;
        }
    }
    const dm = raw_dm orelse return;

    var payload = std.mem.trim(u8, dm, " \t\r\"");
    if (std.mem.startsWith(u8, payload, "tcleval(") and payload.len >= "tcleval()".len and
        payload[payload.len - 1] == ')')
    {
        payload = std.mem.trim(u8, payload["tcleval(".len .. payload.len - 1], " \t\r\n");
    }
    if (payload.len == 0) return;

    var user_conf_dir: ?[]const u8 = null;
    if (std.process.getEnvVarOwned(gpa, "USER_CONF_DIR")) |v| {
        user_conf_dir = v;
    } else |_| {
        if (std.process.getEnvVarOwned(gpa, "HOME")) |home| {
            defer gpa.free(home);
            user_conf_dir = std.fmt.allocPrint(gpa, "{s}/.xschem", .{home}) catch null;
        } else |_| {}
    }
    defer if (user_conf_dir) |v| gpa.free(v);

    var normalized = List(u8){};
    defer normalized.deinit(gpa);
    var it = std.mem.splitScalar(u8, payload, '\n');
    while (it.next()) |ln_raw| {
        const ln = std.mem.trim(u8, ln_raw, " \t\r");
        if (ln.len == 0) continue;
        if (ln[0] == '*') continue;
        var emit_line = ln;

        if (user_conf_dir) |ucd| {
            var expanded = List(u8){};
            defer expanded.deinit(gpa);
            var pos: usize = 0;
            var replaced = false;
            while (std.mem.indexOfPos(u8, ln, pos, "$USER_CONF_DIR")) |idx| {
                replaced = true;
                try expanded.appendSlice(gpa, ln[pos..idx]);
                try expanded.appendSlice(gpa, ucd);
                pos = idx + "$USER_CONF_DIR".len;
            }
            if (replaced) {
                try expanded.appendSlice(gpa, ln[pos..]);
                emit_line = try gpa.dupe(u8, expanded.items);
                defer gpa.free(emit_line);
            }
        }
        if (normalized.items.len > 0) try normalized.append(gpa, '\n');
        try normalized.appendSlice(gpa, emit_line);
    }
    if (normalized.items.len == 0) return;

    if (seen.contains(normalized.items)) return;
    const key = try gpa.dupe(u8, normalized.items);
    errdefer gpa.free(key);
    try seen.put(gpa, key, {});

    try w.writeAll(normalized.items);
    try w.writeByte('\n');
}

fn resolveNetsForDevice(
    buf: [][]const u8,
    pin_order: []const []const u8,
    conns: []const Conn,
    all_nets: []const Net,
) []const []const u8 {
    const n = @min(pin_order.len, buf.len);
    for (pin_order[0..n], 0..n) |pin, idx| {
        buf[idx] = "0";
        if (resolveConnNet(pin, conns, all_nets)) |net_name| {
            buf[idx] = net_name;
        }
    }
    return buf[0..n];
}

/// Returns true if every connection resolves to "0" (SPICE ground).
/// Used to suppress .sym-internal primitive instances with no real wiring.
fn allConnsZero(conns: []const Conn, all_nets: []const Net) bool {
    for (conns) |c| {
        const net = resolveConnNet(c.pin, conns, all_nets) orelse c.net;
        if (!std.mem.eql(u8, net, "0")) return false;
    }
    return true;
}

fn pinNameMatch(a: []const u8, b: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(a, b)) return true;
    return isAlias(a, b) or isAlias(b, a);
}

fn isAlias(needle: []const u8, candidate: []const u8) bool {
    const Entry = struct { name: []const u8, aliases: []const []const u8 };
    const table = [_]Entry{
        .{ .name = "n", .aliases = &.{ "m", "minus", "vss" } },
        .{ .name = "m", .aliases = &.{ "n", "minus" } },
        .{ .name = "p", .aliases = &.{ "plus", "z" } },
        .{ .name = "plus", .aliases = &.{"p"} },
        .{ .name = "minus", .aliases = &.{ "m", "n" } },
        .{ .name = "z", .aliases = &.{"p"} },
        .{ .name = "vss", .aliases = &.{"n"} },
        .{ .name = "cp", .aliases = &.{"a"} },
        .{ .name = "a", .aliases = &.{"cp"} },
        .{ .name = "cn", .aliases = &.{"cm"} },
        .{ .name = "cm", .aliases = &.{"cn"} },
    };
    for (&table) |entry| {
        if (std.ascii.eqlIgnoreCase(needle, entry.name)) {
            for (entry.aliases) |alias| {
                if (std.ascii.eqlIgnoreCase(candidate, alias)) return true;
            }
        }
    }
    return false;
}

fn propsToParamOverrides(gpa: Allocator, props: []const Prop) ![]const @import("SpiceIF.zig").ParamOverride {
    const ParamOverride = @import("SpiceIF.zig").ParamOverride;
    const o = try gpa.alloc(ParamOverride, props.len);
    for (props, o) |p, *slot| {
        slot.* = .{
            .name = p.key,
            .value = .{ .expr = stripExprWrapper(p.val) },
        };
    }
    return o;
}

/// Strip XSchem `expr(...)` wrapper from a value string.
/// XSchem evaluates these at netlist time; we strip the wrapper and emit the
/// inner expression directly (matching xschem's output for unresolved params).
fn stripExprWrapper(val: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, val, " \t");
    // Match "expr(" or "expr (" prefix
    const start = if (std.mem.startsWith(u8, trimmed, "expr("))
        @as(usize, 5) // len("expr(")
    else if (std.mem.startsWith(u8, trimmed, "expr ("))
        @as(usize, 6)
    else
        return val;
    // Find matching closing paren
    if (std.mem.lastIndexOfScalar(u8, trimmed, ')')) |end| {
        return std.mem.trim(u8, trimmed[start..end], " \t");
    }
    return val;
}

fn parseTokenBusRange(token: []const u8) ?struct { prefix: []const u8, first: i32, last: i32, width: usize } {
    const ob = std.mem.indexOfScalar(u8, token, '[') orelse return null;
    const colon = std.mem.indexOfScalarPos(u8, token, ob + 1, ':') orelse return null;
    const cb = std.mem.indexOfScalarPos(u8, token, colon + 1, ']') orelse return null;
    if (cb + 1 != token.len) return null;
    const first = std.fmt.parseInt(i32, token[ob + 1 .. colon], 10) catch return null;
    const last = std.fmt.parseInt(i32, token[colon + 1 .. cb], 10) catch return null;
    const diff: i32 = if (first >= last) first - last else last - first;
    return .{ .prefix = token[0..ob], .first = first, .last = last, .width = @intCast(diff + 1) };
}

// =============================================================================
// Bus instance multiplication (XSchem bus expansion)
// =============================================================================
//
// When an instance name contains a bus range (e.g., R5[3:0]), XSchem
// expands it into multiple instances — one per bit.  Bus net connections
// are expanded in parallel: DATA[3:0] → DATA[3], DATA[2], DATA[1], DATA[0].
// Non-bus (scalar) nets are shared across all bits.

const BusRange = struct {
    prefix: []const u8,
    first: i32,
    last: i32,
    width: usize,
    /// True when the separator is ".." — individual bits are written as
    /// PREFIX<N> (no brackets), e.g. DIN[4..1] → DIN4, DIN3, DIN2, DIN1.
    /// False when the separator is ":" — bits use PREFIX[N] bracket form.
    dot_sep: bool,
};

/// Parse a bus range from a name token.  Supports both colon (DATA[3:0])
/// and double-dot (DIN[4..1]) separators.  Returns null if no bus range found.
fn parseBusRange(token: []const u8) ?BusRange {
    const ob = std.mem.indexOfScalar(u8, token, '[') orelse return null;
    const cb = std.mem.lastIndexOfScalar(u8, token, ']') orelse return null;
    if (cb <= ob + 2) return null;
    const inner = token[ob + 1 .. cb];

    // Try ":"  first, then ".."
    if (std.mem.indexOfScalar(u8, inner, ':')) |sep| {
        const first = std.fmt.parseInt(i32, inner[0..sep], 10) catch return null;
        const last = std.fmt.parseInt(i32, inner[sep + 1 ..], 10) catch return null;
        const diff: i32 = if (first >= last) first - last else last - first;
        return .{ .prefix = token[0..ob], .first = first, .last = last, .width = @intCast(diff + 1), .dot_sep = false };
    }
    if (std.mem.indexOf(u8, inner, "..")) |sep| {
        const first = std.fmt.parseInt(i32, inner[0..sep], 10) catch return null;
        const last = std.fmt.parseInt(i32, inner[sep + 2 ..], 10) catch return null;
        const diff: i32 = if (first >= last) first - last else last - first;
        return .{ .prefix = token[0..ob], .first = first, .last = last, .width = @intCast(diff + 1), .dot_sep = true };
    }
    return null;
}

/// Format a single bit name from a BusRange.  Caller owns the returned slice.
///   dot_sep=true  → "PREFIX<bit>"  (no brackets)
///   dot_sep=false → "PREFIX[<bit>]"
fn fmtBusBit(alloc: Allocator, prefix: []const u8, bit: i32, dot_sep: bool) ![]u8 {
    if (dot_sep) {
        return std.fmt.allocPrint(alloc, "{s}{d}", .{ prefix, bit });
    } else {
        return std.fmt.allocPrint(alloc, "{s}[{d}]", .{ prefix, bit });
    }
}

/// Check if a net name looks like an auto-generated/private net (e.g. "net1", "net23").
/// In XSchem, private nets (originally prefixed with `#`) are auto-expanded in
/// bus instance contexts, while named nets stay as-is.
fn isPrivateNet(name: []const u8) bool {
    if (!std.mem.startsWith(u8, name, "net")) return false;
    if (name.len <= 3) return false;
    for (name[3..]) |ch| {
        if (!std.ascii.isDigit(ch)) return false;
    }
    return true;
}

/// Expand a bus-ranged instance into multiple single-bit instances.
/// Calls `emitFn` for each bit with the single-bit instance name and
/// single-bit net connections.  `emitFn` is a closure that receives the
/// modified name and conns.
///
/// Returns true if bus expansion was performed, false if the name has no
/// bus range (caller should emit the instance as-is).
fn emitBusExpanded(
    w: anytype,
    gpa: Allocator,
    inst_name: []const u8,
    sym_name: []const u8,
    props: []const Prop,
    conns: []const Conn,
    all_nets: []const Net,
    fmt: ?[]const u8,
    template: ?[]const u8,
    is_subckt_call: bool,
) !bool {
    const inst_bus = parseBusRange(inst_name) orelse return false;
    if (inst_bus.width <= 1) return false;
    const iw = inst_bus.width;

    // Pre-parse bus ranges for each net and pin connection
    const ConnInfo = struct {
        net_range: ?BusRange,
        pin_range: ?BusRange,
        raw_net: []const u8,
        pin_name: []const u8,
    };
    var conn_info = try gpa.alloc(ConnInfo, conns.len);
    defer gpa.free(conn_info);
    for (conns, 0..) |c, ci| {
        const net = resolveConnNet(c.pin, conns, all_nets) orelse c.net;
        conn_info[ci] = .{
            .net_range = parseBusRange(net),
            .pin_range = parseBusRange(c.pin),
            .raw_net = net,
            .pin_name = c.pin,
        };
    }

    // Validate: bus-ranged nets must have width matching inst_width or inst_width * pin_width
    for (conn_info) |ci| {
        if (ci.net_range) |nr| {
            const pw: usize = if (ci.pin_range) |pr| pr.width else 1;
            const total = iw * pw;
            if (nr.width != total and nr.width != iw) return false;
        }
    }

    // Emit one instance per bit
    const step: i32 = if (inst_bus.first > inst_bus.last) -1 else 1;
    var bit = inst_bus.first;
    var bit_idx: usize = 0;
    while (bit_idx < iw) : (bit_idx += 1) {
        // Build single-bit instance name
        const bit_name = try fmtBusBit(gpa, inst_bus.prefix, bit, false);
        defer gpa.free(bit_name);

        // Build per-bit conns — one conn per original conn.
        // For scalar net + bus pin: encode as a bus range net (e.g. "net7[7:4]")
        // so downstream writeNetForPin expands it correctly.
        // For scalar net + scalar pin: encode as indexed net (e.g. "net8[1]").
        var bit_conns = try gpa.alloc(Conn, conns.len);
        defer gpa.free(bit_conns);
        var bit_net_strs = try gpa.alloc([]u8, conns.len);
        defer {
            for (bit_net_strs[0..conns.len]) |s| gpa.free(s);
            gpa.free(bit_net_strs);
        }

        for (conn_info, 0..) |ci, idx| {
            const pw: usize = if (ci.pin_range) |pr| pr.width else 1;

            if (ci.net_range) |nr| {
                // Net has explicit bus range
                if (pw > 1 and nr.width == iw * pw) {
                    // Bus net with total_width bits: create a sub-range for this inst bit.
                    // E.g. net7[7:0] for inst[1:0] on A[3:0] → inst bit 0 gets net7[7:4]
                    const slice_first_idx = bit_idx * pw;
                    const slice_last_idx = slice_first_idx + pw - 1;
                    const rf: i32 = if (nr.first > nr.last)
                        nr.first - @as(i32, @intCast(slice_first_idx))
                    else
                        nr.first + @as(i32, @intCast(slice_first_idx));
                    const rl: i32 = if (nr.first > nr.last)
                        nr.first - @as(i32, @intCast(slice_last_idx))
                    else
                        nr.first + @as(i32, @intCast(slice_last_idx));
                    if (pw == 1) {
                        bit_net_strs[idx] = try fmtBusBit(gpa, nr.prefix, rf, nr.dot_sep);
                    } else {
                        bit_net_strs[idx] = try std.fmt.allocPrint(gpa, "{s}[{d}:{d}]", .{ nr.prefix, rf, rl });
                    }
                } else {
                    // Bus net matching inst_width: extract single bit
                    const net_bit: i32 = if (nr.first > nr.last)
                        nr.first - @as(i32, @intCast(bit_idx))
                    else
                        nr.first + @as(i32, @intCast(bit_idx));
                    bit_net_strs[idx] = try fmtBusBit(gpa, nr.prefix, net_bit, nr.dot_sep);
                }
            } else if (pw > 1) {
                // Scalar net + bus pin: auto-expand private nets, keep named nets as-is
                if (isPrivateNet(ci.raw_net)) {
                    // Private net: create a bus range for this inst bit's slice.
                    const total_w: i32 = @intCast(iw * pw);
                    const rf = total_w - 1 - @as(i32, @intCast(bit_idx * pw));
                    const rl = total_w - 1 - @as(i32, @intCast(bit_idx * pw + pw - 1));
                    if (pw == 1) {
                        bit_net_strs[idx] = try std.fmt.allocPrint(gpa, "{s}[{d}]", .{ ci.raw_net, rf });
                    } else {
                        bit_net_strs[idx] = try std.fmt.allocPrint(gpa, "{s}[{d}:{d}]", .{ ci.raw_net, rf, rl });
                    }
                } else {
                    // Named net: keep as-is, let writeNetForPin handle pin expansion
                    bit_net_strs[idx] = try gpa.dupe(u8, ci.raw_net);
                }
            } else {
                // Scalar net + scalar pin
                if (isPrivateNet(ci.raw_net)) {
                    // Private net: index by instance bit
                    const net_bit: i32 = @as(i32, @intCast(iw - 1 - bit_idx));
                    bit_net_strs[idx] = try std.fmt.allocPrint(gpa, "{s}[{d}]", .{ ci.raw_net, net_bit });
                } else {
                    // Named net: use as-is (shared across all inst bits)
                    bit_net_strs[idx] = try gpa.dupe(u8, ci.raw_net);
                }
            }
            bit_conns[idx] = .{ .pin = conns[idx].pin, .net = bit_net_strs[idx] };
        }

        if (fmt) |f| {
            try expandSpiceFormat(w, f, bit_name, sym_name, props, bit_conns, all_nets, template);
        } else if (is_subckt_call) {
            try emitSubcircuitCall(w, bit_name, sym_name, props, bit_conns, all_nets);
        }

        bit += step;
    }
    return true;
}
