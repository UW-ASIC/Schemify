//! Extensive tests for core/ — Reader, Writer, Schemify, Types.
//!
//! Validates Arch.md compliance, round-trip fidelity, annotation preservation,
//! pin_positions parsing, [N] guardrail handling, and rendering data completeness.

const std = @import("std");
const testing = std.testing;
const core = @import("core");

const Schemify = core.Schemify;
const sch = core.sch;

// ═══════════════════════════════════════════════════════════════════════════════
// Helpers
// ═══════════════════════════════════════════════════════════════════════════════

fn readCHN(data: []const u8) Schemify {
    return Schemify.readFile(data, testing.allocator, null);
}

fn findSymProp(s: *const Schemify, key: []const u8) ?[]const u8 {
    for (s.sym_props.items) |p| {
        if (std.mem.eql(u8, p.key, key)) return p.val;
    }
    return null;
}

fn findSymPropPrefix(s: *const Schemify, prefix: []const u8) usize {
    var count: usize = 0;
    for (s.sym_props.items) |p| {
        if (std.mem.startsWith(u8, p.key, prefix)) count += 1;
    }
    return count;
}

fn roundTrip(input: []const u8) !void {
    var s1 = readCHN(input);
    defer s1.deinit();

    const written = s1.writeFile(testing.allocator, null) orelse return error.WriteFailed;
    defer testing.allocator.free(written);

    var s2 = Schemify.readFile(written, testing.allocator, null);
    defer s2.deinit();

    // Compare key structural properties
    try testing.expectEqual(s1.stype, s2.stype);
    try testing.expectEqual(s1.pins.len, s2.pins.len);
    try testing.expectEqual(s1.instances.len, s2.instances.len);
    try testing.expectEqual(s1.wires.len, s2.wires.len);
}

// ═══════════════════════════════════════════════════════════════════════════════
// 1. Reader — SYMBOL section
// ═══════════════════════════════════════════════════════════════════════════════

test "Reader: parse component header" {
    const input =
        \\chn 1.0
        \\
        \\SYMBOL inverter
        \\  desc: CMOS inverter
        \\
        \\  pins [2]:
        \\    IN  in
        \\    OUT out
        \\
        \\SCHEMATIC
    ;
    var s = readCHN(input);
    defer s.deinit();

    try testing.expectEqual(sch.SifyType.component, s.stype);
    try testing.expectEqualStrings("inverter", s.name);
    try testing.expectEqual(@as(usize, 2), s.pins.len);

    const desc = findSymProp(&s, "description");
    try testing.expect(desc != null);
    try testing.expectEqualStrings("CMOS inverter", desc.?);
}

test "Reader: parse primitive header" {
    const input =
        \\chn_prim 1.0
        \\
        \\SYMBOL nmos
        \\  desc: N-channel MOSFET
        \\
        \\  pins [4]:
        \\    d  inout
        \\    g  in
        \\    s  inout
        \\    b  inout
        \\
        \\  spice_prefix: M
        \\  spice_format: @name @d @g @s @b @model w=@w l=@l
    ;
    var s = readCHN(input);
    defer s.deinit();

    try testing.expectEqual(sch.SifyType.primitive, s.stype);
    try testing.expectEqualStrings("nmos", s.name);
    try testing.expectEqual(@as(usize, 4), s.pins.len);

    // Check pin directions
    const dirs = s.pins.items(.dir);
    try testing.expectEqual(sch.PinDir.inout, dirs[0]); // d
    try testing.expectEqual(sch.PinDir.input, dirs[1]); // g
    try testing.expectEqual(sch.PinDir.inout, dirs[2]); // s

    // Check spice metadata
    try testing.expectEqualStrings("M", findSymProp(&s, "spice_prefix").?);
    try testing.expectEqualStrings("@name @d @g @s @b @model w=@w l=@l", findSymProp(&s, "spice_format").?);
}

test "Reader: parse testbench header" {
    const input =
        \\chn_testbench 1.0
        \\
        \\TESTBENCH tb_opamp
        \\  desc: Open-loop AC response
    ;
    var s = readCHN(input);
    defer s.deinit();

    try testing.expectEqual(sch.SifyType.testbench, s.stype);
    try testing.expectEqualStrings("tb_opamp", s.name);
}

test "Reader: pin width attribute" {
    const input =
        \\chn 1.0
        \\
        \\SYMBOL bus_mux
        \\  pins [2]:
        \\    DATA in width=8
        \\    SEL  in width=3
        \\
        \\SCHEMATIC
    ;
    var s = readCHN(input);
    defer s.deinit();

    const widths = s.pins.items(.width);
    try testing.expectEqual(@as(u16, 8), widths[0]);
    try testing.expectEqual(@as(u16, 3), widths[1]);
}

test "Reader: pin x/y attributes" {
    const input =
        \\chn 1.0
        \\
        \\SYMBOL res
        \\  pins [2]:
        \\    p inout x=0 y=-30
        \\    n inout x=0 y=30
        \\
        \\SCHEMATIC
    ;
    var s = readCHN(input);
    defer s.deinit();

    const px = s.pins.items(.x);
    const py = s.pins.items(.y);
    try testing.expectEqual(@as(i32, 0), px[0]);
    try testing.expectEqual(@as(i32, -30), py[0]);
    try testing.expectEqual(@as(i32, 0), px[1]);
    try testing.expectEqual(@as(i32, 30), py[1]);
}

test "Reader: params section" {
    const input =
        \\chn 1.0
        \\
        \\SYMBOL opamp
        \\  pins [1]:
        \\    OUT out
        \\
        \\  params [3]:
        \\    wp = 10u
        \\    lp = 500n
        \\    cc = 2p
        \\
        \\SCHEMATIC
    ;
    var s = readCHN(input);
    defer s.deinit();

    try testing.expectEqualStrings("10u", findSymProp(&s, "wp").?);
    try testing.expectEqualStrings("500n", findSymProp(&s, "lp").?);
    try testing.expectEqualStrings("2p", findSymProp(&s, "cc").?);
}

test "Reader: spice_lib" {
    const input =
        \\chn_prim 1.0
        \\
        \\SYMBOL nmos
        \\  pins [1]:
        \\    d inout
        \\
        \\  spice_prefix: M
        \\  spice_lib: $PDK/models/nmos.lib section=tt
    ;
    var s = readCHN(input);
    defer s.deinit();

    try testing.expectEqualStrings("$PDK/models/nmos.lib section=tt", findSymProp(&s, "spice_lib").?);
}

// ═══════════════════════════════════════════════════════════════════════════════
// 2. Reader — SCHEMATIC section: instances
// ═══════════════════════════════════════════════════════════════════════════════

test "Reader: type-grouped tabular instances" {
    const input =
        \\chn 1.0
        \\
        \\SYMBOL diffpair
        \\  pins [1]:
        \\    OUT out
        \\
        \\SCHEMATIC
        \\
        \\  nmos [3]{name, w, l, model}:
        \\    M0  2u  100n  nch
        \\    M1  2u  100n  nch
        \\    M2  4u  200n  nch
    ;
    var s = readCHN(input);
    defer s.deinit();

    try testing.expectEqual(@as(usize, 3), s.instances.len);

    const names = s.instances.items(.name);
    try testing.expectEqualStrings("M0", names[0]);
    try testing.expectEqualStrings("M1", names[1]);
    try testing.expectEqualStrings("M2", names[2]);

    // Check props for M2
    const ps = s.instances.items(.prop_start);
    const pc = s.instances.items(.prop_count);
    const m2_props = s.props.items[ps[2]..][0..pc[2]];
    var found_w = false;
    for (m2_props) |p| {
        if (std.mem.eql(u8, p.key, "w")) {
            try testing.expectEqualStrings("4u", p.val);
            found_w = true;
        }
    }
    try testing.expect(found_w);
}

test "Reader: type-grouped with position columns" {
    const input =
        \\chn 1.0
        \\
        \\SYMBOL test
        \\  pins [1]:
        \\    OUT out
        \\
        \\SCHEMATIC
        \\
        \\  nmos [1]{name, x, y, rot, flip, w, l}:
        \\    M0  300  400  1  0  2u  100n
    ;
    var s = readCHN(input);
    defer s.deinit();

    try testing.expectEqual(@as(usize, 1), s.instances.len);
    const ix = s.instances.items(.x);
    const iy = s.instances.items(.y);
    const irot = s.instances.items(.rot);
    try testing.expectEqual(@as(i32, 300), ix[0]);
    try testing.expectEqual(@as(i32, 400), iy[0]);
    try testing.expectEqual(@as(u2, 1), irot[0]);
}

test "Reader: generic instances with key=value" {
    const input =
        \\chn 1.0
        \\
        \\SYMBOL test
        \\  pins [1]:
        \\    OUT out
        \\
        \\SCHEMATIC
        \\
        \\  instances [2]:
        \\    XBUF chn/buffer strength=4 fanout=8 x=100 y=200
        \\    DUT  chn/opamp  gain=60 x=500 y=300
    ;
    var s = readCHN(input);
    defer s.deinit();

    try testing.expectEqual(@as(usize, 2), s.instances.len);

    const names = s.instances.items(.name);
    try testing.expectEqualStrings("XBUF", names[0]);
    try testing.expectEqualStrings("DUT", names[1]);

    const ix = s.instances.items(.x);
    try testing.expectEqual(@as(i32, 100), ix[0]);
    try testing.expectEqual(@as(i32, 500), ix[1]);
}

test "Reader: multiple type groups" {
    const input =
        \\chn 1.0
        \\
        \\SYMBOL test
        \\  pins [1]:
        \\    OUT out
        \\
        \\SCHEMATIC
        \\
        \\  nmos [2]{name, w, l}:
        \\    M0  2u  100n
        \\    M1  2u  100n
        \\
        \\  pmos [1]{name, w, l}:
        \\    M2  4u  100n
        \\
        \\  capacitors [1]{name, c}:
        \\    CC  2p
    ;
    var s = readCHN(input);
    defer s.deinit();

    try testing.expectEqual(@as(usize, 4), s.instances.len);

    const kinds = s.instances.items(.kind);
    try testing.expect(kinds[0].isNmos());
    try testing.expect(kinds[1].isNmos());
    try testing.expect(kinds[2].isPmos());
    try testing.expectEqual(core.Devices.DeviceKind.capacitor, kinds[3]);
}

// ═══════════════════════════════════════════════════════════════════════════════
// 3. Reader — SCHEMATIC section: nets
// ═══════════════════════════════════════════════════════════════════════════════

test "Reader: net declarations" {
    const input =
        \\chn 1.0
        \\
        \\SYMBOL test
        \\  pins [1]:
        \\    OUT out
        \\
        \\SCHEMATIC
        \\
        \\  nmos [2]{name, w, l}:
        \\    M0  2u  100n
        \\    M1  2u  100n
        \\
        \\  nets [3]:
        \\    INP  -> M0.g
        \\    INN  -> M1.g
        \\    tail -> M0.s, M1.s
    ;
    var s = readCHN(input);
    defer s.deinit();

    // Check that conns were built for M0
    const cs = s.instances.items(.conn_start);
    const cc = s.instances.items(.conn_count);
    try testing.expect(cc[0] > 0); // M0 should have conns
    try testing.expect(cc[1] > 0); // M1 should have conns

    // Verify M0's conn has pin "g" -> net "INP"
    const m0_conns = s.conns.items[cs[0]..][0..cc[0]];
    var found_inp = false;
    for (m0_conns) |c| {
        if (std.mem.eql(u8, c.pin, "g") and std.mem.eql(u8, c.net, "INP")) found_inp = true;
    }
    try testing.expect(found_inp);

    // Verify M0 has "s" -> "tail"
    var found_tail = false;
    for (m0_conns) |c| {
        if (std.mem.eql(u8, c.pin, "s") and std.mem.eql(u8, c.net, "tail")) found_tail = true;
    }
    try testing.expect(found_tail);
}

// ═══════════════════════════════════════════════════════════════════════════════
// 4. Reader — SCHEMATIC section: wires
// ═══════════════════════════════════════════════════════════════════════════════

test "Reader: wire geometry" {
    const input =
        \\chn 1.0
        \\
        \\SYMBOL test
        \\  pins [1]:
        \\    OUT out
        \\
        \\SCHEMATIC
        \\
        \\  wires [3]:
        \\    0 0 100 0
        \\    100 0 100 50 VDD
        \\    200 100 300 100
    ;
    var s = readCHN(input);
    defer s.deinit();

    try testing.expectEqual(@as(usize, 3), s.wires.len);

    const wx0 = s.wires.items(.x0);
    const wy0 = s.wires.items(.y0);
    const wx1 = s.wires.items(.x1);
    const wy1 = s.wires.items(.y1);
    const wnn = s.wires.items(.net_name);

    try testing.expectEqual(@as(i32, 0), wx0[0]);
    try testing.expectEqual(@as(i32, 0), wy0[0]);
    try testing.expectEqual(@as(i32, 100), wx1[0]);
    try testing.expectEqual(@as(i32, 0), wy1[0]);
    try testing.expect(wnn[0] == null);

    try testing.expectEqual(@as(i32, 100), wx0[1]);
    try testing.expectEqualStrings("VDD", wnn[1].?);
}

// ═══════════════════════════════════════════════════════════════════════════════
// 5. Reader — drawing section
// ═══════════════════════════════════════════════════════════════════════════════

test "Reader: drawing shapes" {
    const input =
        \\chn_prim 1.0
        \\
        \\SYMBOL resistor
        \\  pins [2]:
        \\    p inout
        \\    n inout
        \\
        \\  drawing:
        \\    line 0 -30 0 -20
        \\    line 0 20 0 30
        \\    rect -10 -20 10 20
        \\    circle 0 0 5
        \\    arc 0 0 8 45 270
    ;
    var s = readCHN(input);
    defer s.deinit();

    try testing.expectEqual(@as(usize, 2), s.lines.len);
    try testing.expectEqual(@as(usize, 1), s.rects.len);
    try testing.expectEqual(@as(usize, 1), s.circles.len);
    try testing.expectEqual(@as(usize, 1), s.arcs.len);

    // Verify line coordinates
    const lx0 = s.lines.items(.x0);
    const ly0 = s.lines.items(.y0);
    try testing.expectEqual(@as(i32, 0), lx0[0]);
    try testing.expectEqual(@as(i32, -30), ly0[0]);

    // Verify rect
    const rx0 = s.rects.items(.x0);
    const ry0 = s.rects.items(.y0);
    const rx1 = s.rects.items(.x1);
    const ry1 = s.rects.items(.y1);
    try testing.expectEqual(@as(i32, -10), rx0[0]);
    try testing.expectEqual(@as(i32, -20), ry0[0]);
    try testing.expectEqual(@as(i32, 10), rx1[0]);
    try testing.expectEqual(@as(i32, 20), ry1[0]);

    // Verify circle
    const ccx = s.circles.items(.cx);
    const ccy = s.circles.items(.cy);
    const crad = s.circles.items(.radius);
    try testing.expectEqual(@as(i32, 0), ccx[0]);
    try testing.expectEqual(@as(i32, 0), ccy[0]);
    try testing.expectEqual(@as(i32, 5), crad[0]);

    // Verify arc
    const acx = s.arcs.items(.cx);
    const acy = s.arcs.items(.cy);
    const arad = s.arcs.items(.radius);
    const asa = s.arcs.items(.start_angle);
    const asw = s.arcs.items(.sweep_angle);
    try testing.expectEqual(@as(i32, 0), acx[0]);
    try testing.expectEqual(@as(i32, 0), acy[0]);
    try testing.expectEqual(@as(i32, 8), arad[0]);
    try testing.expectEqual(@as(i16, 45), asa[0]);
    try testing.expectEqual(@as(i16, 270), asw[0]);
}

test "Reader: pin_positions in drawing" {
    const input =
        \\chn_prim 1.0
        \\
        \\SYMBOL nmos
        \\  pins [3]:
        \\    d inout
        \\    g in
        \\    s inout
        \\
        \\  drawing:
        \\    line 0 -30 0 30
        \\    pin_positions:
        \\      d: (0, -30)
        \\      g: (-20, 0)
        \\      s: (0, 30)
    ;
    var s = readCHN(input);
    defer s.deinit();

    try testing.expectEqual(@as(usize, 3), s.pins.len);

    const px = s.pins.items(.x);
    const py = s.pins.items(.y);
    const pnames = s.pins.items(.name);

    // Find pin "d" and verify position
    for (0..s.pins.len) |i| {
        if (std.mem.eql(u8, pnames[i], "d")) {
            try testing.expectEqual(@as(i32, 0), px[i]);
            try testing.expectEqual(@as(i32, -30), py[i]);
        }
        if (std.mem.eql(u8, pnames[i], "g")) {
            try testing.expectEqual(@as(i32, -20), px[i]);
            try testing.expectEqual(@as(i32, 0), py[i]);
        }
        if (std.mem.eql(u8, pnames[i], "s")) {
            try testing.expectEqual(@as(i32, 0), px[i]);
            try testing.expectEqual(@as(i32, 30), py[i]);
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// 6. Reader — annotations
// ═══════════════════════════════════════════════════════════════════════════════

test "Reader: annotation top-level fields" {
    const input =
        \\chn 1.0
        \\
        \\SYMBOL test
        \\  pins [1]:
        \\    OUT out
        \\
        \\SCHEMATIC
        \\
        \\  annotations:
        \\    status: stale
        \\    timestamp: 2026-03-20T14:22:00Z
        \\    sim_tool: ngspice 43
        \\    corner: tt
    ;
    var s = readCHN(input);
    defer s.deinit();

    try testing.expectEqualStrings("stale", findSymProp(&s, "ann.status").?);
    try testing.expectEqualStrings("2026-03-20T14:22:00Z", findSymProp(&s, "ann.timestamp").?);
    try testing.expectEqualStrings("ngspice 43", findSymProp(&s, "ann.sim_tool").?);
    try testing.expectEqualStrings("tt", findSymProp(&s, "ann.corner").?);
}

test "Reader: annotation node_voltages preserved" {
    const input =
        \\chn 1.0
        \\
        \\SYMBOL test
        \\  pins [1]:
        \\    OUT out
        \\
        \\SCHEMATIC
        \\
        \\  annotations:
        \\    status: fresh
        \\
        \\    node_voltages:
        \\      VDD: 1.800
        \\      out_p: 1.023
        \\      tail: 0.412
    ;
    var s = readCHN(input);
    defer s.deinit();

    try testing.expectEqualStrings("1.800", findSymProp(&s, "ann.voltage.VDD").?);
    try testing.expectEqualStrings("1.023", findSymProp(&s, "ann.voltage.out_p").?);
    try testing.expectEqualStrings("0.412", findSymProp(&s, "ann.voltage.tail").?);
}

test "Reader: annotation measures preserved" {
    const input =
        \\chn 1.0
        \\
        \\SYMBOL test
        \\  pins [1]:
        \\    OUT out
        \\
        \\SCHEMATIC
        \\
        \\  annotations:
        \\    status: fresh
        \\
        \\    measures:
        \\      dc_gain: 42.3 dB
        \\      ugbw: 85.2 MHz
    ;
    var s = readCHN(input);
    defer s.deinit();

    try testing.expectEqualStrings("42.3 dB", findSymProp(&s, "ann.measure.dc_gain").?);
    try testing.expectEqualStrings("85.2 MHz", findSymProp(&s, "ann.measure.ugbw").?);
}

test "Reader: annotation notes preserved" {
    const input =
        \\chn 1.0
        \\
        \\SYMBOL test
        \\  pins [1]:
        \\    OUT out
        \\
        \\SCHEMATIC
        \\
        \\  annotations:
        \\    status: fresh
        \\
        \\    notes:
        \\      - "M0/M1 mismatch causing 4.6mV offset"
        \\      - "Phase margin marginal at ff corner"
    ;
    var s = readCHN(input);
    defer s.deinit();

    try testing.expectEqualStrings("M0/M1 mismatch causing 4.6mV offset", findSymProp(&s, "ann.note.0").?);
    try testing.expectEqualStrings("Phase margin marginal at ff corner", findSymProp(&s, "ann.note.1").?);
}

test "Reader: annotation op_points preserved" {
    const input =
        \\chn 1.0
        \\
        \\SYMBOL test
        \\  pins [1]:
        \\    OUT out
        \\
        \\SCHEMATIC
        \\
        \\  annotations:
        \\    status: fresh
        \\
        \\    op_points [2]{inst, vgs, vds, id}:
        \\      M0  0.612  0.611  52.3u
        \\      M1  0.588  0.365  47.7u
    ;
    var s = readCHN(input);
    defer s.deinit();

    try testing.expectEqualStrings("0.612", findSymProp(&s, "ann.op.M0.vgs").?);
    try testing.expectEqualStrings("0.611", findSymProp(&s, "ann.op.M0.vds").?);
    try testing.expectEqualStrings("52.3u", findSymProp(&s, "ann.op.M0.id").?);
    try testing.expectEqualStrings("0.588", findSymProp(&s, "ann.op.M1.vgs").?);
}

// ═══════════════════════════════════════════════════════════════════════════════
// 7. Reader — testbench sections
// ═══════════════════════════════════════════════════════════════════════════════

test "Reader: testbench includes" {
    const input =
        \\chn_testbench 1.0
        \\
        \\TESTBENCH tb_test
        \\
        \\  includes [2]:
        \\    "$PDK/models/all.lib" section=tt
        \\    "$PDK/models/nmos.lib" section=ff
    ;
    var s = readCHN(input);
    defer s.deinit();

    const count = findSymPropPrefix(&s, "include");
    // "include" key (not prefixed)
    var include_count: usize = 0;
    for (s.sym_props.items) |p| {
        if (std.mem.eql(u8, p.key, "include")) include_count += 1;
    }
    _ = count;
    try testing.expectEqual(@as(usize, 2), include_count);
}

test "Reader: testbench analyses" {
    const input =
        \\chn_testbench 1.0
        \\
        \\TESTBENCH tb_test
        \\
        \\  analyses [3]:
        \\    op:
        \\    ac: start=1 stop=10G points_per_dec=20
        \\    tran: tstep=1n tstop=100n
    ;
    var s = readCHN(input);
    defer s.deinit();

    try testing.expect(findSymProp(&s, "analysis.op") != null);
    try testing.expectEqualStrings("start=1 stop=10G points_per_dec=20", findSymProp(&s, "analysis.ac").?);
    try testing.expectEqualStrings("tstep=1n tstop=100n", findSymProp(&s, "analysis.tran").?);
}

test "Reader: testbench measures" {
    const input =
        \\chn_testbench 1.0
        \\
        \\TESTBENCH tb_test
        \\
        \\  measures [2]:
        \\    dc_gain: find dB(V(out)/V(inp)) at freq=1
        \\    ugbw: find freq when dB(V(out)/V(inp))=0
    ;
    var s = readCHN(input);
    defer s.deinit();

    try testing.expectEqualStrings("find dB(V(out)/V(inp)) at freq=1", findSymProp(&s, "measure.dc_gain").?);
    try testing.expectEqualStrings("find freq when dB(V(out)/V(inp))=0", findSymProp(&s, "measure.ugbw").?);
}

// ═══════════════════════════════════════════════════════════════════════════════
// 8. Reader — generate loops
// ═══════════════════════════════════════════════════════════════════════════════

test "Reader: generate loop expansion" {
    const input =
        \\chn 1.0
        \\
        \\SYMBOL test
        \\  pins [1]:
        \\    OUT out
        \\
        \\SCHEMATIC
        \\
        \\  generate bit in 0..2:
        \\    nmos [1]{name, w, l}:
        \\      MDRV_{bit}  1u  100n
        \\    nets:
        \\      data_{bit}  -> MDRV_{bit}.d
    ;
    var s = readCHN(input);
    defer s.deinit();

    // Should have 3 instances: MDRV_0, MDRV_1, MDRV_2
    try testing.expectEqual(@as(usize, 3), s.instances.len);

    const names = s.instances.items(.name);
    try testing.expectEqualStrings("MDRV_0", names[0]);
    try testing.expectEqualStrings("MDRV_1", names[1]);
    try testing.expectEqualStrings("MDRV_2", names[2]);
}

// ═══════════════════════════════════════════════════════════════════════════════
// 9. Reader — digital config
// ═══════════════════════════════════════════════════════════════════════════════

test "Reader: digital behavioral config" {
    const input =
        \\chn 1.0
        \\
        \\SYMBOL counter
        \\  pins [1]:
        \\    OUT out
        \\
        \\SCHEMATIC
        \\
        \\  digital:
        \\    language: verilog
        \\    behavioral:
        \\      mode: file
        \\      source: counter.v
        \\      top_module: counter
    ;
    var s = readCHN(input);
    defer s.deinit();

    try testing.expect(s.digital != null);
    const dig = s.digital.?;
    try testing.expectEqual(sch.HdlLanguage.verilog, dig.language);
    try testing.expectEqualStrings("counter.v", dig.behavioral.source.?);
    try testing.expectEqualStrings("counter", dig.behavioral.top_module.?);
}

// ═══════════════════════════════════════════════════════════════════════════════
// 10. Reader — comments and blank lines
// ═══════════════════════════════════════════════════════════════════════════════

test "Reader: comments are stripped" {
    const input =
        \\chn 1.0
        \\
        \\SYMBOL test # this is a comment
        \\  pins [1]:
        \\    OUT out # output pin
        \\
        \\SCHEMATIC
    ;
    var s = readCHN(input);
    defer s.deinit();

    try testing.expectEqualStrings("test", s.name);
    try testing.expectEqual(@as(usize, 1), s.pins.len);
}

// ═══════════════════════════════════════════════════════════════════════════════
// 11. Writer — round-trip fidelity
// ═══════════════════════════════════════════════════════════════════════════════

test "Writer: round-trip component" {
    const input =
        \\chn 1.0
        \\
        \\SYMBOL inverter
        \\  desc: CMOS inverter
        \\
        \\  pins [4]:
        \\    IN  in
        \\    OUT out
        \\    VDD inout
        \\    VSS inout
        \\
        \\  params [2]:
        \\    wp = 2u
        \\    wn = 1u
        \\
        \\  spice_prefix: X
        \\
        \\SCHEMATIC
        \\
        \\  nmos [1]{name, w, l}:
        \\    M0  2u  100n
        \\
        \\  pmos [1]{name, w, l}:
        \\    M1  4u  100n
        \\
        \\  nets [2]:
        \\    IN -> M0.g, M1.g
        \\    OUT -> M0.d, M1.d
    ;
    try roundTrip(input);
}

test "Writer: round-trip primitive with drawing" {
    const input =
        \\chn_prim 1.0
        \\
        \\SYMBOL nmos
        \\  desc: N-channel MOSFET
        \\
        \\  pins [2]:
        \\    d inout
        \\    s inout
        \\
        \\  spice_prefix: M
        \\  spice_format: @name @d @s @model
        \\
        \\  drawing:
        \\    line 0 -30 0 -20
        \\    line 0 20 0 30
        \\    rect -10 -20 10 20
    ;
    try roundTrip(input);
}

test "Writer: round-trip testbench" {
    const input =
        \\chn_testbench 1.0
        \\
        \\TESTBENCH tb_test
    ;
    try roundTrip(input);
}

test "Writer: spice_format not in params" {
    const input =
        \\chn_prim 1.0
        \\
        \\SYMBOL nmos
        \\  pins [1]:
        \\    d inout
        \\
        \\  params [1]:
        \\    w = 1u
        \\
        \\  spice_prefix: M
        \\  spice_format: @name @d @model w=@w
    ;
    var s = readCHN(input);
    defer s.deinit();

    const written = s.writeFile(testing.allocator, null) orelse return error.WriteFailed;
    defer testing.allocator.free(written);

    // Verify spice_format appears as its own line, not inside params section
    try testing.expect(std.mem.indexOf(u8, written, "spice_format: @name") != null);

    // Parse the written output and check params don't contain spice_format
    var s2 = Schemify.readFile(written, testing.allocator, null);
    defer s2.deinit();

    // The sym_props should have spice_format but it shouldn't be double-counted
    var format_count: usize = 0;
    for (s2.sym_props.items) |p| {
        if (std.mem.eql(u8, p.key, "spice_format")) format_count += 1;
    }
    try testing.expectEqual(@as(usize, 1), format_count);
}

test "Writer: annotations round-trip" {
    const input =
        \\chn 1.0
        \\
        \\SYMBOL test
        \\  pins [1]:
        \\    OUT out
        \\
        \\SCHEMATIC
        \\
        \\  annotations:
        \\    status: fresh
        \\    timestamp: 2026-03-20T14:22:00Z
        \\
        \\    node_voltages:
        \\      VDD: 1.800
        \\
        \\    measures:
        \\      dc_gain: 42.3 dB
        \\
        \\    notes:
        \\      - "check CC sizing"
    ;
    var s = readCHN(input);
    defer s.deinit();

    const written = s.writeFile(testing.allocator, null) orelse return error.WriteFailed;
    defer testing.allocator.free(written);

    // Verify the written output contains annotation sections
    try testing.expect(std.mem.indexOf(u8, written, "annotations:") != null);
    try testing.expect(std.mem.indexOf(u8, written, "status: fresh") != null);
    try testing.expect(std.mem.indexOf(u8, written, "node_voltages:") != null);
    try testing.expect(std.mem.indexOf(u8, written, "VDD:") != null);
    try testing.expect(std.mem.indexOf(u8, written, "measures:") != null);
    try testing.expect(std.mem.indexOf(u8, written, "dc_gain:") != null);
    try testing.expect(std.mem.indexOf(u8, written, "notes:") != null);
    try testing.expect(std.mem.indexOf(u8, written, "check CC sizing") != null);

    // Re-parse and verify data survived
    var s2 = Schemify.readFile(written, testing.allocator, null);
    defer s2.deinit();

    try testing.expectEqualStrings("fresh", findSymProp(&s2, "ann.status").?);
    try testing.expectEqualStrings("1.800", findSymProp(&s2, "ann.voltage.VDD").?);
    try testing.expectEqualStrings("42.3 dB", findSymProp(&s2, "ann.measure.dc_gain").?);
    try testing.expectEqualStrings("check CC sizing", findSymProp(&s2, "ann.note.0").?);
}

test "Writer: includes round-trip" {
    const input =
        \\chn_testbench 1.0
        \\
        \\TESTBENCH tb_test
        \\
        \\  includes [2]:
        \\    "$PDK/models/all.lib" section=tt
        \\    "$PDK/models/nmos.lib"
    ;
    var s = readCHN(input);
    defer s.deinit();

    const written = s.writeFile(testing.allocator, null) orelse return error.WriteFailed;
    defer testing.allocator.free(written);

    try testing.expect(std.mem.indexOf(u8, written, "includes [2]:") != null);
    try testing.expect(std.mem.indexOf(u8, written, "$PDK/models/all.lib") != null);

    var s2 = Schemify.readFile(written, testing.allocator, null);
    defer s2.deinit();

    var ic: usize = 0;
    for (s2.sym_props.items) |p| {
        if (std.mem.eql(u8, p.key, "include")) ic += 1;
    }
    try testing.expectEqual(@as(usize, 2), ic);
}

test "Writer: analyses round-trip" {
    const input =
        \\chn_testbench 1.0
        \\
        \\TESTBENCH tb_test
        \\
        \\  analyses [2]:
        \\    op:
        \\    ac: start=1 stop=10G
    ;
    var s = readCHN(input);
    defer s.deinit();

    const written = s.writeFile(testing.allocator, null) orelse return error.WriteFailed;
    defer testing.allocator.free(written);

    try testing.expect(std.mem.indexOf(u8, written, "analyses [2]:") != null);

    var s2 = Schemify.readFile(written, testing.allocator, null);
    defer s2.deinit();

    try testing.expect(findSymProp(&s2, "analysis.op") != null);
    try testing.expectEqualStrings("start=1 stop=10G", findSymProp(&s2, "analysis.ac").?);
}

test "Writer: measures round-trip" {
    const input =
        \\chn_testbench 1.0
        \\
        \\TESTBENCH tb_test
        \\
        \\  measures [1]:
        \\    dc_gain: find dB(V(out)) at freq=1
    ;
    var s = readCHN(input);
    defer s.deinit();

    const written = s.writeFile(testing.allocator, null) orelse return error.WriteFailed;
    defer testing.allocator.free(written);

    try testing.expect(std.mem.indexOf(u8, written, "measures [1]:") != null);

    var s2 = Schemify.readFile(written, testing.allocator, null);
    defer s2.deinit();

    try testing.expectEqualStrings("find dB(V(out)) at freq=1", findSymProp(&s2, "measure.dc_gain").?);
}

test "Writer: wire geometry round-trip" {
    const input =
        \\chn 1.0
        \\
        \\SYMBOL test
        \\  pins [1]:
        \\    OUT out
        \\
        \\SCHEMATIC
        \\
        \\  wires [2]:
        \\    0 0 100 0
        \\    100 0 100 50 VDD
    ;
    var s = readCHN(input);
    defer s.deinit();

    const written = s.writeFile(testing.allocator, null) orelse return error.WriteFailed;
    defer testing.allocator.free(written);

    var s2 = Schemify.readFile(written, testing.allocator, null);
    defer s2.deinit();

    try testing.expectEqual(@as(usize, 2), s2.wires.len);
    try testing.expectEqual(@as(i32, 0), s2.wires.items(.x0)[0]);
    try testing.expectEqualStrings("VDD", s2.wires.items(.net_name)[1].?);
}

test "Writer: drawing round-trip" {
    const input =
        \\chn_prim 1.0
        \\
        \\SYMBOL res
        \\  pins [1]:
        \\    p inout
        \\
        \\  drawing:
        \\    line 0 -30 0 30
        \\    rect -5 -10 5 10
        \\    arc 0 0 8 0 360
        \\    circle 0 0 3
    ;
    var s = readCHN(input);
    defer s.deinit();

    const written = s.writeFile(testing.allocator, null) orelse return error.WriteFailed;
    defer testing.allocator.free(written);

    var s2 = Schemify.readFile(written, testing.allocator, null);
    defer s2.deinit();

    try testing.expectEqual(@as(usize, 1), s2.lines.len);
    try testing.expectEqual(@as(usize, 1), s2.rects.len);
    try testing.expectEqual(@as(usize, 1), s2.arcs.len);
    try testing.expectEqual(@as(usize, 1), s2.circles.len);
}

// ═══════════════════════════════════════════════════════════════════════════════
// 12. Schemify — builder API
// ═══════════════════════════════════════════════════════════════════════════════

test "Schemify: addComponent" {
    var s = Schemify.init(testing.allocator);
    defer s.deinit();

    const idx = try s.addComponent(.{
        .name = "M0",
        .symbol = "nmos",
        .kind = .nmos4,
        .x = 100,
        .y = 200,
        .rot = 1,
        .props = &.{
            .{ .key = "w", .val = "2u" },
            .{ .key = "l", .val = "100n" },
        },
    });
    try testing.expectEqual(@as(u32, 0), idx);
    try testing.expectEqual(@as(usize, 1), s.instances.len);
    try testing.expectEqual(@as(i32, 100), s.instances.items(.x)[0]);
    try testing.expectEqual(@as(u16, 2), s.instances.items(.prop_count)[0]);
}

test "Schemify: addWire" {
    var s = Schemify.init(testing.allocator);
    defer s.deinit();

    try s.addWire(.{ .x0 = 0, .y0 = 0, .x1 = 100, .y1 = 0, .net_name = "VDD" });
    try testing.expectEqual(@as(usize, 1), s.wires.len);
    try testing.expectEqualStrings("VDD", s.wires.items(.net_name)[0].?);
}

test "Schemify: drawLine/Rect/Circle/Arc" {
    var s = Schemify.init(testing.allocator);
    defer s.deinit();

    try s.drawLine(.{ .layer = 0, .x0 = 0, .y0 = 0, .x1 = 10, .y1 = 10 });
    try s.drawRect(.{ .layer = 0, .x0 = -5, .y0 = -5, .x1 = 5, .y1 = 5 });
    try s.drawCircle(.{ .layer = 0, .cx = 0, .cy = 0, .radius = 3 });
    try s.drawArc(.{ .layer = 0, .cx = 0, .cy = 0, .radius = 5, .start_angle = 0, .sweep_angle = 180 });

    try testing.expectEqual(@as(usize, 1), s.lines.len);
    try testing.expectEqual(@as(usize, 1), s.rects.len);
    try testing.expectEqual(@as(usize, 1), s.circles.len);
    try testing.expectEqual(@as(usize, 1), s.arcs.len);
}

test "Schemify: drawPin" {
    var s = Schemify.init(testing.allocator);
    defer s.deinit();

    try s.drawPin(.{ .name = "VDD", .x = 0, .y = -30, .dir = .power, .width = 1 });
    try testing.expectEqual(@as(usize, 1), s.pins.len);
    try testing.expectEqualStrings("VDD", s.pins.items(.name)[0]);
    try testing.expectEqual(sch.PinDir.power, s.pins.items(.dir)[0]);
}

test "Schemify: addGlobal deduplication" {
    var s = Schemify.init(testing.allocator);
    defer s.deinit();

    try s.addGlobal("VDD");
    try s.addGlobal("VSS");
    try s.addGlobal("VDD"); // duplicate
    try testing.expectEqual(@as(usize, 2), s.globals.items.len);
}

// ═══════════════════════════════════════════════════════════════════════════════
// 13. Schemify — net resolution
// ═══════════════════════════════════════════════════════════════════════════════

test "Schemify: resolveNets basic wire connectivity" {
    var s = Schemify.init(testing.allocator);
    defer s.deinit();

    // Two wires forming a T-junction
    try s.addWire(.{ .x0 = 0, .y0 = 0, .x1 = 100, .y1 = 0 });
    try s.addWire(.{ .x0 = 100, .y0 = 0, .x1 = 100, .y1 = 50 });

    s.resolveNets();

    // Should have at least 1 net connecting these wires
    try testing.expect(s.nets.items.len >= 1);
}

test "Schemify: resolveNets named wire" {
    var s = Schemify.init(testing.allocator);
    defer s.deinit();

    try s.addWire(.{ .x0 = 0, .y0 = 0, .x1 = 100, .y1 = 0, .net_name = "VDD" });
    try s.addWire(.{ .x0 = 100, .y0 = 0, .x1 = 200, .y1 = 0 });

    s.resolveNets();

    // The named net "VDD" should propagate
    var found_vdd = false;
    for (s.nets.items) |n| {
        if (std.mem.eql(u8, n.name, "VDD")) found_vdd = true;
    }
    try testing.expect(found_vdd);
}

// ═══════════════════════════════════════════════════════════════════════════════
// 14. Types — CT namespace
// ═══════════════════════════════════════════════════════════════════════════════

test "FileType.fromPath" {
    try testing.expectEqual(core.FileType.chn, core.FileType.fromPath("opamp.chn"));
    try testing.expectEqual(core.FileType.chn_prim, core.FileType.fromPath("nmos.chn_prim"));
    try testing.expectEqual(core.FileType.chn_tb, core.FileType.fromPath("tb.chn_tb"));
    try testing.expectEqual(core.FileType.xschem_sch, core.FileType.fromPath("test.sch"));
    try testing.expectEqual(core.FileType.unknown, core.FileType.fromPath("readme.txt"));
}

test "PinDir.fromStr" {
    try testing.expectEqual(sch.PinDir.input, sch.PinDir.fromStr("in"));
    try testing.expectEqual(sch.PinDir.input, sch.PinDir.fromStr("input"));
    try testing.expectEqual(sch.PinDir.output, sch.PinDir.fromStr("out"));
    try testing.expectEqual(sch.PinDir.inout, sch.PinDir.fromStr("inout"));
    try testing.expectEqual(sch.PinDir.inout, sch.PinDir.fromStr("io"));
    try testing.expectEqual(sch.PinDir.power, sch.PinDir.fromStr("power"));
    try testing.expectEqual(sch.PinDir.ground, sch.PinDir.fromStr("ground"));
    try testing.expectEqual(sch.PinDir.inout, sch.PinDir.fromStr("")); // default
}

test "Transform.compose" {
    const T = core.Transform;
    const id = T.identity;

    // identity compose identity = identity
    const r = id.compose(id);
    try testing.expectEqual(@as(u2, 0), r.rot);
    try testing.expect(!r.flip);

    // rot90 compose rot90 = rot180
    const rot90 = T{ .rot = 1 };
    const rot180 = rot90.compose(rot90);
    try testing.expectEqual(@as(u2, 2), rot180.rot);
}

test "Shape: all variants" {
    const Shape = core.Shape;
    const shapes = [_]Shape{
        .{ .line = .{ .start = .{ 0, 0 }, .end = .{ 10, 10 } } },
        .{ .rect = .{ .min = .{ -5, -5 }, .max = .{ 5, 5 } } },
        .{ .arc = .{ .center = .{ 0, 0 }, .radius = 8, .start_angle = 45, .sweep_angle = 270 } },
        .{ .circle = .{ .center = .{ 0, 0 }, .radius = 5 } },
        .{ .other = {} },
    };

    for (shapes) |shape| {
        switch (shape) {
            .line => |l| try testing.expectEqual(@as(i32, 10), l.end[0]),
            .rect => |r| try testing.expectEqual(@as(i32, 5), r.max[0]),
            .arc => |a| try testing.expectEqual(@as(i16, 270), a.sweep_angle),
            .circle => |ci| try testing.expectEqual(@as(i32, 5), ci.radius),
            .other => {},
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// 15. Rendering data completeness — positional data exists
// ═══════════════════════════════════════════════════════════════════════════════

test "Rendering: all elements have position fields" {
    // This test ensures the DOD structs have the fields the GUI renderer needs.
    // If a field is removed or renamed, this test breaks — preventing silent rendering loss.
    var s = Schemify.init(testing.allocator);
    defer s.deinit();

    // Add one of every renderable element
    try s.drawLine(.{ .layer = 0, .x0 = 1, .y0 = 2, .x1 = 3, .y1 = 4 });
    try s.drawRect(.{ .layer = 0, .x0 = 5, .y0 = 6, .x1 = 7, .y1 = 8 });
    try s.drawCircle(.{ .layer = 0, .cx = 9, .cy = 10, .radius = 11 });
    try s.drawArc(.{ .layer = 0, .cx = 12, .cy = 13, .radius = 14, .start_angle = 15, .sweep_angle = 16 });
    try s.drawText(.{ .content = "hello", .x = 17, .y = 18, .layer = 0 });
    try s.drawPin(.{ .name = "A", .x = 19, .y = 20, .dir = .input });
    try s.addWire(.{ .x0 = 21, .y0 = 22, .x1 = 23, .y1 = 24 });
    _ = try s.addComponent(.{ .name = "I0", .symbol = "nmos", .x = 25, .y = 26 });

    // Verify all positions are accessible
    try testing.expectEqual(@as(i32, 1), s.lines.items(.x0)[0]);
    try testing.expectEqual(@as(i32, 5), s.rects.items(.x0)[0]);
    try testing.expectEqual(@as(i32, 9), s.circles.items(.cx)[0]);
    try testing.expectEqual(@as(i32, 12), s.arcs.items(.cx)[0]);
    try testing.expectEqual(@as(i32, 17), s.texts.items(.x)[0]);
    try testing.expectEqual(@as(i32, 19), s.pins.items(.x)[0]);
    try testing.expectEqual(@as(i32, 21), s.wires.items(.x0)[0]);
    try testing.expectEqual(@as(i32, 25), s.instances.items(.x)[0]);
}

// ═══════════════════════════════════════════════════════════════════════════════
// 16. Full Arch.md example — two-stage opamp
// ═══════════════════════════════════════════════════════════════════════════════

test "Full Arch.md opamp example" {
    const input =
        \\chn 1.0
        \\
        \\SYMBOL two_stage_opamp
        \\  desc: Miller-compensated two-stage CMOS op-amp
        \\
        \\  pins [6]:
        \\    INP   in
        \\    INN   in
        \\    OUT   out
        \\    VDD   inout
        \\    VSS   inout
        \\    VBIAS in
        \\
        \\  params [4]:
        \\    wp_in = 10u
        \\    ln_in = 500n
        \\    wn_tail = 5u
        \\    cc = 2p
        \\
        \\  spice_prefix: X
        \\
        \\SCHEMATIC
        \\
        \\  nmos [3]{name, w, l, model}:
        \\    M1      10u  500n  nch
        \\    M2      10u  500n  nch
        \\    MTAIL1  5u   1u    nch
        \\
        \\  pmos [2]{name, w, l, model}:
        \\    M3  5u  500n  pch
        \\    M4  5u  500n  pch
        \\
        \\  capacitors [1]{name, c}:
        \\    CC  2p
        \\
        \\  nets [7]:
        \\    INP     -> M1.g
        \\    INN     -> M2.g
        \\    tail1   -> M1.s, M2.s, MTAIL1.d
        \\    stage1p -> M1.d, M3.d
        \\    stage1n -> M2.d, M4.d, CC.p
        \\    VDD     -> M3.s, M4.s
        \\    VSS     -> MTAIL1.s
        \\
        \\  wires [3]:
        \\    300 400 300 350
        \\    500 400 500 350
        \\    400 600 400 550
        \\
        \\  annotations:
        \\    status: stale
        \\    timestamp: 2026-03-19T10:00:00Z
        \\    sim_tool: ngspice 43
        \\    corner: tt
        \\
        \\    op_points [3]{inst, vgs, vds, id}:
        \\      M1      0.612  0.611  52.3u
        \\      M2      0.588  0.365  47.7u
        \\      MTAIL1  0.400  0.412  100u
        \\
        \\    notes:
        \\      - "Params changed since last sim"
    ;

    var s = readCHN(input);
    defer s.deinit();

    // Structure
    try testing.expectEqual(sch.SifyType.component, s.stype);
    try testing.expectEqualStrings("two_stage_opamp", s.name);
    try testing.expectEqual(@as(usize, 6), s.pins.len);
    try testing.expectEqual(@as(usize, 6), s.instances.len);
    try testing.expectEqual(@as(usize, 3), s.wires.len);

    // Pin directions
    const dirs = s.pins.items(.dir);
    try testing.expectEqual(sch.PinDir.input, dirs[0]); // INP
    try testing.expectEqual(sch.PinDir.output, dirs[2]); // OUT

    // Instance kinds
    const kinds = s.instances.items(.kind);
    try testing.expect(kinds[0].isNmos()); // M1
    try testing.expect(kinds[3].isPmos()); // M3

    // Annotations preserved
    try testing.expectEqualStrings("stale", findSymProp(&s, "ann.status").?);
    try testing.expectEqualStrings("0.612", findSymProp(&s, "ann.op.M1.vgs").?);
    try testing.expectEqualStrings("Params changed since last sim", findSymProp(&s, "ann.note.0").?);

    // Params
    try testing.expectEqualStrings("10u", findSymProp(&s, "wp_in").?);
    try testing.expectEqualStrings("X", findSymProp(&s, "spice_prefix").?);

    // Round-trip
    try roundTrip(input);
}

// ═══════════════════════════════════════════════════════════════════════════════
// 17. Full testbench example
// ═══════════════════════════════════════════════════════════════════════════════

test "Full testbench example" {
    const input =
        \\chn_testbench 1.0
        \\
        \\TESTBENCH tb_opamp_ac
        \\
        \\  includes [1]:
        \\    "$PDK/models/all.lib" section=tt
        \\
        \\  instances [3]:
        \\    DUT  chn/opamp  wp_in=10u
        \\    VDD  vsource    dc=1.8
        \\    CL   capacitor  c=5p
        \\
        \\  nets [3]:
        \\    vdd -> DUT.VDD, VDD.p
        \\    gnd -> VDD.n
        \\    out -> DUT.OUT, CL.p
        \\
        \\  analyses [2]:
        \\    op:
        \\    ac: start=1 stop=10G points_per_dec=20
        \\
        \\  measures [2]:
        \\    dc_gain: find dB(V(out)/V(inp)) at freq=1
        \\    ugbw: find freq when dB(V(out)/V(inp))=0
        \\
        \\  annotations:
        \\    status: fresh
        \\    timestamp: 2026-03-20T15:30:00Z
        \\
        \\    measures:
        \\      dc_gain: 62.3 dB
        \\      ugbw: 127.4 MHz
        \\
        \\    notes:
        \\      - "Phase margin below 60 deg target"
    ;

    var s = readCHN(input);
    defer s.deinit();

    try testing.expectEqual(sch.SifyType.testbench, s.stype);
    try testing.expectEqualStrings("tb_opamp_ac", s.name);
    try testing.expectEqual(@as(usize, 3), s.instances.len);
    try testing.expectEqual(@as(usize, 0), s.pins.len); // testbenches have no pins

    // Includes
    var inc_count: usize = 0;
    for (s.sym_props.items) |p| {
        if (std.mem.eql(u8, p.key, "include")) inc_count += 1;
    }
    try testing.expectEqual(@as(usize, 1), inc_count);

    // Analyses
    try testing.expect(findSymProp(&s, "analysis.op") != null);
    try testing.expectEqualStrings("start=1 stop=10G points_per_dec=20", findSymProp(&s, "analysis.ac").?);

    // Measures (top-level)
    try testing.expectEqualStrings("find dB(V(out)/V(inp)) at freq=1", findSymProp(&s, "measure.dc_gain").?);

    // Annotation measures (simulation results)
    try testing.expectEqualStrings("62.3 dB", findSymProp(&s, "ann.measure.dc_gain").?);
    try testing.expectEqualStrings("127.4 MHz", findSymProp(&s, "ann.measure.ugbw").?);

    // Round-trip
    try roundTrip(input);
}

// ═══════════════════════════════════════════════════════════════════════════════
// 18. Edge cases
// ═══════════════════════════════════════════════════════════════════════════════

test "Reader: empty file" {
    var s = readCHN("");
    defer s.deinit();
    try testing.expectEqual(@as(usize, 0), s.instances.len);
}

test "Reader: header only" {
    var s = readCHN("chn 1.0\n");
    defer s.deinit();
    try testing.expectEqual(sch.SifyType.component, s.stype);
}

test "Reader: unknown version warning" {
    var s = readCHN("chn 2.0\n");
    defer s.deinit();
    // Should still parse (with warning), not crash
    try testing.expectEqual(sch.SifyType.component, s.stype);
}

test "Writer: empty schematic" {
    var s = Schemify.init(testing.allocator);
    defer s.deinit();
    s.stype = .component;
    s.name = "empty";

    const written = s.writeFile(testing.allocator, null) orelse return error.WriteFailed;
    defer testing.allocator.free(written);

    try testing.expect(std.mem.startsWith(u8, written, "chn"));
}

test "Writer: testbench with no instances" {
    var s = Schemify.init(testing.allocator);
    defer s.deinit();
    s.stype = .testbench;
    s.name = "tb_empty";

    const written = s.writeFile(testing.allocator, null) orelse return error.WriteFailed;
    defer testing.allocator.free(written);

    try testing.expect(std.mem.indexOf(u8, written, "TESTBENCH tb_empty") != null);
}

// ═══════════════════════════════════════════════════════════════════════════════
// 19. Digital Blocks — generateDigitalSymbolDrawing
// ═══════════════════════════════════════════════════════════════════════════════

test "Digital: generateDigitalSymbolDrawing produces box outline" {
    // Build a Schemify with 2 input pins and 1 output pin, then generate geometry.
    var s = Schemify.init(testing.allocator);
    defer s.deinit();
    s.name = "myblock";

    try s.drawPin(.{ .name = "a", .x = 0, .y = 0, .dir = .input });
    try s.drawPin(.{ .name = "b", .x = 0, .y = 0, .dir = .input });
    try s.drawPin(.{ .name = "y", .x = 0, .y = 0, .dir = .output });

    try s.generateDigitalSymbolDrawing();

    // Box outline = 4 lines; each pin adds at least 1 stub line; total >= 5.
    try testing.expect(s.lines.len >= 5);
    // A name label is placed in the box.
    try testing.expect(s.texts.len >= 1);
    // Output pin stub lands to the right of the box.
    const px = s.pins.items(.x);
    var found_right = false;
    for (0..s.pins.len) |i| {
        if (px[i] > 0) found_right = true;
    }
    try testing.expect(found_right);
}

test "Digital: generateDigitalSymbolDrawing empty pins is a no-op" {
    var s = Schemify.init(testing.allocator);
    defer s.deinit();
    s.name = "empty";

    try s.generateDigitalSymbolDrawing();

    // No geometry generated when there are no pins.
    try testing.expectEqual(@as(usize, 0), s.lines.len);
    try testing.expectEqual(@as(usize, 0), s.texts.len);
}

test "Digital: clock pin produces extra triangle marker lines" {
    // A clock pin triggers isClock() == true and adds 3 triangle lines + 1 stub
    // instead of 1 stub for a regular input.  So a clk pin contributes 4 lines
    // whereas a plain input contributes 1.  With box outline (4 lines) the total
    // with a clock pin should be >= 8.
    var s_clk = Schemify.init(testing.allocator);
    defer s_clk.deinit();
    s_clk.name = "ff";

    try s_clk.drawPin(.{ .name = "clk", .x = 0, .y = 0, .dir = .input });
    try s_clk.drawPin(.{ .name = "d", .x = 0, .y = 0, .dir = .input });
    try s_clk.drawPin(.{ .name = "q", .x = 0, .y = 0, .dir = .output });

    try s_clk.generateDigitalSymbolDrawing();
    const clk_line_count = s_clk.lines.len;

    var s_plain = Schemify.init(testing.allocator);
    defer s_plain.deinit();
    s_plain.name = "ff";

    try s_plain.drawPin(.{ .name = "en", .x = 0, .y = 0, .dir = .input });
    try s_plain.drawPin(.{ .name = "d", .x = 0, .y = 0, .dir = .input });
    try s_plain.drawPin(.{ .name = "q", .x = 0, .y = 0, .dir = .output });

    try s_plain.generateDigitalSymbolDrawing();
    const plain_line_count = s_plain.lines.len;

    // Clock pin should have produced more lines than a regular pin of the same type.
    try testing.expect(clk_line_count > plain_line_count);
}

// ═══════════════════════════════════════════════════════════════════════════════
// 20. Digital Blocks — Writer round-trip for digital config
// ═══════════════════════════════════════════════════════════════════════════════

test "Digital: Writer round-trips inline behavioral source" {
    const input =
        \\chn 1.0
        \\
        \\SYMBOL counter
        \\  pins [2]:
        \\    clk  in
        \\    q  out
        \\
        \\SCHEMATIC
        \\
        \\  digital:
        \\    language: verilog
        \\    behavioral:
        \\      mode: inline
        \\      top_module: counter
        \\      source: |
        \\        module counter(input clk, output q);
        \\          reg r;
        \\          always @(posedge clk) r <= ~r;
        \\          assign q = r;
        \\        endmodule
    ;

    var s1 = readCHN(input);
    defer s1.deinit();

    // Verify initial parse.
    try testing.expect(s1.digital != null);
    const d1 = s1.digital.?;
    try testing.expectEqual(sch.HdlLanguage.verilog, d1.language);
    try testing.expectEqual(sch.SourceMode.@"inline", d1.behavioral.mode);
    try testing.expectEqualStrings("counter", d1.behavioral.top_module.?);
    try testing.expect(d1.behavioral.source != null);
    try testing.expect(std.mem.indexOf(u8, d1.behavioral.source.?, "module counter") != null);

    // Write and re-parse.
    const written = s1.writeFile(testing.allocator, null) orelse return error.WriteFailed;
    defer testing.allocator.free(written);

    var s2 = Schemify.readFile(written, testing.allocator, null);
    defer s2.deinit();

    try testing.expect(s2.digital != null);
    const d2 = s2.digital.?;
    try testing.expectEqual(sch.HdlLanguage.verilog, d2.language);
    try testing.expectEqualStrings("counter", d2.behavioral.top_module.?);
    try testing.expect(d2.behavioral.source != null);
    try testing.expect(std.mem.indexOf(u8, d2.behavioral.source.?, "module counter") != null);
}

test "Digital: Writer round-trips file-mode behavioral source" {
    const input =
        \\chn 1.0
        \\
        \\SYMBOL alu
        \\  pins [1]:
        \\    OUT out
        \\
        \\SCHEMATIC
        \\
        \\  digital:
        \\    language: vhdl
        \\    behavioral:
        \\      mode: file
        \\      top_module: alu
        \\      source: rtl/alu.vhd
    ;

    var s1 = readCHN(input);
    defer s1.deinit();

    try testing.expect(s1.digital != null);
    const d1 = s1.digital.?;
    try testing.expectEqual(sch.HdlLanguage.vhdl, d1.language);
    try testing.expectEqual(sch.SourceMode.file, d1.behavioral.mode);
    try testing.expectEqualStrings("rtl/alu.vhd", d1.behavioral.source.?);

    const written = s1.writeFile(testing.allocator, null) orelse return error.WriteFailed;
    defer testing.allocator.free(written);

    var s2 = Schemify.readFile(written, testing.allocator, null);
    defer s2.deinit();

    try testing.expect(s2.digital != null);
    try testing.expectEqualStrings("rtl/alu.vhd", s2.digital.?.behavioral.source.?);
    try testing.expectEqualStrings("alu", s2.digital.?.behavioral.top_module.?);
}

// ═══════════════════════════════════════════════════════════════════════════════
// 21. Digital Blocks — digital_counter.chn example round-trip
// ═══════════════════════════════════════════════════════════════════════════════

test "Digital: digital_counter example parses correctly" {
    // Mirrors the examples/digital_counter.chn file inline so @embedFile
    // restrictions don't apply and the test is self-contained.
    const input =
        \\chn 1.0
        \\
        \\SYMBOL digital_counter
        \\  desc: 4-bit synchronous counter with async reset — digital block example
        \\
        \\  pins [6]:
        \\    clk  in
        \\    reset  in
        \\    q0  out
        \\    q1  out
        \\    q2  out
        \\    q3  out
        \\
        \\SCHEMATIC
        \\
        \\  digital:
        \\    language: verilog
        \\    behavioral:
        \\      mode: inline
        \\      top_module: digital_counter
        \\      source: |
        \\        module digital_counter(
        \\          input  clk,
        \\          input  reset,
        \\          output q0,
        \\          output q1,
        \\          output q2,
        \\          output q3
        \\        );
        \\          reg [3:0] count;
        \\          always @(posedge clk or posedge reset) begin
        \\            if (reset)
        \\              count <= 4'b0000;
        \\            else
        \\              count <= count + 1'b1;
        \\          end
        \\          assign q0 = count[0];
        \\          assign q1 = count[1];
        \\          assign q2 = count[2];
        \\          assign q3 = count[3];
        \\        endmodule
    ;

    var s = readCHN(input);
    defer s.deinit();

    try testing.expectEqualStrings("digital_counter", s.name);
    try testing.expectEqual(@as(usize, 6), s.pins.len);
    try testing.expect(s.digital != null);
    const d = s.digital.?;
    try testing.expectEqual(sch.HdlLanguage.verilog, d.language);
    try testing.expectEqual(sch.SourceMode.@"inline", d.behavioral.mode);
    try testing.expectEqualStrings("digital_counter", d.behavioral.top_module.?);
    try testing.expect(d.behavioral.source != null);
    try testing.expect(std.mem.indexOf(u8, d.behavioral.source.?, "module digital_counter") != null);
    try testing.expect(std.mem.indexOf(u8, d.behavioral.source.?, "posedge clk") != null);

    // Round-trip through Writer then Reader.
    try roundTrip(input);
}

// ═══════════════════════════════════════════════════════════════════════════════
// 22. Digital Blocks — HdlParser.parseVerilog direct tests
// ═══════════════════════════════════════════════════════════════════════════════

test "HdlParser: parseVerilog extracts ANSI ports" {
    const HdlParser = core.HdlParser;
    const source =
        \\module adder #(parameter WIDTH = 8) (
        \\  input  [WIDTH-1:0] a,
        \\  input  [WIDTH-1:0] b,
        \\  output [WIDTH-1:0] sum,
        \\  output             carry
        \\);
        \\  assign {carry, sum} = a + b;
        \\endmodule
    ;
    var mod = try HdlParser.parseVerilog(source, null, testing.allocator);
    defer mod.deinit();

    try testing.expectEqualStrings("adder", mod.name);
    try testing.expectEqual(@as(usize, 4), mod.pins.len);

    // Port order: a, b, sum, carry
    try testing.expectEqualStrings("a",     mod.pins[0].name);
    try testing.expectEqual(HdlParser.PinDir.input,  mod.pins[0].direction);
    try testing.expectEqualStrings("b",     mod.pins[1].name);
    try testing.expectEqual(HdlParser.PinDir.input,  mod.pins[1].direction);
    try testing.expectEqualStrings("sum",   mod.pins[2].name);
    try testing.expectEqual(HdlParser.PinDir.output, mod.pins[2].direction);
    try testing.expectEqualStrings("carry", mod.pins[3].name);
    try testing.expectEqual(HdlParser.PinDir.output, mod.pins[3].direction);
    try testing.expectEqual(@as(u16, 1), mod.pins[3].width);

    // Parameter extracted
    try testing.expectEqual(@as(usize, 1), mod.params.len);
    try testing.expectEqualStrings("WIDTH", mod.params[0].name);
    try testing.expectEqualStrings("8",     mod.params[0].default_value.?);
}

test "HdlParser: parseVerilog handles scalar ports and widths" {
    const HdlParser = core.HdlParser;
    const source =
        \\module inv(input a, output y);
        \\  assign y = ~a;
        \\endmodule
    ;
    var mod = try HdlParser.parseVerilog(source, null, testing.allocator);
    defer mod.deinit();

    try testing.expectEqualStrings("inv", mod.name);
    try testing.expectEqual(@as(usize, 2), mod.pins.len);
    try testing.expectEqualStrings("a", mod.pins[0].name);
    try testing.expectEqual(HdlParser.PinDir.input,  mod.pins[0].direction);
    try testing.expectEqual(@as(u16, 1), mod.pins[0].width);
    try testing.expectEqualStrings("y", mod.pins[1].name);
    try testing.expectEqual(HdlParser.PinDir.output, mod.pins[1].direction);
    try testing.expectEqual(@as(u16, 1), mod.pins[1].width);
}

// ═══════════════════════════════════════════════════════════════════════════════
// 23. Digital Blocks — syncSymbolFromHdl
// ═══════════════════════════════════════════════════════════════════════════════

test "Digital: syncSymbolFromHdl adds pins from HDL to empty symbol" {
    const input =
        \\chn 1.0
        \\
        \\SYMBOL adder
        \\
        \\SCHEMATIC
        \\
        \\  digital:
        \\    language: verilog
        \\    behavioral:
        \\      mode: inline
        \\      top_module: adder
        \\      source: |
        \\        module adder(input a, input b, output sum);
        \\          assign sum = a + b;
        \\        endmodule
    ;
    var s = readCHN(input);
    defer s.deinit();

    try testing.expectEqual(@as(usize, 0), s.pins.len);

    const report = try s.syncSymbolFromHdl();
    try testing.expect(report.symbol_updated);
    try testing.expectEqual(@as(usize, 3), report.pins_added.len);
    try testing.expectEqual(@as(usize, 0), report.pins_removed.len);
    try testing.expectEqual(@as(usize, 0), report.pins_modified.len);
    try testing.expectEqual(@as(usize, 3), s.pins.len);

    // Verify directions were mapped correctly
    const dirs = s.pins.items(.dir);
    var found_input = false;
    var found_output = false;
    for (dirs) |d| {
        if (d == .input)  found_input  = true;
        if (d == .output) found_output = true;
    }
    try testing.expect(found_input);
    try testing.expect(found_output);
}

test "Digital: syncSymbolFromHdl reports no changes when pins already match" {
    const input =
        \\chn 1.0
        \\
        \\SYMBOL inv
        \\  pins [2]:
        \\    a  in
        \\    y  out
        \\
        \\SCHEMATIC
        \\
        \\  digital:
        \\    language: verilog
        \\    behavioral:
        \\      mode: inline
        \\      top_module: inv
        \\      source: |
        \\        module inv(input a, output y);
        \\          assign y = ~a;
        \\        endmodule
    ;
    var s = readCHN(input);
    defer s.deinit();

    try testing.expectEqual(@as(usize, 2), s.pins.len);

    const report = try s.syncSymbolFromHdl();
    try testing.expect(!report.symbol_updated);
    try testing.expectEqual(@as(usize, 0), report.pins_added.len);
    try testing.expectEqual(@as(usize, 0), report.pins_removed.len);
    try testing.expectEqual(@as(usize, 0), report.pins_modified.len);
}

// ═══════════════════════════════════════════════════════════════════════════════
// 24. Digital Blocks — validateHdlPinMatch
// ═══════════════════════════════════════════════════════════════════════════════

test "Digital: validateHdlPinMatch detects direction mismatch" {
    // Symbol declares 'data' as input; HDL has it as output.
    const input =
        \\chn 1.0
        \\
        \\SYMBOL mismatch_block
        \\  pins [1]:
        \\    data  in
        \\
        \\SCHEMATIC
        \\
        \\  digital:
        \\    language: verilog
        \\    behavioral:
        \\      mode: inline
        \\      top_module: mismatch_block
        \\      source: |
        \\        module mismatch_block(output data);
        \\          assign data = 1'b0;
        \\        endmodule
    ;
    var s = readCHN(input);
    defer s.deinit();

    const mismatches = try s.validateHdlPinMatch();
    try testing.expect(mismatches.len >= 1);

    var found = false;
    for (mismatches) |m| {
        if (std.mem.eql(u8, m.pin_name, "data") and
            std.mem.indexOf(u8, m.issue, "direction") != null)
        {
            found = true;
        }
    }
    try testing.expect(found);
}

test "Digital: validateHdlPinMatch passes when all pins match" {
    const input =
        \\chn 1.0
        \\
        \\SYMBOL inv
        \\  pins [2]:
        \\    a  in
        \\    y  out
        \\
        \\SCHEMATIC
        \\
        \\  digital:
        \\    language: verilog
        \\    behavioral:
        \\      mode: inline
        \\      top_module: inv
        \\      source: |
        \\        module inv(input a, output y);
        \\          assign y = ~a;
        \\        endmodule
    ;
    var s = readCHN(input);
    defer s.deinit();

    const mismatches = try s.validateHdlPinMatch();
    try testing.expectEqual(@as(usize, 0), mismatches.len);
}
