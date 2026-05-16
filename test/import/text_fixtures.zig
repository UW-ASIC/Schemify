// test_fixtures.zig — Integration tests using fixture files from test/import/fixtures/.
//
// Tests the SPICE parser against realistic netlist files covering various
// edge cases: mixed devices, hierarchy, parameters, models, globals,
// continuation lines, and inline comments.

const std = @import("std");
const parser = @import("spice/parser.zig");
const PySpice = @import("PySpice/mod.zig");

fn parseFixture(source: []const u8) !parser.Netlist {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    errdefer arena.deinit();
    // Leak the arena — tests are short-lived and testing.allocator detects real leaks.
    return parser.parseNetlist(arena.allocator(), source);
}

// ── Existing fixtures ───────────────────────────────────────────────────────

test "fixture: inverter.sp — subckt with 2 MOSFETs + testbench" {
    const source = @embedFile("fixtures/inverter.sp");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const netlist = try parser.parseNetlist(arena.allocator(), source);

    try std.testing.expectEqualStrings("CMOS Inverter", netlist.title);

    // One subcircuit: inv
    try std.testing.expectEqual(@as(usize, 1), netlist.subckts.len);
    const inv = netlist.subckts[0];
    try std.testing.expectEqualStrings("inv", inv.name);
    try std.testing.expectEqual(@as(usize, 4), inv.ports.len);
    try std.testing.expectEqualStrings("in", inv.ports[0]);
    try std.testing.expectEqualStrings("out", inv.ports[1]);
    try std.testing.expectEqualStrings("vdd", inv.ports[2]);
    try std.testing.expectEqualStrings("vss", inv.ports[3]);
    try std.testing.expectEqual(@as(usize, 2), inv.elements.len);

    // M1: PMOS
    try std.testing.expectEqual(@as(u8, 'm'), inv.elements[0].prefix);
    try std.testing.expectEqualStrings("M1", inv.elements[0].name);
    try std.testing.expectEqualStrings("sky130_fd_pr__pfet_01v8", inv.elements[0].model.?);
    try std.testing.expectEqual(@as(usize, 4), inv.elements[0].nodes.len);

    // M2: NMOS
    try std.testing.expectEqual(@as(u8, 'm'), inv.elements[1].prefix);
    try std.testing.expectEqualStrings("sky130_fd_pr__nfet_01v8", inv.elements[1].model.?);

    // Top-level: V1, V2 (pulse), X1
    try std.testing.expectEqual(@as(usize, 3), netlist.top_elements.len);
    try std.testing.expectEqual(@as(u8, 'v'), netlist.top_elements[0].prefix);
    try std.testing.expectEqual(@as(u8, 'v'), netlist.top_elements[1].prefix);
    try std.testing.expectEqual(@as(u8, 'x'), netlist.top_elements[2].prefix);
    try std.testing.expectEqualStrings("inv", netlist.top_elements[2].model.?);
}

test "fixture: ota.sp — 5-transistor OTA" {
    const source = @embedFile("fixtures/ota.sp");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const netlist = try parser.parseNetlist(arena.allocator(), source);

    try std.testing.expectEqualStrings("Five-Transistor OTA", netlist.title);
    try std.testing.expectEqual(@as(usize, 1), netlist.subckts.len);

    const ota = netlist.subckts[0];
    try std.testing.expectEqualStrings("ota", ota.name);
    try std.testing.expectEqual(@as(usize, 5), ota.ports.len);
    try std.testing.expectEqual(@as(usize, 5), ota.elements.len);

    // All elements are MOSFETs
    for (ota.elements) |elem| {
        try std.testing.expectEqual(@as(u8, 'm'), elem.prefix);
        try std.testing.expectEqual(@as(usize, 4), elem.nodes.len);
    }

    // No top-level elements (just .end)
    try std.testing.expectEqual(@as(usize, 0), netlist.top_elements.len);
}

test "fixture: bandgap.sp — mirrors, cascodes, BJTs, resistors" {
    const source = @embedFile("fixtures/bandgap.sp");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const netlist = try parser.parseNetlist(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 1), netlist.subckts.len);

    const bg = netlist.subckts[0];
    try std.testing.expectEqualStrings("bandgap", bg.name);
    try std.testing.expectEqual(@as(usize, 3), bg.ports.len);

    // 7 MOSFETs + 2 BJTs + 2 resistors = 11
    try std.testing.expectEqual(@as(usize, 11), bg.elements.len);

    // Count by prefix
    var m_count: usize = 0;
    var q_count: usize = 0;
    var r_count: usize = 0;
    for (bg.elements) |elem| {
        switch (elem.prefix) {
            'm' => m_count += 1,
            'q' => q_count += 1,
            'r' => r_count += 1,
            else => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 7), m_count);
    try std.testing.expectEqual(@as(usize, 2), q_count);
    try std.testing.expectEqual(@as(usize, 2), r_count);

    // BJT Q2 has m=8 param
    const q2 = bg.elements[8]; // Q2 is after 7 MOSFETs + Q1
    try std.testing.expectEqual(@as(u8, 'q'), q2.prefix);
    try std.testing.expectEqualStrings("Q2", q2.name);
    try std.testing.expectEqual(@as(usize, 1), q2.params.len);
    try std.testing.expectEqualStrings("m", q2.params[0].key);
    try std.testing.expectEqualStrings("8", q2.params[0].val);
}

// ── New fixtures ────────────────────────────────────────────────────────────

test "fixture: diff_amp.sp — differential pair with params and testbench" {
    const source = @embedFile("fixtures/diff_amp.sp");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const netlist = try parser.parseNetlist(arena.allocator(), source);

    try std.testing.expectEqualStrings("Differential Amplifier with Current Mirror Load", netlist.title);

    // .param directives
    try std.testing.expectEqual(@as(usize, 6), netlist.params.len);
    try std.testing.expectEqualStrings("W_diff", netlist.params[0].key);
    try std.testing.expectEqualStrings("2u", netlist.params[0].val);

    // Subcircuit
    try std.testing.expectEqual(@as(usize, 1), netlist.subckts.len);
    const da = netlist.subckts[0];
    try std.testing.expectEqualStrings("diff_amp", da.name);
    try std.testing.expectEqual(@as(usize, 5), da.ports.len);
    try std.testing.expectEqual(@as(usize, 5), da.elements.len);

    // All subckt elements are MOSFETs
    for (da.elements) |elem| {
        try std.testing.expectEqual(@as(u8, 'm'), elem.prefix);
    }

    // Top-level: 4 voltage sources + 1 subckt instance
    try std.testing.expectEqual(@as(usize, 5), netlist.top_elements.len);
    try std.testing.expectEqual(@as(u8, 'x'), netlist.top_elements[4].prefix);
    try std.testing.expectEqualStrings("diff_amp", netlist.top_elements[4].model.?);
}

test "fixture: ldo.sp — mixed devices with .global" {
    const source = @embedFile("fixtures/ldo.sp");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const netlist = try parser.parseNetlist(arena.allocator(), source);

    // .global VDD VSS
    try std.testing.expectEqual(@as(usize, 2), netlist.globals.len);
    try std.testing.expectEqualStrings("VDD", netlist.globals[0]);
    try std.testing.expectEqualStrings("VSS", netlist.globals[1]);

    try std.testing.expectEqual(@as(usize, 1), netlist.subckts.len);
    const ldo = netlist.subckts[0];
    try std.testing.expectEqualStrings("ldo", ldo.name);
    try std.testing.expectEqual(@as(usize, 3), ldo.ports.len);

    // M1-M6 + R1-R2 + C1 + V1 = 10
    try std.testing.expectEqual(@as(usize, 10), ldo.elements.len);

    var m_count: usize = 0;
    var r_count: usize = 0;
    var c_count: usize = 0;
    var v_count: usize = 0;
    for (ldo.elements) |elem| {
        switch (elem.prefix) {
            'm' => m_count += 1,
            'r' => r_count += 1,
            'c' => c_count += 1,
            'v' => v_count += 1,
            else => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 6), m_count);
    try std.testing.expectEqual(@as(usize, 2), r_count);
    try std.testing.expectEqual(@as(usize, 1), c_count);
    try std.testing.expectEqual(@as(usize, 1), v_count);
}

test "fixture: cascode_mirror.sp — GF180MCU PDK models" {
    const source = @embedFile("fixtures/cascode_mirror.sp");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const netlist = try parser.parseNetlist(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 1), netlist.subckts.len);
    const cm = netlist.subckts[0];
    try std.testing.expectEqualStrings("cascode_mirror", cm.name);
    try std.testing.expectEqual(@as(usize, 4), cm.ports.len);

    // 4 MOSFETs + 1 resistor
    try std.testing.expectEqual(@as(usize, 5), cm.elements.len);

    // Verify GF180 model name
    try std.testing.expectEqualStrings("gf180mcu_fd_pr__nfet_03v3", cm.elements[0].model.?);

    // R1 is the last element
    const r1 = cm.elements[4];
    try std.testing.expectEqual(@as(u8, 'r'), r1.prefix);
    try std.testing.expectEqualStrings("10k", r1.value.?);
}

test "fixture: passives_only.sp — R, C, L, K (coupled inductors)" {
    const source = @embedFile("fixtures/passives_only.sp");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const netlist = try parser.parseNetlist(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 1), netlist.subckts.len);
    const pn = netlist.subckts[0];
    try std.testing.expectEqualStrings("passive_net", pn.name);
    try std.testing.expectEqual(@as(usize, 3), pn.ports.len);

    // R1-R3 + C1-C3 + L1-L2 = 8 elements
    // K1 line has prefix 'k' which is UnknownPrefix — parser skips it
    try std.testing.expectEqual(@as(usize, 8), pn.elements.len);

    var r_count: usize = 0;
    var c_count: usize = 0;
    var l_count: usize = 0;
    for (pn.elements) |elem| {
        switch (elem.prefix) {
            'r' => r_count += 1,
            'c' => c_count += 1,
            'l' => l_count += 1,
            else => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 3), r_count);
    try std.testing.expectEqual(@as(usize, 3), c_count);
    try std.testing.expectEqual(@as(usize, 2), l_count);

    // Check inductor values
    const l1 = pn.elements[6];
    try std.testing.expectEqual(@as(u8, 'l'), l1.prefix);
    try std.testing.expectEqualStrings("10u", l1.value.?);
}

test "fixture: hierarchical.sp — multiple subcircuits with X instances" {
    const source = @embedFile("fixtures/hierarchical.sp");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const netlist = try parser.parseNetlist(arena.allocator(), source);

    // 3 subcircuits: inv, nand2, nand2_buf
    try std.testing.expectEqual(@as(usize, 3), netlist.subckts.len);

    const inv = netlist.subckts[0];
    try std.testing.expectEqualStrings("inv", inv.name);
    try std.testing.expectEqual(@as(usize, 4), inv.ports.len);
    try std.testing.expectEqual(@as(usize, 2), inv.elements.len);

    const nand2 = netlist.subckts[1];
    try std.testing.expectEqualStrings("nand2", nand2.name);
    try std.testing.expectEqual(@as(usize, 5), nand2.ports.len);
    try std.testing.expectEqual(@as(usize, 4), nand2.elements.len);

    const nand2_buf = netlist.subckts[2];
    try std.testing.expectEqualStrings("nand2_buf", nand2_buf.name);
    try std.testing.expectEqual(@as(usize, 5), nand2_buf.ports.len);
    try std.testing.expectEqual(@as(usize, 2), nand2_buf.elements.len);

    // X instances reference subcircuit names
    try std.testing.expectEqual(@as(u8, 'x'), nand2_buf.elements[0].prefix);
    try std.testing.expectEqualStrings("nand2", nand2_buf.elements[0].model.?);
    try std.testing.expectEqualStrings("inv", nand2_buf.elements[1].model.?);

    // Top-level: V1, V2, V3, X1
    try std.testing.expectEqual(@as(usize, 4), netlist.top_elements.len);
    try std.testing.expectEqual(@as(u8, 'x'), netlist.top_elements[3].prefix);
    try std.testing.expectEqualStrings("nand2_buf", netlist.top_elements[3].model.?);
}

test "fixture: params_and_models.sp — .param, .model, continuation, inline comments" {
    const source = @embedFile("fixtures/params_and_models.sp");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const netlist = try parser.parseNetlist(arena.allocator(), source);

    // 3 .param values: vdd_val, vth_n, gm_target
    try std.testing.expectEqual(@as(usize, 3), netlist.params.len);
    try std.testing.expectEqualStrings("vdd_val", netlist.params[0].key);
    try std.testing.expectEqualStrings("1.8", netlist.params[0].val);
    try std.testing.expectEqualStrings("vth_n", netlist.params[1].key);
    try std.testing.expectEqualStrings("gm_target", netlist.params[2].key);
    // gm_target value should be '50u' (with quotes stripped or kept depending on parser)
    try std.testing.expect(netlist.params[2].val.len > 0);

    // 2 .model statements (continuation lines get joined)
    try std.testing.expectEqual(@as(usize, 2), netlist.models.len);
    try std.testing.expectEqualStrings("NMOD", netlist.models[0].name);
    try std.testing.expectEqualStrings("nmos", netlist.models[0].kind);
    try std.testing.expectEqualStrings("PMOD", netlist.models[1].name);
    try std.testing.expectEqualStrings("pmos", netlist.models[1].kind);

    // 1 subcircuit with 3 elements
    try std.testing.expectEqual(@as(usize, 1), netlist.subckts.len);
    const amp = netlist.subckts[0];
    try std.testing.expectEqualStrings("amp_stage", amp.name);
    try std.testing.expectEqual(@as(usize, 4), amp.ports.len);
    try std.testing.expectEqual(@as(usize, 3), amp.elements.len);

    // M1 has inline comment stripped ($ ...)
    try std.testing.expectEqual(@as(u8, 'm'), amp.elements[0].prefix);
    try std.testing.expectEqualStrings("NMOD", amp.elements[0].model.?);

    // M2 has inline comment stripped (; ...)
    try std.testing.expectEqual(@as(u8, 'm'), amp.elements[1].prefix);
    try std.testing.expectEqualStrings("PMOD", amp.elements[1].model.?);

    // R1
    try std.testing.expectEqual(@as(u8, 'r'), amp.elements[2].prefix);
    try std.testing.expectEqualStrings("500", amp.elements[2].value.?);

    // Top-level: V1, V2, X1
    try std.testing.expectEqual(@as(usize, 3), netlist.top_elements.len);
    try std.testing.expectEqual(@as(u8, 'v'), netlist.top_elements[0].prefix);
    try std.testing.expectEqual(@as(u8, 'v'), netlist.top_elements[1].prefix);
    try std.testing.expectEqual(@as(u8, 'x'), netlist.top_elements[2].prefix);
}

// ── PySpice detection tests ─────────────────────────────────────────────────

test "fixture: pyspice_inv.py — detected as PySpice file (pyspice_rs import)" {
    const source = @embedFile("fixtures/pyspice_inv.py");
    try std.testing.expect(PySpice.isPySpiceFile(source));
}

test "fixture: pyspice_ota.py — detected as PySpice file (pyspice_rs import)" {
    const source = @embedFile("fixtures/pyspice_ota.py");
    try std.testing.expect(PySpice.isPySpiceFile(source));
}

test "fixture: pyspice_ldo.py — detected as PySpice file (pyspice_rs import)" {
    const source = @embedFile("fixtures/pyspice_ldo.py");
    try std.testing.expect(PySpice.isPySpiceFile(source));
}

test "fixture: spectre_amp.scs — NOT detected as PySpice file" {
    const source = @embedFile("fixtures/spectre_amp.scs");
    try std.testing.expect(!PySpice.isPySpiceFile(source));
}

test "fixture: cdl_opamp.cdl — NOT detected as PySpice file" {
    const source = @embedFile("fixtures/cdl_opamp.cdl");
    try std.testing.expect(!PySpice.isPySpiceFile(source));
}

// ── CDL through SPICE parser (subset compatibility) ─────────────────────────

test "fixture: rc_filter.cdl — parses as SPICE subset" {
    const source = @embedFile("fixtures/rc_filter.cdl");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const netlist = try parser.parseNetlist(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 1), netlist.subckts.len);
    const rc = netlist.subckts[0];
    try std.testing.expectEqualStrings("rc_filter", rc.name);
    try std.testing.expectEqual(@as(usize, 3), rc.ports.len);
    // R1, C1, R2 — each has 2 nodes + model name + params
    try std.testing.expectEqual(@as(usize, 3), rc.elements.len);
}

test "fixture: cdl_opamp.cdl — parses as SPICE subset" {
    const source = @embedFile("fixtures/cdl_opamp.cdl");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const netlist = try parser.parseNetlist(arena.allocator(), source);

    try std.testing.expectEqual(@as(usize, 1), netlist.subckts.len);
    const op = netlist.subckts[0];
    try std.testing.expectEqualStrings("opamp", op.name);

    // Ports include bang-suffixed globals
    try std.testing.expectEqual(@as(usize, 5), op.ports.len);
    try std.testing.expectEqualStrings("VIN+", op.ports[0]);
    try std.testing.expectEqualStrings("VIN-", op.ports[1]);
    try std.testing.expectEqualStrings("VOUT", op.ports[2]);

    // 7 MOSFETs + 1 capacitor = 8 elements
    // (*.PININFO lines are comments, skipped by parser)
    try std.testing.expectEqual(@as(usize, 8), op.elements.len);

    var m_count: usize = 0;
    var c_count: usize = 0;
    for (op.elements) |elem| {
        switch (elem.prefix) {
            'm' => m_count += 1,
            'c' => c_count += 1,
            else => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 7), m_count);
    try std.testing.expectEqual(@as(usize, 1), c_count);
}
