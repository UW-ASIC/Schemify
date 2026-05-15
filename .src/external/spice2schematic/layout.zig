// layout.zig — Topological signal-flow placer for SPICE netlists.
//
// Algorithm:
//   1. Build net → element adjacency (skip power/ground nets)
//   2. BFS layer assignment seeded from V/I source elements
//   3. Within each layer: row = BFS visit order
//   4. Overlap nudge: shift conflicting elements down one row slot
//   5. Convert (layer, row) to grid coordinates, snap to SNAP units
//
// Design: Arena-allocated, data-oriented.

const std = @import("std");
const Allocator = std.mem.Allocator;
const List = std.ArrayListUnmanaged;
const parser = @import("parser.zig");
const pdk_map = @import("pdk_map.zig");
const core = @import("core");
const DeviceKind = core.types.DeviceKind;

// ── Grid constants ──────────────────────────────────────────────────────────

pub const H_STEP: i32 = 200;
pub const V_STEP: i32 = 120;
pub const SNAP: i32 = 10;
pub const ORIGIN_X: i32 = 100;
pub const ORIGIN_Y: i32 = -100;

// ── Public types ────────────────────────────────────────────────────────────

pub const PlacedElement = struct {
    elem_idx: u32,
    x: i32,
    y: i32,
    kind: DeviceKind,
    symbol: []const u8,
};

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

// ── Placement algorithm ─────────────────────────────────────────────────────

/// Place elements on a grid using BFS topological layout.
pub fn place(
    arena: Allocator,
    elements: []const parser.Element,
    models: []const parser.Model,
) ![]const PlacedElement {
    const n = elements.len;
    if (n == 0) return &.{};

    // Build net -> [element index] adjacency map (skip power nets)
    var net_map = std.StringHashMapUnmanaged(List(u32)){};
    for (elements, 0..) |elem, i| {
        for (elem.nodes) |node| {
            if (isPowerNet(node)) continue;
            const gop = try net_map.getOrPut(arena, node);
            if (!gop.found_existing) {
                gop.value_ptr.* = .{};
            }
            try gop.value_ptr.append(arena, @intCast(i));
        }
    }

    // BFS layer assignment
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

    // Fallback: if no sources, put everything at layer 0
    if (queue.items.len == 0) {
        for (0..n) |i| {
            layers[i] = 0;
            try queue.append(arena, @intCast(i));
        }
    }

    // BFS propagation
    var qi: usize = 0;
    while (qi < queue.items.len) : (qi += 1) {
        const idx = queue.items[qi];
        const elem = elements[idx];
        for (elem.nodes) |node| {
            if (isPowerNet(node)) continue;
            if (net_map.get(node)) |neighbors| {
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

    // Row assignment within each layer (BFS order)
    var row_counters = std.AutoHashMapUnmanaged(i32, i32){};
    const rows = try arena.alloc(i32, n);
    @memset(rows, 0);

    for (queue.items) |idx| {
        const layer = layers[idx];
        const gop = try row_counters.getOrPut(arena, layer);
        if (!gop.found_existing) gop.value_ptr.* = 0;
        rows[idx] = gop.value_ptr.*;
        gop.value_ptr.* += 1;
    }

    // Overlap resolution and final placement
    var occupied = std.AutoHashMapUnmanaged(u64, void){};
    var result: List(PlacedElement) = .{};
    try result.ensureTotalCapacity(arena, n);

    for (elements, 0..) |elem, i| {
        const col = layers[i];
        var row = rows[i];

        while (occupied.contains(packColRow(col, row))) {
            row += 1;
        }
        try occupied.put(arena, packColRow(col, row), {});

        const x = snap(ORIGIN_X + col * H_STEP);
        const y = snap(ORIGIN_Y - row * V_STEP);

        const model_kind = findModelKind(elem.model, models);
        const kind = pdk_map.deviceKindForElement(elem.prefix, elem.model, model_kind);
        const symbol = pdk_map.symbolForKind(kind);

        result.appendAssumeCapacity(.{
            .elem_idx = @intCast(i),
            .x = x,
            .y = y,
            .kind = kind,
            .symbol = symbol,
        });
    }

    return result.items;
}

// ── Helpers ─────────────────────────────────────────────────────────────────

fn snap(v: i32) i32 {
    const half = @divTrunc(SNAP, 2);
    if (v >= 0) {
        return @divTrunc(v + half, SNAP) * SNAP;
    } else {
        return @divTrunc(v - half, SNAP) * SNAP;
    }
}

fn packColRow(col: i32, row: i32) u64 {
    const c: u64 = @bitCast(@as(i64, col));
    const r: u64 = @bitCast(@as(i64, row));
    return (c << 32) | (r & 0xFFFFFFFF);
}

fn toLowerBuf(s: []const u8, buf: []u8) ?[]const u8 {
    if (s.len > buf.len) return null;
    for (s, 0..) |c, i| {
        buf[i] = std.ascii.toLower(c);
    }
    return buf[0..s.len];
}

fn findModelKind(model_name: ?[]const u8, models: []const parser.Model) ?[]const u8 {
    const name = model_name orelse return null;
    for (models) |m| {
        if (std.ascii.eqlIgnoreCase(m.name, name)) {
            return m.kind;
        }
    }
    return null;
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
    const arena = arena_state.allocator();

    const result = try place(arena, &.{}, &.{});
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "place single source" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const nodes = try arena.dupe([]const u8, &.{ "vdd", "0" });
    const elements = [_]parser.Element{
        .{ .prefix = 'v', .name = "V1", .nodes = nodes, .value = "1.8" },
    };

    const result = try place(arena, &elements, &.{});
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqual(@as(i32, 100), result[0].x);
    try std.testing.expectEqual(@as(i32, -100), result[0].y);
}
