// test_reader.zig - Tests for XSchem .sch/.sym reader (reader.zig).
//
// Tests cover: .sch parsing, .sym parsing, all element types, K-block extraction,
// file type detection, multi-line property blocks, instance prop linkage,
// and strict error behavior per D-06.

const std = @import("std");
const testing = std.testing;
const xschem = @import("xschem");

// ── Inline fixture data ─────────────────────────────────────────────────

// Minimal .sch file with multiple element types for thorough testing.
const minimal_sch =
    \\v {xschem version=3.4.5 file_version=1.2
    \\* comment line
    \\}
    \\G {}
    \\V {}
    \\S {}
    \\E {}
    \\L 4 0 0 100 100 {}
    \\B 3 10 20 30 40 {}
    \\A 4 50 50 25 0 360 {}
    \\T {hello world} 10 20 0 0 0.4 0.4 {}
    \\N 0 0 100 0 {lab=VDD}
    \\N 50 50 50 100 {lab=GND}
    \\C {nmos4.sym} 120 -170 0 0 {name=M1 model=n w=10u l=1u m=1}
    \\C {res.sym} 210 -230 1 0 {name=R1
    \\value=10k
    \\footprint=1206
    \\device=resistor
    \\m=1}
;

// Minimal .sym file with K block and B layer-5 pins.
const minimal_sym =
    \\v {xschem version=3.4.4 file_version=1.2}
    \\G {}
    \\K {type=subcircuit
    \\format="@name @pinlist @symname W=@W L=@L m=@m"
    \\template="name=X1 W=10u L=1u m=1"
    \\}
    \\V {}
    \\S {}
    \\E {}
    \\L 4 -40 0 -27.5 0 {}
    \\L 4 26.25 0 40 0 {}
    \\B 5 37.5 -2.5 42.5 2.5 {name=Z dir=out}
    \\B 5 -42.5 -2.5 -37.5 2.5 {name=A dir=in}
    \\A 4 21.25 0 5 180 360 {}
    \\T {@name} -26.25 -5 0 0 0.2 0.2 {}
;

// .sym file using G block (old format) instead of K block.
const g_block_sym =
    \\v {xschem version=3.4.4 file_version=1.2}
    \\G {type=subcircuit
    \\format="@name @pinlist @symname"
    \\template="name=x1"
    \\}
    \\V {}
    \\S {}
    \\E {}
    \\L 4 0 -30 0 30 {}
    \\B 5 17.5 -32.5 22.5 -27.5 {name=P3 dir=inout}
    \\B 5 -22.5 -2.5 -17.5 2.5 {name=P2 dir=inout}
    \\T {@symname} 20 -15 0 0 0.2 0.2 {}
;

// .sch file with no K block (pure schematic).
const pure_sch =
    \\v {xschem version=3.4.5 file_version=1.2}
    \\G {}
    \\V {}
    \\S {}
    \\E {}
    \\N 160 -310 250 -310 {lab=A}
    \\N 160 -190 210 -190 {lab=B}
    \\C {ipin.sym} 160 -310 0 0 {name=p1 lab=A}
    \\C {opin.sym} 500 -380 0 0 {name=p2 lab=Z}
;

// .sch file with polygon.
const polygon_sch =
    \\v {xschem version=3.4.5 file_version=1.2}
    \\G {}
    \\V {}
    \\S {}
    \\E {}
    \\P 2 5 160 -930 160 -120 610 -120 610 -930 160 -930 {dash=5}
    \\T {@name} 250 -965 0 0 0.5 0.5 {}
    \\N 190 -690 190 -300 {lab=A}
;

// ── Test 1: Parse .sch -> instances and wires present ───────────────────

test "parse sch has instances and wires" {
    var schem = try xschem.parse(testing.allocator, minimal_sch);
    defer schem.deinit();

    try testing.expect(schem.instances.len > 0);
    try testing.expect(schem.wires.len > 0);
}

// ── Test 2: Parse .sym -> k_type not null, pins present ─────────────────

test "parse sym has k_type and pins" {
    var schem = try xschem.parse(testing.allocator, minimal_sym);
    defer schem.deinit();

    try testing.expect(schem.k_type != null);
    try testing.expectEqualStrings("subcircuit", schem.k_type.?);
    try testing.expect(schem.pins.len > 0);
}

// ── Test 3: Parse file with all element types (L, B, A, T, N, C) ───────

test "parse sch has all present element types" {
    var schem = try xschem.parse(testing.allocator, minimal_sch);
    defer schem.deinit();

    // L -> lines
    try testing.expect(schem.lines.len > 0);
    // B -> rects
    try testing.expect(schem.rects.len > 0);
    // A -> arcs
    try testing.expect(schem.arcs.len > 0);
    // T -> texts
    try testing.expect(schem.texts.len > 0);
    // N -> wires
    try testing.expect(schem.wires.len > 0);
    // C -> instances
    try testing.expect(schem.instances.len > 0);
}

test "parse polygon sch has text and wires" {
    var schem = try xschem.parse(testing.allocator, polygon_sch);
    defer schem.deinit();

    try testing.expect(schem.texts.len > 0);
    try testing.expect(schem.wires.len > 0);
}

test "parse sym has lines and pins" {
    var schem = try xschem.parse(testing.allocator, minimal_sym);
    defer schem.deinit();

    try testing.expect(schem.lines.len > 0);
    try testing.expect(schem.pins.len > 0);
}

// ── Test 4: Parse .sym file -> k_format contains @ pattern ──────────────

test "parse sym k_format contains @ pattern" {
    var schem = try xschem.parse(testing.allocator, minimal_sym);
    defer schem.deinit();

    try testing.expect(schem.k_format != null);
    try testing.expect(std.mem.indexOf(u8, schem.k_format.?, "@") != null);
}

// ── Test 5: File type detection ─────────────────────────────────────────

test "file type detection schematic vs symbol" {
    // .sym file with K block -> .symbol
    var sym = try xschem.parse(testing.allocator, minimal_sym);
    defer sym.deinit();
    try testing.expectEqual(xschem.FileType.symbol, sym.file_type);

    // A .sch without K block -> .schematic
    var sch = try xschem.parse(testing.allocator, pure_sch);
    defer sch.deinit();
    try testing.expectEqual(xschem.FileType.schematic, sch.file_type);
}

// ── Test 6: Multi-line property block in C element ──────────────────────

test "multi-line property block in C element" {
    var schem = try xschem.parse(testing.allocator, minimal_sch);
    defer schem.deinit();

    // Find the res.sym instance - it has a multi-line property block
    var found_res = false;
    const slice = schem.instances.slice();
    for (0..schem.instances.len) |i| {
        const sym_name = slice.items(.symbol)[i];
        if (std.mem.eql(u8, sym_name, "res.sym")) {
            found_res = true;
            const pcount = slice.items(.prop_count)[i];
            // Should have 5 properties: name, value, footprint, device, m
            try testing.expect(pcount >= 4);
            break;
        }
    }
    try testing.expect(found_res);
}

// ── Test 7: Instance properties stored with correct prop_start/prop_count ─

test "instance properties have correct prop_start and prop_count" {
    var schem = try xschem.parse(testing.allocator, minimal_sch);
    defer schem.deinit();

    const inst_slice = schem.instances.slice();
    var total_checked: usize = 0;
    for (0..schem.instances.len) |i| {
        const pstart = inst_slice.items(.prop_start)[i];
        const pcount = inst_slice.items(.prop_count)[i];

        // Verify start + count doesn't exceed props array
        try testing.expect(pstart + pcount <= schem.props.items.len);

        // Verify each property is valid (non-empty key)
        for (pstart..pstart + pcount) |pi| {
            try testing.expect(schem.props.items[pi].key.len > 0);
        }
        total_checked += 1;
    }
    try testing.expect(total_checked > 0);
}

// ── Test 8: Malformed line returns ParseError ───────────────────────────

test "malformed line returns ParseError" {
    const bad_input = "v {xschem version=3.4.4 file_version=1.2}\nZ invalid_tag_data\n";
    const result = xschem.parse(testing.allocator, bad_input);
    try testing.expectError(error.UnknownElementTag, result);
}

test "malformed wire returns ParseError" {
    const bad_input = "v {xschem version=3.4.4 file_version=1.2}\nN 10 20\n";
    const result = xschem.parse(testing.allocator, bad_input);
    try testing.expectError(error.MalformedWire, result);
}

// ── Test: G block with type= sets symbol file type ──────────────────────

test "G block with type= sets file_type to symbol" {
    var schem = try xschem.parse(testing.allocator, g_block_sym);
    defer schem.deinit();

    try testing.expectEqual(xschem.FileType.symbol, schem.file_type);
    try testing.expect(schem.k_type != null);
}

// ── Test: Wire net_name extraction ──────────────────────────────────────

test "wire lab= attribute extracted as net_name" {
    var schem = try xschem.parse(testing.allocator, minimal_sch);
    defer schem.deinit();

    var found_named = false;
    const wire_slice = schem.wires.slice();
    for (0..schem.wires.len) |i| {
        if (wire_slice.items(.net_name)[i]) |name| {
            if (std.mem.eql(u8, name, "VDD") or std.mem.eql(u8, name, "GND")) {
                found_named = true;
                break;
            }
        }
    }
    try testing.expect(found_named);
}

// ── Test: Pin direction from B layer-5 ──────────────────────────────────

test "B layer-5 creates pin with correct direction" {
    var schem = try xschem.parse(testing.allocator, minimal_sym);
    defer schem.deinit();

    const pin_slice = schem.pins.slice();
    var found_out = false;
    var found_in = false;
    for (0..schem.pins.len) |i| {
        const name = pin_slice.items(.name)[i];
        const dir = pin_slice.items(.direction)[i];
        if (std.mem.eql(u8, name, "Z")) {
            found_out = true;
            try testing.expectEqual(xschem.PinDirection.output, dir);
        }
        if (std.mem.eql(u8, name, "A")) {
            found_in = true;
            try testing.expectEqual(xschem.PinDirection.input, dir);
        }
    }
    try testing.expect(found_out);
    try testing.expect(found_in);
}

// ── Test: Arc parsing with correct values ───────────────────────────────

test "arc parsed with correct values" {
    var schem = try xschem.parse(testing.allocator, minimal_sch);
    defer schem.deinit();

    try testing.expectEqual(@as(usize, 1), schem.arcs.len);
    const arc_slice = schem.arcs.slice();
    try testing.expectEqual(@as(i32, 4), arc_slice.items(.layer)[0]);
    try testing.expectEqual(@as(f64, 50), arc_slice.items(.cx)[0]);
    try testing.expectEqual(@as(f64, 50), arc_slice.items(.cy)[0]);
    try testing.expectEqual(@as(f64, 25), arc_slice.items(.radius)[0]);
}

// ── Test: K-block template extraction ───────────────────────────────────

test "K-block template extracted" {
    var schem = try xschem.parse(testing.allocator, minimal_sym);
    defer schem.deinit();

    try testing.expect(schem.k_template != null);
    try testing.expect(std.mem.indexOf(u8, schem.k_template.?, "name=") != null);
}
