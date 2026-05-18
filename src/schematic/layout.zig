// layout.zig — Cadence-style compact placement engine.
//
// Pipeline:
//   1. Compute bounding boxes from symbol geometry (comptime LUT + runtime subckt)
//   2. Recognize building blocks (diff pair, current mirror, cascode, load pair, bias)
//   3. Template-place blocks (internal geometry per block type)
//   4. Place singles (smart passives, then remaining by connectivity)
//   5. Compact (horizontal constraint-graph DAG, vertical sweep)
//   6. Grid snap
//
// Complexity: O(n^2) for n elements — tight for <200 devices.

const std = @import("std");
const Allocator = std.mem.Allocator;
const List = std.ArrayListUnmanaged;
const types = @import("types.zig");
const DeviceKind = types.DeviceKind;
const Devices = @import("devices/lib.zig").Devices;
const primitives = @import("devices/primitives.zig");

// ── Gap constants (Cadence-style compact) ────────────────────────────────────

pub const SNAP: i32 = 10;
pub const INTRA_BLOCK_GAP: i32 = 20;
pub const INTER_DEVICE_GAP: i32 = 80;
pub const INTER_BLOCK_GAP: i32 = 60;
pub const WIRE_CHANNEL: i32 = 20;

// Keep legacy constants for backward compatibility with Router pin offsets
pub const H_STEP: i32 = 200;
pub const V_STEP: i32 = 160;

// ── Bounding Box ─────────────────────────────────────────────────────────────

pub const BBox = struct {
    min_x: i16,
    min_y: i16,
    max_x: i16,
    max_y: i16,

    pub fn width(self: BBox) i32 {
        return @as(i32, self.max_x) - @as(i32, self.min_x);
    }

    pub fn height(self: BBox) i32 {
        return @as(i32, self.max_y) - @as(i32, self.min_y);
    }

    pub fn halfWidth(self: BBox) i32 {
        return @divTrunc(self.width(), 2);
    }

    pub fn halfHeight(self: BBox) i32 {
        return @divTrunc(self.height(), 2);
    }
};

/// Compute bounding box from a PrimEntry's geometry (segments + pins + circles).
fn bboxFromPrim(prim: *const primitives.PrimEntry) BBox {
    var min_x: i16 = std.math.maxInt(i16);
    var min_y: i16 = std.math.maxInt(i16);
    var max_x: i16 = std.math.minInt(i16);
    var max_y: i16 = std.math.minInt(i16);

    var has_geom = false;

    for (prim.segments[0..prim.segment_count]) |seg| {
        has_geom = true;
        if (seg.x0 < min_x) min_x = seg.x0;
        if (seg.y0 < min_y) min_y = seg.y0;
        if (seg.x1 < min_x) min_x = seg.x1;
        if (seg.y1 < min_y) min_y = seg.y1;
        if (seg.x0 > max_x) max_x = seg.x0;
        if (seg.y0 > max_y) max_y = seg.y0;
        if (seg.x1 > max_x) max_x = seg.x1;
        if (seg.y1 > max_y) max_y = seg.y1;
    }

    for (prim.pin_positions[0..prim.pin_pos_count]) |pp| {
        has_geom = true;
        if (pp.x < min_x) min_x = pp.x;
        if (pp.y < min_y) min_y = pp.y;
        if (pp.x > max_x) max_x = pp.x;
        if (pp.y > max_y) max_y = pp.y;
    }

    for (prim.circles[0..prim.circle_count]) |c| {
        has_geom = true;
        const left = c.cx - c.r;
        const right = c.cx + c.r;
        const top = c.cy - c.r;
        const bottom = c.cy + c.r;
        if (left < min_x) min_x = left;
        if (top < min_y) min_y = top;
        if (right > max_x) max_x = right;
        if (bottom > max_y) max_y = bottom;
    }

    if (!has_geom) return .{ .min_x = -20, .min_y = -30, .max_x = 20, .max_y = 30 };
    return .{ .min_x = min_x, .min_y = min_y, .max_x = max_x, .max_y = max_y };
}

/// Comptime LUT mapping DeviceKind ordinal -> BBox.
const bbox_lut: [std.meta.fields(DeviceKind).len]BBox = blk: {
    @setEvalBranchQuota(500_000);
    var lut: [std.meta.fields(DeviceKind).len]BBox = undefined;
    const default_bbox = BBox{ .min_x = -20, .min_y = -30, .max_x = 20, .max_y = 30 };

    for (0..std.meta.fields(DeviceKind).len) |i| {
        lut[i] = default_bbox;
    }

    // Map each prim entry's kind_name to its DeviceKind ordinal
    for (&primitives.parsed_prims) |*prim| {
        if (std.meta.stringToEnum(DeviceKind, prim.kind_name)) |kind| {
            lut[@intFromEnum(kind)] = bboxFromPrim(prim);
        }
    }

    break :blk lut;
};

/// Get the bounding box for a device kind (comptime LUT for built-in, runtime for subckt).
pub fn bboxForKind(kind: DeviceKind) BBox {
    return bbox_lut[@intFromEnum(kind)];
}

/// Runtime bbox for subcircuits based on pin count.
pub fn bboxFromPinCount(n: usize) BBox {
    const pins_per_side = @max(1, @as(i16, @intCast((n + 1) / 2)));
    const half_h: i16 = pins_per_side * 15 + 10;
    return .{ .min_x = -30, .min_y = -half_h, .max_x = 30, .max_y = half_h };
}

// ── Input type ───────────────────────────────────────────────────────────────

pub const LayoutElement = struct {
    prefix: u8,
    name: []const u8 = "",
    nodes: []const []const u8,
    model: ?[]const u8 = null,
};

// ── Public types ─────────────────────────────────────────────────────────────

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

// ── Net classification ───────────────────────────────────────────────────────

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
        std.mem.startsWith(u8, lo, "vcc"))
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
        std.mem.startsWith(u8, lo, "vcc");
}

// ── Main placement entry point ───────────────────────────────────────────────

pub fn place(
    arena: Allocator,
    elements: []const LayoutElement,
    kinds: []const DeviceKind,
) ![]const PlacedDevice {
    const n = elements.len;
    if (n == 0) return &.{};

    const symbols = try arena.alloc([]const u8, n);
    for (kinds, 0..) |k, i| {
        if ((k == .subckt or k == .digital_instance) and elements[i].model != null) {
            symbols[i] = elements[i].model.?;
        } else {
            symbols[i] = Devices.symbolForKind(k);
        }
    }

    // Compute per-element bboxes
    const bboxes = try arena.alloc(BBox, n);
    for (kinds, 0..) |k, i| {
        if (k == .subckt or k == .digital_instance) {
            bboxes[i] = bboxFromPinCount(elements[i].nodes.len);
        } else {
            bboxes[i] = bboxForKind(k);
        }
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

    // Step 2: Zone assignment
    const zones = try assignZones(arena, elements, kinds, n);

    // Step 3: Orientation
    const orientations = try assignOrientations(arena, elements, kinds, n);

    // Step 4: Template-place blocks + place singles + compact
    return buildCompactPlacement(arena, n, elements, kinds, symbols, bboxes, groups, blocks, zones, orientations, &net_adj);
}

// ── Step 1: Building block recognition ───────────────────────────────────────

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

    // Scan for load pairs: two PMOS sharing gate, one diode-connected
    for (elements, 0..) |e1, i| {
        if (used[i]) continue;
        if (!isPmos(kinds[i])) continue;
        for (elements[i + 1 ..], i + 1..) |e2, j| {
            if (used[j]) continue;
            if (!isPmos(kinds[j])) continue;
            if (isLoadPair(e1, e2)) {
                const members = try arena.dupe(u32, &.{ @intCast(i), @intCast(j) });
                try blocks.append(arena, .{ .kind = .load_pair, .members = members, .axis_x = 0 });
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
            if (isMirror(e1, e2)) {
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

    // Scan for bias networks: MOSFET with gate=drain (diode-connected) not already used
    for (elements, 0..) |e1, i| {
        if (used[i]) continue;
        if (!isMosfet(kinds[i])) continue;
        if (e1.nodes.len < 4) continue;
        const g = e1.nodes[1];
        const d = e1.nodes[0];
        if (!std.mem.eql(u8, g, d)) continue;
        // Check if this device only connects to power nets + one signal
        var signal_count: u32 = 0;
        for (e1.nodes) |node| {
            if (!isPowerNet(node)) signal_count += 1;
        }
        if (signal_count <= 2) {
            // Check if gate net only connects to other gates (bias distribution)
            if (net_adj.get(g)) |neighbors| {
                var is_bias = true;
                for (neighbors.items) |ni| {
                    if (ni == @as(u32, @intCast(i))) continue;
                    if (used[ni]) continue;
                    // It's bias if neighbors' connection to this net is via gate
                    const ne = elements[ni];
                    if (ne.nodes.len >= 2) {
                        var found_gate = false;
                        if (ne.nodes.len >= 4 and std.mem.eql(u8, ne.nodes[1], g)) found_gate = true;
                        if (!found_gate) { is_bias = false; break; }
                    }
                }
                if (is_bias) {
                    const members = try arena.dupe(u32, &.{@intCast(i)});
                    try blocks.append(arena, .{ .kind = .bias_network, .members = members, .axis_x = 0 });
                    used[i] = true;
                }
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

fn isLoadPair(e1: LayoutElement, e2: LayoutElement) bool {
    if (e1.nodes.len < 4 or e2.nodes.len < 4) return false;
    const g1 = e1.nodes[1];
    const g2 = e2.nodes[1];
    if (!std.mem.eql(u8, g1, g2)) return false;
    // At least one must be diode-connected
    const d1 = e1.nodes[0];
    const d2 = e2.nodes[0];
    const diode1 = std.mem.eql(u8, g1, d1);
    const diode2 = std.mem.eql(u8, g2, d2);
    if (!diode1 and !diode2) return false;
    // Sources should connect to power (VDD for PMOS loads)
    const s1 = e1.nodes[2];
    const s2 = e2.nodes[2];
    if (!isPowerNet(s1) or !isPowerNet(s2)) return false;
    return true;
}

fn isMirror(e1: LayoutElement, e2: LayoutElement) bool {
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
        .nmos3, .pmos3, .nmos4, .pmos4, .nmos4_depl, .nmos_sub, .pmos_sub, .nmoshv4, .pmoshv4, .rnmos4 => true,
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

// ── Zone assignment ──────────────────────────────────────────────────────────

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

    if (elem.prefix == 'v' or elem.prefix == 'i') return .middle;

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

// ── Orientation ──────────────────────────────────────────────────────────────

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

// ── Compact placement engine ─────────────────────────────────────────────────

fn buildCompactPlacement(
    arena: Allocator,
    n: usize,
    elements: []const LayoutElement,
    kinds: []const DeviceKind,
    symbols: []const []const u8,
    bboxes: []const BBox,
    groups: []const GroupId,
    blocks: []const BuildingBlock,
    zones: []const Zone,
    orientations: []const Orientation,
    net_adj: *const std.StringHashMapUnmanaged(List(u32)),
) ![]const PlacedDevice {
    // Working coordinate arrays
    const xs = try arena.alloc(i32, n);
    const ys = try arena.alloc(i32, n);
    @memset(xs, std.math.minInt(i32));
    @memset(ys, std.math.minInt(i32));

    const placed_flags = try arena.alloc(bool, n);
    @memset(placed_flags, false);

    // ── Phase 1: Template-place building blocks ──
    // Track block positions for load-pair alignment
    var diff_pair_xs: [16][2]i32 = undefined;
    var diff_pair_count: usize = 0;

    for (blocks) |blk| {
        switch (blk.kind) {
            .diff_pair => {
                const a = blk.members[0];
                const b = blk.members[1];
                const bbox_a = bboxes[a];
                const bbox_b = bboxes[b];
                const gap = INTRA_BLOCK_GAP;
                const half_span = @divTrunc(bbox_a.halfWidth() + gap + bbox_b.halfWidth(), 1);
                xs[a] = -half_span;
                xs[b] = half_span;
                const zone_y = zoneBaseY(zones[a]);
                ys[a] = zone_y;
                ys[b] = zone_y;
                placed_flags[a] = true;
                placed_flags[b] = true;
                if (diff_pair_count < 16) {
                    diff_pair_xs[diff_pair_count] = .{ xs[a], xs[b] };
                    diff_pair_count += 1;
                }
            },
            .load_pair => {
                const a = blk.members[0];
                const b = blk.members[1];
                const bbox_a = bboxes[a];
                const bbox_b = bboxes[b];
                const gap = INTRA_BLOCK_GAP;
                const half_span = @divTrunc(bbox_a.halfWidth() + gap + bbox_b.halfWidth(), 1);
                // Align with diff pair if one exists
                var base_x: i32 = 0;
                if (diff_pair_count > 0) {
                    base_x = @divTrunc(diff_pair_xs[0][0] + diff_pair_xs[0][1], 2);
                }
                xs[a] = base_x - half_span;
                xs[b] = base_x + half_span;
                const zone_y = zoneBaseY(zones[a]);
                ys[a] = zone_y;
                ys[b] = zone_y;
                placed_flags[a] = true;
                placed_flags[b] = true;
            },
            .current_mirror => {
                const a = blk.members[0];
                const b = blk.members[1];
                const bbox_a = bboxes[a];
                const bbox_b = bboxes[b];
                const gap = INTRA_BLOCK_GAP;
                const half_span = @divTrunc(bbox_a.halfWidth() + gap + bbox_b.halfWidth(), 1);
                // Diode-connected on left
                const diode_a = if (elements[a].nodes.len >= 4)
                    std.mem.eql(u8, elements[a].nodes[0], elements[a].nodes[1])
                else
                    false;
                if (diode_a) {
                    xs[a] = -half_span;
                    xs[b] = half_span;
                } else {
                    xs[a] = half_span;
                    xs[b] = -half_span;
                }
                const zone_y = zoneBaseY(zones[a]);
                ys[a] = zone_y;
                ys[b] = zone_y;
                placed_flags[a] = true;
                placed_flags[b] = true;
            },
            .cascode_stack => {
                const a = blk.members[0];
                const b = blk.members[1];
                const bbox_a = bboxes[a];
                const bbox_b = bboxes[b];
                const gap = INTRA_BLOCK_GAP;
                const stack_center_x: i32 = 0;
                xs[a] = stack_center_x;
                xs[b] = stack_center_x;
                const zone_y = zoneBaseY(zones[a]);
                ys[a] = zone_y - @divTrunc(bbox_a.halfHeight() + gap + bbox_b.halfHeight(), 2);
                ys[b] = zone_y + @divTrunc(bbox_a.halfHeight() + gap + bbox_b.halfHeight(), 2);
                placed_flags[a] = true;
                placed_flags[b] = true;
            },
            .bias_network => {
                for (blk.members) |m| {
                    // Bias devices go far left
                    xs[m] = -200;
                    ys[m] = zoneBaseY(zones[m]);
                    placed_flags[m] = true;
                }
            },
            .none => {},
        }
    }

    // ── Phase 2: Place remaining devices by connectivity ──
    // Build connectivity strength: for each pair of devices, count shared signal nets
    const conn_strength = try arena.alloc(i32, n);

    // Place smart passives and remaining elements
    for (0..n) |pass| {
        _ = pass;
        var progress = false;
        for (0..n) |i| {
            if (placed_flags[i]) continue;

            // Compute connectivity strength to each placed device
            @memset(conn_strength, 0);
            var best_neighbor: ?u32 = null;
            var best_score: i32 = 0;

            for (elements[i].nodes) |node| {
                if (isPowerNet(node)) continue;
                if (net_adj.get(node)) |neighbors| {
                    for (neighbors.items) |ni| {
                        if (ni == @as(u32, @intCast(i))) continue;
                        if (!placed_flags[ni]) continue;
                        conn_strength[ni] += 1;
                        if (conn_strength[ni] > best_score) {
                            best_score = conn_strength[ni];
                            best_neighbor = ni;
                        }
                    }
                }
            }

            if (best_neighbor) |nb| {
                // Smart passive placement
                if (isPassive(kinds[i])) {
                    // Check if passive bridges two placed devices
                    var second_neighbor: ?u32 = null;
                    var second_score: i32 = 0;
                    for (0..n) |k| {
                        if (k == nb or k == i) continue;
                        if (!placed_flags[k]) continue;
                        if (conn_strength[k] > second_score) {
                            second_score = conn_strength[k];
                            second_neighbor = @intCast(k);
                        }
                    }

                    if (second_neighbor) |sn| {
                        // Bridge: place between the two
                        xs[i] = @divTrunc(xs[nb] + xs[sn], 2);
                        ys[i] = @divTrunc(ys[nb] + ys[sn], 2);
                    } else {
                        // Power-adjacent or single-connected: place adjacent
                        const bbox_nb = bboxes[nb];
                        const bbox_i = bboxes[i];
                        xs[i] = xs[nb] + bbox_nb.halfWidth() + INTER_DEVICE_GAP + bbox_i.halfWidth();
                        ys[i] = ys[nb];
                    }
                } else {
                    // Regular device: place to the right of strongest neighbor
                    const bbox_nb = bboxes[nb];
                    const bbox_i = bboxes[i];
                    xs[i] = xs[nb] + bbox_nb.halfWidth() + INTER_DEVICE_GAP + bbox_i.halfWidth();
                    ys[i] = zoneBaseY(zones[i]);
                }
                placed_flags[i] = true;
                progress = true;
            }
        }
        if (!progress) break;
    }

    // Place any remaining unconnected devices
    var next_x: i32 = 0;
    for (0..n) |i| {
        if (placed_flags[i]) continue;
        xs[i] = next_x;
        ys[i] = zoneBaseY(zones[i]);
        next_x += bboxes[i].width() + INTER_DEVICE_GAP;
        placed_flags[i] = true;
    }

    // ── Phase 3: Compaction ──
    // Horizontal: constraint-graph approach — ensure no overlaps
    try compactHorizontal(arena, n, xs, bboxes, elements, net_adj, zones);

    // Vertical: within each zone, ensure no overlaps
    compactVertical(n, xs, ys, bboxes, zones);

    // ── Phase 4: Snap to grid ──
    for (0..n) |i| {
        xs[i] = snap(xs[i]);
        ys[i] = snap(ys[i]);
    }

    // ── Build result ──
    var result: List(PlacedDevice) = .{};
    try result.ensureTotalCapacity(arena, n);
    for (0..n) |i| {
        result.appendAssumeCapacity(.{
            .elem_idx = @intCast(i),
            .x = xs[i],
            .y = ys[i],
            .orientation = orientations[i],
            .kind = kinds[i],
            .symbol = symbols[i],
            .group = groups[i],
        });
    }
    return result.items;
}

fn isPassive(kind: DeviceKind) bool {
    return switch (kind) {
        .resistor, .resistor3, .var_resistor, .capacitor, .inductor => true,
        else => false,
    };
}

fn zoneBaseY(zone: Zone) i32 {
    return switch (zone) {
        .pmos_top => -120,
        .nmos_bottom => 120,
        .middle => 0,
        .port => -200,
    };
}

// ── Horizontal compaction ────────────────────────────────────────────────────
// Build a DAG where edges encode minimum spacing constraints based on
// connectivity (signal flow). Then assign x = longest path from source.

fn compactHorizontal(
    arena: Allocator,
    n: usize,
    xs: []i32,
    bboxes: []const BBox,
    elements: []const LayoutElement,
    net_adj: *const std.StringHashMapUnmanaged(List(u32)),
    zones: []const Zone,
) !void {
    // Build ordering: sort elements by current x position to establish flow
    const order = try arena.alloc(u32, n);
    for (0..n) |i| order[i] = @intCast(i);
    std.mem.sort(u32, order, xs, struct {
        fn lessThan(x_arr: []i32, a: u32, b: u32) bool {
            return x_arr[a] < x_arr[b];
        }
    }.lessThan);

    // Build constraint edges: for each signal net, create edge from
    // leftmost device to rightmost device on that net
    const Edge = struct { from: u32, to: u32, min_dist: i32 };
    var edges: List(Edge) = .{};

    var iter = net_adj.iterator();
    while (iter.next()) |entry| {
        const neighbors = entry.value_ptr.items;
        if (neighbors.len < 2) continue;

        // Find leftmost and rightmost in this net
        var left: u32 = neighbors[0];
        var right: u32 = neighbors[0];
        for (neighbors[1..]) |ni| {
            if (xs[ni] < xs[left]) left = ni;
            if (xs[ni] > xs[right]) right = ni;
        }

        if (left != right) {
            const min_dist = bboxes[left].halfWidth() + INTER_DEVICE_GAP + bboxes[right].halfWidth();
            try edges.append(arena, .{ .from = left, .to = right, .min_dist = min_dist });
        }
    }

    // Also add overlap-avoidance constraints for devices in the same zone
    // that are currently too close
    for (0..n) |i| {
        for (i + 1..n) |j| {
            if (zones[i] != zones[j]) continue;
            _ = elements;

            const i_right = xs[i] + bboxes[i].halfWidth();
            const j_left = xs[j] - bboxes[j].halfWidth();

            if (i_right + INTER_DEVICE_GAP > j_left and xs[i] <= xs[j]) {
                // i is left of j but overlapping — push j right
                const min_dist = bboxes[i].halfWidth() + INTER_DEVICE_GAP + bboxes[j].halfWidth();
                try edges.append(arena, .{ .from = @intCast(i), .to = @intCast(j), .min_dist = min_dist });
            } else if (xs[j] < xs[i]) {
                const j_right = xs[j] + bboxes[j].halfWidth();
                const i_left = xs[i] - bboxes[i].halfWidth();
                if (j_right + INTER_DEVICE_GAP > i_left) {
                    const min_dist = bboxes[j].halfWidth() + INTER_DEVICE_GAP + bboxes[i].halfWidth();
                    try edges.append(arena, .{ .from = @intCast(j), .to = @intCast(i), .min_dist = min_dist });
                }
            }
        }
    }

    // Longest-path relaxation (Bellman-Ford style, limited iterations)
    const dist = try arena.alloc(i32, n);
    @memset(dist, 0);

    // Seed distances from current x ordering
    for (order) |idx| {
        dist[idx] = xs[idx];
    }

    // Relax edges — iterate until stable or max iterations
    var changed = true;
    var iters: u32 = 0;
    while (changed and iters < n + 1) : (iters += 1) {
        changed = false;
        for (edges.items) |e| {
            const candidate = dist[e.from] + e.min_dist;
            if (candidate > dist[e.to]) {
                dist[e.to] = candidate;
                changed = true;
            }
        }
    }

    // Apply compacted positions
    for (0..n) |i| {
        xs[i] = dist[i];
    }

    // Center around 0
    if (n > 0) {
        var min_x: i32 = std.math.maxInt(i32);
        var max_x: i32 = std.math.minInt(i32);
        for (0..n) |i| {
            if (xs[i] < min_x) min_x = xs[i];
            if (xs[i] > max_x) max_x = xs[i];
        }
        const center = @divTrunc(min_x + max_x, 2);
        for (0..n) |i| {
            xs[i] -= center;
        }
    }
}

// ── Vertical compaction ──────────────────────────────────────────────────────
// Within each zone, separate overlapping devices vertically.

fn compactVertical(
    n: usize,
    xs: []const i32,
    ys: []i32,
    bboxes: []const BBox,
    zones: []const Zone,
) void {
    // For each pair of devices in same zone that overlap horizontally,
    // separate vertically
    for (0..n) |i| {
        for (i + 1..n) |j| {
            if (zones[i] != zones[j]) continue;

            // Check horizontal overlap
            const i_left = xs[i] - bboxes[i].halfWidth();
            const i_right = xs[i] + bboxes[i].halfWidth();
            const j_left = xs[j] - bboxes[j].halfWidth();
            const j_right = xs[j] + bboxes[j].halfWidth();

            const h_overlap = i_left < j_right and j_left < i_right;
            if (!h_overlap) continue;

            // Check vertical overlap
            const i_top = ys[i] - bboxes[i].halfHeight();
            const i_bot = ys[i] + bboxes[i].halfHeight();
            const j_top = ys[j] - bboxes[j].halfHeight();
            const j_bot = ys[j] + bboxes[j].halfHeight();

            const v_overlap = i_top < j_bot and j_top < i_bot;
            if (!v_overlap) continue;

            // Push j down (away from i)
            const min_gap = bboxes[i].halfHeight() + INTER_DEVICE_GAP + bboxes[j].halfHeight();
            if (ys[j] >= ys[i]) {
                ys[j] = ys[i] + min_gap;
            } else {
                ys[j] = ys[i] - min_gap;
            }
        }
    }
}

// ── Helpers ──────────────────────────────────────────────────────────────────

pub fn snap(v: i32) i32 {
    const half = @divTrunc(SNAP, 2);
    if (v >= 0) {
        return @divTrunc(v + half, SNAP) * SNAP;
    } else {
        return @divTrunc(v - half, SNAP) * SNAP;
    }
}

// ── Tests ────────────────────────────────────────────────────────────────────

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
    const zones_result = try assignZones(arena, &elements, &kinds, 2);
    try std.testing.expectEqual(Zone.pmos_top, zones_result[0]);
    try std.testing.expectEqual(Zone.nmos_bottom, zones_result[1]);
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

    // PMOS should be above NMOS
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

    // Diff pair M1 and M2 should have same Y
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

test "bbox for nmos4" {
    const bbox = bboxForKind(.nmos4);
    // nmos.chn_prim: x range [-20, 25], y range [-30, 30]
    try std.testing.expect(bbox.min_x <= -20);
    try std.testing.expect(bbox.max_x >= 20);
    try std.testing.expect(bbox.min_y <= -30);
    try std.testing.expect(bbox.max_y >= 30);
    try std.testing.expect(bbox.width() > 0);
    try std.testing.expect(bbox.height() > 0);
}

test "bbox for resistor" {
    const bbox = bboxForKind(.resistor);
    // resistor.chn_prim: x range [-8, 15], y range [-30, 30]
    try std.testing.expect(bbox.min_x <= -8);
    try std.testing.expect(bbox.max_x >= 8);
    try std.testing.expect(bbox.min_y <= -30);
    try std.testing.expect(bbox.max_y >= 30);
}

test "bboxFromPinCount — subcircuit" {
    const bbox2 = bboxFromPinCount(2);
    try std.testing.expect(bbox2.width() == 60);
    try std.testing.expect(bbox2.height() > 0);

    const bbox8 = bboxFromPinCount(8);
    try std.testing.expect(bbox8.height() > bbox2.height());
}

test "isLoadPair — two PMOS sharing gate, one diode" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const n1 = try arena.dupe([]const u8, &.{ "net1", "net1", "vdd", "vdd" });
    const n2 = try arena.dupe([]const u8, &.{ "out", "net1", "vdd", "vdd" });
    const e1 = LayoutElement{ .prefix = 'm', .name = "M3", .nodes = n1, .model = "pfet" };
    const e2 = LayoutElement{ .prefix = 'm', .name = "M4", .nodes = n2, .model = "pfet" };
    try std.testing.expect(isLoadPair(e1, e2));
}

test "isLoadPair — rejects non-power sources" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const n1 = try arena.dupe([]const u8, &.{ "net1", "net1", "mid", "vdd" });
    const n2 = try arena.dupe([]const u8, &.{ "out", "net1", "mid", "vdd" });
    const e1 = LayoutElement{ .prefix = 'm', .name = "M3", .nodes = n1, .model = "pfet" };
    const e2 = LayoutElement{ .prefix = 'm', .name = "M4", .nodes = n2, .model = "pfet" };
    try std.testing.expect(!isLoadPair(e1, e2));
}

test "compact placement — no overlapping bboxes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const elements = [_]LayoutElement{
        .{ .prefix = 'r', .name = "R1", .nodes = try arena.dupe([]const u8, &.{ "a", "b" }) },
        .{ .prefix = 'r', .name = "R2", .nodes = try arena.dupe([]const u8, &.{ "b", "c" }) },
        .{ .prefix = 'r', .name = "R3", .nodes = try arena.dupe([]const u8, &.{ "c", "d" }) },
    };
    const kinds = [_]DeviceKind{ .resistor, .resistor, .resistor };

    const result = try place(arena, &elements, &kinds);
    try std.testing.expectEqual(@as(usize, 3), result.len);

    // Verify no overlaps
    for (0..result.len) |i| {
        const bbox_i = bboxForKind(result[i].kind);
        for (i + 1..result.len) |j| {
            const bbox_j = bboxForKind(result[j].kind);
            const i_left = result[i].x + bbox_i.min_x;
            const i_right = result[i].x + bbox_i.max_x;
            const j_left = result[j].x + bbox_j.min_x;
            const j_right = result[j].x + bbox_j.max_x;

            // If they share the same Y-band, they must not overlap horizontally
            const i_top = result[i].y + bbox_i.min_y;
            const i_bot = result[i].y + bbox_i.max_y;
            const j_top = result[j].y + bbox_j.min_y;
            const j_bot = result[j].y + bbox_j.max_y;

            const v_overlap = i_top < j_bot and j_top < i_bot;
            const h_overlap = i_left < j_right and j_left < i_right;

            // If both overlap, that's a placement error
            try std.testing.expect(!(v_overlap and h_overlap));
        }
    }
}

test "compact placement — total area smaller than legacy" {
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

    // Measure bounding rectangle of all placed devices
    var min_x: i32 = std.math.maxInt(i32);
    var max_x: i32 = std.math.minInt(i32);
    var min_y: i32 = std.math.maxInt(i32);
    var max_y: i32 = std.math.minInt(i32);
    for (result) |dev| {
        if (dev.x < min_x) min_x = dev.x;
        if (dev.x > max_x) max_x = dev.x;
        if (dev.y < min_y) min_y = dev.y;
        if (dev.y > max_y) max_y = dev.y;
    }

    const width = max_x - min_x;
    const height = max_y - min_y;

    // Legacy would give 5 * H_STEP = 1000 width, here should be much less
    try std.testing.expect(width < 500);
    try std.testing.expect(height < 500);
}

test "place inverter — 2 MOSFET compact" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const elements = [_]LayoutElement{
        .{ .prefix = 'm', .name = "M1", .nodes = try arena.dupe([]const u8, &.{ "out", "in", "vdd", "vdd" }), .model = "pfet" },
        .{ .prefix = 'm', .name = "M2", .nodes = try arena.dupe([]const u8, &.{ "out", "in", "0", "0" }), .model = "nfet" },
    };
    const kinds = [_]DeviceKind{ .pmos4, .nmos4 };

    const result = try place(arena, &elements, &kinds);
    try std.testing.expectEqual(@as(usize, 2), result.len);

    // PMOS above NMOS
    var pmos_y: ?i32 = null;
    var nmos_y: ?i32 = null;
    for (result) |dev| {
        if (dev.kind == .pmos4) pmos_y = dev.y;
        if (dev.kind == .nmos4) nmos_y = dev.y;
    }
    try std.testing.expect(pmos_y.? < nmos_y.?);

    // Total height should be compact (< 300, was 600+ with old algorithm)
    const total_h = nmos_y.? - pmos_y.?;
    try std.testing.expect(total_h < 300);
}
