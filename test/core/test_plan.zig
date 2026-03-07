//! Schemify Core Test Plan implementation.
//!
//! Seven tiers of tests:
//!   T1 — XSchem parser accuracy
//!   T2 — XSchem → Schemify conversion equivalence
//!   T3 — Dual-path convergence (fromXSchem vs toSchemify+fromSchemify)
//!   T4 — Generated SPICE vs reference netlist
//!   T5 — CHN v2 round-trip
//!   T6 — Net resolution correctness
//!   T7 — Edge cases and regression guards
//!
//! Fixtures are loaded at runtime from CWD (project root).
//! All tests use std.testing.allocator for automatic leak detection.

const std = @import("std");
const testing = std.testing;
const core = @import("core");

const XSchem = core.XSchem;
const XSchemType = core.XSchemType;
const sch = core.sch;
const netlist = core.netlist;
const dev = core.dev;

// ── Fixture paths (relative to project root) ─────────────────────────────── //

const P = struct {
    const res_div_sch = "test/examples/resistor_divider.sch";
    const empty_sch = "test/examples/empty.sch";
    const res_div_chn = "test/examples/resistor_divider.chn";
    const res_div_chn2 = "test/examples/resistor_divider.chn2";
    const res_div_spice_ref = "test/examples/resistor_divider.spice.ref";
    const cmos_inv_sch = "test/examples/xschem_core_examples/cmos_inv.sch";
    const lcc_sch = "test/examples/xschem_core_examples/LCC_instances.sch";
    const nfet_sym = "test/examples/xschem_sky130/sky130_fd_pr/nfet_01v8.sym";
    // classD_amp has a V {} verilog block
    const verilog_sch = "test/examples/xschem_core_examples/classD_amp.sch";
};

fn readFixture(a: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.fs.cwd().readFileAlloc(a, path, 16 * 1024 * 1024);
}

// ── SPICE structural comparison ──────────────────────────────────────────── //

const SpiceInst = struct {
    prefix: u8,
    name: []const u8,
};

fn parseSpiceInstances(a: std.mem.Allocator, spice: []const u8) ![]SpiceInst {
    var result: std.ArrayListUnmanaged(SpiceInst) = .{};
    errdefer result.deinit(a);
    var it = std.mem.splitScalar(u8, spice, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len < 2) continue;
        const c = std.ascii.toUpper(line[0]);
        if (c == '*' or c == '.' or c == '+') continue;
        if (!std.ascii.isAlphabetic(c)) continue;
        var tok = std.mem.tokenizeAny(u8, line[1..], " \t");
        const name_rest = tok.next() orelse continue;
        const full_name = line[0 .. 1 + name_rest.len];
        try result.append(a, .{ .prefix = c, .name = try a.dupe(u8, full_name) });
    }
    return result.toOwnedSlice(a);
}

fn cmpInstName(_: void, a: SpiceInst, b: SpiceInst) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

fn expectSameInstances(a: std.mem.Allocator, ref: []const u8, got: []const u8) !void {
    const ref_i = try parseSpiceInstances(a, ref);
    defer {
        for (ref_i) |r| a.free(r.name);
        a.free(ref_i);
    }
    const got_i = try parseSpiceInstances(a, got);
    defer {
        for (got_i) |g| a.free(g.name);
        a.free(got_i);
    }

    try testing.expectEqual(ref_i.len, got_i.len);
    std.mem.sort(SpiceInst, ref_i, {}, cmpInstName);
    std.mem.sort(SpiceInst, got_i, {}, cmpInstName);
    for (ref_i, got_i) |r, g| {
        try testing.expectEqual(r.prefix, g.prefix);
        try testing.expectEqualStrings(r.name, g.name);
    }
}

// ═══════════════════════════════════════════════════════════════════════════ //
// Tier 1: XSchem Parser Accuracy
// ═══════════════════════════════════════════════════════════════════════════ //

test "T1.1 resistor_divider.sch — element counts" {
    const data = try readFixture(testing.allocator, P.res_div_sch);
    defer testing.allocator.free(data);
    var xs = XSchem.readFile(data, testing.allocator, null);
    defer xs.deinit();

    try testing.expectEqual(@as(usize, 3), xs.instances.len); // V1, R1, R2
    try testing.expectEqual(@as(usize, 3), xs.wires.len);
    try testing.expectEqual(XSchemType.schematic, xs.xtype);
}

test "T1.1b cmos_inv.sch — element counts" {
    const data = try readFixture(testing.allocator, P.cmos_inv_sch);
    defer testing.allocator.free(data);
    var xs = XSchem.readFile(data, testing.allocator, null);
    defer xs.deinit();

    try testing.expectEqual(XSchemType.schematic, xs.xtype);
    try testing.expect(xs.instances.len > 0);
}

test "T1.1c LCC_instances.sch — element counts" {
    const data = try readFixture(testing.allocator, P.lcc_sch);
    defer testing.allocator.free(data);
    var xs = XSchem.readFile(data, testing.allocator, null);
    defer xs.deinit();

    try testing.expectEqual(XSchemType.schematic, xs.xtype);
    try testing.expect(xs.instances.len > 0);
}

test "T1.2 nfet_01v8.sym — detected as symbol, pins extracted" {
    const data = try readFixture(testing.allocator, P.nfet_sym);
    defer testing.allocator.free(data);
    var xs = XSchem.readFile(data, testing.allocator, null);
    defer xs.deinit();

    try testing.expectEqual(XSchemType.symbol, xs.xtype);
    try testing.expect(xs.pins.len >= 2);
    try testing.expectEqual(@as(usize, 0), xs.instances.len);
}

test "T1.3 resistor_divider.sch — instance names extracted" {
    const data = try readFixture(testing.allocator, P.res_div_sch);
    defer testing.allocator.free(data);
    var xs = XSchem.readFile(data, testing.allocator, null);
    defer xs.deinit();

    const names = xs.instances.slice().items(.name);
    try testing.expectEqualStrings("V1", names[0]);
    try testing.expectEqualStrings("R1", names[1]);
    try testing.expectEqualStrings("R2", names[2]);
}

test "T1.3b resistor_divider.sch — R1 has value=10k prop" {
    const data = try readFixture(testing.allocator, P.res_div_sch);
    defer testing.allocator.free(data);
    var xs = XSchem.readFile(data, testing.allocator, null);
    defer xs.deinit();

    const ps = xs.instances.slice().items(.prop_start);
    const pc = xs.instances.slice().items(.prop_count);
    try testing.expect(pc[1] >= 2);
    var found_value = false;
    for (xs.props.items[ps[1]..][0..pc[1]]) |p| {
        if (std.mem.eql(u8, p.key, "value")) {
            try testing.expectEqualStrings("10k", p.value);
            found_value = true;
        }
    }
    try testing.expect(found_value);
}

test "T1.4 resistor_divider.sch — wire net labels" {
    const data = try readFixture(testing.allocator, P.res_div_sch);
    defer testing.allocator.free(data);
    var xs = XSchem.readFile(data, testing.allocator, null);
    defer xs.deinit();

    const nets = xs.wires.slice().items(.net_name);
    try testing.expectEqualStrings("VDD", nets[0].?);
    try testing.expect(nets[1] == null);
    try testing.expectEqualStrings("GND", nets[2].?);
}

test "T1.5 LCC_instances.sch — at least one instance with multiple props" {
    const data = try readFixture(testing.allocator, P.lcc_sch);
    defer testing.allocator.free(data);
    var xs = XSchem.readFile(data, testing.allocator, null);
    defer xs.deinit();

    try testing.expect(xs.instances.len >= 1);
    const pc = xs.instances.slice().items(.prop_count);
    var max_props: u16 = 0;
    for (pc) |c| {
        if (c > max_props) max_props = c;
    }
    try testing.expect(max_props >= 2);
}

test "T1.6 classD_amp.sch — parses without crash, V block handled" {
    const data = try readFixture(testing.allocator, P.verilog_sch);
    defer testing.allocator.free(data);
    var xs = XSchem.readFile(data, testing.allocator, null);
    defer xs.deinit();

    // classD_amp.sch has `V {}` (empty verilog block) — parser correctly yields null.
    // What matters is no crash and schematic elements are parsed.
    try testing.expectEqual(XSchemType.schematic, xs.xtype);
    try testing.expect(xs.instances.len > 0);
}

test "T1.7 empty.sch — zero elements, no crash" {
    const data = try readFixture(testing.allocator, P.empty_sch);
    defer testing.allocator.free(data);
    var xs = XSchem.readFile(data, testing.allocator, null);
    defer xs.deinit();

    try testing.expectEqual(@as(usize, 0), xs.instances.len);
    try testing.expectEqual(@as(usize, 0), xs.wires.len);
    try testing.expectEqual(@as(usize, 0), xs.pins.len);
}

test "T1.8 resistor_divider.sch — f64 coordinates parsed correctly" {
    const data = try readFixture(testing.allocator, P.res_div_sch);
    defer testing.allocator.free(data);
    var xs = XSchem.readFile(data, testing.allocator, null);
    defer xs.deinit();

    const wx0 = xs.wires.slice().items(.x0);
    const wy0 = xs.wires.slice().items(.y0);
    const wx1 = xs.wires.slice().items(.x1);
    const wy1 = xs.wires.slice().items(.y1);

    // First wire: N 0 0 200 0
    try testing.expectApproxEqAbs(@as(f64, 0), wx0[0], 0.01);
    try testing.expectApproxEqAbs(@as(f64, 0), wy0[0], 0.01);
    try testing.expectApproxEqAbs(@as(f64, 200), wx1[0], 0.01);
    try testing.expectApproxEqAbs(@as(f64, 0), wy1[0], 0.01);
}

// ═══════════════════════════════════════════════════════════════════════════ //
// Tier 2: XSchem → Schemify Conversion Equivalence
// ═══════════════════════════════════════════════════════════════════════════ //

test "T2.1 instance count survives conversion" {
    const data = try readFixture(testing.allocator, P.res_div_sch);
    defer testing.allocator.free(data);
    var xs = XSchem.readFile(data, testing.allocator, null);
    defer xs.deinit();
    var sfy = try xs.toSchemify(testing.allocator);
    defer sfy.deinit();

    try testing.expectEqual(xs.instances.len, sfy.instances.len);
}

test "T2.2 wire count survives conversion" {
    const data = try readFixture(testing.allocator, P.res_div_sch);
    defer testing.allocator.free(data);
    var xs = XSchem.readFile(data, testing.allocator, null);
    defer xs.deinit();
    var sfy = try xs.toSchemify(testing.allocator);
    defer sfy.deinit();

    try testing.expectEqual(xs.wires.len, sfy.wires.len);
}

test "T2.3 props mapped: XSchem .value → Schemify .val" {
    const data = try readFixture(testing.allocator, P.res_div_sch);
    defer testing.allocator.free(data);
    var xs = XSchem.readFile(data, testing.allocator, null);
    defer xs.deinit();
    var sfy = try xs.toSchemify(testing.allocator);
    defer sfy.deinit();

    try testing.expectEqual(xs.props.items.len, sfy.props.items.len);
    for (xs.props.items, sfy.props.items) |xp, sp| {
        try testing.expectEqualStrings(xp.key, sp.key);
        try testing.expectEqualStrings(xp.value, sp.val);
    }
}

test "T2.4 coordinates rounded f64 → i32" {
    const data = try readFixture(testing.allocator, P.res_div_sch);
    defer testing.allocator.free(data);
    var xs = XSchem.readFile(data, testing.allocator, null);
    defer xs.deinit();
    var sfy = try xs.toSchemify(testing.allocator);
    defer sfy.deinit();

    const xs_x = xs.instances.slice().items(.x);
    const sf_x = sfy.instances.slice().items(.x);
    const xs_y = xs.instances.slice().items(.y);
    const sf_y = sfy.instances.slice().items(.y);

    for (xs_x, sf_x) |xv, sv| {
        try testing.expectEqual(@as(i32, @intFromFloat(@round(xv))), sv);
    }
    for (xs_y, sf_y) |yv, sv| {
        try testing.expectEqual(@as(i32, @intFromFloat(@round(yv))), sv);
    }
}

test "T2.5 wire net labels survive conversion" {
    const data = try readFixture(testing.allocator, P.res_div_sch);
    defer testing.allocator.free(data);
    var xs = XSchem.readFile(data, testing.allocator, null);
    defer xs.deinit();
    var sfy = try xs.toSchemify(testing.allocator);
    defer sfy.deinit();

    const xs_nets = xs.wires.slice().items(.net_name);
    const sf_nets = sfy.wires.slice().items(.net_name);
    for (xs_nets, sf_nets) |xn, sn| {
        if (xn) |x_name| {
            try testing.expect(sn != null);
            try testing.expectEqualStrings(x_name, sn.?);
        } else {
            try testing.expect(sn == null);
        }
    }
}

test "T2.6 symbol paths survive conversion" {
    const data = try readFixture(testing.allocator, P.cmos_inv_sch);
    defer testing.allocator.free(data);
    var xs = XSchem.readFile(data, testing.allocator, null);
    defer xs.deinit();
    var sfy = try xs.toSchemify(testing.allocator);
    defer sfy.deinit();

    const xs_sym = xs.instances.slice().items(.symbol);
    const sf_sym = sfy.instances.slice().items(.symbol);
    for (xs_sym, sf_sym) |x, s| {
        try testing.expectEqualStrings(x, s);
    }
}

test "T2.7 DeviceKind inferred for sky130 devices in cmos_inv" {
    const data = try readFixture(testing.allocator, P.cmos_inv_sch);
    defer testing.allocator.free(data);
    var xs = XSchem.readFile(data, testing.allocator, null);
    defer xs.deinit();
    var sfy = try xs.toSchemify(testing.allocator);
    defer sfy.deinit();

    const kinds = sfy.instances.slice().items(.kind);
    var has_mosfet = false;
    for (kinds) |k| if (k == .mosfet) { has_mosfet = true; };
    try testing.expect(has_mosfet);
}

test "T2.8 shapes survive conversion: lines, rects, arcs, circles" {
    const data = try readFixture(testing.allocator, P.cmos_inv_sch);
    defer testing.allocator.free(data);
    var xs = XSchem.readFile(data, testing.allocator, null);
    defer xs.deinit();
    var sfy = try xs.toSchemify(testing.allocator);
    defer sfy.deinit();

    try testing.expectEqual(xs.lines.len, sfy.lines.len);
    try testing.expectEqual(xs.rects.len, sfy.rects.len);
    try testing.expectEqual(xs.arcs.len, sfy.arcs.len);
    try testing.expectEqual(xs.circles.len, sfy.circles.len);
}

// ═══════════════════════════════════════════════════════════════════════════ //
// Tier 3: Dual-Path Convergence
// ═══════════════════════════════════════════════════════════════════════════ //

const DualResult = struct {
    xs: XSchem,
    sfy: sch.Schemify,
    form_a: netlist.UniversalNetlistForm,
    form_b: netlist.UniversalNetlistForm,
    data: []u8,

    fn deinit(self: *DualResult) void {
        self.form_b.deinit();
        self.form_a.deinit();
        self.sfy.deinit();
        self.xs.deinit();
        testing.allocator.free(self.data);
    }
};

fn dualPath(path: []const u8) !DualResult {
    const data = try readFixture(testing.allocator, path);
    errdefer testing.allocator.free(data);

    var xs = XSchem.readFile(data, testing.allocator, null);
    errdefer xs.deinit();

    // Path A: XSchem → fromXSchem
    var form_a = try netlist.UniversalNetlistForm.fromXSchem(testing.allocator, &xs);
    errdefer form_a.deinit();

    // Path B: XSchem → toSchemify → resolveNets → fromSchemify
    var sfy = try xs.toSchemify(testing.allocator);
    errdefer sfy.deinit();
    sfy.resolveNets();
    var form_b = try netlist.UniversalNetlistForm.fromSchemify(testing.allocator, &sfy);
    errdefer form_b.deinit();

    return .{ .xs = xs, .sfy = sfy, .form_a = form_a, .form_b = form_b, .data = data };
}

test "T3.1 dual-path: same device count — cmos_inv" {
    var r = try dualPath(P.cmos_inv_sch);
    defer r.deinit();
    try testing.expectEqual(r.form_a.devices.len, r.form_b.devices.len);
}

test "T3.2 dual-path: same wire count — cmos_inv" {
    var r = try dualPath(P.cmos_inv_sch);
    defer r.deinit();
    try testing.expectEqual(r.form_a.wires.len, r.form_b.wires.len);
}

test "T3.3 dual-path: same prop count — cmos_inv" {
    var r = try dualPath(P.cmos_inv_sch);
    defer r.deinit();
    try testing.expectEqual(r.form_a.props.items.len, r.form_b.props.items.len);
}

test "T3.4 dual-path: same device symbols in order — cmos_inv" {
    var r = try dualPath(P.cmos_inv_sch);
    defer r.deinit();
    const syms_a = r.form_a.devices.slice().items(.symbol);
    const syms_b = r.form_b.devices.slice().items(.symbol);
    for (syms_a, syms_b) |a_sym, b_sym| try testing.expectEqualStrings(a_sym, b_sym);
}

test "T3.5 dual-path: same device names — cmos_inv" {
    var r = try dualPath(P.cmos_inv_sch);
    defer r.deinit();
    const names_a = r.form_a.devices.slice().items(.name);
    const names_b = r.form_b.devices.slice().items(.name);
    for (names_a, names_b) |an, bn| try testing.expectEqualStrings(an, bn);
}

test "T3.6 dual-path: net_names populated via resolveNets path — cmos_inv" {
    var r = try dualPath(P.cmos_inv_sch);
    defer r.deinit();
    // form_b was built after resolveNets — should have net_names
    try testing.expect(r.form_b.net_names.items.len > 0);
}

test "T3.7 dual-path convergence — all fixtures" {
    const fixtures = [_][]const u8{ P.res_div_sch, P.cmos_inv_sch, P.lcc_sch };
    for (fixtures) |path| {
        var r = try dualPath(path);
        defer r.deinit();
        try testing.expectEqual(r.form_a.devices.len, r.form_b.devices.len);
        try testing.expectEqual(r.form_a.wires.len, r.form_b.wires.len);
        try testing.expectEqual(r.form_a.props.items.len, r.form_b.props.items.len);
    }
}

// ═══════════════════════════════════════════════════════════════════════════ //
// Tier 4: Generated SPICE vs Reference Netlist
// ═══════════════════════════════════════════════════════════════════════════ //

test "T4.1 resistor_divider — SPICE has same instances as reference" {
    const data = try readFixture(testing.allocator, P.res_div_sch);
    defer testing.allocator.free(data);
    const ref = try readFixture(testing.allocator, P.res_div_spice_ref);
    defer testing.allocator.free(ref);

    var xs = XSchem.readFile(data, testing.allocator, null);
    defer xs.deinit();
    var sfy = try xs.toSchemify(testing.allocator);
    defer sfy.deinit();
    sfy.resolveNets();

    var form = try netlist.UniversalNetlistForm.fromSchemify(testing.allocator, &sfy);
    defer form.deinit();

    var reg = dev.PdkDeviceRegistry{};
    const got = try form.generateSpice(testing.allocator, &reg);
    defer testing.allocator.free(got);

    try expectSameInstances(testing.allocator, ref, got);
}

test "T4.4 SPICE output has .title and .end" {
    const data = try readFixture(testing.allocator, P.res_div_sch);
    defer testing.allocator.free(data);

    var xs = XSchem.readFile(data, testing.allocator, null);
    defer xs.deinit();
    var sfy = try xs.toSchemify(testing.allocator);
    defer sfy.deinit();
    sfy.resolveNets();

    var form = try netlist.UniversalNetlistForm.fromSchemify(testing.allocator, &sfy);
    defer form.deinit();

    var reg = dev.PdkDeviceRegistry{};
    const got = try form.generateSpice(testing.allocator, &reg);
    defer testing.allocator.free(got);

    const trimmed = std.mem.trimLeft(u8, got, " \t\n\r");
    try testing.expect(std.mem.startsWith(u8, trimmed, ".title"));
    try testing.expect(std.mem.indexOf(u8, got, ".end") != null);
}

test "T4.5 named wires resolved into net_names" {
    const data = try readFixture(testing.allocator, P.res_div_sch);
    defer testing.allocator.free(data);

    var xs = XSchem.readFile(data, testing.allocator, null);
    defer xs.deinit();
    var sfy = try xs.toSchemify(testing.allocator);
    defer sfy.deinit();
    sfy.resolveNets();

    var form = try netlist.UniversalNetlistForm.fromSchemify(testing.allocator, &sfy);
    defer form.deinit();

    // VDD and GND should appear in the resolved net names.
    var has_vdd = false;
    var has_gnd = false;
    for (form.net_names.items) |n| {
        if (std.mem.eql(u8, n, "VDD")) has_vdd = true;
        if (std.mem.eql(u8, n, "GND") or std.mem.eql(u8, n, "0")) has_gnd = true;
    }
    try testing.expect(has_vdd);
    try testing.expect(has_gnd);
}

// ═══════════════════════════════════════════════════════════════════════════ //
// Tier 5: CHN v2 Round-Trip
// ═══════════════════════════════════════════════════════════════════════════ //

test "T5.1 CHN v2 round-trip: element counts preserved" {
    const data = try readFixture(testing.allocator, P.res_div_sch);
    defer testing.allocator.free(data);

    var xs = XSchem.readFile(data, testing.allocator, null);
    defer xs.deinit();
    var sfy1 = try xs.toSchemify(testing.allocator);
    defer sfy1.deinit();
    sfy1.resolveNets();

    const bytes = sfy1.writeFile(testing.allocator, null) orelse return error.WriteFailed;
    defer testing.allocator.free(bytes);

    var sfy2 = sch.Schemify.readFile(bytes, testing.allocator, null);
    defer sfy2.deinit();

    try testing.expectEqual(sfy1.instances.len, sfy2.instances.len);
    try testing.expectEqual(sfy1.wires.len, sfy2.wires.len);
    try testing.expectEqual(sfy1.texts.len, sfy2.texts.len);
    try testing.expectEqual(sfy1.lines.len, sfy2.lines.len);
    try testing.expectEqual(sfy1.rects.len, sfy2.rects.len);
}

test "T5.2 CHN v2 round-trip: net names preserved" {
    const data = try readFixture(testing.allocator, P.res_div_sch);
    defer testing.allocator.free(data);

    var xs = XSchem.readFile(data, testing.allocator, null);
    defer xs.deinit();
    var sfy1 = try xs.toSchemify(testing.allocator);
    defer sfy1.deinit();
    sfy1.resolveNets();

    const bytes = sfy1.writeFile(testing.allocator, null) orelse return error.WriteFailed;
    defer testing.allocator.free(bytes);

    var sfy2 = sch.Schemify.readFile(bytes, testing.allocator, null);
    defer sfy2.deinit();

    try testing.expectEqual(sfy1.nets.items.len, sfy2.nets.items.len);
    for (sfy1.nets.items, sfy2.nets.items) |a_net, b_net| {
        try testing.expectEqualStrings(a_net.name, b_net.name);
    }
}

test "T5.3 CHN v2 round-trip: net_conns preserved" {
    const data = try readFixture(testing.allocator, P.res_div_sch);
    defer testing.allocator.free(data);

    var xs = XSchem.readFile(data, testing.allocator, null);
    defer xs.deinit();
    var sfy1 = try xs.toSchemify(testing.allocator);
    defer sfy1.deinit();
    sfy1.resolveNets();

    const bytes = sfy1.writeFile(testing.allocator, null) orelse return error.WriteFailed;
    defer testing.allocator.free(bytes);

    var sfy2 = sch.Schemify.readFile(bytes, testing.allocator, null);
    defer sfy2.deinit();

    try testing.expectEqual(sfy1.net_conns.items.len, sfy2.net_conns.items.len);
    for (sfy1.net_conns.items, sfy2.net_conns.items) |a_conn, b_conn| {
        try testing.expectEqual(a_conn.net_id, b_conn.net_id);
        try testing.expectEqual(a_conn.kind, b_conn.kind);
        try testing.expectEqual(a_conn.ref_a, b_conn.ref_a);
        try testing.expectEqual(a_conn.ref_b, b_conn.ref_b);
    }
}

test "T5.4 CHN v1 backward compat: parses, nets empty" {
    const data = try readFixture(testing.allocator, P.res_div_chn);
    defer testing.allocator.free(data);

    var sfy = sch.Schemify.readFile(data, testing.allocator, null);
    defer sfy.deinit();

    try testing.expectEqual(@as(usize, 3), sfy.instances.len);
    try testing.expectEqual(@as(usize, 3), sfy.wires.len);
    try testing.expectEqual(@as(usize, 0), sfy.nets.items.len);
    try testing.expectEqual(@as(usize, 0), sfy.net_conns.items.len);
}

test "T5.5 CHN v2 direct parse: nets section populated" {
    const data = try readFixture(testing.allocator, P.res_div_chn2);
    defer testing.allocator.free(data);

    var sfy = sch.Schemify.readFile(data, testing.allocator, null);
    defer sfy.deinit();

    try testing.expectEqual(@as(usize, 3), sfy.instances.len);
    try testing.expect(sfy.nets.items.len >= 2);
    try testing.expect(sfy.net_conns.items.len > 0);
    try testing.expectEqualStrings("VDD", sfy.nets.items[0].name);
    try testing.expectEqualStrings("GND", sfy.nets.items[1].name);
}

// ═══════════════════════════════════════════════════════════════════════════ //
// Tier 6: Net Resolution Correctness
// ═══════════════════════════════════════════════════════════════════════════ //

test "T6.1 resolveNets: resistor_divider = 3 nets (VDD, GND, mid)" {
    const data = try readFixture(testing.allocator, P.res_div_sch);
    defer testing.allocator.free(data);

    var xs = XSchem.readFile(data, testing.allocator, null);
    defer xs.deinit();
    var sfy = try xs.toSchemify(testing.allocator);
    defer sfy.deinit();

    sfy.resolveNets();

    try testing.expectEqual(@as(usize, 3), sfy.nets.items.len);
    var has_vdd = false;
    var has_gnd = false;
    for (sfy.nets.items) |net| {
        if (std.mem.eql(u8, net.name, "VDD")) has_vdd = true;
        if (std.mem.eql(u8, net.name, "GND") or std.mem.eql(u8, net.name, "0")) has_gnd = true;
    }
    try testing.expect(has_vdd);
    try testing.expect(has_gnd);
}

test "T6.2 resolveNets: named wire takes precedence, only 1 auto-named net" {
    const data = try readFixture(testing.allocator, P.res_div_sch);
    defer testing.allocator.free(data);

    var xs = XSchem.readFile(data, testing.allocator, null);
    defer xs.deinit();
    var sfy = try xs.toSchemify(testing.allocator);
    defer sfy.deinit();

    sfy.resolveNets();

    var auto_count: usize = 0;
    for (sfy.nets.items) |net| {
        if (std.mem.startsWith(u8, net.name, "_n")) auto_count += 1;
    }
    try testing.expectEqual(@as(usize, 1), auto_count);
}

test "T6.3 resolveNets: ground net present — cmos_inv" {
    const data = try readFixture(testing.allocator, P.cmos_inv_sch);
    defer testing.allocator.free(data);

    var xs = XSchem.readFile(data, testing.allocator, null);
    defer xs.deinit();
    var sfy = try xs.toSchemify(testing.allocator);
    defer sfy.deinit();

    sfy.resolveNets();

    var has_ground = false;
    for (sfy.nets.items) |net| {
        if (std.mem.eql(u8, net.name, "0") or std.mem.eql(u8, net.name, "GND")) {
            has_ground = true;
        }
    }
    try testing.expect(has_ground);
}

test "T6.4 resolveNets: wire_endpoint entries populate net_conns" {
    const data = try readFixture(testing.allocator, P.res_div_sch);
    defer testing.allocator.free(data);

    var xs = XSchem.readFile(data, testing.allocator, null);
    defer xs.deinit();
    var sfy = try xs.toSchemify(testing.allocator);
    defer sfy.deinit();

    sfy.resolveNets();

    // 3 wires × 2 endpoints = 6 wire_endpoint entries
    var we_count: usize = 0;
    for (sfy.net_conns.items) |conn| {
        if (conn.kind == .wire_endpoint) we_count += 1;
    }
    try testing.expectEqual(@as(usize, 6), we_count);
}

test "T6.5 resolveNets: idempotent — calling twice gives same counts" {
    const data = try readFixture(testing.allocator, P.res_div_sch);
    defer testing.allocator.free(data);

    var xs = XSchem.readFile(data, testing.allocator, null);
    defer xs.deinit();
    var sfy = try xs.toSchemify(testing.allocator);
    defer sfy.deinit();

    sfy.resolveNets();
    const nets_1 = sfy.nets.items.len;
    const conns_1 = sfy.net_conns.items.len;

    sfy.resolveNets();
    try testing.expectEqual(nets_1, sfy.nets.items.len);
    try testing.expectEqual(conns_1, sfy.net_conns.items.len);
}

// ═══════════════════════════════════════════════════════════════════════════ //
// Tier 7: Edge Cases and Regression Guards
// ═══════════════════════════════════════════════════════════════════════════ //

test "T7.1 XSchem: garbage input produces empty store, no crash" {
    var xs = XSchem.readFile("this is not a schematic at all", testing.allocator, null);
    defer xs.deinit();
    try testing.expectEqual(@as(usize, 0), xs.instances.len);
}

test "T7.1b Schemify: garbage input produces empty store, no crash" {
    var sfy = sch.Schemify.readFile("not a chn file", testing.allocator, null);
    defer sfy.deinit();
    try testing.expectEqual(@as(usize, 0), sfy.instances.len);
}

test "T7.2 large fixture parses without crash — cmos_inv" {
    const data = try readFixture(testing.allocator, P.cmos_inv_sch);
    defer testing.allocator.free(data);
    var xs = XSchem.readFile(data, testing.allocator, null);
    defer xs.deinit();
    try testing.expect(xs.instances.len > 0);
}

test "T7.4 .sym file: XSchem parse → toSchemify preserves pins" {
    const data = try readFixture(testing.allocator, P.nfet_sym);
    defer testing.allocator.free(data);
    var xs = XSchem.readFile(data, testing.allocator, null);
    defer xs.deinit();
    var sfy = try xs.toSchemify(testing.allocator);
    defer sfy.deinit();

    try testing.expect(sfy.pins.len >= 2);
    const pin_names = sfy.pins.slice().items(.name);
    for (pin_names) |name| try testing.expect(name.len > 0);
}

test "T7.5 empty.sch toSchemify: no crash, zero elements" {
    const data = try readFixture(testing.allocator, P.empty_sch);
    defer testing.allocator.free(data);
    var xs = XSchem.readFile(data, testing.allocator, null);
    defer xs.deinit();
    var sfy = try xs.toSchemify(testing.allocator);
    defer sfy.deinit();

    try testing.expectEqual(@as(usize, 0), sfy.instances.len);
    try testing.expectEqual(@as(usize, 0), sfy.wires.len);
}

test "T7.6 resolveNets on empty schematic: no crash, zero nets" {
    const data = try readFixture(testing.allocator, P.empty_sch);
    defer testing.allocator.free(data);
    var xs = XSchem.readFile(data, testing.allocator, null);
    defer xs.deinit();
    var sfy = try xs.toSchemify(testing.allocator);
    defer sfy.deinit();

    sfy.resolveNets();
    try testing.expectEqual(@as(usize, 0), sfy.nets.items.len);
    try testing.expectEqual(@as(usize, 0), sfy.net_conns.items.len);
}

test "T7.7 generateSpice on empty schematic: valid .title and .end" {
    const data = try readFixture(testing.allocator, P.empty_sch);
    defer testing.allocator.free(data);
    var xs = XSchem.readFile(data, testing.allocator, null);
    defer xs.deinit();
    var sfy = try xs.toSchemify(testing.allocator);
    defer sfy.deinit();
    sfy.resolveNets();

    var form = try netlist.UniversalNetlistForm.fromSchemify(testing.allocator, &sfy);
    defer form.deinit();

    var reg = dev.PdkDeviceRegistry{};
    const got = try form.generateSpice(testing.allocator, &reg);
    defer testing.allocator.free(got);

    try testing.expect(std.mem.indexOf(u8, got, ".end") != null);
}
