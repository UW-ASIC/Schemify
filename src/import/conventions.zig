// conventions.zig — Net classification and polarity heuristics for import.
//
// Provides:
//   - isPowerNet, isGndNet, isVddNet — net name classification
//   - inferPolarity — SPICE element prefix + model → DeviceKind

const std = @import("std");
const core = @import("schematic");
const DeviceKind = core.types.DeviceKind;
const PdkMap = @import("PdkMap.zig");

// ── Net classification ──────────────────────────────────────────────────────

pub fn isPowerNet(name: []const u8) bool {
    if (name.len == 0) return false;
    if (name.len == 1 and name[0] == '0') return true;
    var buf: [64]u8 = undefined;
    const lo = toLowerBuf(name, &buf) orelse return false;
    if (std.mem.eql(u8, lo, "gnd") or
        std.mem.eql(u8, lo, "ground") or
        std.mem.eql(u8, lo, "vss"))
        return true;
    if (std.mem.startsWith(u8, lo, "vdd") or
        std.mem.startsWith(u8, lo, "vcc") or
        std.mem.startsWith(u8, lo, "vref"))
        return true;
    return false;
}

pub fn isGndNet(name: []const u8) bool {
    if (name.len == 0) return false;
    if (name.len == 1 and name[0] == '0') return true;
    var buf: [64]u8 = undefined;
    const lo = toLowerBuf(name, &buf) orelse return false;
    return std.mem.eql(u8, lo, "gnd") or
        std.mem.eql(u8, lo, "ground") or
        std.mem.eql(u8, lo, "vss");
}

pub fn isVddNet(name: []const u8) bool {
    if (name.len < 3) return false;
    var buf: [64]u8 = undefined;
    const lo = toLowerBuf(name, &buf) orelse return false;
    return std.mem.startsWith(u8, lo, "vdd") or
        std.mem.startsWith(u8, lo, "vcc") or
        std.mem.eql(u8, lo, "vref");
}

// ── Polarity inference ──────────────────────────────────────────────────────

pub fn inferPolarity(prefix: u8, model_name: ?[]const u8, model_kind: ?[]const u8) DeviceKind {
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
            if (model_kind) |mk| {
                var buf2: [64]u8 = undefined;
                const lo = toLowerBuf(mk, &buf2) orelse return .nmos4;
                if (std.mem.startsWith(u8, lo, "p")) return .pmos4;
                return .nmos4;
            }
            if (isPmos(model_name)) return .pmos4;
            return .nmos4;
        },
        'q' => {
            if (model_kind) |mk| {
                var buf2: [64]u8 = undefined;
                const lo = toLowerBuf(mk, &buf2) orelse return .npn;
                if (std.mem.eql(u8, lo, "pnp") or std.mem.startsWith(u8, lo, "p")) return .pnp;
                return .npn;
            }
            if (isPnp(model_name)) return .pnp;
            return .npn;
        },
        'j' => {
            if (model_kind) |mk| {
                var buf2: [64]u8 = undefined;
                const lo = toLowerBuf(mk, &buf2) orelse return .njfet;
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

// ── Polarity heuristic helpers ──────────────────────────────────────────────

const pmos_patterns = [_][]const u8{ "pmos", "pfet", "pch", "ptype" };
const pnp_patterns = [_][]const u8{ "pnp", "vpnp" };
const pjfet_patterns = [_][]const u8{ "pjfet", "pjf" };
const zener_patterns = [_][]const u8{ "zener", "brkdwn" };

fn nameContainsAny(name: []const u8, patterns: []const []const u8) bool {
    var buf: [128]u8 = undefined;
    const lo = toLowerBuf(name, &buf) orelse return false;
    for (patterns) |pat| {
        if (std.mem.indexOf(u8, lo, pat) != null) return true;
    }
    return false;
}

pub fn isPmos(model_name: ?[]const u8) bool {
    const name = model_name orelse return false;
    if (PdkMap.matchPdkPrefix(&PdkMap.pdk_table, name)) |m| return m.kind == .pmos4;
    return nameContainsAny(name, &pmos_patterns);
}

pub fn isPnp(model_name: ?[]const u8) bool {
    const name = model_name orelse return false;
    if (PdkMap.matchPdkPrefix(&PdkMap.pdk_table, name)) |m| return m.kind == .pnp;
    return nameContainsAny(name, &pnp_patterns);
}

pub fn isPjfet(model_name: ?[]const u8) bool {
    const name = model_name orelse return false;
    return nameContainsAny(name, &pjfet_patterns);
}

pub fn isZener(model_name: ?[]const u8) bool {
    const name = model_name orelse return false;
    return nameContainsAny(name, &zener_patterns);
}

// ── Helpers ─────────────────────────────────────────────────────────────────

fn toLowerBuf(s: []const u8, buf: []u8) ?[]const u8 {
    if (s.len > buf.len) return null;
    for (s, 0..) |c, i| {
        buf[i] = std.ascii.toLower(c);
    }
    return buf[0..s.len];
}

// ── Tests ───────────────────────────────────────────────────────────────────

test "isPowerNet" {
    try std.testing.expect(isPowerNet("0"));
    try std.testing.expect(isPowerNet("GND"));
    try std.testing.expect(isPowerNet("gnd"));
    try std.testing.expect(isPowerNet("vdd"));
    try std.testing.expect(isPowerNet("VDD"));
    try std.testing.expect(isPowerNet("VCC"));
    try std.testing.expect(isPowerNet("vss"));
    try std.testing.expect(!isPowerNet("net1"));
    try std.testing.expect(!isPowerNet("out"));
}

test "isGndNet" {
    try std.testing.expect(isGndNet("0"));
    try std.testing.expect(isGndNet("GND"));
    try std.testing.expect(isGndNet("vss"));
    try std.testing.expect(!isGndNet("vdd"));
}

test "isVddNet" {
    try std.testing.expect(isVddNet("vdd"));
    try std.testing.expect(isVddNet("VCC"));
    try std.testing.expect(isVddNet("vref"));
    try std.testing.expect(!isVddNet("gnd"));
    try std.testing.expect(!isVddNet("0"));
}

test "inferPolarity -- passives" {
    try std.testing.expectEqual(DeviceKind.resistor, inferPolarity('r', null, null));
    try std.testing.expectEqual(DeviceKind.capacitor, inferPolarity('c', null, null));
    try std.testing.expectEqual(DeviceKind.inductor, inferPolarity('l', null, null));
}

test "inferPolarity -- mosfet with model kind" {
    try std.testing.expectEqual(DeviceKind.pmos4, inferPolarity('m', "mymodel", "pmos"));
    try std.testing.expectEqual(DeviceKind.nmos4, inferPolarity('m', "mymodel", "nmos"));
}

test "inferPolarity -- bjt" {
    try std.testing.expectEqual(DeviceKind.pnp, inferPolarity('q', null, "pnp"));
    try std.testing.expectEqual(DeviceKind.npn, inferPolarity('q', null, "npn"));
    try std.testing.expectEqual(DeviceKind.npn, inferPolarity('q', null, null));
}

test "inferPolarity -- controlled sources" {
    try std.testing.expectEqual(DeviceKind.vcvs, inferPolarity('e', null, null));
    try std.testing.expectEqual(DeviceKind.vccs, inferPolarity('g', null, null));
    try std.testing.expectEqual(DeviceKind.cccs, inferPolarity('f', null, null));
    try std.testing.expectEqual(DeviceKind.ccvs, inferPolarity('h', null, null));
}

test "isPmos -- pdk prefix" {
    try std.testing.expect(isPmos("sky130_fd_pr__pfet_01v8_hvt"));
    try std.testing.expect(!isPmos("sky130_fd_pr__nfet_01v8"));
}

test "isPmos -- heuristic" {
    try std.testing.expect(isPmos("PMOS_3V3"));
    try std.testing.expect(!isPmos("NMOS_3V3"));
}
