// pdk_remap.zig — Sky130 PDK → generic primitive remapping.
//
// Walks all instances in a core.Schemify and replaces sky130-specific symbol
// references with generic behavioral equivalents. Property filtering strips
// PDK-specific layout parameters.

const std = @import("std");
const core = @import("core");

const Schemify = core.Schemify;
const DeviceKind = core.DeviceKind;

// ── PDK-specific property keys to strip ─────────────────────────────────── //

const pdk_prop_keys = std.StaticStringMap(void).initComptime(.{
    .{ "sa", {} },
    .{ "sb", {} },
    .{ "sd", {} },
    .{ "nf", {} },
    .{ "mult", {} },
    .{ "VPWR", {} },
    .{ "VGND", {} },
    .{ "VPB", {} },
    .{ "VNB", {} },
    .{ "topography", {} },
    .{ "area", {} },
    .{ "perim", {} },
});

// ── Standard cell gate type mapping ─────────────────────────────────────── //

const GateMapping = struct {
    needle: []const u8,
    symbol: []const u8,
};

/// Order matters: longer/more-specific patterns first to avoid false matches
/// (e.g. "xnor" before "nor", "nand" before "and").
const gate_mappings = [_]GateMapping{
    .{ .needle = "dfxtp", .symbol = "dff_behavioral" },
    .{ .needle = "dfrtp", .symbol = "dff_behavioral" },
    .{ .needle = "dlrtp", .symbol = "latch_behavioral" },
    .{ .needle = "xnor2", .symbol = "xnor2_behavioral" },
    .{ .needle = "xor2", .symbol = "xor2_behavioral" },
    .{ .needle = "nand4", .symbol = "nand4_behavioral" },
    .{ .needle = "nand3", .symbol = "nand3_behavioral" },
    .{ .needle = "nand2", .symbol = "nand2_behavioral" },
    .{ .needle = "nor4", .symbol = "nor4_behavioral" },
    .{ .needle = "nor3", .symbol = "nor3_behavioral" },
    .{ .needle = "nor2", .symbol = "nor2_behavioral" },
    .{ .needle = "and4", .symbol = "and4_behavioral" },
    .{ .needle = "and3", .symbol = "and3_behavioral" },
    .{ .needle = "and2", .symbol = "and2_behavioral" },
    .{ .needle = "or4", .symbol = "or4_behavioral" },
    .{ .needle = "or3", .symbol = "or3_behavioral" },
    .{ .needle = "or2", .symbol = "or2_behavioral" },
    .{ .needle = "mux4", .symbol = "mux4_behavioral" },
    .{ .needle = "mux2", .symbol = "mux2_behavioral" },
    .{ .needle = "inv", .symbol = "inv_behavioral" },
    .{ .needle = "buf", .symbol = "buf_behavioral" },
    .{ .needle = "conb", .symbol = "conb_behavioral" },
    .{ .needle = "tap", .symbol = "" }, // empty = remove
};

// ── Primitive (analog) prefix mapping ───────────────────────────────────── //

const PrimMapping = struct {
    prefix: []const u8,
    symbol: []const u8,
    kind: DeviceKind,
};

const prim_mappings = [_]PrimMapping{
    .{ .prefix = "sky130_fd_pr__nfet", .symbol = "nmos4", .kind = .nmos4 },
    .{ .prefix = "sky130_fd_pr__pfet", .symbol = "pmos4", .kind = .pmos4 },
    .{ .prefix = "sky130_fd_pr__res", .symbol = "res", .kind = .resistor },
    .{ .prefix = "sky130_fd_pr__cap", .symbol = "capa", .kind = .capacitor },
    .{ .prefix = "sky130_fd_pr__diode", .symbol = "diode", .kind = .diode },
};

// ── Public API ──────────────────────────────────────────────────────────── //

/// Walk every instance in `sch` and remap sky130 symbols to generic primitives.
/// Uses the Schemify's own arena allocator for new string allocations.
/// Instances mapped to substrate taps (empty symbol) are left in place with
/// their symbol set to "tap_behavioral" — the caller can filter them if needed.
pub fn remapSky130(sch: *Schemify) void {
    const n = sch.instances.len;
    if (n == 0) return;

    const syms = sch.instances.items(.symbol);
    const kinds = sch.instances.items(.kind);
    const prop_starts = sch.instances.items(.prop_start);
    const prop_counts = sch.instances.items(.prop_count);

    for (0..n) |i| {
        const sym = syms[i];
        if (!std.mem.startsWith(u8, sym, "sky130_")) continue;

        // Try analog primitive mappings first (sky130_fd_pr__*)
        if (remapPrimitive(sym)) |mapping| {
            syms[i] = arenaDupe(sch, mapping.symbol);
            kinds[i] = mapping.kind;
            filterProps(sch, prop_starts[i], prop_counts[i]);
            continue;
        }

        // Standard cell mapping (sky130_fd_sc_hd__* or sky130_fd_sc_*)
        if (std.mem.startsWith(u8, sym, "sky130_fd_sc_")) {
            if (remapStdCell(sym)) |new_sym| {
                syms[i] = arenaDupe(sch, new_sym);
                kinds[i] = .digital_instance;
                filterProps(sch, prop_starts[i], prop_counts[i]);
            } else {
                // Unknown std cell — generic subckt
                syms[i] = arenaDupe(sch, "subckt_behavioral");
                kinds[i] = .subckt;
                filterProps(sch, prop_starts[i], prop_counts[i]);
            }
            continue;
        }

        // Other sky130_* prefixes — generic subckt fallback
        syms[i] = arenaDupe(sch, "subckt_behavioral");
        kinds[i] = .subckt;
        filterProps(sch, prop_starts[i], prop_counts[i]);
    }
}

// ── Helpers ─────────────────────────────────────────────────────────────── //

fn remapPrimitive(sym: []const u8) ?PrimMapping {
    for (&prim_mappings) |m| {
        if (std.mem.startsWith(u8, sym, m.prefix)) return m;
    }
    return null;
}

fn remapStdCell(sym: []const u8) ?[]const u8 {
    // Extract the stem after sky130_fd_sc_*__ prefix.
    // Pattern: sky130_fd_sc_hd__<gate>_<drive>  or  sky130_fd_sc_<lib>__<gate>_<drive>
    const stem = extractStdCellStem(sym);

    for (&gate_mappings) |gm| {
        if (std.mem.indexOf(u8, stem, gm.needle) != null) {
            if (gm.symbol.len == 0) {
                // "tap" — map to a marker symbol (caller can remove)
                return "tap_behavioral";
            }
            return gm.symbol;
        }
    }
    return null;
}

/// Extract the gate+drive portion after the double-underscore separator
/// in a sky130 standard cell name. Returns the full sym if no separator found.
fn extractStdCellStem(sym: []const u8) []const u8 {
    // Find "sky130_fd_sc_<lib>__" — look for the double underscore
    if (std.mem.indexOf(u8, sym, "__")) |pos| {
        return sym[pos + 2 ..];
    }
    return sym;
}

/// Strip PDK-specific properties from an instance's property range.
/// Overwrites removed entries with empty key/val (arena alloc means we can't
/// actually shrink the flat list without reindexing everything).
fn filterProps(sch: *Schemify, start: u32, count: u16) void {
    const props = sch.props.items[start..][0..count];
    for (props) |*p| {
        if (pdk_prop_keys.has(p.key)) {
            p.key = "";
            p.val = "";
        }
    }
}

/// Dupe a string literal into the Schemify's arena. Falls back to the original
/// pointer if allocation fails (arena OOM is extremely rare and the string
/// literals are static anyway).
fn arenaDupe(sch: *Schemify, s: []const u8) []const u8 {
    return sch.alloc().dupe(u8, s) catch s;
}

// ── Tests ───────────────────────────────────────────────────────────────── //

test "remapPrimitive — nfet match" {
    const m = remapPrimitive("sky130_fd_pr__nfet_01v8") orelse unreachable;
    try std.testing.expectEqualStrings("nmos4", m.symbol);
    try std.testing.expectEqual(DeviceKind.nmos4, m.kind);
}

test "remapPrimitive — pfet match" {
    const m = remapPrimitive("sky130_fd_pr__pfet_01v8_hvt") orelse unreachable;
    try std.testing.expectEqualStrings("pmos4", m.symbol);
    try std.testing.expectEqual(DeviceKind.pmos4, m.kind);
}

test "remapPrimitive — no match" {
    try std.testing.expect(remapPrimitive("generic_nmos") == null);
}

test "remapStdCell — inv" {
    const result = remapStdCell("sky130_fd_sc_hd__inv_1") orelse unreachable;
    try std.testing.expectEqualStrings("inv_behavioral", result);
}

test "remapStdCell — nand2" {
    const result = remapStdCell("sky130_fd_sc_hd__nand2_4") orelse unreachable;
    try std.testing.expectEqualStrings("nand2_behavioral", result);
}

test "remapStdCell — dfxtp" {
    const result = remapStdCell("sky130_fd_sc_hd__dfxtp_1") orelse unreachable;
    try std.testing.expectEqualStrings("dff_behavioral", result);
}

test "remapStdCell — tap becomes tap_behavioral" {
    const result = remapStdCell("sky130_fd_sc_hd__tap_1") orelse unreachable;
    try std.testing.expectEqualStrings("tap_behavioral", result);
}

test "remapStdCell — unknown cell" {
    try std.testing.expect(remapStdCell("sky130_fd_sc_hd__zzzzz_1") == null);
}

test "extractStdCellStem" {
    try std.testing.expectEqualStrings("inv_1", extractStdCellStem("sky130_fd_sc_hd__inv_1"));
    try std.testing.expectEqualStrings("nand2b_4", extractStdCellStem("sky130_fd_sc_hd__nand2b_4"));
}
