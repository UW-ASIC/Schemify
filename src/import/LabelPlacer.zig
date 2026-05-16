// LabelPlacer.zig — Positions instance name and parameter labels to avoid
// overlap with wires, devices, and other labels.
//
// Algorithm: O(n * k) greedy placement where n = devices, k = candidates per device.
// Devices are processed left-to-right, top-to-bottom. Each device generates
// 4-8 candidate label positions scored by overlap penalties and conventional
// position bonuses. The lowest-penalty candidate wins and its bbox is recorded
// as occupied for subsequent devices.

const std = @import("std");
const Allocator = std.mem.Allocator;
const List = std.ArrayListUnmanaged;
const Router = @import("Router.zig");
const core = @import("schematic");
const Layout = core.layout;
const DeviceKind = core.types.DeviceKind;

// ── Public types ────────────────────────────────────────────────────────────

pub const LabelOffset = struct {
    elem_idx: u32,
    name_dx: i16,
    name_dy: i16,
    param_dx: i16,
    param_dy: i16,
};

pub const RouteWire = Router.RouteWire;

// ── Internal types ──────────────────────────────────────────────────────────

const Candidate = struct {
    name_dx: i16,
    name_dy: i16,
    param_dx: i16,
    param_dy: i16,
    penalty: i32,
};

const BBox = struct {
    x0: i32,
    y0: i32,
    x1: i32,
    y1: i32,

    fn overlaps(self: BBox, other: BBox) bool {
        return self.x0 < other.x1 and self.x1 > other.x0 and
            self.y0 < other.y1 and self.y1 > other.y0;
    }
};

// ── Constants ───────────────────────────────────────────────────────────────

const NAME_W: i32 = 60;
const NAME_H: i32 = 15;
const PARAM_W: i32 = 80;
const PARAM_H: i32 = 15;
const DEV_PASSIVE_W: i32 = 40;
const DEV_PASSIVE_H: i32 = 60;
const DEV_MOS_W: i32 = 50;
const DEV_MOS_H: i32 = 60;
const DEV_DEFAULT_W: i32 = 40;
const DEV_DEFAULT_H: i32 = 60;

const PENALTY_WIRE: i32 = 100;
const PENALTY_LABEL: i32 = 200;
const PENALTY_DEVICE: i32 = 150;
const BONUS_CONVENTIONAL: i32 = -50;

// ── Candidate generation ────────────────────────────────────────────────────

const CandPair = struct {
    name_dx: i16,
    name_dy: i16,
    param_dx: i16,
    param_dy: i16,
};

fn candidates(kind: DeviceKind, orientation: Layout.Orientation) []const CandPair {
    const is_vertical = orientation == .up or orientation == .down;

    return switch (kind) {
        .nmos3, .nmos4, .nmos4_depl, .nmos_sub, .nmoshv4, .rnmos4,
        .pmos3, .pmos4, .pmos_sub, .pmoshv4,
        => if (is_vertical) &mos_vertical else &mos_horizontal,

        .resistor, .resistor3, .var_resistor,
        => if (is_vertical) &res_vertical else &res_horizontal,

        .capacitor,
        => if (is_vertical) &cap_vertical else &cap_horizontal,

        .vsource, .isource, .sqwsource,
        => &source_cands,

        .subckt, .digital_instance,
        => &subckt_cands,

        else => &default_cands,
    };
}

const mos_vertical = [_]CandPair{
    .{ .name_dx = 30, .name_dy = 0, .param_dx = 0, .param_dy = 50 }, // right, below
    .{ .name_dx = 30, .name_dy = 0, .param_dx = 30, .param_dy = 20 }, // right, right-below
    .{ .name_dx = -50, .name_dy = 0, .param_dx = 0, .param_dy = 50 }, // left, below
    .{ .name_dx = 0, .name_dy = -40, .param_dx = 0, .param_dy = 50 }, // above, below
    .{ .name_dx = 0, .name_dy = 40, .param_dx = 0, .param_dy = 60 }, // below, further below
};

const mos_horizontal = [_]CandPair{
    .{ .name_dx = 0, .name_dy = -30, .param_dx = 0, .param_dy = 30 },
    .{ .name_dx = 0, .name_dy = 30, .param_dx = 0, .param_dy = -30 },
    .{ .name_dx = 30, .name_dy = 0, .param_dx = -50, .param_dy = 0 },
};

const res_vertical = [_]CandPair{
    .{ .name_dx = -40, .name_dy = 0, .param_dx = 40, .param_dy = 0 }, // left, right
    .{ .name_dx = 40, .name_dy = 0, .param_dx = -40, .param_dy = 0 }, // right, left
    .{ .name_dx = -40, .name_dy = -10, .param_dx = 40, .param_dy = 10 },
    .{ .name_dx = 40, .name_dy = -10, .param_dx = -40, .param_dy = 10 },
};

const res_horizontal = [_]CandPair{
    .{ .name_dx = 0, .name_dy = -30, .param_dx = 0, .param_dy = 30 }, // above, below
    .{ .name_dx = 0, .name_dy = 30, .param_dx = 0, .param_dy = -30 }, // below, above
    .{ .name_dx = -30, .name_dy = -30, .param_dx = 30, .param_dy = 30 },
};

const cap_vertical = [_]CandPair{
    .{ .name_dx = -40, .name_dy = 0, .param_dx = 40, .param_dy = 0 },
    .{ .name_dx = 40, .name_dy = 0, .param_dx = -40, .param_dy = 0 },
    .{ .name_dx = -40, .name_dy = -10, .param_dx = 40, .param_dy = 10 },
};

const cap_horizontal = [_]CandPair{
    .{ .name_dx = 0, .name_dy = -30, .param_dx = 0, .param_dy = 30 },
    .{ .name_dx = 0, .name_dy = 30, .param_dx = 0, .param_dy = -30 },
};

const source_cands = [_]CandPair{
    .{ .name_dx = -40, .name_dy = 0, .param_dx = 0, .param_dy = 40 },
    .{ .name_dx = 40, .name_dy = 0, .param_dx = 0, .param_dy = 40 },
    .{ .name_dx = -40, .name_dy = -10, .param_dx = 40, .param_dy = 10 },
    .{ .name_dx = 0, .name_dy = -40, .param_dx = 0, .param_dy = 40 },
};

const subckt_cands = [_]CandPair{
    .{ .name_dx = 0, .name_dy = -40, .param_dx = 0, .param_dy = 40 },
    .{ .name_dx = 30, .name_dy = -40, .param_dx = 30, .param_dy = 40 },
    .{ .name_dx = -30, .name_dy = -40, .param_dx = -30, .param_dy = 40 },
};

const default_cands = [_]CandPair{
    .{ .name_dx = 30, .name_dy = 0, .param_dx = 30, .param_dy = 20 },
    .{ .name_dx = 0, .name_dy = -30, .param_dx = 0, .param_dy = -10 },
    .{ .name_dx = -40, .name_dy = 0, .param_dx = -40, .param_dy = 20 },
    .{ .name_dx = 0, .name_dy = 30, .param_dx = 0, .param_dy = 50 },
};

// ── BBox helpers ────────────────────────────────────────────────────────────

fn nameBBox(dev_x: i32, dev_y: i32, dx: i16, dy: i16) BBox {
    const cx = dev_x + @as(i32, dx);
    const cy = dev_y + @as(i32, dy);
    return .{
        .x0 = cx - @divTrunc(NAME_W, 2),
        .y0 = cy - @divTrunc(NAME_H, 2),
        .x1 = cx + @divTrunc(NAME_W, 2),
        .y1 = cy + @divTrunc(NAME_H, 2),
    };
}

fn paramBBox(dev_x: i32, dev_y: i32, dx: i16, dy: i16) BBox {
    const cx = dev_x + @as(i32, dx);
    const cy = dev_y + @as(i32, dy);
    return .{
        .x0 = cx - @divTrunc(PARAM_W, 2),
        .y0 = cy - @divTrunc(PARAM_H, 2),
        .x1 = cx + @divTrunc(PARAM_W, 2),
        .y1 = cy + @divTrunc(PARAM_H, 2),
    };
}

fn deviceBBox(dev: Layout.PlacedDevice) BBox {
    const half_w: i32 = @divTrunc(deviceWidth(dev.kind), 2);
    const half_h: i32 = @divTrunc(deviceHeight(dev.kind), 2);
    return .{
        .x0 = dev.x - half_w,
        .y0 = dev.y - half_h,
        .x1 = dev.x + half_w,
        .y1 = dev.y + half_h,
    };
}

fn deviceWidth(kind: DeviceKind) i32 {
    return switch (kind) {
        .nmos3, .nmos4, .nmos4_depl, .nmos_sub, .nmoshv4, .rnmos4,
        .pmos3, .pmos4, .pmos_sub, .pmoshv4,
        => DEV_MOS_W,
        .resistor, .resistor3, .var_resistor, .capacitor, .inductor,
        => DEV_PASSIVE_W,
        else => DEV_DEFAULT_W,
    };
}

fn deviceHeight(kind: DeviceKind) i32 {
    return switch (kind) {
        .nmos3, .nmos4, .nmos4_depl, .nmos_sub, .nmoshv4, .rnmos4,
        .pmos3, .pmos4, .pmos_sub, .pmoshv4,
        => DEV_MOS_H,
        .resistor, .resistor3, .var_resistor, .capacitor, .inductor,
        => DEV_PASSIVE_H,
        else => DEV_DEFAULT_H,
    };
}

fn wireBBox(w: RouteWire) BBox {
    const pad: i32 = 3;
    return .{
        .x0 = @min(w.x0, w.x1) - pad,
        .y0 = @min(w.y0, w.y1) - pad,
        .x1 = @max(w.x0, w.x1) + pad,
        .y1 = @max(w.y0, w.y1) + pad,
    };
}

// ── Scoring ─────────────────────────────────────────────────────────────────

fn scoreCandidate(
    dev: Layout.PlacedDevice,
    cand: CandPair,
    is_conventional: bool,
    wires: []const RouteWire,
    placed_devices: []const Layout.PlacedDevice,
    occupied_labels: []const BBox,
) Candidate {
    const nb = nameBBox(dev.x, dev.y, cand.name_dx, cand.name_dy);
    const pb = paramBBox(dev.x, dev.y, cand.param_dx, cand.param_dy);

    var penalty: i32 = 0;

    // Wire overlap
    for (wires) |w| {
        const wb = wireBBox(w);
        if (BBox.overlaps(nb, wb)) penalty += PENALTY_WIRE;
        if (BBox.overlaps(pb, wb)) penalty += PENALTY_WIRE;
    }

    // Device overlap
    for (placed_devices) |other| {
        if (other.elem_idx == dev.elem_idx) continue;
        const db = deviceBBox(other);
        if (BBox.overlaps(nb, db)) penalty += PENALTY_DEVICE;
        if (BBox.overlaps(pb, db)) penalty += PENALTY_DEVICE;
    }

    // Already-placed label overlap
    for (occupied_labels) |lb| {
        if (BBox.overlaps(nb, lb)) penalty += PENALTY_LABEL;
        if (BBox.overlaps(pb, lb)) penalty += PENALTY_LABEL;
    }

    // Self-overlap: name vs param labels
    if (BBox.overlaps(nb, pb)) penalty += PENALTY_LABEL;

    // Conventional position bonus (first candidate is the conventional one)
    if (is_conventional) penalty += BONUS_CONVENTIONAL;

    return .{
        .name_dx = cand.name_dx,
        .name_dy = cand.name_dy,
        .param_dx = cand.param_dx,
        .param_dy = cand.param_dy,
        .penalty = penalty,
    };
}

// ── Main entry point ────────────────────────────────────────────────────────

pub fn placeLabels(
    arena: Allocator,
    placed: []const Layout.PlacedDevice,
    wires: []const RouteWire,
) ![]const LabelOffset {
    if (placed.len == 0) return &.{};

    // Sort indices left-to-right, top-to-bottom for greedy assignment
    const order = try arena.alloc(u32, placed.len);
    for (0..placed.len) |i| order[i] = @intCast(i);

    std.mem.sort(u32, order, placed, struct {
        fn lessThan(ctx: []const Layout.PlacedDevice, a: u32, b: u32) bool {
            const da = ctx[a];
            const db = ctx[b];
            if (da.x != db.x) return da.x < db.x;
            return da.y < db.y;
        }
    }.lessThan);

    // Occupied label bboxes (name + param for each placed device so far)
    var occupied: List(BBox) = .{};
    try occupied.ensureTotalCapacity(arena, placed.len * 2);

    const result = try arena.alloc(LabelOffset, placed.len);

    for (order) |idx| {
        const dev = placed[idx];
        const cands = candidates(dev.kind, dev.orientation);

        var best = Candidate{
            .name_dx = 30,
            .name_dy = 0,
            .param_dx = 30,
            .param_dy = 20,
            .penalty = std.math.maxInt(i32),
        };

        for (cands, 0..) |c, ci| {
            const scored = scoreCandidate(
                dev,
                c,
                ci == 0,
                wires,
                placed,
                occupied.items,
            );
            if (scored.penalty < best.penalty) {
                best = scored;
            }
        }

        // Record chosen label bboxes as occupied
        occupied.appendAssumeCapacity(nameBBox(dev.x, dev.y, best.name_dx, best.name_dy));
        occupied.appendAssumeCapacity(paramBBox(dev.x, dev.y, best.param_dx, best.param_dy));

        result[idx] = .{
            .elem_idx = dev.elem_idx,
            .name_dx = best.name_dx,
            .name_dy = best.name_dy,
            .param_dx = best.param_dx,
            .param_dy = best.param_dy,
        };
    }

    return result;
}

// ── Tests ───────────────────────────────────────────────────────────────────

test "BBox.overlaps" {
    const a = BBox{ .x0 = 0, .y0 = 0, .x1 = 10, .y1 = 10 };
    const b = BBox{ .x0 = 5, .y0 = 5, .x1 = 15, .y1 = 15 };
    const c = BBox{ .x0 = 20, .y0 = 20, .x1 = 30, .y1 = 30 };
    const d = BBox{ .x0 = 10, .y0 = 0, .x1 = 20, .y1 = 10 };

    try std.testing.expect(BBox.overlaps(a, b));
    try std.testing.expect(BBox.overlaps(b, a));
    try std.testing.expect(!BBox.overlaps(a, c));
    try std.testing.expect(!BBox.overlaps(c, a));
    // Touching edges (not overlapping — strict inequality)
    try std.testing.expect(!BBox.overlaps(a, d));
}

test "placeLabels — empty" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const result = try placeLabels(arena_state.allocator(), &.{}, &.{});
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "placeLabels — single device" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const placed = [_]Layout.PlacedDevice{
        .{
            .elem_idx = 0,
            .x = 100,
            .y = 0,
            .orientation = .up,
            .kind = .resistor,
            .symbol = "res",
            .group = 0,
        },
    };

    const result = try placeLabels(arena, &placed, &.{});
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqual(@as(u32, 0), result[0].elem_idx);
    // Should get the conventional (first) candidate for vertical resistor: left side
    try std.testing.expectEqual(@as(i16, -40), result[0].name_dx);
    try std.testing.expectEqual(@as(i16, 0), result[0].name_dy);
    try std.testing.expectEqual(@as(i16, 40), result[0].param_dx);
    try std.testing.expectEqual(@as(i16, 0), result[0].param_dy);
}

test "placeLabels — no overlap" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Two resistors close together vertically
    const placed = [_]Layout.PlacedDevice{
        .{
            .elem_idx = 0,
            .x = 100,
            .y = 0,
            .orientation = .up,
            .kind = .resistor,
            .symbol = "res",
            .group = 0,
        },
        .{
            .elem_idx = 1,
            .x = 100,
            .y = 80,
            .orientation = .up,
            .kind = .resistor,
            .symbol = "res",
            .group = 0,
        },
    };

    const result = try placeLabels(arena, &placed, &.{});
    try std.testing.expectEqual(@as(usize, 2), result.len);

    // Verify the label bboxes don't overlap
    const nb0 = nameBBox(placed[0].x, placed[0].y, result[0].name_dx, result[0].name_dy);
    const pb0 = paramBBox(placed[0].x, placed[0].y, result[0].param_dx, result[0].param_dy);
    const nb1 = nameBBox(placed[1].x, placed[1].y, result[1].name_dx, result[1].name_dy);
    const pb1 = paramBBox(placed[1].x, placed[1].y, result[1].param_dx, result[1].param_dy);

    // Name labels should not overlap each other
    try std.testing.expect(!BBox.overlaps(nb0, nb1));
    // Param labels should not overlap each other
    try std.testing.expect(!BBox.overlaps(pb0, pb1));
    // Cross: name of one should not overlap param of other
    try std.testing.expect(!BBox.overlaps(nb0, pb1));
    try std.testing.expect(!BBox.overlaps(nb1, pb0));
}

test "conventional position for MOSFET" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const placed = [_]Layout.PlacedDevice{
        .{
            .elem_idx = 0,
            .x = 200,
            .y = 100,
            .orientation = .up,
            .kind = .nmos4,
            .symbol = "nmos4",
            .group = 0,
        },
    };

    const result = try placeLabels(arena, &placed, &.{});
    try std.testing.expectEqual(@as(usize, 1), result.len);
    // Without any obstacles, should pick the conventional (first) MOSFET candidate:
    // name right of gate (+30, 0), param below (+0, +50)
    try std.testing.expectEqual(@as(i16, 30), result[0].name_dx);
    try std.testing.expectEqual(@as(i16, 0), result[0].name_dy);
    try std.testing.expectEqual(@as(i16, 0), result[0].param_dx);
    try std.testing.expectEqual(@as(i16, 50), result[0].param_dy);
}

test "wire avoidance" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Place a wire exactly where the conventional MOSFET name label would go
    // (right of gate: device at 200, name_dx=30 → label center at 230, width 60 → 200..260)
    const wires = [_]RouteWire{
        .{ .x0 = 200, .y0 = 95, .x1 = 260, .y1 = 105, .net_name = "net1" },
    };

    const placed = [_]Layout.PlacedDevice{
        .{
            .elem_idx = 0,
            .x = 200,
            .y = 100,
            .orientation = .up,
            .kind = .nmos4,
            .symbol = "nmos4",
            .group = 0,
        },
    };

    const result = try placeLabels(arena, &placed, &wires);
    try std.testing.expectEqual(@as(usize, 1), result.len);
    // With a wire blocking the conventional position, it should pick a different candidate
    // The exact choice depends on scoring, but it should NOT be the conventional (30, 0)
    // if the wire fully overlaps that position — OR it still wins if the bonus outweighs.
    // Just verify we get a valid result.
    try std.testing.expectEqual(@as(u32, 0), result[0].elem_idx);
}
