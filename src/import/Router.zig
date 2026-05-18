// Router.zig — Obstacle-aware Manhattan wire router.
//
// Pipeline:
//   1. Build obstacle rects from placed device bounding boxes (inflated by margin)
//   2. Build net -> [(elem_idx, node_idx)] map from elements
//   3. Sort nets by estimated wire length (shortest first), power nets last
//   4. For each net:
//      a. Power nets → place symbols and skip wiring
//      b. Signal nets → MST (Prim's) over pin positions
//      c. Each MST edge → pick best among L/Z candidates scored by:
//         - obstacle intersections (heavy penalty)
//         - wire-wire crossings with other nets
//         - collinear overlap with other-net wires (prevents T-junction merges)
//      d. If all candidates hit obstacles → route around bbox edges
//
// Complexity: O(n² * w) for n pins and w existing wires + o obstacles.

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

// ── Obstacle rect ───────────────────────────────────────────────────────────

const Rect = struct {
    x0: i32,
    y0: i32,
    x1: i32,
    y1: i32,
};

/// Margin around device bounding boxes for wire clearance.
const OBS_MARGIN: i32 = 5;

fn buildObstacles(arena: Allocator, placed: []const Layout.PlacedDevice) ![]const Rect {
    var rects: List(Rect) = .{};
    for (placed) |p| {
        const bb = Layout.bboxForKind(p.kind);
        const rot = rotatedBBox(bb, p.orientation);
        try rects.append(arena, .{
            .x0 = p.x + rot.min_x - OBS_MARGIN,
            .y0 = p.y + rot.min_y - OBS_MARGIN,
            .x1 = p.x + rot.max_x + OBS_MARGIN,
            .y1 = p.y + rot.max_y + OBS_MARGIN,
        });
    }
    return rects.items;
}

fn rotatedBBox(bb: Layout.BBox, orient: Layout.Orientation) Layout.BBox {
    return switch (orient) {
        .up => bb,
        .down => .{ .min_x = -bb.max_x, .min_y = -bb.max_y, .max_x = -bb.min_x, .max_y = -bb.min_y },
        .left => .{ .min_x = bb.min_y, .min_y = -bb.max_x, .max_x = bb.max_y, .max_y = -bb.min_x },
        .right => .{ .min_x = -bb.max_y, .min_y = bb.min_x, .max_x = -bb.min_y, .max_y = bb.max_x },
    };
}

// ── Pin offset tables ───────────────────────────────────────────────────────

const PinOff = struct { dx: i32, dy: i32 };

const TWO_TERM = [_]PinOff{
    .{ .dx = 0, .dy = -30 },
    .{ .dx = 0, .dy = 30 },
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
    .{ .dx = 20, .dy = -30 },
    .{ .dx = -20, .dy = 0 },
    .{ .dx = 20, .dy = 30 },
};

const JFET_P_PINS = [_]PinOff{
    .{ .dx = 20, .dy = 30 },
    .{ .dx = -20, .dy = 0 },
    .{ .dx = 20, .dy = -30 },
};

const FOUR_TERM_CTRL = [_]PinOff{
    .{ .dx = 0, .dy = -30 },
    .{ .dx = 0, .dy = 30 },
    .{ .dx = -30, .dy = -30 },
    .{ .dx = -30, .dy = 30 },
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

/// Dynamic pin position for subcircuit/digital instances with N pins.
/// Pins at x=0, evenly spaced 20px apart, centered vertically.
pub fn pinPosN(placed: Layout.PlacedDevice, node_idx: usize, total_pins: usize) ?Point {
    const offs = basePinOffsets(placed.kind);
    // Use static offsets when they cover all pins
    if (total_pins <= offs.len) return pinPos(placed, node_idx);
    // For devices with more pins than static table: use all-dynamic positions
    if (node_idx >= total_pins) return null;
    const i: i32 = @intCast(node_idx);
    const n: i32 = @intCast(total_pins);
    const spacing: i32 = 20;
    const base = PinOff{ .dx = 0, .dy = i * spacing - (n - 1) * @divTrunc(spacing, 2) };
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

    // Build obstacle rects from device bounding boxes
    const obstacles = try buildObstacles(arena, placed);

    // Collect all pin positions for T-junction avoidance
    var all_pins_list: List(Point) = .{};
    for (placed) |p| {
        const n_pins = elements[p.elem_idx].nodes.len;
        for (0..n_pins) |i| {
            if (pinPosN(p, i, n_pins)) |pos| {
                try all_pins_list.append(arena, pos);
            }
        }
    }
    const all_pins = all_pins_list.items;

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
            est = estimateNetLength(pins, placed, &idx_map, elements);
        }

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
                if (resolvePinPos(pin, placed, &idx_map, elements)) |pos| {
                    try power.append(arena, .{ .kind = .gnd, .x = pos.x, .y = pos.y + 10 });
                }
            }
            continue;
        }

        if (Layout.isVddNet(net.name)) {
            for (net.pins) |pin| {
                if (resolvePinPos(pin, placed, &idx_map, elements)) |pos| {
                    try power.append(arena, .{ .kind = .vdd, .x = pos.x, .y = pos.y - 10 });
                }
            }
            continue;
        }

        var pts: List(Point) = .{};
        for (net.pins) |pin| {
            if (resolvePinPos(pin, placed, &idx_map, elements)) |pos| {
                try pts.append(arena, pos);
            }
        }
        if (pts.items.len < 2) continue;

        try routeNetMst(arena, &wires, pts.items, net.name, obstacles, all_pins);
    }

    // Post-routing fixup: nudge wire corners that share positions with other-net wire endpoints.
    // This prevents connectivity union-find from merging different nets via shared pointKeys.
    fixupEndpointCollisions(wires.items, all_pins);

    // Deduplicate power symbols within proximity
    var deduped: List(PowerSym) = .{};
    for (power.items) |ps| {
        var dup = false;
        for (deduped.items) |existing| {
            if (existing.kind == ps.kind) {
                const dx = abs32(existing.x - ps.x);
                const dy = abs32(existing.y - ps.y);
                if (dx < 30 and dy < 30) {
                    dup = true;
                    break;
                }
            }
        }
        if (!dup) {
            try deduped.append(arena, ps);
        }
    }


    return .{
        .wires = wires.items,
        .power = deduped.items,
    };
}

fn resolvePinPos(
    pin: PinRef,
    placed: []const Layout.PlacedDevice,
    idx_map: *const std.AutoHashMapUnmanaged(u32, u32),
    elements: []const parser.Element,
) ?Point {
    const pi = idx_map.get(pin.elem_idx) orelse return null;
    const n_pins = elements[pin.elem_idx].nodes.len;
    return pinPosN(placed[pi], pin.node_idx, n_pins);
}

fn estimateNetLength(
    pins: []const PinRef,
    placed: []const Layout.PlacedDevice,
    idx_map: *const std.AutoHashMapUnmanaged(u32, u32),
    elements: []const parser.Element,
) i64 {
    var min_x: i32 = std.math.maxInt(i32);
    var max_x: i32 = std.math.minInt(i32);
    var min_y: i32 = std.math.maxInt(i32);
    var max_y: i32 = std.math.minInt(i32);
    var count: usize = 0;

    for (pins) |pin| {
        if (resolvePinPos(pin, placed, idx_map, elements)) |pos| {
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
    obstacles: []const Rect,
    all_pins: []const Point,
) !void {
    const n = pts.len;
    if (n < 2) return;

    const in_tree = try arena.alloc(bool, n);
    @memset(in_tree, false);
    const key = try arena.alloc(i64, n);
    @memset(key, std.math.maxInt(i64));
    const parent = try arena.alloc(usize, n);
    @memset(parent, std.math.maxInt(usize));

    key[0] = 0;

    for (0..n) |_| {
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

        for (0..n) |v| {
            if (in_tree[v]) continue;
            const dist = manhattan(pts[u], pts[v]);
            if (dist < key[v]) {
                key[v] = dist;
                parent[v] = u;
            }
        }
    }

    const existing_start = wires.items.len;
    for (1..n) |i| {
        if (parent[i] == std.math.maxInt(usize)) continue;
        const p1 = pts[parent[i]];
        const p2 = pts[i];
        try routeEdge(arena, wires, p1, p2, net, existing_start, obstacles, all_pins);
    }
}

fn manhattan(a: Point, b: Point) i64 {
    const dx: i64 = abs64(@as(i64, a.x) - @as(i64, b.x));
    const dy: i64 = abs64(@as(i64, a.y) - @as(i64, b.y));
    return dx + dy;
}

// ── Edge routing with obstacle avoidance ────────────────────────────────────

const MIN_STUB: i32 = Layout.SNAP;

/// Weight for obstacle hits vs wire crossings. Obstacle hits are much worse.
const OBS_PENALTY: u32 = 100;

/// Weight for collinear overlap with existing wires (prevents T-junction merges).
const OVERLAP_PENALTY: u32 = 50;

/// Weight for passing through an unrelated pin (causes T-junction net merges).
const PIN_PENALTY: u32 = 500;

fn routeEdge(
    arena: Allocator,
    wires: *List(RouteWire),
    p1: Point,
    p2: Point,
    net: []const u8,
    existing_start: usize,
    obstacles: []const Rect,
    all_pins: []const Point,
) !void {
    if (p1.x == p2.x and p1.y == p2.y) return;

    const existing = wires.items[0..existing_start];
    const is_aligned = (p1.x == p2.x or p1.y == p2.y);

    // Generate candidates. Start with straight line if axis-aligned.
    const score = struct {
        fn s(candidate: []const Seg, existing_w: []const RouteWire, obs: []const Rect, ep1: Point, ep2: Point, pins: []const Point) u32 {
            return scoreCandidateExcluding(candidate, existing_w, obs, ep1, ep2, pins);
        }
    }.s;

    const straight = [1]Seg{.{ .a = p1, .b = p2 }};
    const straight_score: u32 = if (is_aligned) score(&straight, existing, obstacles, p1, p2, all_pins) else std.math.maxInt(u32);

    // Straight line with no obstacle hits — emit directly
    if (is_aligned and straight_score == 0) {
        try wires.append(arena, .{ .x0 = p1.x, .y0 = p1.y, .x1 = p2.x, .y1 = p2.y, .net_name = net });
        return;
    }

    const mid_x = snapToGrid(@divTrunc(p1.x + p2.x, 2));
    const mid_y = snapToGrid(@divTrunc(p1.y + p2.y, 2));

    const la = [2]Seg{
        .{ .a = p1, .b = .{ .x = p2.x, .y = p1.y } },
        .{ .a = .{ .x = p2.x, .y = p1.y }, .b = p2 },
    };
    const lb = [2]Seg{
        .{ .a = p1, .b = .{ .x = p1.x, .y = p2.y } },
        .{ .a = .{ .x = p1.x, .y = p2.y }, .b = p2 },
    };
    const zh = [3]Seg{
        .{ .a = p1, .b = .{ .x = mid_x, .y = p1.y } },
        .{ .a = .{ .x = mid_x, .y = p1.y }, .b = .{ .x = mid_x, .y = p2.y } },
        .{ .a = .{ .x = mid_x, .y = p2.y }, .b = p2 },
    };
    const zv = [3]Seg{
        .{ .a = p1, .b = .{ .x = p1.x, .y = mid_y } },
        .{ .a = .{ .x = p1.x, .y = mid_y }, .b = .{ .x = p2.x, .y = mid_y } },
        .{ .a = .{ .x = p2.x, .y = mid_y }, .b = p2 },
    };

    const la_score = score(&la, existing, obstacles, p1, p2, all_pins);
    const lb_score = score(&lb, existing, obstacles, p1, p2, all_pins);
    const zh_score = score(&zh, existing, obstacles, p1, p2, all_pins);
    const zv_score = score(&zv, existing, obstacles, p1, p2, all_pins);

    var best_score = straight_score;
    var best: u8 = 4;
    if (!is_aligned) { best_score = la_score; best = 0; }
    if (la_score < best_score) { best_score = la_score; best = 0; }
    if (lb_score < best_score) { best_score = lb_score; best = 1; }
    if (zh_score < best_score) { best_score = zh_score; best = 2; }
    if (zv_score < best_score) { best_score = zv_score; best = 3; }

    // If best candidate has any collision penalty, try routing around
    if (best_score > 0) {
        if (try routeAroundObstacles(arena, wires, p1, p2, net, existing, obstacles, all_pins, best_score)) return;
    }

    switch (best) {
        0 => try emitSegs(arena, wires, &la, net),
        1 => try emitSegs(arena, wires, &lb, net),
        2 => try emitSegs(arena, wires, &zh, net),
        3 => try emitSegs(arena, wires, &zv, net),
        4 => try wires.append(arena, .{ .x0 = p1.x, .y0 = p1.y, .x1 = p2.x, .y1 = p2.y, .net_name = net }),
        else => unreachable,
    }
}

// ── Obstacle-aware route-around ─────────────────────────────────────────────

/// Try routing around obstacles using bbox edge waypoints.
/// Returns true if a valid route was found and emitted.
fn routeAroundObstacles(
    arena: Allocator,
    wires: *List(RouteWire),
    p1: Point,
    p2: Point,
    net: []const u8,
    existing: []const RouteWire,
    obstacles: []const Rect,
    all_pins: []const Point,
    caller_best: u32,
) !bool {
    // Collect obstacle rects that lie between p1 and p2
    const region = Rect{
        .x0 = @min(p1.x, p2.x) - Layout.SNAP,
        .y0 = @min(p1.y, p2.y) - Layout.SNAP,
        .x1 = @max(p1.x, p2.x) + Layout.SNAP,
        .y1 = @max(p1.y, p2.y) + Layout.SNAP,
    };

    // Generate waypoint candidates from obstacle corners (with margin)
    const WP_MARGIN: i32 = Layout.SNAP;
    var waypoints: List(Point) = .{};

    for (obstacles) |obs| {
        if (!rectsOverlap(obs, region)) continue;

        // 4 corners of inflated obstacle
        const corners = [4]Point{
            .{ .x = obs.x0 - WP_MARGIN, .y = obs.y0 - WP_MARGIN },
            .{ .x = obs.x1 + WP_MARGIN, .y = obs.y0 - WP_MARGIN },
            .{ .x = obs.x0 - WP_MARGIN, .y = obs.y1 + WP_MARGIN },
            .{ .x = obs.x1 + WP_MARGIN, .y = obs.y1 + WP_MARGIN },
        };
        for (&corners) |c| {
            const snapped = Point{ .x = snapToGrid(c.x), .y = snapToGrid(c.y) };
            try waypoints.append(arena, snapped);
        }
    }

    // Pin-dodge waypoints: for each pin in the region, add offset positions
    // This ensures detours exist even when pins aren't near obstacle corners
    const DODGE: i32 = 2 * Layout.SNAP;
    for (all_pins) |pin| {
        if (pin.x >= region.x0 and pin.x <= region.x1 and
            pin.y >= region.y0 and pin.y <= region.y1)
        {
            // Skip p1/p2 themselves
            if (pin.x == p1.x and pin.y == p1.y) continue;
            if (pin.x == p2.x and pin.y == p2.y) continue;
            const offsets = [4]Point{
                .{ .x = pin.x - DODGE, .y = pin.y },
                .{ .x = pin.x + DODGE, .y = pin.y },
                .{ .x = pin.x, .y = pin.y - DODGE },
                .{ .x = pin.x, .y = pin.y + DODGE },
            };
            for (&offsets) |o| {
                try waypoints.append(arena, .{ .x = snapToGrid(o.x), .y = snapToGrid(o.y) });
            }
        }
    }

    // Endpoint-dodge waypoints: offset from existing wire endpoints in the region
    // to avoid corner-endpoint coincidence (which causes union-find merges)
    for (existing) |w| {
        const eps = [2]Point{
            .{ .x = w.x0, .y = w.y0 },
            .{ .x = w.x1, .y = w.y1 },
        };
        for (&eps) |ep| {
            if (ep.x >= region.x0 and ep.x <= region.x1 and
                ep.y >= region.y0 and ep.y <= region.y1)
            {
                if (ep.x == p1.x and ep.y == p1.y) continue;
                if (ep.x == p2.x and ep.y == p2.y) continue;
                const nudge = Layout.SNAP;
                const offsets = [4]Point{
                    .{ .x = ep.x - nudge, .y = ep.y },
                    .{ .x = ep.x + nudge, .y = ep.y },
                    .{ .x = ep.x, .y = ep.y - nudge },
                    .{ .x = ep.x, .y = ep.y + nudge },
                };
                for (&offsets) |o| {
                    try waypoints.append(arena, .{ .x = snapToGrid(o.x), .y = snapToGrid(o.y) });
                }
            }
        }
    }

    if (waypoints.items.len == 0) return false;

    // Try each waypoint as a single intermediate point (greedy 2-bend route)
    var best_segs: [4]Seg = undefined;
    var best_seg_count: usize = 0;
    var best_wp_score: u32 = std.math.maxInt(u32);

    for (waypoints.items) |wp| {
        // Route p1 -> wp -> p2, each leg as L-shape picking better orientation
        const leg1_a = [2]Seg{
            .{ .a = p1, .b = .{ .x = wp.x, .y = p1.y } },
            .{ .a = .{ .x = wp.x, .y = p1.y }, .b = wp },
        };
        const leg1_b = [2]Seg{
            .{ .a = p1, .b = .{ .x = p1.x, .y = wp.y } },
            .{ .a = .{ .x = p1.x, .y = wp.y }, .b = wp },
        };
        const leg2_a = [2]Seg{
            .{ .a = wp, .b = .{ .x = p2.x, .y = wp.y } },
            .{ .a = .{ .x = p2.x, .y = wp.y }, .b = p2 },
        };
        const leg2_b = [2]Seg{
            .{ .a = wp, .b = .{ .x = wp.x, .y = p2.y } },
            .{ .a = .{ .x = wp.x, .y = p2.y }, .b = p2 },
        };

        // Try all 4 combinations of leg orientations
        const combos = [4][2]u8{ .{ 0, 0 }, .{ 0, 1 }, .{ 1, 0 }, .{ 1, 1 } };
        for (&combos) |combo| {
            var segs: [4]Seg = undefined;
            if (combo[0] == 0) {
                segs[0] = leg1_a[0];
                segs[1] = leg1_a[1];
            } else {
                segs[0] = leg1_b[0];
                segs[1] = leg1_b[1];
            }
            if (combo[1] == 0) {
                segs[2] = leg2_a[0];
                segs[3] = leg2_a[1];
            } else {
                segs[2] = leg2_b[0];
                segs[3] = leg2_b[1];
            }

            const wp_score = scoreCandidateExcluding(&segs, existing, obstacles, p1, p2, all_pins);
            if (wp_score < best_wp_score) {
                best_wp_score = wp_score;
                best_segs = segs;
                best_seg_count = 4;
            }
        }

        // Also try straight-line legs if aligned
        if (p1.x == wp.x or p1.y == wp.y) {
            const straight1 = Seg{ .a = p1, .b = wp };
            if (wp.x == p2.x or wp.y == p2.y) {
                const straight2 = Seg{ .a = wp, .b = p2 };
                const two = [2]Seg{ straight1, straight2 };
                const two_score = scoreCandidateExcluding(&two, existing, obstacles, p1, p2, all_pins);
                if (two_score < best_wp_score) {
                    best_wp_score = two_score;
                    best_segs[0] = two[0];
                    best_segs[1] = two[1];
                    best_seg_count = 2;
                }
            }
        }
    }

    // Accept waypoint route if it's strictly better than the caller's best candidate
    if (best_seg_count > 0 and best_wp_score < caller_best) {
        try emitSegs(arena, wires, best_segs[0..best_seg_count], net);
        return true;
    }

    return false;
}

// ── Post-routing endpoint collision fixup ────────────────────────────────────

/// Detect wire endpoints from different nets sharing the same position and nudge
/// corner endpoints to eliminate the collision. Pin positions are never nudged.
fn fixupEndpointCollisions(wires: []RouteWire, all_pins: []const Point) void {
    const NUDGE: i32 = Layout.SNAP;

    // For each wire endpoint, check if any other-net wire has an endpoint at the same position.
    // If so, and this endpoint is NOT a pin position (i.e., it's a bend/corner), nudge it.
    for (wires, 0..) |*w, wi| {
        for (0..2) |ep_idx| {
            const ex = if (ep_idx == 0) w.x0 else w.x1;
            const ey = if (ep_idx == 0) w.y0 else w.y1;

            // Skip if this is a pin position (fixed, can't nudge)
            var is_pin = false;
            for (all_pins) |pin| {
                if (pin.x == ex and pin.y == ey) {
                    is_pin = true;
                    break;
                }
            }
            if (is_pin) continue;

            // Check if any other-net wire has an endpoint at this position
            var conflict = false;
            for (wires, 0..) |other, oi| {
                if (oi == wi) continue;
                if (std.mem.eql(u8, w.net_name, other.net_name)) continue;
                if ((other.x0 == ex and other.y0 == ey) or (other.x1 == ex and other.y1 == ey)) {
                    conflict = true;
                    break;
                }
            }
            if (!conflict) continue;

            // Nudge this corner endpoint. Pick direction based on wire orientation.
            const other_x = if (ep_idx == 0) w.x1 else w.x0;

            var nx = ex;
            var ny = ey;
            if (ex == other_x) {
                // Vertical wire → nudge horizontally
                nx = ex + NUDGE;
            } else {
                // Horizontal wire → nudge vertically
                ny = ey + NUDGE;
            }

            // Apply nudge and also update any same-net wire that shares this corner
            for (wires) |*sw| {
                if (!std.mem.eql(u8, sw.net_name, w.net_name)) continue;
                if (sw.x0 == ex and sw.y0 == ey) { sw.x0 = nx; sw.y0 = ny; }
                if (sw.x1 == ex and sw.y1 == ey) { sw.x1 = nx; sw.y1 = ny; }
            }
        }
    }
}

// ── Scoring ─────────────────────────────────────────────────────────────────

fn scoreCandidate(candidate: []const Seg, existing: []const RouteWire, obstacles: []const Rect) u32 {
    return scoreCandidateExcluding(candidate, existing, obstacles, null, null, &.{});
}

fn scoreCandidateExcluding(
    candidate: []const Seg,
    existing: []const RouteWire,
    obstacles: []const Rect,
    exclude_p1: ?Point,
    exclude_p2: ?Point,
    all_pins: []const Point,
) u32 {
    var score: u32 = 0;

    for (candidate) |seg| {
        if (seg.a.x == seg.b.x and seg.a.y == seg.b.y) continue;

        for (obstacles) |obs| {
            // Skip obstacles that contain the source or destination pin
            if (exclude_p1) |ep| {
                if (ep.x >= obs.x0 and ep.x <= obs.x1 and ep.y >= obs.y0 and ep.y <= obs.y1) continue;
            }
            if (exclude_p2) |ep| {
                if (ep.x >= obs.x0 and ep.x <= obs.x1 and ep.y >= obs.y0 and ep.y <= obs.y1) continue;
            }
            if (segIntersectsRect(seg, obs)) score += OBS_PENALTY;
        }

        for (existing) |w| {
            if (segmentsCross(seg.a, seg.b, .{ .x = w.x0, .y = w.y0 }, .{ .x = w.x1, .y = w.y1 })) {
                score += 1;
            }
        }

        for (existing) |w| {
            if (segmentsOverlapCollinear(seg.a, seg.b, .{ .x = w.x0, .y = w.y0 }, .{ .x = w.x1, .y = w.y1 })) {
                score += OVERLAP_PENALTY;
            }
        }

        // Penalize passing through unrelated pins (causes T-junction net merges)
        for (all_pins) |pin| {
            // Skip the endpoints of this edge — those are the intended connections
            if (exclude_p1) |ep| {
                if (pin.x == ep.x and pin.y == ep.y) continue;
            }
            if (exclude_p2) |ep| {
                if (pin.x == ep.x and pin.y == ep.y) continue;
            }
            if (pointOnSegInterior(pin, seg)) score += PIN_PENALTY;
        }

        // (A) Penalize existing wire endpoints landing on candidate interior
        // This catches route corners from previous nets creating T-junctions
        for (existing) |w| {
            const ep0 = Point{ .x = w.x0, .y = w.y0 };
            const ep1 = Point{ .x = w.x1, .y = w.y1 };
            if (pointOnSegInterior(ep0, seg)) score += PIN_PENALTY;
            if (pointOnSegInterior(ep1, seg)) score += PIN_PENALTY;
        }
    }

    // (B) Penalize candidate intermediate points landing on existing wire interiors
    // or coinciding with device pin positions (causes union in connectivity step 3)
    if (candidate.len > 1) {
        for (candidate[0 .. candidate.len - 1]) |seg| {
            const mid_pt = seg.b;
            // Skip if this is actually p1 or p2
            if (exclude_p1) |ep| {
                if (mid_pt.x == ep.x and mid_pt.y == ep.y) continue;
            }
            if (exclude_p2) |ep| {
                if (mid_pt.x == ep.x and mid_pt.y == ep.y) continue;
            }
            for (existing) |w| {
                const wa = Point{ .x = w.x0, .y = w.y0 };
                const wb = Point{ .x = w.x1, .y = w.y1 };
                if (pointOnSegInterior(mid_pt, .{ .a = wa, .b = wb })) {
                    score += PIN_PENALTY;
                }
                // Corner coinciding with existing wire endpoint → connectivity merges via shared pointKey
                if (mid_pt.x == wa.x and mid_pt.y == wa.y) score += PIN_PENALTY;
                if (mid_pt.x == wb.x and mid_pt.y == wb.y) score += PIN_PENALTY;
            }
            // Penalize corner landing on a device pin position
            for (all_pins) |pin| {
                if (exclude_p1) |ep| {
                    if (pin.x == ep.x and pin.y == ep.y) continue;
                }
                if (exclude_p2) |ep| {
                    if (pin.x == ep.x and pin.y == ep.y) continue;
                }
                if (mid_pt.x == pin.x and mid_pt.y == pin.y) {
                    score += PIN_PENALTY;
                }
            }
        }
    }

    return score;
}

// ── Segment-rect intersection ───────────────────────────────────────────────

/// Check if an axis-aligned segment passes through the strict interior of a rect.
fn segIntersectsRect(seg: Seg, rect: Rect) bool {
    const is_h = (seg.a.y == seg.b.y);
    const is_v = (seg.a.x == seg.b.x);

    if (is_h) {
        const y = seg.a.y;
        if (y <= rect.y0 or y >= rect.y1) return false;
        const sx0 = @min(seg.a.x, seg.b.x);
        const sx1 = @max(seg.a.x, seg.b.x);
        return sx0 < rect.x1 and sx1 > rect.x0;
    }

    if (is_v) {
        const x = seg.a.x;
        if (x <= rect.x0 or x >= rect.x1) return false;
        const sy0 = @min(seg.a.y, seg.b.y);
        const sy1 = @max(seg.a.y, seg.b.y);
        return sy0 < rect.y1 and sy1 > rect.y0;
    }

    return false;
}

// ── Collinear overlap detection ─────────────────────────────────────────────

/// Check if two axis-aligned segments share a collinear overlap region.
/// This would cause a T-junction merge in connectivity if a third wire
/// endpoint lands on the overlapping region.
fn segmentsOverlapCollinear(a0: Point, a1: Point, b0: Point, b1: Point) bool {
    const a_horiz = (a0.y == a1.y);
    const a_vert = (a0.x == a1.x);
    const b_horiz = (b0.y == b1.y);
    const b_vert = (b0.x == b1.x);

    if (a_horiz and b_horiz and a0.y == b0.y) {
        const a_min = @min(a0.x, a1.x);
        const a_max = @max(a0.x, a1.x);
        const b_min = @min(b0.x, b1.x);
        const b_max = @max(b0.x, b1.x);
        return a_min < b_max and b_min < a_max;
    }

    if (a_vert and b_vert and a0.x == b0.x) {
        const a_min = @min(a0.y, a1.y);
        const a_max = @max(a0.y, a1.y);
        const b_min = @min(b0.y, b1.y);
        const b_max = @max(b0.y, b1.y);
        return a_min < b_max and b_min < a_max;
    }

    return false;
}

// ── Helpers ─────────────────────────────────────────────────────────────────

const Seg = struct { a: Point, b: Point };

fn emitSegs(arena: Allocator, wires: *List(RouteWire), segs: []const Seg, net: []const u8) !void {
    for (segs) |s| {
        if (s.a.x == s.b.x and s.a.y == s.b.y) continue;
        try wires.append(arena, .{ .x0 = s.a.x, .y0 = s.a.y, .x1 = s.b.x, .y1 = s.b.y, .net_name = net });
    }
}

fn snapToGrid(v: i32) i32 {
    const s = Layout.SNAP;
    if (v >= 0) {
        return @divTrunc(v + @divTrunc(s, 2), s) * s;
    } else {
        return @divTrunc(v - @divTrunc(s, 2), s) * s;
    }
}

fn abs32(v: i32) i32 {
    return if (v < 0) -v else v;
}

fn abs64(v: i64) i64 {
    return if (v < 0) -v else v;
}

fn rectsOverlap(a: Rect, b: Rect) bool {
    return a.x0 < b.x1 and a.x1 > b.x0 and a.y0 < b.y1 and a.y1 > b.y0;
}

/// Returns true if `pt` lies strictly in the interior of axis-aligned segment (not at endpoints).
fn pointOnSegInterior(pt: Point, seg: Seg) bool {
    if (seg.a.x == seg.b.x and seg.a.y == seg.b.y) return false;
    if (seg.a.x == seg.b.x and pt.x == seg.a.x) {
        // Vertical segment
        const min_y = @min(seg.a.y, seg.b.y);
        const max_y = @max(seg.a.y, seg.b.y);
        return pt.y > min_y and pt.y < max_y;
    }
    if (seg.a.y == seg.b.y and pt.y == seg.a.y) {
        // Horizontal segment
        const min_x = @min(seg.a.x, seg.b.x);
        const max_x = @max(seg.a.x, seg.b.x);
        return pt.x > min_x and pt.x < max_x;
    }
    return false;
}

// ── Crossing detection ──────────────────────────────────────────────────────

pub fn segmentsCross(a0: Point, a1: Point, b0: Point, b1: Point) bool {
    const a_horiz = (a0.y == a1.y);
    const a_vert = (a0.x == a1.x);
    const b_horiz = (b0.y == b1.y);
    const b_vert = (b0.x == b1.x);

    if (a_horiz and b_vert) {
        return hCrossesV(a0, a1, b0, b1);
    }
    if (a_vert and b_horiz) {
        return hCrossesV(b0, b1, a0, a1);
    }
    return false;
}

fn hCrossesV(h0: Point, h1: Point, v0: Point, v1: Point) bool {
    const h_min_x = @min(h0.x, h1.x);
    const h_max_x = @max(h0.x, h1.x);
    const h_y = h0.y;

    const v_x = v0.x;
    const v_min_y = @min(v0.y, v1.y);
    const v_max_y = @max(v0.y, v1.y);

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
    const d = pinPos(placed, 0).?;
    try std.testing.expectEqual(@as(i32, 180), d.x);
    try std.testing.expectEqual(@as(i32, 30), d.y);

    const g = pinPos(placed, 1).?;
    try std.testing.expectEqual(@as(i32, 220), g.x);
    try std.testing.expectEqual(@as(i32, 0), g.y);
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

    try std.testing.expect(result.wires.len > 0);
    try std.testing.expect(result.power.len > 0);

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

    try std.testing.expectEqual(@as(usize, 0), result.wires.len);
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
    try std.testing.expect(segmentsCross(
        .{ .x = 0, .y = 0 },
        .{ .x = 100, .y = 0 },
        .{ .x = 50, .y = -50 },
        .{ .x = 50, .y = 50 },
    ));
}

test "segmentsCross — parallel no crossing" {
    try std.testing.expect(!segmentsCross(
        .{ .x = 0, .y = 0 },
        .{ .x = 100, .y = 0 },
        .{ .x = 0, .y = 10 },
        .{ .x = 100, .y = 10 },
    ));

    try std.testing.expect(!segmentsCross(
        .{ .x = 0, .y = 0 },
        .{ .x = 100, .y = 0 },
        .{ .x = 50, .y = 0 },
        .{ .x = 150, .y = 0 },
    ));
}

test "segmentsCross — T junction not counted" {
    try std.testing.expect(!segmentsCross(
        .{ .x = 0, .y = 0 },
        .{ .x = 100, .y = 0 },
        .{ .x = 100, .y = -50 },
        .{ .x = 100, .y = 50 },
    ));
}

test "segmentsCross — no overlap" {
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

test "segIntersectsRect — horizontal through rect" {
    const rect = Rect{ .x0 = 10, .y0 = -20, .x1 = 50, .y1 = 20 };
    // Horizontal seg at y=0 from x=0 to x=60 passes through rect
    const seg = Seg{ .a = .{ .x = 0, .y = 0 }, .b = .{ .x = 60, .y = 0 } };
    try std.testing.expect(segIntersectsRect(seg, rect));
}

test "segIntersectsRect — horizontal above rect" {
    const rect = Rect{ .x0 = 10, .y0 = -20, .x1 = 50, .y1 = 20 };
    const seg = Seg{ .a = .{ .x = 0, .y = -30 }, .b = .{ .x = 60, .y = -30 } };
    try std.testing.expect(!segIntersectsRect(seg, rect));
}

test "segIntersectsRect — vertical through rect" {
    const rect = Rect{ .x0 = 10, .y0 = -20, .x1 = 50, .y1 = 20 };
    const seg = Seg{ .a = .{ .x = 30, .y = -40 }, .b = .{ .x = 30, .y = 40 } };
    try std.testing.expect(segIntersectsRect(seg, rect));
}

test "segIntersectsRect — segment outside rect" {
    const rect = Rect{ .x0 = 10, .y0 = -20, .x1 = 50, .y1 = 20 };
    const seg = Seg{ .a = .{ .x = 60, .y = -40 }, .b = .{ .x = 60, .y = 40 } };
    try std.testing.expect(!segIntersectsRect(seg, rect));
}

test "segmentsOverlapCollinear — horizontal overlap" {
    try std.testing.expect(segmentsOverlapCollinear(
        .{ .x = 0, .y = 0 },
        .{ .x = 100, .y = 0 },
        .{ .x = 50, .y = 0 },
        .{ .x = 150, .y = 0 },
    ));
}

test "segmentsOverlapCollinear — no overlap different y" {
    try std.testing.expect(!segmentsOverlapCollinear(
        .{ .x = 0, .y = 0 },
        .{ .x = 100, .y = 0 },
        .{ .x = 50, .y = 10 },
        .{ .x = 150, .y = 10 },
    ));
}

test "segmentsOverlapCollinear — vertical overlap" {
    try std.testing.expect(segmentsOverlapCollinear(
        .{ .x = 0, .y = 0 },
        .{ .x = 0, .y = 100 },
        .{ .x = 0, .y = 50 },
        .{ .x = 0, .y = 150 },
    ));
}

test "segmentsOverlapCollinear — no overlap disjoint" {
    try std.testing.expect(!segmentsOverlapCollinear(
        .{ .x = 0, .y = 0 },
        .{ .x = 0, .y = 40 },
        .{ .x = 0, .y = 50 },
        .{ .x = 0, .y = 100 },
    ));
}

test "scoreCandidate — obstacle hit scores high" {
    const obs = [_]Rect{.{ .x0 = 10, .y0 = -20, .x1 = 50, .y1 = 20 }};
    const seg_through = [1]Seg{.{ .a = .{ .x = 0, .y = 0 }, .b = .{ .x = 60, .y = 0 } }};
    const seg_clear = [1]Seg{.{ .a = .{ .x = 0, .y = 30 }, .b = .{ .x = 60, .y = 30 } }};

    const score_through = scoreCandidate(&seg_through, &.{}, &obs);
    const score_clear = scoreCandidate(&seg_clear, &.{}, &obs);

    try std.testing.expect(score_through >= OBS_PENALTY);
    try std.testing.expectEqual(@as(u32, 0), score_clear);
}

test "buildObstacles — creates rects from placed devices" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const placed = [_]Layout.PlacedDevice{
        .{ .elem_idx = 0, .x = 100, .y = 0, .orientation = .up, .kind = .nmos4, .symbol = "nmos4", .group = 0 },
    };

    const obs = try buildObstacles(arena, &placed);
    try std.testing.expectEqual(@as(usize, 1), obs.len);

    // NMOS bbox: (-20,-30) to (20,30) + OBS_MARGIN=5
    // At center (100,0): x0=100-20-5=75, y0=0-30-5=-35, x1=100+20+5=125, y1=0+30+5=35
    try std.testing.expectEqual(@as(i32, 75), obs[0].x0);
    try std.testing.expectEqual(@as(i32, -35), obs[0].y0);
    try std.testing.expectEqual(@as(i32, 125), obs[0].x1);
    try std.testing.expectEqual(@as(i32, 35), obs[0].y1);
}

test "route avoids device bodies" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Two NMOS devices with a net connecting drain of first to gate of second.
    // Place them so a naive L-shape would go through the second device body.
    const n1 = try arena.dupe([]const u8, &.{ "mid", "0", "0", "0" });
    const n2 = try arena.dupe([]const u8, &.{ "0", "mid", "0", "0" });
    const elements = [_]parser.Element{
        .{ .prefix = 'm', .name = "M1", .nodes = n1, .value = "nch" },
        .{ .prefix = 'm', .name = "M2", .nodes = n2, .value = "nch" },
    };
    const placed = [_]Layout.PlacedDevice{
        .{ .elem_idx = 0, .x = 0, .y = 0, .orientation = .up, .kind = .nmos4, .symbol = "nmos4", .group = 0 },
        .{ .elem_idx = 1, .x = 100, .y = 0, .orientation = .up, .kind = .nmos4, .symbol = "nmos4", .group = 0 },
    };

    const result = try route(arena, &elements, &placed);

    // Should have wires for "mid" net
    try std.testing.expect(result.wires.len > 0);

    // Build obstacles and verify no wire passes through a device body
    const obs = try buildObstacles(arena, &placed);
    for (result.wires) |w| {
        const seg = Seg{ .a = .{ .x = w.x0, .y = w.y0 }, .b = .{ .x = w.x1, .y = w.y1 } };
        for (obs) |o| {
            if (segIntersectsRect(seg, o)) {
                // Allow wires that start/end at pin positions (they touch device edge)
                const starts_at_pin = isNearDevicePin(&placed, w.x0, w.y0);
                const ends_at_pin = isNearDevicePin(&placed, w.x1, w.y1);
                if (!starts_at_pin and !ends_at_pin) {
                    return error.WirePassesThroughDevice;
                }
            }
        }
    }
}

fn isNearDevicePin(placed: []const Layout.PlacedDevice, x: i32, y: i32) bool {
    for (placed) |p| {
        const offs = basePinOffsets(p.kind);
        for (0..offs.len) |i| {
            if (pinPos(p, i)) |pp| {
                if (abs32(pp.x - x) <= 1 and abs32(pp.y - y) <= 1) return true;
            }
        }
    }
    return false;
}
