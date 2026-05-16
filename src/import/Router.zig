// Router.zig — MST-based Manhattan wire router with obstacle avoidance.
//
// Pipeline:
//   1. Build net -> [(elem_idx, node_idx)] map from elements
//   2. Sort nets by estimated wire length (shortest first), power nets last
//   3. For each net:
//      a. Power nets → place symbols, skip wiring
//      b. Signal nets → MST (Prim's) over pin positions
//      c. Each MST edge → pick best among L-shape variants and Z-shape
//   4. Score candidates by crossing count against existing wires
//
// Complexity: O(n² * w) for n pins and w existing wires.

const std = @import("std");
const Allocator = std.mem.Allocator;
const List = std.ArrayListUnmanaged;
const parser = @import("spice/parser.zig");
const core = @import("schematic");
const Layout = core.layout;
const DeviceKind = core.types.DeviceKind;

// ── Public types ────────────────────────────────────────────────────────────

pub const RouteWire = struct {
    x0: i32,
    y0: i32,
    x1: i32,
    y1: i32,
    net_name: []const u8,
};

pub const PowerKind = enum(u1) { vdd, gnd };

pub const PowerSym = struct {
    kind: PowerKind,
    x: i32,
    y: i32,
};

pub const RouteResult = struct {
    wires: []const RouteWire,
    power: []const PowerSym,
};

// ── Pin offset tables ───────────────────────────────────────────────────────

const PinOff = struct { dx: i32, dy: i32 };

// Base offsets assume orientation = .up
const TWO_TERM = [_]PinOff{
    .{ .dx = 0, .dy = -30 }, // p (positive / pin 0)
    .{ .dx = 0, .dy = 30 }, // n (negative / pin 1)
};

const NMOS_PINS = [_]PinOff{
    .{ .dx = 20, .dy = -30 }, // drain
    .{ .dx = -20, .dy = 0 }, // gate
    .{ .dx = 20, .dy = 30 }, // source
    .{ .dx = 20, .dy = 0 }, // bulk
};

const PMOS_PINS = [_]PinOff{
    .{ .dx = 20, .dy = 30 }, // drain
    .{ .dx = -20, .dy = 0 }, // gate
    .{ .dx = 20, .dy = -30 }, // source
    .{ .dx = 20, .dy = 0 }, // bulk
};

const NPN_PINS = [_]PinOff{
    .{ .dx = 20, .dy = -30 }, // collector
    .{ .dx = -20, .dy = 0 }, // base
    .{ .dx = 20, .dy = 30 }, // emitter
};

const PNP_PINS = [_]PinOff{
    .{ .dx = 20, .dy = 30 }, // collector
    .{ .dx = -20, .dy = 0 }, // base
    .{ .dx = 20, .dy = -30 }, // emitter
};

const JFET_N_PINS = [_]PinOff{
    .{ .dx = 20, .dy = -30 }, // drain
    .{ .dx = -20, .dy = 0 }, // gate
    .{ .dx = 20, .dy = 30 }, // source
};

const JFET_P_PINS = [_]PinOff{
    .{ .dx = 20, .dy = 30 }, // drain
    .{ .dx = -20, .dy = 0 }, // gate
    .{ .dx = 20, .dy = -30 }, // source
};

const FOUR_TERM_CTRL = [_]PinOff{
    .{ .dx = 0, .dy = -30 }, // n+
    .{ .dx = 0, .dy = 30 }, // n-
    .{ .dx = -30, .dy = -30 }, // nc+
    .{ .dx = -30, .dy = 30 }, // nc-
};

fn basePinOffsets(kind: DeviceKind) []const PinOff {
    return switch (kind) {
        .nmos3, .nmos4, .nmos4_depl, .nmos_sub, .nmoshv4, .rnmos4 => &NMOS_PINS,
        .pmos3, .pmos4, .pmos_sub, .pmoshv4 => &PMOS_PINS,
        .npn => &NPN_PINS,
        .pnp => &PNP_PINS,
        .njfet => &JFET_N_PINS,
        .pjfet => &JFET_P_PINS,
        .vcvs, .vccs => &FOUR_TERM_CTRL,
        else => &TWO_TERM,
    };
}

const Point = struct { x: i32, y: i32 };

/// Compute pin position accounting for device orientation.
pub fn pinPos(placed: Layout.PlacedDevice, node_idx: usize) ?Point {
    const offs = basePinOffsets(placed.kind);
    if (node_idx >= offs.len) return null;
    const base = offs[node_idx];
    const rotated = rotateOffset(base, placed.orientation);
    return .{
        .x = placed.x + rotated.dx,
        .y = placed.y + rotated.dy,
    };
}

fn rotateOffset(off: PinOff, orient: Layout.Orientation) PinOff {
    return switch (orient) {
        .up => off,
        .down => .{ .dx = -off.dx, .dy = -off.dy },
        .left => .{ .dx = off.dy, .dy = -off.dx },
        .right => .{ .dx = -off.dy, .dy = off.dx },
    };
}

// ── Routing algorithm ───────────────────────────────────────────────────────

const PinRef = struct {
    elem_idx: u32,
    node_idx: u32,
};

const NetEntry = struct {
    name: []const u8,
    pins: []const PinRef,
    est_len: i64,
};

pub fn route(
    arena: Allocator,
    elements: []const parser.Element,
    placed: []const Layout.PlacedDevice,
) !RouteResult {
    if (elements.len == 0 or placed.len == 0) {
        return .{ .wires = &.{}, .power = &.{} };
    }

    // Build elem_idx -> placed index lookup
    var idx_map = std.AutoHashMapUnmanaged(u32, u32){};
    for (placed, 0..) |p, i| {
        try idx_map.put(arena, p.elem_idx, @intCast(i));
    }

    // Step 1: Build net -> [(elem_idx, node_idx)] map
    var net_pins = std.StringHashMapUnmanaged(List(PinRef)){};
    for (elements, 0..) |elem, ei| {
        for (elem.nodes, 0..) |node, ni| {
            const gop = try net_pins.getOrPut(arena, node);
            if (!gop.found_existing) gop.value_ptr.* = .{};
            try gop.value_ptr.append(arena, .{
                .elem_idx = @intCast(ei),
                .node_idx = @intCast(ni),
            });
        }
    }

    // Step 2: Collect and sort nets
    var nets: List(NetEntry) = .{};
    var iter = net_pins.iterator();
    while (iter.next()) |entry| {
        const name = entry.key_ptr.*;
        const pins = entry.value_ptr.items;
        if (pins.len < 2) continue;

        var est: i64 = 0;
        if (!Layout.isPowerNet(name)) {
            est = estimateNetLength(pins, placed, &idx_map);
        }

        // Power nets get max estimate so they sort last
        const sort_key = if (Layout.isPowerNet(name)) std.math.maxInt(i64) else est;
        try nets.append(arena, .{ .name = name, .pins = pins, .est_len = sort_key });
    }

    std.mem.sort(NetEntry, nets.items, {}, struct {
        fn lessThan(_: void, a: NetEntry, b: NetEntry) bool {
            return a.est_len < b.est_len;
        }
    }.lessThan);

    // Step 3: Route each net
    var wires: List(RouteWire) = .{};
    var power: List(PowerSym) = .{};

    for (nets.items) |net| {
        if (Layout.isGndNet(net.name)) {
            for (net.pins) |pin| {
                if (resolvePinPos(pin, placed, &idx_map)) |pos| {
                    try power.append(arena, .{ .kind = .gnd, .x = pos.x, .y = pos.y + 10 });
                }
            }
            continue;
        }

        if (Layout.isVddNet(net.name)) {
            for (net.pins) |pin| {
                if (resolvePinPos(pin, placed, &idx_map)) |pos| {
                    try power.append(arena, .{ .kind = .vdd, .x = pos.x, .y = pos.y - 10 });
                }
            }
            continue;
        }

        // Collect pin positions for this net
        var pts: List(Point) = .{};
        for (net.pins) |pin| {
            if (resolvePinPos(pin, placed, &idx_map)) |pos| {
                try pts.append(arena, pos);
            }
        }
        if (pts.items.len < 2) continue;

        // Build MST using Prim's algorithm and route each edge
        try routeNetMst(arena, &wires, pts.items, net.name);
    }

    return .{
        .wires = wires.items,
        .power = power.items,
    };
}

fn resolvePinPos(
    pin: PinRef,
    placed: []const Layout.PlacedDevice,
    idx_map: *const std.AutoHashMapUnmanaged(u32, u32),
) ?Point {
    const pi = idx_map.get(pin.elem_idx) orelse return null;
    return pinPos(placed[pi], pin.node_idx);
}

fn estimateNetLength(
    pins: []const PinRef,
    placed: []const Layout.PlacedDevice,
    idx_map: *const std.AutoHashMapUnmanaged(u32, u32),
) i64 {
    var min_x: i32 = std.math.maxInt(i32);
    var max_x: i32 = std.math.minInt(i32);
    var min_y: i32 = std.math.maxInt(i32);
    var max_y: i32 = std.math.minInt(i32);
    var count: usize = 0;

    for (pins) |pin| {
        if (resolvePinPos(pin, placed, idx_map)) |pos| {
            if (pos.x < min_x) min_x = pos.x;
            if (pos.x > max_x) max_x = pos.x;
            if (pos.y < min_y) min_y = pos.y;
            if (pos.y > max_y) max_y = pos.y;
            count += 1;
        }
    }
    if (count < 2) return 0;
    return @as(i64, max_x - min_x) + @as(i64, max_y - min_y);
}

// ── MST routing (Prim's) ────────────────────────────────────────────────────

fn routeNetMst(
    arena: Allocator,
    wires: *List(RouteWire),
    pts: []const Point,
    net: []const u8,
) !void {
    const n = pts.len;
    if (n < 2) return;

    // Prim's: in_tree[i] tracks membership, key[i] = min edge weight to tree
    const in_tree = try arena.alloc(bool, n);
    @memset(in_tree, false);
    const key = try arena.alloc(i64, n);
    @memset(key, std.math.maxInt(i64));
    const parent = try arena.alloc(usize, n);
    @memset(parent, std.math.maxInt(usize));

    key[0] = 0;

    for (0..n) |_| {
        // Find min-key vertex not in tree
        var u: usize = std.math.maxInt(usize);
        var min_key: i64 = std.math.maxInt(i64);
        for (0..n) |i| {
            if (!in_tree[i] and key[i] < min_key) {
                min_key = key[i];
                u = i;
            }
        }
        if (u == std.math.maxInt(usize)) break;
        in_tree[u] = true;

        // Update keys of adjacent vertices
        for (0..n) |v| {
            if (in_tree[v]) continue;
            const dist = manhattan(pts[u], pts[v]);
            if (dist < key[v]) {
                key[v] = dist;
                parent[v] = u;
            }
        }
    }

    // Route each MST edge
    const existing_start = wires.items.len;
    for (1..n) |i| {
        if (parent[i] == std.math.maxInt(usize)) continue;
        const p1 = pts[parent[i]];
        const p2 = pts[i];
        try routeEdge(arena, wires, p1, p2, net, existing_start);
    }
}

fn manhattan(a: Point, b: Point) i64 {
    const dx = if (a.x > b.x) @as(i64, a.x - b.x) else @as(i64, b.x - a.x);
    const dy = if (a.y > b.y) @as(i64, a.y - b.y) else @as(i64, b.y - a.y);
    return dx + dy;
}

// ── Edge routing with obstacle avoidance ────────────────────────────────────

fn routeEdge(
    arena: Allocator,
    wires: *List(RouteWire),
    p1: Point,
    p2: Point,
    net: []const u8,
    existing_start: usize,
) !void {
    if (p1.x == p2.x and p1.y == p2.y) return;

    // Straight line (same axis)
    if (p1.x == p2.x or p1.y == p2.y) {
        try wires.append(arena, .{ .x0 = p1.x, .y0 = p1.y, .x1 = p2.x, .y1 = p2.y, .net_name = net });
        return;
    }

    const existing = wires.items[0..existing_start];

    // L-shape A: horizontal then vertical (elbow at p2.x, p1.y)
    const la_segs = [2]Seg{
        .{ .a = p1, .b = .{ .x = p2.x, .y = p1.y } },
        .{ .a = .{ .x = p2.x, .y = p1.y }, .b = p2 },
    };
    const la_cross = countCrossings(&la_segs, existing);

    // L-shape B: vertical then horizontal (elbow at p1.x, p2.y)
    const lb_segs = [2]Seg{
        .{ .a = p1, .b = .{ .x = p1.x, .y = p2.y } },
        .{ .a = .{ .x = p1.x, .y = p2.y }, .b = p2 },
    };
    const lb_cross = countCrossings(&lb_segs, existing);

    // If both L-shapes have crossings, try Z-shapes
    if (la_cross > 0 and lb_cross > 0) {
        const mid_x = @divTrunc(p1.x + p2.x, 2);
        const mid_y = @divTrunc(p1.y + p2.y, 2);

        // Z-shape H-V-H
        const zh_segs = [3]Seg{
            .{ .a = p1, .b = .{ .x = mid_x, .y = p1.y } },
            .{ .a = .{ .x = mid_x, .y = p1.y }, .b = .{ .x = mid_x, .y = p2.y } },
            .{ .a = .{ .x = mid_x, .y = p2.y }, .b = p2 },
        };
        const zh_cross = countCrossings(&zh_segs, existing);

        // Z-shape V-H-V
        const zv_segs = [3]Seg{
            .{ .a = p1, .b = .{ .x = p1.x, .y = mid_y } },
            .{ .a = .{ .x = p1.x, .y = mid_y }, .b = .{ .x = p2.x, .y = mid_y } },
            .{ .a = .{ .x = p2.x, .y = mid_y }, .b = p2 },
        };
        const zv_cross = countCrossings(&zv_segs, existing);

        // Pick best among all four candidates
        const best = bestOf4(la_cross, lb_cross, zh_cross, zv_cross);

        switch (best) {
            0 => try emitSegs(arena, wires, &la_segs, net),
            1 => try emitSegs(arena, wires, &lb_segs, net),
            2 => try emitSegs3(arena, wires, &zh_segs, net),
            3 => try emitSegs3(arena, wires, &zv_segs, net),
        }
        return;
    }

    // Pick the L-shape with fewer crossings
    if (la_cross <= lb_cross) {
        try emitSegs(arena, wires, &la_segs, net);
    } else {
        try emitSegs(arena, wires, &lb_segs, net);
    }
}

const Seg = struct { a: Point, b: Point };

fn emitSegs(arena: Allocator, wires: *List(RouteWire), segs: []const Seg, net: []const u8) !void {
    for (segs) |s| {
        if (s.a.x == s.b.x and s.a.y == s.b.y) continue;
        try wires.append(arena, .{ .x0 = s.a.x, .y0 = s.a.y, .x1 = s.b.x, .y1 = s.b.y, .net_name = net });
    }
}

fn emitSegs3(arena: Allocator, wires: *List(RouteWire), segs: []const Seg, net: []const u8) !void {
    for (segs) |s| {
        if (s.a.x == s.b.x and s.a.y == s.b.y) continue;
        try wires.append(arena, .{ .x0 = s.a.x, .y0 = s.a.y, .x1 = s.b.x, .y1 = s.b.y, .net_name = net });
    }
}

fn countCrossings(candidate: []const Seg, existing: []const RouteWire) u32 {
    var count: u32 = 0;
    for (candidate) |seg| {
        for (existing) |w| {
            if (segmentsCross(seg.a, seg.b, .{ .x = w.x0, .y = w.y0 }, .{ .x = w.x1, .y = w.y1 })) {
                count += 1;
            }
        }
    }
    return count;
}

fn bestOf4(a: u32, b: u32, c: u32, d: u32) u2 {
    var best: u2 = 0;
    var min = a;
    if (b < min) {
        min = b;
        best = 1;
    }
    if (c < min) {
        min = c;
        best = 2;
    }
    if (d < min) {
        best = 3;
    }
    return best;
}

// ── Crossing detection ──────────────────────────────────────────────────────

/// Check if two Manhattan (axis-aligned) segments cross.
/// An H segment crosses a V segment when their bounding ranges overlap
/// in both axes and they are perpendicular.
pub fn segmentsCross(a0: Point, a1: Point, b0: Point, b1: Point) bool {
    const a_horiz = (a0.y == a1.y);
    const a_vert = (a0.x == a1.x);
    const b_horiz = (b0.y == b1.y);
    const b_vert = (b0.x == b1.x);

    // Only perpendicular crossings count for Manhattan segments
    if (a_horiz and b_vert) {
        return hCrossesV(a0, a1, b0, b1);
    }
    if (a_vert and b_horiz) {
        return hCrossesV(b0, b1, a0, a1);
    }
    return false;
}

/// h0-h1 is horizontal, v0-v1 is vertical. Check if they cross.
fn hCrossesV(h0: Point, h1: Point, v0: Point, v1: Point) bool {
    const h_min_x = @min(h0.x, h1.x);
    const h_max_x = @max(h0.x, h1.x);
    const h_y = h0.y;

    const v_x = v0.x;
    const v_min_y = @min(v0.y, v1.y);
    const v_max_y = @max(v0.y, v1.y);

    // Strict interior crossing (not touching at endpoints)
    return v_x > h_min_x and v_x < h_max_x and
        h_y > v_min_y and h_y < v_max_y;
}

// ── Tests ───────────────────────────────────────────────────────────────────

test "route empty" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const result = try route(arena_state.allocator(), &.{}, &.{});
    try std.testing.expectEqual(@as(usize, 0), result.wires.len);
    try std.testing.expectEqual(@as(usize, 0), result.power.len);
}

test "pinPos — two terminal" {
    const placed = Layout.PlacedDevice{
        .elem_idx = 0,
        .x = 100,
        .y = -100,
        .orientation = .up,
        .kind = .resistor,
        .symbol = "res",
        .group = 0,
    };
    const p0 = pinPos(placed, 0).?;
    try std.testing.expectEqual(@as(i32, 100), p0.x);
    try std.testing.expectEqual(@as(i32, -130), p0.y);

    const p1 = pinPos(placed, 1).?;
    try std.testing.expectEqual(@as(i32, 100), p1.x);
    try std.testing.expectEqual(@as(i32, -70), p1.y);

    try std.testing.expect(pinPos(placed, 5) == null);
}

test "pinPos — nmos4 orientation up" {
    const placed = Layout.PlacedDevice{
        .elem_idx = 0,
        .x = 200,
        .y = 0,
        .orientation = .up,
        .kind = .nmos4,
        .symbol = "nmos4",
        .group = 0,
    };
    const d = pinPos(placed, 0).?;
    try std.testing.expectEqual(@as(i32, 220), d.x);
    try std.testing.expectEqual(@as(i32, -30), d.y);

    const g = pinPos(placed, 1).?;
    try std.testing.expectEqual(@as(i32, 180), g.x);
    try std.testing.expectEqual(@as(i32, 0), g.y);

    const s = pinPos(placed, 2).?;
    try std.testing.expectEqual(@as(i32, 220), s.x);
    try std.testing.expectEqual(@as(i32, 30), s.y);
}

test "pinPos — nmos4 orientation down" {
    const placed = Layout.PlacedDevice{
        .elem_idx = 0,
        .x = 200,
        .y = 0,
        .orientation = .down,
        .kind = .nmos4,
        .symbol = "nmos4",
        .group = 0,
    };
    // .down flips both axes: dx=-dx, dy=-dy
    const d = pinPos(placed, 0).?;
    try std.testing.expectEqual(@as(i32, 180), d.x); // 200 + (-20)
    try std.testing.expectEqual(@as(i32, 30), d.y); // 0 + 30

    const g = pinPos(placed, 1).?;
    try std.testing.expectEqual(@as(i32, 220), g.x); // 200 + 20
    try std.testing.expectEqual(@as(i32, 0), g.y); // 0 + 0
}

test "pinPos — pmos4 orientation up" {
    const placed = Layout.PlacedDevice{
        .elem_idx = 0,
        .x = 200,
        .y = 0,
        .orientation = .up,
        .kind = .pmos4,
        .symbol = "pmos4",
        .group = 0,
    };
    // PMOS drain is at bottom (+30), source at top (-30) in .up
    const d = pinPos(placed, 0).?;
    try std.testing.expectEqual(@as(i32, 220), d.x);
    try std.testing.expectEqual(@as(i32, 30), d.y);

    const s = pinPos(placed, 2).?;
    try std.testing.expectEqual(@as(i32, 220), s.x);
    try std.testing.expectEqual(@as(i32, -30), s.y);
}

test "route — simple two-element net" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const n1 = try arena.dupe([]const u8, &.{ "mid", "0" });
    const n2 = try arena.dupe([]const u8, &.{ "mid", "0" });
    const elements = [_]parser.Element{
        .{ .prefix = 'r', .name = "R1", .nodes = n1, .value = "1k" },
        .{ .prefix = 'r', .name = "R2", .nodes = n2, .value = "2k" },
    };
    const placed = [_]Layout.PlacedDevice{
        .{ .elem_idx = 0, .x = 0, .y = 0, .orientation = .up, .kind = .resistor, .symbol = "res", .group = 0 },
        .{ .elem_idx = 1, .x = 200, .y = 0, .orientation = .up, .kind = .resistor, .symbol = "res", .group = 0 },
    };

    const result = try route(arena, &elements, &placed);

    // "mid" net connects R1 pin0 to R2 pin0 — should produce wire(s)
    try std.testing.expect(result.wires.len > 0);

    // "0" is GND — should produce power symbols, not wires
    try std.testing.expect(result.power.len > 0);

    // All power symbols should be gnd
    for (result.power) |ps| {
        try std.testing.expectEqual(PowerKind.gnd, ps.kind);
    }
}

test "route — power nets get symbols not wires" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const n1 = try arena.dupe([]const u8, &.{ "vdd", "0" });
    const n2 = try arena.dupe([]const u8, &.{ "vdd", "0" });
    const elements = [_]parser.Element{
        .{ .prefix = 'r', .name = "R1", .nodes = n1, .value = "1k" },
        .{ .prefix = 'r', .name = "R2", .nodes = n2, .value = "2k" },
    };
    const placed = [_]Layout.PlacedDevice{
        .{ .elem_idx = 0, .x = 0, .y = 0, .orientation = .up, .kind = .resistor, .symbol = "res", .group = 0 },
        .{ .elem_idx = 1, .x = 200, .y = 0, .orientation = .up, .kind = .resistor, .symbol = "res", .group = 0 },
    };

    const result = try route(arena, &elements, &placed);

    // Both nets are power — no signal wires should be emitted
    try std.testing.expectEqual(@as(usize, 0), result.wires.len);

    // Should have power symbols for both VDD and GND pins
    try std.testing.expect(result.power.len > 0);

    var has_vdd = false;
    var has_gnd = false;
    for (result.power) |ps| {
        if (ps.kind == .vdd) has_vdd = true;
        if (ps.kind == .gnd) has_gnd = true;
    }
    try std.testing.expect(has_vdd);
    try std.testing.expect(has_gnd);
}

test "segmentsCross — orthogonal crossing" {
    // Horizontal from (0,0)→(100,0) crosses vertical from (50,-50)→(50,50)
    try std.testing.expect(segmentsCross(
        .{ .x = 0, .y = 0 },
        .{ .x = 100, .y = 0 },
        .{ .x = 50, .y = -50 },
        .{ .x = 50, .y = 50 },
    ));
}

test "segmentsCross — parallel no crossing" {
    // Two horizontal segments at different y
    try std.testing.expect(!segmentsCross(
        .{ .x = 0, .y = 0 },
        .{ .x = 100, .y = 0 },
        .{ .x = 0, .y = 10 },
        .{ .x = 100, .y = 10 },
    ));

    // Two horizontal segments at same y (collinear, not crossing)
    try std.testing.expect(!segmentsCross(
        .{ .x = 0, .y = 0 },
        .{ .x = 100, .y = 0 },
        .{ .x = 50, .y = 0 },
        .{ .x = 150, .y = 0 },
    ));
}

test "segmentsCross — T junction not counted" {
    // Endpoint touching is not a crossing (strict interior)
    try std.testing.expect(!segmentsCross(
        .{ .x = 0, .y = 0 },
        .{ .x = 100, .y = 0 },
        .{ .x = 100, .y = -50 },
        .{ .x = 100, .y = 50 },
    ));
}

test "segmentsCross — no overlap" {
    // Perpendicular but not overlapping
    try std.testing.expect(!segmentsCross(
        .{ .x = 0, .y = 0 },
        .{ .x = 100, .y = 0 },
        .{ .x = 50, .y = 10 },
        .{ .x = 50, .y = 50 },
    ));
}

test "rotateOffset — all orientations" {
    const base = PinOff{ .dx = 20, .dy = -30 };

    const up = rotateOffset(base, .up);
    try std.testing.expectEqual(@as(i32, 20), up.dx);
    try std.testing.expectEqual(@as(i32, -30), up.dy);

    const down = rotateOffset(base, .down);
    try std.testing.expectEqual(@as(i32, -20), down.dx);
    try std.testing.expectEqual(@as(i32, 30), down.dy);

    const left = rotateOffset(base, .left);
    try std.testing.expectEqual(@as(i32, -30), left.dx);
    try std.testing.expectEqual(@as(i32, -20), left.dy);

    const right = rotateOffset(base, .right);
    try std.testing.expectEqual(@as(i32, 30), right.dx);
    try std.testing.expectEqual(@as(i32, 20), right.dy);
}
