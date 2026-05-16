// layout.zig — Analog-aware placement engine.
//
// Pipeline:
//   1. Recognize building blocks (diff pairs, mirrors, cascodes)
//   2. Layer assignment (topological sort, signal flow L->R)
//   3. Zone assignment (PMOS top, NMOS bottom)
//   4. Orientation determination (vertical vs horizontal per device)
//   5. Intra-layer ordering (barycenter crossing minimization)
//   6. Coordinate assignment (grid snap)
//   7. Symmetry enforcement (matched pairs equidistant from axis)
//
// Complexity: O(n^2) for n elements — tight for <200 devices.

const std = @import("std");
const Allocator = std.mem.Allocator;
const List = std.ArrayListUnmanaged;
const types = @import("types.zig");
const DeviceKind = types.DeviceKind;
const Devices = @import("devices/lib.zig").Devices;

// ── Grid constants ──────────────────────────────────────────────────────────

pub const H_STEP: i32 = 200;
pub const V_STEP: i32 = 160;
pub const SNAP: i32 = 10;

// ── Input type ──────────────────────────────────────────────────────────────

pub const LayoutElement = struct {
    prefix: u8,
    name: []const u8 = "",
    nodes: []const []const u8,
    model: ?[]const u8 = null,
};

// ── Public types ────────────────────────────────────────────────────────────

pub const Orientation = enum(u2) { up, down, left, right };

pub const GroupId = u16;

pub const BlockKind = enum(u4) {
    diff_pair,
    current_mirror,
    cascode_stack,
    load_pair,
    bias_network,
    none,
};

pub const BuildingBlock = struct {
    kind: BlockKind,
    members: []const u32,
    axis_x: i32,
};

pub const Zone = enum(u2) {
    pmos_top,
    nmos_bottom,
    middle,
    port,
};

pub const PlacedDevice = struct {
    elem_idx: u32,
    x: i32,
    y: i32,
    orientation: Orientation,
    kind: DeviceKind,
    symbol: []const u8,
    group: GroupId,
    name_dx: i16 = 0,
    name_dy: i16 = 0,
    param_dx: i16 = 0,
    param_dy: i16 = 0,
};

// ── Net classification ──────────────────────────────────────────────────────

fn toLowerBuf(s: []const u8, buf: []u8) ?[]const u8 {
    if (s.len > buf.len) return null;
    for (s, 0..) |c, i| {
        buf[i] = std.ascii.toLower(c);
    }
    return buf[0..s.len];
}

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

// ── Main placement entry point ──────────────────────────────────────────────

pub fn place(
    arena: Allocator,
    elements: []const LayoutElement,
    kinds: []const DeviceKind,
) ![]const PlacedDevice {
    const n = elements.len;
    if (n == 0) return &.{};

    const symbols = try arena.alloc([]const u8, n);
    for (kinds, 0..) |k, i| {
        symbols[i] = Devices.symbolForKind(k);
    }

    // Build net adjacency (skip power nets)
    var net_adj = std.StringHashMapUnmanaged(List(u32)){};
    for (elements, 0..) |elem, i| {
        for (elem.nodes) |node| {
            if (isPowerNet(node)) continue;
            const gop = try net_adj.getOrPut(arena, node);
            if (!gop.found_existing) gop.value_ptr.* = .{};
            try gop.value_ptr.append(arena, @intCast(i));
        }
    }

    // Step 1: Recognize building blocks
    const blocks = try recognizeBlocks(arena, elements, kinds, &net_adj);
    const groups = try assignGroups(arena, n, blocks);

    // Step 2: Layer assignment (BFS from sources/inputs)
    const layers = try assignLayers(arena, elements, &net_adj, n);

    // Step 3: Zone assignment
    const zones = try assignZones(arena, elements, kinds, n);

    // Step 4: Orientation
    const orientations = try assignOrientations(arena, elements, kinds, n);

    // Step 5: Intra-layer ordering (barycenter)
    const orders = try barycenterOrder(arena, elements, layers, &net_adj, n);

    // Step 6+7: Coordinate assignment with symmetry
    return buildPlacement(arena, n, elements, kinds, symbols, groups, blocks, layers, zones, orientations, orders);
}

// ── Step 1: Building block recognition ──────────────────────────────────────

fn recognizeBlocks(
    arena: Allocator,
    elements: []const LayoutElement,
    kinds: []const DeviceKind,
    net_adj: *const std.StringHashMapUnmanaged(List(u32)),
) ![]const BuildingBlock {
    var blocks: List(BuildingBlock) = .{};
    var used = try arena.alloc(bool, elements.len);
    @memset(used, false);

    // Scan for diff pairs
    for (elements, 0..) |e1, i| {
        if (used[i]) continue;
        if (!isMosfet(kinds[i])) continue;
        for (elements[i + 1 ..], i + 1..) |e2, j| {
            if (used[j]) continue;
            if (!isMosfet(kinds[j])) continue;
            if (kinds[i] != kinds[j]) continue;
            if (isDiffPair(e1, e2)) {
                const members = try arena.dupe(u32, &.{ @intCast(i), @intCast(j) });
                try blocks.append(arena, .{ .kind = .diff_pair, .members = members, .axis_x = 0 });
                used[i] = true;
                used[j] = true;
                break;
            }
        }
    }

    // Scan for current mirrors
    for (elements, 0..) |e1, i| {
        if (used[i]) continue;
        if (!isMosfet(kinds[i])) continue;
        for (elements[i + 1 ..], i + 1..) |e2, j| {
            if (used[j]) continue;
            if (!isMosfet(kinds[j])) continue;
            if (kinds[i] != kinds[j]) continue;
            if (isMirror(e1, e2, net_adj)) {
                const members = try arena.dupe(u32, &.{ @intCast(i), @intCast(j) });
                try blocks.append(arena, .{ .kind = .current_mirror, .members = members, .axis_x = 0 });
                used[i] = true;
                used[j] = true;
                break;
            }
        }
    }

    // Scan for cascode stacks
    for (elements, 0..) |e1, i| {
        if (used[i]) continue;
        if (!isMosfet(kinds[i])) continue;
        for (elements[i + 1 ..], i + 1..) |e2, j| {
            if (used[j]) continue;
            if (!isMosfet(kinds[j])) continue;
            if (kinds[i] != kinds[j]) continue;
            if (isCascodeStack(e1, e2)) {
                const members = try arena.dupe(u32, &.{ @intCast(i), @intCast(j) });
                try blocks.append(arena, .{ .kind = .cascode_stack, .members = members, .axis_x = 0 });
                used[i] = true;
                used[j] = true;
                break;
            }
        }
    }

    return blocks.items;
}

fn isDiffPair(e1: LayoutElement, e2: LayoutElement) bool {
    if (e1.nodes.len < 4 or e2.nodes.len < 4) return false;
    const s1 = e1.nodes[2];
    const s2 = e2.nodes[2];
    if (!std.mem.eql(u8, s1, s2)) return false;
    const g1 = e1.nodes[1];
    const g2 = e2.nodes[1];
    if (std.mem.eql(u8, g1, g2)) return false;
    if (isPowerNet(g1) or isPowerNet(g2)) return false;
    return true;
}

fn isMirror(e1: LayoutElement, e2: LayoutElement, net_adj: *const std.StringHashMapUnmanaged(List(u32))) bool {
    _ = net_adj;
    if (e1.nodes.len < 4 or e2.nodes.len < 4) return false;
    const g1 = e1.nodes[1];
    const g2 = e2.nodes[1];
    if (!std.mem.eql(u8, g1, g2)) return false;
    const d1 = e1.nodes[0];
    const d2 = e2.nodes[0];
    const diode1 = std.mem.eql(u8, g1, d1);
    const diode2 = std.mem.eql(u8, g2, d2);
    return diode1 or diode2;
}

fn isCascodeStack(e1: LayoutElement, e2: LayoutElement) bool {
    if (e1.nodes.len < 4 or e2.nodes.len < 4) return false;
    const d1 = e1.nodes[0];
    const s2 = e2.nodes[2];
    const d2 = e2.nodes[0];
    const s1 = e1.nodes[2];
    const fwd = std.mem.eql(u8, d1, s2) and !isPowerNet(d1);
    const rev = std.mem.eql(u8, d2, s1) and !isPowerNet(d2);
    return fwd or rev;
}

fn isMosfet(kind: DeviceKind) bool {
    return switch (kind) {
        .nmos3,
        .pmos3,
        .nmos4,
        .pmos4,
        .nmos4_depl,
        .nmos_sub,
        .pmos_sub,
        .nmoshv4,
        .pmoshv4,
        .rnmos4,
        => true,
        else => false,
    };
}

fn isPmos(kind: DeviceKind) bool {
    return switch (kind) {
        .pmos3, .pmos4, .pmos_sub, .pmoshv4 => true,
        else => false,
    };
}

fn assignGroups(arena: Allocator, n: usize, blocks: []const BuildingBlock) ![]const GroupId {
    const groups = try arena.alloc(GroupId, n);
    @memset(groups, 0);
    for (blocks, 1..) |blk, group_num| {
        for (blk.members) |idx| {
            groups[idx] = @intCast(group_num);
        }
    }
    return groups;
}

// ── Step 2: Layer assignment ────────────────────────────────────────────────

fn assignLayers(
    arena: Allocator,
    elements: []const LayoutElement,
    net_adj: *const std.StringHashMapUnmanaged(List(u32)),
    n: usize,
) ![]const i32 {
    const layers = try arena.alloc(i32, n);
    @memset(layers, -1);
    var queue: List(u32) = .{};

    // Seed: V/I sources at layer 0
    for (elements, 0..) |elem, i| {
        if (elem.prefix == 'v' or elem.prefix == 'i') {
            layers[i] = 0;
            try queue.append(arena, @intCast(i));
        }
    }

    // Fallback: if no sources, seed all at layer 0
    if (queue.items.len == 0) {
        for (0..n) |i| {
            layers[i] = 0;
            try queue.append(arena, @intCast(i));
        }
        return layers;
    }

    // BFS propagation
    var qi: usize = 0;
    while (qi < queue.items.len) : (qi += 1) {
        const idx = queue.items[qi];
        const elem = elements[idx];
        for (elem.nodes) |node| {
            if (isPowerNet(node)) continue;
            if (net_adj.get(node)) |neighbors| {
                for (neighbors.items) |ni| {
                    if (layers[ni] < 0) {
                        layers[ni] = layers[idx] + 1;
                        try queue.append(arena, ni);
                    }
                }
            }
        }
    }

    // Assign unvisited to max_layer + 1
    var max_layer: i32 = 0;
    for (layers) |l| {
        if (l > max_layer) max_layer = l;
    }
    for (layers) |*l| {
        if (l.* < 0) l.* = max_layer + 1;
    }

    return layers;
}

// ── Step 3: Zone assignment ─────────────────────────────────────────────────

fn assignZones(
    arena: Allocator,
    elements: []const LayoutElement,
    kinds: []const DeviceKind,
    n: usize,
) ![]const Zone {
    const zones = try arena.alloc(Zone, n);
    for (elements, 0..) |elem, i| {
        zones[i] = zoneForDevice(elem, kinds[i]);
    }
    return zones;
}

fn zoneForDevice(elem: LayoutElement, kind: DeviceKind) Zone {
    if (kind == .vdd or kind == .gnd or kind == .lab_pin or
        kind == .input_pin or kind == .output_pin or kind == .inout_pin)
        return .port;

    if (isPmos(kind)) return .pmos_top;

    if (isMosfet(kind) and !isPmos(kind)) return .nmos_bottom;

    // Sources connected to power nets -> appropriate zone
    if (elem.prefix == 'v' or elem.prefix == 'i') return .middle;

    // Passives and subcircuits
    if (elem.nodes.len >= 2) {
        var has_vdd = false;
        var has_gnd = false;
        for (elem.nodes) |node| {
            if (isVddNet(node)) has_vdd = true;
            if (isGndNet(node)) has_gnd = true;
        }
        if (has_vdd and !has_gnd) return .pmos_top;
        if (has_gnd and !has_vdd) return .nmos_bottom;
    }

    return .middle;
}

// ── Step 4: Orientation ─────────────────────────────────────────────────────

fn assignOrientations(
    arena: Allocator,
    elements: []const LayoutElement,
    kinds: []const DeviceKind,
    n: usize,
) ![]const Orientation {
    const orientations = try arena.alloc(Orientation, n);
    for (elements, 0..) |elem, i| {
        orientations[i] = orientForDevice(elem, kinds[i]);
    }
    return orientations;
}

fn orientForDevice(elem: LayoutElement, kind: DeviceKind) Orientation {
    if (isPmos(kind)) return .down;
    if (isMosfet(kind)) return .up;

    if (kind == .resistor or kind == .capacitor or kind == .inductor) {
        if (elem.nodes.len >= 2) {
            const pwr0 = isPowerNet(elem.nodes[0]);
            const pwr1 = isPowerNet(elem.nodes[1]);
            if (pwr0 or pwr1) return .up;
            return .right;
        }
    }

    if (elem.prefix == 'v' or elem.prefix == 'i') return .up;

    return .up;
}

// ── Step 5: Barycenter ordering ─────────────────────────────────────────────

fn barycenterOrder(
    arena: Allocator,
    elements: []const LayoutElement,
    layers: []const i32,
    net_adj: *const std.StringHashMapUnmanaged(List(u32)),
    n: usize,
) ![]const i32 {
    const orders = try arena.alloc(i32, n);
    const positions = try arena.alloc(f32, n);
    for (0..n) |i| positions[i] = @floatFromInt(i);

    for (elements, 0..) |elem, i| {
        var sum: f32 = 0;
        var count: f32 = 0;
        for (elem.nodes) |node| {
            if (isPowerNet(node)) continue;
            if (net_adj.get(node)) |neighbors| {
                for (neighbors.items) |ni| {
                    if (layers[ni] != layers[i]) {
                        sum += positions[ni];
                        count += 1;
                    }
                }
            }
        }
        if (count > 0) {
            positions[i] = sum / count;
        }
    }

    for (0..n) |i| {
        orders[i] = @intFromFloat(positions[i] * 10);
    }

    return orders;
}

// ── Step 6+7: Coordinate assignment ─────────────────────────────────────────

fn buildPlacement(
    arena: Allocator,
    n: usize,
    elements: []const LayoutElement,
    kinds: []const DeviceKind,
    symbols: []const []const u8,
    groups: []const GroupId,
    blocks: []const BuildingBlock,
    layers: []const i32,
    zones: []const Zone,
    orientations: []const Orientation,
    orders: []const i32,
) ![]const PlacedDevice {
    _ = elements;
    _ = orders;

    var result: List(PlacedDevice) = .{};
    try result.ensureTotalCapacity(arena, n);

    const pmos_base_y: i32 = -300;
    const middle_base_y: i32 = 0;
    const nmos_base_y: i32 = 300;
    const port_base_y: i32 = -500;

    var occupied = std.AutoHashMapUnmanaged(u64, void){};

    // Place building blocks first (symmetry enforcement)
    for (blocks) |blk| {
        if (blk.members.len < 2) continue;
        const a = blk.members[0];
        const b = blk.members[1];
        const layer = layers[a];
        const zone = zones[a];
        const base_y = zoneBaseY(zone, pmos_base_y, middle_base_y, nmos_base_y, port_base_y);

        const center_x = snap(layer * H_STEP);
        const left_x = center_x - H_STEP / 2;
        const right_x = center_x + H_STEP / 2;

        var row_a: i32 = 0;
        while (occupied.contains(packKey(zone, layer, row_a))) row_a += 1;
        try occupied.put(arena, packKey(zone, layer, row_a), {});
        try occupied.put(arena, packKey(zone, layer, row_a + 1), {});

        const y = snap(base_y - row_a * V_STEP);

        result.appendAssumeCapacity(.{
            .elem_idx = a,
            .x = snap(left_x),
            .y = y,
            .orientation = orientations[a],
            .kind = kinds[a],
            .symbol = symbols[a],
            .group = groups[a],
        });
        result.appendAssumeCapacity(.{
            .elem_idx = b,
            .x = snap(right_x),
            .y = y,
            .orientation = orientations[b],
            .kind = kinds[b],
            .symbol = symbols[b],
            .group = groups[b],
        });
    }

    // Track which elements are already placed (in blocks)
    var placed_set = std.AutoHashMapUnmanaged(u32, void){};
    for (blocks) |blk| {
        for (blk.members) |idx| {
            try placed_set.put(arena, idx, {});
        }
    }

    // Place remaining elements
    for (0..n) |i| {
        const idx: u32 = @intCast(i);
        if (placed_set.contains(idx)) continue;

        const layer = layers[i];
        const zone = zones[i];
        const base_y = zoneBaseY(zone, pmos_base_y, middle_base_y, nmos_base_y, port_base_y);

        var row: i32 = 0;
        while (occupied.contains(packKey(zone, layer, row))) row += 1;
        try occupied.put(arena, packKey(zone, layer, row), {});

        const x = snap(layer * H_STEP);
        const y = snap(base_y - row * V_STEP);

        result.appendAssumeCapacity(.{
            .elem_idx = idx,
            .x = x,
            .y = y,
            .orientation = orientations[i],
            .kind = kinds[i],
            .symbol = symbols[i],
            .group = groups[i],
        });
    }

    return result.items;
}

fn zoneBaseY(zone: Zone, pmos_y: i32, mid_y: i32, nmos_y: i32, port_y: i32) i32 {
    return switch (zone) {
        .pmos_top => pmos_y,
        .nmos_bottom => nmos_y,
        .middle => mid_y,
        .port => port_y,
    };
}

// ── Helpers ─────────────────────────────────────────────────────────────────

pub fn snap(v: i32) i32 {
    const half = @divTrunc(SNAP, 2);
    if (v >= 0) {
        return @divTrunc(v + half, SNAP) * SNAP;
    } else {
        return @divTrunc(v - half, SNAP) * SNAP;
    }
}

fn packKey(zone: Zone, layer: i32, row: i32) u64 {
    const z: u64 = @intFromEnum(zone);
    const l: u64 = @bitCast(@as(i64, layer));
    const r: u64 = @bitCast(@as(i64, row));
    return (z << 56) | ((l & 0x0FFFFFFF) << 28) | (r & 0x0FFFFFFF);
}

// ── Tests ───────────────────────────────────────────────────────────────────

test "snap" {
    try std.testing.expectEqual(@as(i32, 100), snap(100));
    try std.testing.expectEqual(@as(i32, 110), snap(105));
    try std.testing.expectEqual(@as(i32, 100), snap(104));
    try std.testing.expectEqual(@as(i32, -100), snap(-100));
    try std.testing.expectEqual(@as(i32, -110), snap(-105));
}

test "place empty" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const result = try place(arena_state.allocator(), &.{}, &.{});
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "place single source" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const nodes = try arena.dupe([]const u8, &.{ "vdd", "0" });
    const elements = [_]LayoutElement{
        .{ .prefix = 'v', .name = "V1", .nodes = nodes },
    };
    const kinds = [_]DeviceKind{.vsource};
    const result = try place(arena, &elements, &kinds);
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqual(DeviceKind.vsource, result[0].kind);
}

test "isDiffPair — matching sources, different gates" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const n1 = try arena.dupe([]const u8, &.{ "net1", "inp", "tail", "vss" });
    const n2 = try arena.dupe([]const u8, &.{ "out", "inn", "tail", "vss" });
    const e1 = LayoutElement{ .prefix = 'm', .name = "M1", .nodes = n1, .model = "nmos" };
    const e2 = LayoutElement{ .prefix = 'm', .name = "M2", .nodes = n2, .model = "nmos" };
    try std.testing.expect(isDiffPair(e1, e2));
}

test "isDiffPair — same gate rejects" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const n1 = try arena.dupe([]const u8, &.{ "net1", "bias", "tail", "vss" });
    const n2 = try arena.dupe([]const u8, &.{ "net2", "bias", "tail", "vss" });
    const e1 = LayoutElement{ .prefix = 'm', .name = "M1", .nodes = n1, .model = "nmos" };
    const e2 = LayoutElement{ .prefix = 'm', .name = "M2", .nodes = n2, .model = "nmos" };
    try std.testing.expect(!isDiffPair(e1, e2));
}

test "isCascodeStack — drain to source connection" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const n1 = try arena.dupe([]const u8, &.{ "mid", "bias1", "vss", "vss" });
    const n2 = try arena.dupe([]const u8, &.{ "out", "bias2", "mid", "vss" });
    const e1 = LayoutElement{ .prefix = 'm', .name = "M1", .nodes = n1, .model = "nmos" };
    const e2 = LayoutElement{ .prefix = 'm', .name = "M2", .nodes = n2, .model = "nmos" };
    try std.testing.expect(isCascodeStack(e1, e2));
}

test "zone assignment — PMOS on top, NMOS on bottom" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const n1 = try arena.dupe([]const u8, &.{ "out", "in", "vdd", "vdd" });
    const n2 = try arena.dupe([]const u8, &.{ "out", "in", "vss", "vss" });
    const elements = [_]LayoutElement{
        .{ .prefix = 'm', .name = "M1", .nodes = n1, .model = "sky130_fd_pr__pfet_01v8" },
        .{ .prefix = 'm', .name = "M2", .nodes = n2, .model = "sky130_fd_pr__nfet_01v8" },
    };
    const kinds = [_]DeviceKind{ .pmos4, .nmos4 };
    const zones = try assignZones(arena, &elements, &kinds, 2);
    try std.testing.expectEqual(Zone.pmos_top, zones[0]);
    try std.testing.expectEqual(Zone.nmos_bottom, zones[1]);
}

test "place OTA — 5 transistors with diff pair" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const elements = [_]LayoutElement{
        .{ .prefix = 'm', .name = "M1", .nodes = try arena.dupe([]const u8, &.{ "net1", "inp", "net3", "vss" }), .model = "nfet" },
        .{ .prefix = 'm', .name = "M2", .nodes = try arena.dupe([]const u8, &.{ "out", "inn", "net3", "vss" }), .model = "nfet" },
        .{ .prefix = 'm', .name = "M3", .nodes = try arena.dupe([]const u8, &.{ "net1", "net1", "vdd", "vdd" }), .model = "pfet" },
        .{ .prefix = 'm', .name = "M4", .nodes = try arena.dupe([]const u8, &.{ "out", "net1", "vdd", "vdd" }), .model = "pfet" },
        .{ .prefix = 'm', .name = "M5", .nodes = try arena.dupe([]const u8, &.{ "net3", "vbias", "vss", "vss" }), .model = "nfet" },
    };
    const kinds = [_]DeviceKind{ .nmos4, .nmos4, .pmos4, .pmos4, .nmos4 };

    const result = try place(arena, &elements, &kinds);
    try std.testing.expectEqual(@as(usize, 5), result.len);

    var pmos_max_y: i32 = std.math.minInt(i32);
    var nmos_min_y: i32 = std.math.maxInt(i32);
    for (result) |dev| {
        if (isPmos(dev.kind)) {
            if (dev.y > pmos_max_y) pmos_max_y = dev.y;
        } else if (isMosfet(dev.kind)) {
            if (dev.y < nmos_min_y) nmos_min_y = dev.y;
        }
    }
    if (pmos_max_y != std.math.minInt(i32) and nmos_min_y != std.math.maxInt(i32)) {
        try std.testing.expect(pmos_max_y <= nmos_min_y);
    }

    var m1_y: ?i32 = null;
    var m2_y: ?i32 = null;
    for (result) |dev| {
        if (dev.elem_idx == 0) m1_y = dev.y;
        if (dev.elem_idx == 1) m2_y = dev.y;
    }
    if (m1_y) |y1| {
        if (m2_y) |y2| {
            try std.testing.expectEqual(y1, y2);
        }
    }
}

test "orientation — PMOS down, NMOS up" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const pmos_nodes = try arena.dupe([]const u8, &.{ "out", "in", "vdd", "vdd" });
    const nmos_nodes = try arena.dupe([]const u8, &.{ "out", "in", "vss", "vss" });
    const pmos_elem = LayoutElement{ .prefix = 'm', .name = "M1", .nodes = pmos_nodes, .model = "pfet" };
    const nmos_elem = LayoutElement{ .prefix = 'm', .name = "M2", .nodes = nmos_nodes, .model = "nfet" };

    try std.testing.expectEqual(Orientation.down, orientForDevice(pmos_elem, .pmos4));
    try std.testing.expectEqual(Orientation.up, orientForDevice(nmos_elem, .nmos4));
}

test "orientation — passive vertical when power-connected" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const nodes_pwr = try arena.dupe([]const u8, &.{ "net1", "vdd" });
    const nodes_sig = try arena.dupe([]const u8, &.{ "net1", "net2" });
    const res_pwr = LayoutElement{ .prefix = 'r', .name = "R1", .nodes = nodes_pwr };
    const res_sig = LayoutElement{ .prefix = 'r', .name = "R2", .nodes = nodes_sig };

    try std.testing.expectEqual(Orientation.up, orientForDevice(res_pwr, .resistor));
    try std.testing.expectEqual(Orientation.right, orientForDevice(res_sig, .resistor));
}
