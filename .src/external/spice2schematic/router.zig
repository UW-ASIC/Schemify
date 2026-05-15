// router.zig — Manhattan wire router for SPICE-to-schematic conversion.
//
// Connects pins by net name using orthogonal (Manhattan) routing.
// For each net with 2+ pins, creates L-shaped wire segments between
// consecutive pin positions. Power/ground nets get power symbols instead.

const std = @import("std");
const Allocator = std.mem.Allocator;
const List = std.ArrayListUnmanaged;
const parser = @import("parser.zig");
const layout = @import("layout.zig");
const core = @import("core");
const DeviceKind = core.types.DeviceKind;

// ── Public types ────────────────────────────────────────────────────────────

pub const RouteWire = struct {
    x0: i32,
    y0: i32,
    x1: i32,
    y1: i32,
    net_name: []const u8,
};

pub const PowerKind = enum(u1) {
    vdd,
    gnd,
};

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

const PinOff = struct {
    dx: i32,
    dy: i32,
};

const TWO_TERM = [_]PinOff{
    .{ .dx = 0, .dy = -30 }, // p (positive)
    .{ .dx = 0, .dy = 30 }, // n (negative)
};

const NMOS_PINS = [_]PinOff{
    .{ .dx = 20, .dy = -30 }, // d (drain)
    .{ .dx = -20, .dy = 0 }, // g (gate)
    .{ .dx = 20, .dy = 30 }, // s (source)
    .{ .dx = 20, .dy = 0 }, // b (bulk)
};

const PMOS_PINS = [_]PinOff{
    .{ .dx = 20, .dy = 30 }, // d (drain)
    .{ .dx = -20, .dy = 0 }, // g (gate)
    .{ .dx = 20, .dy = -30 }, // s (source)
    .{ .dx = 20, .dy = 0 }, // b (bulk)
};

const NPN_PINS = [_]PinOff{
    .{ .dx = 20, .dy = -30 }, // c (collector)
    .{ .dx = -20, .dy = 0 }, // b (base)
    .{ .dx = 20, .dy = 30 }, // e (emitter)
};

const PNP_PINS = [_]PinOff{
    .{ .dx = 20, .dy = 30 }, // c (collector)
    .{ .dx = -20, .dy = 0 }, // b (base)
    .{ .dx = 20, .dy = -30 }, // e (emitter)
};

const JFET_N_PINS = [_]PinOff{
    .{ .dx = 20, .dy = -30 }, // d
    .{ .dx = -20, .dy = 0 }, // g
    .{ .dx = 20, .dy = 30 }, // s
};

const JFET_P_PINS = [_]PinOff{
    .{ .dx = 20, .dy = 30 }, // d
    .{ .dx = -20, .dy = 0 }, // g
    .{ .dx = 20, .dy = -30 }, // s
};

const FOUR_TERM_CTRL = [_]PinOff{
    .{ .dx = 0, .dy = -30 }, // n+
    .{ .dx = 0, .dy = 30 }, // n-
    .{ .dx = -30, .dy = -30 }, // nc+
    .{ .dx = -30, .dy = 30 }, // nc-
};

fn pinOffsets(kind: DeviceKind) []const PinOff {
    return switch (kind) {
        .nmos4 => &NMOS_PINS,
        .pmos4 => &PMOS_PINS,
        .npn => &NPN_PINS,
        .pnp => &PNP_PINS,
        .njfet => &JFET_N_PINS,
        .pjfet => &JFET_P_PINS,
        .vcvs, .vccs => &FOUR_TERM_CTRL,
        else => &TWO_TERM,
    };
}

pub fn pinPos(placed: layout.PlacedElement, node_idx: usize) ?struct { x: i32, y: i32 } {
    const offs = pinOffsets(placed.kind);
    if (node_idx >= offs.len) return null;
    return .{
        .x = placed.x + offs[node_idx].dx,
        .y = placed.y + offs[node_idx].dy,
    };
}

// ── Routing algorithm ───────────────────────────────────────────────────────

const PinRef = struct {
    elem_idx: u32,
    node_idx: u32,
};

const Point = struct { x: i32, y: i32 };

/// Route all nets from placed element list.
pub fn route(
    arena: Allocator,
    elements: []const parser.Element,
    placed: []const layout.PlacedElement,
) !RouteResult {
    if (elements.len == 0 or placed.len == 0) {
        return .{ .wires = &.{}, .power = &.{} };
    }

    // Build net -> [(elem_idx, node_idx)] map
    var net_pins = std.StringHashMapUnmanaged(List(PinRef)){};

    for (elements, 0..) |elem, ei| {
        for (elem.nodes, 0..) |node, ni| {
            const gop = try net_pins.getOrPut(arena, node);
            if (!gop.found_existing) {
                gop.value_ptr.* = .{};
            }
            try gop.value_ptr.append(arena, .{
                .elem_idx = @intCast(ei),
                .node_idx = @intCast(ni),
            });
        }
    }

    var wires: List(RouteWire) = .{};
    var power: List(PowerSym) = .{};

    var iter = net_pins.iterator();
    while (iter.next()) |entry| {
        const net = entry.key_ptr.*;
        const pins = entry.value_ptr.items;

        // Ground nets -> place GND symbols
        if (layout.isGndNet(net)) {
            for (pins) |pin| {
                if (pin.elem_idx < placed.len) {
                    if (pinPos(placed[pin.elem_idx], pin.node_idx)) |pos| {
                        try power.append(arena, .{ .kind = .gnd, .x = pos.x, .y = pos.y + 10 });
                    }
                }
            }
            continue;
        }

        // VDD nets -> place VDD symbols
        if (layout.isVddNet(net)) {
            for (pins) |pin| {
                if (pin.elem_idx < placed.len) {
                    if (pinPos(placed[pin.elem_idx], pin.node_idx)) |pos| {
                        try power.append(arena, .{ .kind = .vdd, .x = pos.x, .y = pos.y - 10 });
                    }
                }
            }
            continue;
        }

        // Regular net: collect pin positions, route pairwise
        var pts: List(Point) = .{};
        for (pins) |pin| {
            if (pin.elem_idx < placed.len) {
                if (pinPos(placed[pin.elem_idx], pin.node_idx)) |pos| {
                    try pts.append(arena, .{ .x = pos.x, .y = pos.y });
                }
            }
        }

        if (pts.items.len < 2) continue;

        // Chain route: connect consecutive pin positions
        for (1..pts.items.len) |i| {
            try routeSegment(arena, &wires, pts.items[i - 1], pts.items[i], net);
        }
    }

    return .{
        .wires = wires.items,
        .power = power.items,
    };
}

/// Emit one L-shaped Manhattan wire from p1 to p2.
fn routeSegment(
    arena: Allocator,
    wires: *List(RouteWire),
    p1: Point,
    p2: Point,
    net: []const u8,
) !void {
    if (p1.x == p2.x and p1.y == p2.y) return;

    // Straight line
    if (p1.x == p2.x or p1.y == p2.y) {
        try wires.append(arena, .{
            .x0 = p1.x,
            .y0 = p1.y,
            .x1 = p2.x,
            .y1 = p2.y,
            .net_name = net,
        });
        return;
    }

    // L-shape: horizontal then vertical
    const elbow_x = p2.x;
    const elbow_y = p1.y;
    try wires.append(arena, .{
        .x0 = p1.x,
        .y0 = p1.y,
        .x1 = elbow_x,
        .y1 = elbow_y,
        .net_name = net,
    });
    try wires.append(arena, .{
        .x0 = elbow_x,
        .y0 = elbow_y,
        .x1 = p2.x,
        .y1 = p2.y,
        .net_name = net,
    });
}

// ── Tests ───────────────────────────────────────────────────────────────────

test "pinPos — two terminal" {
    const placed = layout.PlacedElement{
        .elem_idx = 0,
        .x = 100,
        .y = -100,
        .kind = .resistor,
        .symbol = "res",
    };
    const p0 = pinPos(placed, 0).?;
    try std.testing.expectEqual(@as(i32, 100), p0.x);
    try std.testing.expectEqual(@as(i32, -130), p0.y);

    const p1 = pinPos(placed, 1).?;
    try std.testing.expectEqual(@as(i32, 100), p1.x);
    try std.testing.expectEqual(@as(i32, -70), p1.y);
}

test "pinPos — nmos4" {
    const placed = layout.PlacedElement{
        .elem_idx = 0,
        .x = 200,
        .y = 0,
        .kind = .nmos4,
        .symbol = "nmos4",
    };
    const d = pinPos(placed, 0).?;
    try std.testing.expectEqual(@as(i32, 220), d.x);
    try std.testing.expectEqual(@as(i32, -30), d.y);
    const g = pinPos(placed, 1).?;
    try std.testing.expectEqual(@as(i32, 180), g.x);
    try std.testing.expectEqual(@as(i32, 0), g.y);
}

test "pinPos — out of range" {
    const placed = layout.PlacedElement{
        .elem_idx = 0,
        .x = 0,
        .y = 0,
        .kind = .resistor,
        .symbol = "res",
    };
    try std.testing.expect(pinPos(placed, 5) == null);
}

test "route empty" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const result = try route(arena, &.{}, &.{});
    try std.testing.expectEqual(@as(usize, 0), result.wires.len);
    try std.testing.expectEqual(@as(usize, 0), result.power.len);
}
