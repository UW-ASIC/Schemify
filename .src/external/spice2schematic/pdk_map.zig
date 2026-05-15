// pdk_map.zig — PDK-aware device model name mapping for SPICE import.
//
// Maps PDK-specific MOSFET/BJT/passive model names to Schemify DeviceKind
// using prefix matching. Supports Sky130, GF180MCU, IHP SG13G2.
// Also provides polarity inference from model names when .MODEL statements
// are absent (common in extracted netlists).

const std = @import("std");
const core = @import("core");
const DeviceKind = core.types.DeviceKind;

// ── PDK prefix → DeviceKind mapping ────────────────────────────────────────

pub const PdkMapping = struct {
    prefix: []const u8,
    kind: DeviceKind,
    symbol: []const u8,
};

/// Ordered longest-first for correct matching. Analog primitives from all
/// supported PDKs.
pub const pdk_mappings = [_]PdkMapping{
    // Sky130
    .{ .prefix = "sky130_fd_pr__nfet", .kind = .nmos4, .symbol = "nmos4" },
    .{ .prefix = "sky130_fd_pr__pfet", .kind = .pmos4, .symbol = "pmos4" },
    .{ .prefix = "sky130_fd_pr__res", .kind = .resistor, .symbol = "res" },
    .{ .prefix = "sky130_fd_pr__cap", .kind = .capacitor, .symbol = "capa" },
    .{ .prefix = "sky130_fd_pr__diode", .kind = .diode, .symbol = "diode" },
    .{ .prefix = "sky130_fd_pr__npn", .kind = .npn, .symbol = "npn" },
    .{ .prefix = "sky130_fd_pr__pnp", .kind = .pnp, .symbol = "pnp" },
    // GF180MCU
    .{ .prefix = "gf180mcu_fd_pr__nfet", .kind = .nmos4, .symbol = "nmos4" },
    .{ .prefix = "gf180mcu_fd_pr__pfet", .kind = .pmos4, .symbol = "pmos4" },
    .{ .prefix = "gf180mcu_fd_pr__res", .kind = .resistor, .symbol = "res" },
    .{ .prefix = "gf180mcu_fd_pr__cap", .kind = .capacitor, .symbol = "capa" },
    .{ .prefix = "gf180mcu_fd_pr__diode", .kind = .diode, .symbol = "diode" },
    .{ .prefix = "gf180mcu_fd_pr__vnpn", .kind = .npn, .symbol = "npn" },
    .{ .prefix = "gf180mcu_fd_pr__vpnp", .kind = .pnp, .symbol = "pnp" },
    // IHP SG13G2
    .{ .prefix = "sg13_lv_nmos", .kind = .nmos4, .symbol = "nmos4" },
    .{ .prefix = "sg13_hv_nmos", .kind = .nmos4, .symbol = "nmos4" },
    .{ .prefix = "sg13_lv_pmos", .kind = .pmos4, .symbol = "pmos4" },
    .{ .prefix = "sg13_hv_pmos", .kind = .pmos4, .symbol = "pmos4" },
    .{ .prefix = "npn13g2", .kind = .npn, .symbol = "npn" },
    .{ .prefix = "pnpMPA", .kind = .pnp, .symbol = "pnp" },
    .{ .prefix = "sg13_lv_res", .kind = .resistor, .symbol = "res" },
    .{ .prefix = "sg13_hv_res", .kind = .resistor, .symbol = "res" },
};

/// Attempt to match a model name against known PDK prefixes.
/// Returns the mapping if found, null otherwise.
pub fn matchPdkModel(model_name: []const u8) ?PdkMapping {
    for (&pdk_mappings) |m| {
        if (model_name.len >= m.prefix.len and
            std.mem.startsWith(u8, model_name, m.prefix))
        {
            return m;
        }
    }
    return null;
}

// ── Polarity inference from model name heuristics ───────────────────────────

/// Patterns that indicate P-type MOSFET model.
const pmos_patterns = [_][]const u8{ "pmos", "pfet", "pch", "ptype" };

/// Patterns that indicate PNP BJT model.
const pnp_patterns = [_][]const u8{ "pnp", "vpnp" };

/// Patterns that indicate P-type JFET model.
const pjfet_patterns = [_][]const u8{ "pjfet", "pjf" };

/// Patterns that indicate zener diode model.
const zener_patterns = [_][]const u8{ "zener", "brkdwn" };

/// Check if a model name contains any of the given substring patterns.
fn nameContainsAny(name: []const u8, patterns: []const []const u8) bool {
    var buf: [128]u8 = undefined;
    const lo = toLowerBuf(name, &buf) orelse return false;
    for (patterns) |pat| {
        if (std.mem.indexOf(u8, lo, pat) != null) return true;
    }
    return false;
}

/// Infer whether a MOSFET model name indicates PMOS.
/// First checks PDK prefix mapping, then falls back to substring heuristics.
pub fn isPmos(model_name: ?[]const u8) bool {
    const name = model_name orelse return false;
    if (matchPdkModel(name)) |m| {
        return m.kind == .pmos4;
    }
    return nameContainsAny(name, &pmos_patterns);
}

/// Infer whether a BJT model name indicates PNP.
pub fn isPnp(model_name: ?[]const u8) bool {
    const name = model_name orelse return false;
    if (matchPdkModel(name)) |m| {
        return m.kind == .pnp;
    }
    return nameContainsAny(name, &pnp_patterns);
}

/// Infer whether a JFET model name indicates P-channel.
pub fn isPjfet(model_name: ?[]const u8) bool {
    const name = model_name orelse return false;
    return nameContainsAny(name, &pjfet_patterns);
}

/// Infer whether a diode model name indicates zener.
pub fn isZener(model_name: ?[]const u8) bool {
    const name = model_name orelse return false;
    return nameContainsAny(name, &zener_patterns);
}

/// Determine the DeviceKind for a SPICE element given its prefix char and model.
/// Uses .MODEL declarations (model_kind) first, then PDK prefix matching,
/// then name heuristics.
pub fn deviceKindForElement(
    prefix: u8,
    model_name: ?[]const u8,
    model_kind: ?[]const u8,
) DeviceKind {
    switch (prefix) {
        'r' => return .resistor,
        'c' => return .capacitor,
        'l' => return .inductor,
        'd' => {
            if (isZener(model_name)) return .zener;
            if (model_kind) |mk| {
                if (std.mem.indexOf(u8, mk, "z") != null) return .zener;
            }
            return .diode;
        },
        'm' => {
            // Check .MODEL kind first
            if (model_kind) |mk| {
                var buf: [64]u8 = undefined;
                const lo = toLowerBuf(mk, &buf) orelse return .nmos4;
                if (std.mem.startsWith(u8, lo, "p")) return .pmos4;
                return .nmos4;
            }
            // PDK prefix or heuristic
            if (isPmos(model_name)) return .pmos4;
            return .nmos4;
        },
        'q' => {
            if (model_kind) |mk| {
                var buf: [64]u8 = undefined;
                const lo = toLowerBuf(mk, &buf) orelse return .npn;
                if (std.mem.eql(u8, lo, "pnp") or std.mem.startsWith(u8, lo, "p")) return .pnp;
                return .npn;
            }
            if (isPnp(model_name)) return .pnp;
            return .npn;
        },
        'j' => {
            if (model_kind) |mk| {
                var buf: [64]u8 = undefined;
                const lo = toLowerBuf(mk, &buf) orelse return .njfet;
                if (std.mem.startsWith(u8, lo, "p")) return .pjfet;
                return .njfet;
            }
            if (isPjfet(model_name)) return .pjfet;
            return .njfet;
        },
        'v' => return .vsource,
        'i' => return .isource,
        'e' => return .vcvs,
        'g' => return .vccs,
        'f' => return .cccs,
        'h' => return .ccvs,
        'b' => return .behavioral,
        'x' => return .subckt,
        else => return .unknown,
    }
}

/// Map DeviceKind to schematic symbol name.
pub fn symbolForKind(kind: DeviceKind) []const u8 {
    return switch (kind) {
        .resistor => "res",
        .capacitor => "capa",
        .inductor => "ind",
        .diode => "diode",
        .zener => "zener",
        .nmos4 => "nmos4",
        .pmos4 => "pmos4",
        .npn => "npn",
        .pnp => "pnp",
        .njfet => "njfet",
        .pjfet => "pjfet",
        .vsource => "vsource",
        .isource => "isource",
        .vcvs => "vcvs",
        .vccs => "vccs",
        .ccvs => "ccvs",
        .cccs => "cccs",
        .behavioral => "vsource",
        .subckt => "subckt",
        else => "vsource",
    };
}

// ── Helpers ─────────────────────────────────────────────────────────────────

fn toLowerBuf(s: []const u8, buf: []u8) ?[]const u8 {
    if (s.len > buf.len) return null;
    for (s, 0..) |c, i| {
        buf[i] = std.ascii.toLower(c);
    }
    return buf[0..s.len];
}

// ── Tests ─────���─────────────────────────────────────────────────────────────

test "matchPdkModel — sky130 nfet" {
    const m = matchPdkModel("sky130_fd_pr__nfet_01v8") orelse unreachable;
    try std.testing.expectEqual(DeviceKind.nmos4, m.kind);
    try std.testing.expectEqualStrings("nmos4", m.symbol);
}

test "matchPdkModel — gf180mcu pfet" {
    const m = matchPdkModel("gf180mcu_fd_pr__pfet_03v3") orelse unreachable;
    try std.testing.expectEqual(DeviceKind.pmos4, m.kind);
}

test "matchPdkModel — sg13 pmos" {
    const m = matchPdkModel("sg13_lv_pmos_lr") orelse unreachable;
    try std.testing.expectEqual(DeviceKind.pmos4, m.kind);
}

test "matchPdkModel — no match" {
    try std.testing.expect(matchPdkModel("generic_nmos") == null);
}

test "isPmos — pdk prefix" {
    try std.testing.expect(isPmos("sky130_fd_pr__pfet_01v8_hvt"));
    try std.testing.expect(!isPmos("sky130_fd_pr__nfet_01v8"));
}

test "isPmos — heuristic" {
    try std.testing.expect(isPmos("PMOS_3V3"));
    try std.testing.expect(!isPmos("NMOS_3V3"));
}

test "deviceKindForElement — mosfet with model kind" {
    try std.testing.expectEqual(DeviceKind.pmos4, deviceKindForElement('m', "mymodel", "pmos"));
    try std.testing.expectEqual(DeviceKind.nmos4, deviceKindForElement('m', "mymodel", "nmos"));
}

test "deviceKindForElement — passives" {
    try std.testing.expectEqual(DeviceKind.resistor, deviceKindForElement('r', null, null));
    try std.testing.expectEqual(DeviceKind.capacitor, deviceKindForElement('c', null, null));
    try std.testing.expectEqual(DeviceKind.inductor, deviceKindForElement('l', null, null));
}
