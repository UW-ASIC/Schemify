const std = @import("std");
const Allocator = std.mem.Allocator;
const List = std.ArrayListUnmanaged;

const sch = @import("Schemify.zig");
const Schemify = sch.Schemify;
const Prop = sch.Prop;
const PinDir = sch.PinDir;
const DigitalConfig = sch.DigitalConfig;

const Devices = @import("Devices.zig");

const utility = @import("utility");
const simd = utility.simd;

pub const Writer = struct {
    pub fn writeCHN(a: Allocator, s: *Schemify, logger: ?*utility.Logger) ?[]u8 {
        s.logger = logger;
        var buf: List(u8) = .{};
        buf.ensureTotalCapacity(a, simd.estimateCHNSize(s)) catch {};
        s.emit(.info, "writing {s}: {d} instances, {d} pins", .{
            switch (s.stype) {
                .testbench => "testbench",
                .primitive => "primitive",
                .component => "component",
            },
            s.instances.len,
            s.pins.len,
        });
        writeCHNImpl(buf.writer(a), s, a) catch |e| {
            s.emit(.err, "write failed: {}", .{e});
            buf.deinit(a);
            return null;
        };
        return buf.toOwnedSlice(a) catch |e| {
            s.emit(.err, "write toOwnedSlice failed: {}", .{e});
            buf.deinit(a);
            return null;
        };
    }
};

// =============================================================================
// Internal implementation (Arch.md .chn format)
// =============================================================================

fn writeCHNImpl(w: anytype, s: *const Schemify, a: Allocator) !void {
    // W1 fix: A component with 0 pins is effectively a testbench for .chn purposes.
    // Override stype locally so the header and structure reflect this.
    const effective_stype: @TypeOf(s.stype) = if (s.stype == .component and s.pins.len == 0) .testbench else s.stype;

    // -- File header --
    switch (effective_stype) {
        .primitive => try w.writeAll("chn_prim 1.0\n"),
        .component => try w.writeAll("chn 1.0\n"),
        .testbench => try w.writeAll("chn_testbench 1.0\n"),
    }

    // -- SYMBOL section (component and primitive only) --
    if (effective_stype != .testbench) {
        try w.writeByte('\n');
        try w.writeAll("SYMBOL ");
        try w.writeAll(if (s.name.len > 0) s.name else "untitled");
        try w.writeByte('\n');

        // desc from sym_props (look for "description" key)
        const desc = findSymProp(s.sym_props.items, "description");
        if (desc) |d| {
            try w.writeAll("  desc: ");
            try w.writeAll(d);
            try w.writeByte('\n');
        }

        // pins (with x, y location for symbol view)
        try w.writeByte('\n');
        try w.print("  pins [{d}]:\n", .{s.pins.len});
        {
            const pname = s.pins.items(.name);
            const pdir = s.pins.items(.dir);
            const pwidth = s.pins.items(.width);
            const px = s.pins.items(.x);
            const py = s.pins.items(.y);
            for (0..s.pins.len) |i| {
                try w.writeAll("    ");
                try w.writeAll(pname[i]);
                try w.writeAll("  ");
                try w.writeAll(pinDirToChnStr(pdir[i]));
                if (px[i] != 0 or py[i] != 0) {
                    try w.print("  x={d}  y={d}", .{ px[i], py[i] });
                }
                if (pwidth[i] > 1) {
                    try w.print("  width={d}", .{pwidth[i]});
                }
                try w.writeByte('\n');
            }
        }

        // params (sym_props, excluding metadata keys that get their own lines)
        {
            var param_count: usize = 0;
            for (s.sym_props.items) |p| {
                if (!isSymPropMetadata(p.key)) param_count += 1;
            }
            if (param_count > 0) {
                try w.writeByte('\n');
                try w.print("  params [{d}]:\n", .{param_count});
                for (s.sym_props.items) |p| {
                    if (isSymPropMetadata(p.key)) continue;
                    try w.writeAll("    ");
                    try w.writeAll(p.key);
                    try w.writeAll(" = ");
                    try writeFlatValue(w, p.val);
                    try w.writeByte('\n');
                }
            }
        }

        // spice_prefix
        {
            const spice_prefix = findSymProp(s.sym_props.items, "spice_prefix");
            if (spice_prefix) |pfx| {
                try w.writeByte('\n');
                try w.writeAll("  spice_prefix: ");
                try w.writeAll(pfx);
                try w.writeByte('\n');
            }
        }

        // spice_format
        {
            const spice_format = findSymProp(s.sym_props.items, "spice_format");
            if (spice_format) |fmt| {
                try w.writeAll("  spice_format: ");
                try w.writeAll(fmt);
                try w.writeByte('\n');
            }
        }

        // spice_lib
        {
            const spice_lib = findSymProp(s.sym_props.items, "spice_lib");
            if (spice_lib) |lib| {
                try w.writeAll("  spice_lib: ");
                try w.writeAll(lib);
                try w.writeByte('\n');
            }
        }

        // drawing section — symbol geometry (lines, rects, arcs, circles) + pin_positions
        const has_drawing = s.lines.len > 0 or s.rects.len > 0 or s.arcs.len > 0 or s.circles.len > 0;
        if (has_drawing) {
            try w.writeAll("\n  drawing:\n");
            if (s.lines.len > 0) {
                const lx0 = s.lines.items(.x0);
                const ly0 = s.lines.items(.y0);
                const lx1 = s.lines.items(.x1);
                const ly1 = s.lines.items(.y1);
                for (0..s.lines.len) |i| {
                    try w.print("    line {d} {d} {d} {d}\n", .{ lx0[i], ly0[i], lx1[i], ly1[i] });
                }
            }
            if (s.rects.len > 0) {
                const rx0 = s.rects.items(.x0);
                const ry0 = s.rects.items(.y0);
                const rx1 = s.rects.items(.x1);
                const ry1 = s.rects.items(.y1);
                for (0..s.rects.len) |i| {
                    try w.print("    rect {d} {d} {d} {d}\n", .{ rx0[i], ry0[i], rx1[i], ry1[i] });
                }
            }
            if (s.arcs.len > 0) {
                const acx = s.arcs.items(.cx);
                const acy = s.arcs.items(.cy);
                const arad = s.arcs.items(.radius);
                const asa = s.arcs.items(.start_angle);
                const asw = s.arcs.items(.sweep_angle);
                for (0..s.arcs.len) |i| {
                    try w.print("    arc {d} {d} {d} {d} {d}\n", .{ acx[i], acy[i], arad[i], asa[i], asw[i] });
                }
            }
            if (s.circles.len > 0) {
                const ccx = s.circles.items(.cx);
                const ccy = s.circles.items(.cy);
                const crad = s.circles.items(.radius);
                for (0..s.circles.len) |i| {
                    try w.print("    circle {d} {d} {d}\n", .{ ccx[i], ccy[i], crad[i] });
                }
            }
            // pin_positions — write if any pin has non-zero position
            {
                var has_pin_pos = false;
                const ppx = s.pins.items(.x);
                const ppy = s.pins.items(.y);
                for (0..s.pins.len) |i| {
                    if (ppx[i] != 0 or ppy[i] != 0) { has_pin_pos = true; break; }
                }
                if (has_pin_pos) {
                    try w.writeAll("    pin_positions:\n");
                    const ppn = s.pins.items(.name);
                    for (0..s.pins.len) |i| {
                        try w.print("      {s}: ({d}, {d})\n", .{ ppn[i], ppx[i], ppy[i] });
                    }
                }
            }
        }
    }

    // -- SCHEMATIC section (component and testbench only) --
    if (effective_stype != .primitive) {
        try w.writeByte('\n');
        if (effective_stype == .testbench) {
            try w.writeAll("TESTBENCH ");
            try w.writeAll(if (s.name.len > 0) s.name else "untitled");
            try w.writeByte('\n');

            // Testbench includes
            try writeCHNIncludes(w, s);
        } else {
            try w.writeAll("SCHEMATIC\n");
        }

        // Count electrical instances only
        const ikind = s.instances.items(.kind);
        var elec_count: usize = 0;
        for (0..s.instances.len) |i| {
            if (!ikind[i].isNonElectrical()) elec_count += 1;
        }

        if (elec_count > 0) {
            // Group instances by DeviceKind
            try writeCHNInstanceGroups(w, s, a);
        }

        // Digital section
        if (s.digital) |dig| {
            try writeCHNDigital(w, &dig);
        }

        // Nets section: build net_name -> list of "inst.pin" from conns
        try writeCHNNets(w, s, a);

        // Analyses and measures (primarily for testbenches but valid in any schematic)
        try writeCHNAnalyses(w, s);
        try writeCHNMeasures(w, s);

        // Code blocks — stored separately from electrical instances
        try writeCHNCodeBlocks(w, s);

        // HDL blocks — stored separately from electrical instances
        try writeCHNHdlBlocks(w, s);

        // Annotations — probes, graphs, titles, launchers, etc.
        try writeCHNAnnotationInstances(w, s);

        // Annotation metadata (from sym_props ann.* keys)
        try writeCHNAnnotations(w, s);

        // Wires section: visual wire geometry (x0 y0 x1 y1 [net_name])
        if (s.wires.len > 0) {
            try w.writeByte('\n');
            try w.print("  wires [{d}]:\n", .{s.wires.len});
            const wx0 = s.wires.items(.x0);
            const wy0 = s.wires.items(.y0);
            const wx1 = s.wires.items(.x1);
            const wy1 = s.wires.items(.y1);
            const wnn = s.wires.items(.net_name);
            for (0..s.wires.len) |i| {
                try w.print("    {d} {d} {d} {d}", .{ wx0[i], wy0[i], wx1[i], wy1[i] });
                if (wnn[i]) |n| {
                    try w.writeByte(' ');
                    try w.writeAll(n);
                }
                try w.writeByte('\n');
            }
        }
    }
}

/// Write type-grouped tabular instance blocks.
fn writeCHNInstanceGroups(w: anytype, s: *const Schemify, a: Allocator) !void {
    const ikind = s.instances.items(.kind);
    const iname = s.instances.items(.name);
    const ips = s.instances.items(.prop_start);
    const ipc = s.instances.items(.prop_count);
    const isym = s.instances.items(.symbol);

    // Collect the unique DeviceKind values in order of first appearance (electrical only).
    var kind_order = List(Devices.DeviceKind){};
    defer kind_order.deinit(a);
    for (0..s.instances.len) |i| {
        const k = ikind[i];
        if (k.isNonElectrical()) continue;
        var found = false;
        for (kind_order.items) |existing| {
            if (existing == k) {
                found = true;
                break;
            }
        }
        if (!found) kind_order.append(a, k) catch continue;
    }

    for (kind_order.items) |kind| {
        // Collect indices of instances with this kind.
        var group_indices = List(usize){};
        defer group_indices.deinit(a);
        for (0..s.instances.len) |i| {
            if (ikind[i] == kind) group_indices.append(a, i) catch continue;
        }
        if (group_indices.items.len == 0) continue;

        // Determine common parameter columns from the first instance's props.
        // Use union of all param keys across the group to handle heterogeneous params.
        // Filter out internal/metadata props and the "name" key (already the first column).
        var col_keys = List([]const u8){};
        defer col_keys.deinit(a);
        for (group_indices.items) |idx| {
            const pc = ipc[idx];
            if (pc == 0) continue;
            const props_slice = s.props.items[ips[idx]..][0..pc];
            for (props_slice) |p| {
                if (std.mem.eql(u8, p.key, "name")) continue;
                var already = false;
                for (col_keys.items) |ck| {
                    if (std.mem.eql(u8, ck, p.key)) {
                        already = true;
                        break;
                    }
                }
                if (!already) col_keys.append(a, p.key) catch continue;
            }
        }

        // If this kind is a subcircuit type or unknown, use the "instances" generic form
        const is_subckt = kind.isSubcircuit();
        const use_generic = is_subckt or kind == .unknown;

        // F1 fix: Check if any prop value in this group contains newlines.
        // If so, tabular form would break the [N] row count — use generic form.
        const has_multiline_props = blk: {
            for (group_indices.items) |idx| {
                const pc = ipc[idx];
                if (pc == 0) continue;
                const props_slice = s.props.items[ips[idx]..][0..pc];
                for (props_slice) |p| {
                    if (std.mem.eql(u8, p.key, "name")) continue;
                    if (std.mem.indexOfScalar(u8, p.val, '\n') != null) break :blk true;
                }
            }
            break :blk false;
        };

        try w.writeByte('\n');
        const ix = s.instances.items(.x);
        const iy = s.instances.items(.y);
        const irot = s.instances.items(.rot);
        const iflip = s.instances.items(.flip);

        if (use_generic or has_multiline_props) {
            // Generic instances form
            try w.print("  instances [{d}]:\n", .{group_indices.items.len});
            for (group_indices.items) |idx| {
                try w.writeAll("    ");
                try w.writeAll(iname[idx]);
                try w.writeAll("  ");
                try w.writeAll(isym[idx]);
                // Position data
                try w.print("  x={d}  y={d}", .{ ix[idx], iy[idx] });
                if (irot[idx] != 0) try w.print("  rot={d}", .{@as(u8, irot[idx])});
                if (iflip[idx]) try w.writeAll("  flip=1");
                try writeInstanceProps(w, s.props.items, ips[idx], ipc[idx]);
                try w.writeByte('\n');
            }
        } else {
            // Tabular form: group_name [N]{name, x, y, rot, flip, col1, col2, ...}:
            const group_name = kindToGroupName(kind);
            try w.writeAll("  ");
            try w.writeAll(group_name);
            try w.print(" [{d}]", .{group_indices.items.len});
            try w.writeAll("{name, x, y, rot, flip");
            for (col_keys.items) |ck| {
                try w.writeAll(", ");
                try w.writeAll(ck);
            }
            try w.writeAll("}:\n");

            // Emit rows
            for (group_indices.items) |idx| {
                try w.writeAll("    ");
                try w.writeAll(iname[idx]);
                try w.print("  {d}  {d}  {d}  {d}", .{
                    ix[idx], iy[idx], @as(u8, irot[idx]), @intFromBool(iflip[idx]),
                });

                // For each column key, find its value in this instance's props
                for (col_keys.items) |ck| {
                    try w.writeAll("  ");
                    const pc = ipc[idx];
                    const val = blk: {
                        if (pc > 0) {
                            const props_slice = s.props.items[ips[idx]..][0..pc];
                            for (props_slice) |p| {
                                if (std.mem.eql(u8, p.key, ck)) break :blk p.val;
                            }
                        }
                        break :blk "-";
                    };
                    try w.writeAll(val);
                }
                try w.writeByte('\n');
            }
        }
    }
}

/// Write code_blocks section for code/param instances (stored separately from electrical).
fn writeCHNCodeBlocks(w: anytype, s: *const Schemify) !void {
    try writeFilteredInstances(w, s, "code_blocks", .code_block);
}

/// Write hdl_blocks section for HDL instances (stored separately from electrical).
fn writeCHNHdlBlocks(w: anytype, s: *const Schemify) !void {
    try writeFilteredInstances(w, s, "hdl_blocks", .hdl_block);
}

/// Write annotations section for probes, graphs, titles, etc. (stored separately).
fn writeCHNAnnotationInstances(w: anytype, s: *const Schemify) !void {
    try writeFilteredInstances(w, s, "annotations", .annotation);
}

const InstanceFilter = enum { code_block, hdl_block, annotation };

/// Unified writer for code_blocks, hdl_blocks, and annotations sections.
fn writeFilteredInstances(w: anytype, s: *const Schemify, section_name: []const u8, filter: InstanceFilter) !void {
    const ikind = s.instances.items(.kind);
    const iname = s.instances.items(.name);
    const ips = s.instances.items(.prop_start);
    const ipc = s.instances.items(.prop_count);

    var count: usize = 0;
    for (0..s.instances.len) |i| {
        if (matchesFilter(ikind[i], filter)) count += 1;
    }
    if (count == 0) return;

    try w.writeByte('\n');
    try w.print("  {s} [{d}]:\n", .{ section_name, count });

    const ix = s.instances.items(.x);
    const iy = s.instances.items(.y);

    for (0..s.instances.len) |i| {
        if (!matchesFilter(ikind[i], filter)) continue;
        try w.writeAll("    ");
        try w.writeAll(iname[i]);
        switch (filter) {
            .code_block => {
                try w.writeAll("  ");
                try w.writeAll(@tagName(ikind[i]));
            },
            .annotation => {
                try w.writeAll("  ");
                try w.writeAll(@tagName(ikind[i]));
                try w.print("  x={d}  y={d}", .{ ix[i], iy[i] });
            },
            .hdl_block => {},
        }
        try writeInstanceProps(w, s.props.items, ips[i], ipc[i]);
        try w.writeByte('\n');
    }
}

fn matchesFilter(kind: Devices.DeviceKind, filter: InstanceFilter) bool {
    return switch (filter) {
        .code_block => kind.isCodeBlock(),
        .hdl_block => kind.isHdlBlock(),
        .annotation => kind.isAnnotation(),
    };
}

/// Write instance properties as key=value pairs, flattening multiline values.
fn writeInstanceProps(w: anytype, all_props: []const Prop, prop_start: u32, prop_count: u32) !void {
    if (prop_count == 0) return;
    const props_slice = all_props[prop_start..][0..prop_count];
    for (props_slice) |p| {
        if (std.mem.eql(u8, p.key, "name")) continue;
        try w.writeAll("  ");
        try w.writeAll(p.key);
        try w.writeByte('=');
        try writeFlatValue(w, p.val);
    }
}

/// Write a value, replacing newlines with spaces for single-line output.
fn writeFlatValue(w: anytype, val: []const u8) !void {
    if (std.mem.indexOfScalar(u8, val, '\n') != null) {
        for (val) |c| {
            try w.writeByte(if (c == '\n') ' ' else c);
        }
    } else {
        try w.writeAll(val);
    }
}

/// Write the digital: section (behavioral/synthesized models).
fn writeCHNDigital(w: anytype, dig: *const DigitalConfig) !void {
    try w.writeAll("\n  digital:\n");
    try w.writeAll("    language: ");
    try w.writeAll(dig.language.toStr());
    try w.writeByte('\n');

    // Behavioral model
    if (dig.behavioral.source) |src| {
        try w.writeAll("\n    behavioral:\n");
        try w.writeAll("      mode: ");
        try w.writeAll(if (dig.behavioral.mode == .@"inline") "inline" else "file");
        try w.writeByte('\n');
        if (dig.behavioral.top_module) |tm| {
            try w.writeAll("      top_module: ");
            try w.writeAll(tm);
            try w.writeByte('\n');
        }
        if (dig.behavioral.mode == .@"inline") {
            try w.writeAll("      source: |\n");
            // Emit each line of inline source indented
            var line_it = std.mem.splitScalar(u8, src, '\n');
            while (line_it.next()) |line| {
                try w.writeAll("        ");
                try w.writeAll(line);
                try w.writeByte('\n');
            }
        } else {
            try w.writeAll("      source: ");
            try w.writeAll(src);
            try w.writeByte('\n');
        }
    }

    // Synthesized model
    if (dig.synthesized.source) |src| {
        try w.writeAll("\n    synthesized:\n");
        try w.writeAll("      mode: ");
        try w.writeAll(if (dig.synthesized.mode == .@"inline") "inline" else "file");
        try w.writeByte('\n');
        try w.writeAll("      source: ");
        try w.writeAll(src);
        try w.writeByte('\n');
        if (dig.synthesized.liberty) |lib| {
            try w.writeAll("      liberty: ");
            try w.writeAll(lib);
            try w.writeByte('\n');
        }
        if (dig.synthesized.mapping) |map| {
            try w.writeAll("      mapping: ");
            try w.writeAll(map);
            try w.writeByte('\n');
        }
        if (dig.synthesized.supply_map.items.len > 0) {
            try w.writeAll("      supply_map:\n");
            for (dig.synthesized.supply_map.items) |sm| {
                try w.writeAll("        ");
                try w.writeAll(sm.key);
                try w.writeAll(": ");
                try w.writeAll(sm.val);
                try w.writeByte('\n');
            }
        }
    }
}

/// Map DeviceKind to Arch.md-convention group names.
fn kindToGroupName(kind: Devices.DeviceKind) []const u8 {
    return switch (kind) {
        // MOSFETs — all NMOS variants → "nmos", all PMOS variants → "pmos"
        .nmos3, .nmos4, .nmos4_depl, .nmos_sub, .nmoshv4, .rnmos4 => "nmos",
        .pmos3, .pmos4, .pmos_sub, .pmoshv4 => "pmos",
        // Passives — pluralized group names per Arch.md Section 4.1
        .capacitor => "capacitors",
        .resistor, .resistor3, .var_resistor => "resistors",
        .inductor => "inductors",
        .diode, .zener => "diodes",
        // BJTs
        .npn => "npn",
        .pnp => "pnp",
        // JFETs
        .njfet => "njfet",
        .pjfet => "pjfet",
        // Sources — singular per Arch.md Section 12
        .vsource, .sqwsource => "vsource",
        .isource => "isource",
        .ammeter => "vsource", // ammeter is a zero-volt source
        .behavioral => "behavioral",
        // Controlled sources
        .vcvs => "vcvs",
        .vccs => "vccs",
        .ccvs => "ccvs",
        .cccs => "cccs",
        // Everything else — use tag name
        else => @tagName(kind),
    };
}

/// Build nets from instance conns and write the nets section.
fn writeCHNNets(w: anytype, s: *const Schemify, a: Allocator) !void {
    const iname = s.instances.items(.name);
    const ikind = s.instances.items(.kind);
    const ics = s.instances.items(.conn_start);
    const icc = s.instances.items(.conn_count);

    // Build map: net_name -> list of "inst.pin" strings
    var net_map = std.StringArrayHashMap(List([]const u8)).init(a);
    defer {
        for (net_map.values()) |*list| list.deinit(a);
        net_map.deinit();
    }

    for (0..s.instances.len) |i| {
        if (ikind[i].isNonElectrical()) continue;
        const cc = icc[i];
        if (cc == 0) continue;
        const conns_slice = s.conns.items[ics[i]..][0..cc];
        for (conns_slice) |c| {
            const net_name = c.net;
            if (net_name.len == 0 or std.mem.eql(u8, net_name, "?")) continue;

            // Build "inst.pin" string
            const inst_pin = std.fmt.allocPrint(a, "{s}.{s}", .{ iname[i], c.pin }) catch continue;

            const gop = net_map.getOrPut(net_name) catch continue;
            if (!gop.found_existing) gop.value_ptr.* = .{};
            gop.value_ptr.append(a, inst_pin) catch continue;
        }
    }

    if (net_map.count() == 0) return;

    try w.writeByte('\n');
    try w.print("  nets [{d}]:\n", .{net_map.count()});

    var iter = net_map.iterator();
    while (iter.next()) |entry| {
        try w.writeAll("    ");
        try w.writeAll(entry.key_ptr.*);
        try w.writeAll("  -> ");
        for (entry.value_ptr.items, 0..) |inst_pin, j| {
            if (j > 0) try w.writeAll(", ");
            try w.writeAll(inst_pin);
        }
        try w.writeByte('\n');
    }
}

/// Write includes section from sym_props with key=="include".
fn writeCHNIncludes(w: anytype, s: *const Schemify) !void {
    var count: usize = 0;
    for (s.sym_props.items) |p| {
        if (std.mem.eql(u8, p.key, "include")) count += 1;
    }
    if (count == 0) return;
    try w.writeByte('\n');
    try w.print("  includes [{d}]:\n", .{count});
    for (s.sym_props.items) |p| {
        if (std.mem.eql(u8, p.key, "include")) {
            try w.writeAll("    ");
            try w.writeAll(p.val);
            try w.writeByte('\n');
        }
    }
}

/// Write analyses section from sym_props with "analysis." prefix.
fn writeCHNAnalyses(w: anytype, s: *const Schemify) !void {
    try writePrefixedSymProps(w, s.sym_props.items, "analysis.", "analyses");
}

/// Write measures section from sym_props with "measure." prefix.
fn writeCHNMeasures(w: anytype, s: *const Schemify) !void {
    try writePrefixedSymProps(w, s.sym_props.items, "measure.", "measures");
}

/// Generic helper: count sym_props matching a prefix, then emit as a "key: val" section.
fn writePrefixedSymProps(w: anytype, props: []const Prop, prefix: []const u8, section_name: []const u8) !void {
    var count: usize = 0;
    for (props) |p| {
        if (std.mem.startsWith(u8, p.key, prefix)) count += 1;
    }
    if (count == 0) return;
    try w.writeByte('\n');
    try w.print("  {s} [{d}]:\n", .{ section_name, count });
    for (props) |p| {
        if (std.mem.startsWith(u8, p.key, prefix)) {
            const key = p.key[prefix.len..];
            try w.writeAll("    ");
            try w.writeAll(key);
            try w.writeAll(": ");
            try w.writeAll(p.val);
            try w.writeByte('\n');
        }
    }
}

/// Write annotations section from sym_props with "ann." prefix.
fn writeCHNAnnotations(w: anytype, s: *const Schemify) !void {
    // Check if there are any annotation props
    var has_ann = false;
    for (s.sym_props.items) |p| {
        if (std.mem.startsWith(u8, p.key, "ann.")) { has_ann = true; break; }
    }
    if (!has_ann) return;

    try w.writeAll("\n  annotations:\n");

    // Top-level annotation keys (status, timestamp, sim_tool, corner)
    for (s.sym_props.items) |p| {
        if (!std.mem.startsWith(u8, p.key, "ann.")) continue;
        const sub = p.key["ann.".len..];
        // Skip sub-section keys
        if (std.mem.startsWith(u8, sub, "op.") or
            std.mem.startsWith(u8, sub, "measure.") or
            std.mem.startsWith(u8, sub, "note.") or
            std.mem.startsWith(u8, sub, "voltage.")) continue;
        try w.writeAll("    ");
        try w.writeAll(sub);
        try w.writeAll(": ");
        try w.writeAll(p.val);
        try w.writeByte('\n');
    }

    // Sub-sections: node_voltages, op_points, measures (all key-value format)
    try writeAnnSubSection(w, s.sym_props.items, "ann.voltage.", "node_voltages");
    try writeAnnSubSection(w, s.sym_props.items, "ann.op.", "op_points");
    try writeAnnSubSection(w, s.sym_props.items, "ann.measure.", "measures");

    // notes (list format, different from the key-value sub-sections)
    {
        var ncount: usize = 0;
        for (s.sym_props.items) |p| {
            if (std.mem.startsWith(u8, p.key, "ann.note.")) ncount += 1;
        }
        if (ncount > 0) {
            try w.writeAll("\n    notes:\n");
            for (s.sym_props.items) |p| {
                if (!std.mem.startsWith(u8, p.key, "ann.note.")) continue;
                try w.writeAll("      - \"");
                try w.writeAll(p.val);
                try w.writeAll("\"\n");
            }
        }
    }
}

/// Write an annotation sub-section (key-value pairs with a given prefix).
fn writeAnnSubSection(w: anytype, props: []const Prop, prefix: []const u8, section_name: []const u8) !void {
    var count: usize = 0;
    for (props) |p| {
        if (std.mem.startsWith(u8, p.key, prefix)) count += 1;
    }
    if (count == 0) return;
    try w.writeAll("\n    ");
    try w.writeAll(section_name);
    try w.writeAll(":\n");
    for (props) |p| {
        if (!std.mem.startsWith(u8, p.key, prefix)) continue;
        const rest = p.key[prefix.len..];
        try w.print("      {s}:  {s}\n", .{ rest, p.val });
    }
}

/// Map PinDir to Arch.md direction strings.
fn pinDirToChnStr(dir: PinDir) []const u8 {
    return switch (dir) {
        .input => "in",
        .output => "out",
        .inout => "inout",
        .power => "inout",
        .ground => "inout",
    };
}

/// Find a value in sym_props by key.
fn findSymProp(props: []const Prop, key: []const u8) ?[]const u8 {
    for (props) |p| {
        if (std.mem.eql(u8, p.key, key)) return p.val;
    }
    return null;
}

/// Keys emitted as dedicated lines/sections, not as params.
fn isSymPropMetadata(key: []const u8) bool {
    return std.mem.eql(u8, key, "description") or
        std.mem.eql(u8, key, "spice_prefix") or
        std.mem.eql(u8, key, "spice_format") or
        std.mem.eql(u8, key, "spice_lib") or
        std.mem.eql(u8, key, "include") or
        std.mem.startsWith(u8, key, "ann.") or
        std.mem.startsWith(u8, key, "analysis.") or
        std.mem.startsWith(u8, key, "measure.");
}

