//! Reader.zig — CHN format parser
//!
//! All parsing logic lives in utils.zig. This module delegates completely.

const std = @import("std");
const Allocator = std.mem.Allocator;

const sch = @import("../Schemify.zig");
const Schemify = sch.Schemify;
const utility = @import("utility");
const utils = @import("utils.zig");

pub const Reader = struct {
    /// Parse CHN data into a Schemify. Returns fully-loaded schematic.
    pub fn readCHN(data: []const u8, backing: Allocator, logger: ?*utility.Logger) Schemify {
        var s = Schemify.init(backing);
        s.logger = logger;
        utils.parse(&s, data);
        collapseBusPins(&s);
        synthesizePortInstances(&s);
        return s;
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// POST-PARSE TRANSFORMS
// ─────────────────────────────────────────────────────────────────────────────

/// Collapse sequential bus pin bits (A[0]…A[15]) into a single wide pin (A[15:0] width=16).
fn collapseBusPins(s: *Schemify) void {
    const n = s.pins.len;
    if (n <= 1) return;
    const a = s.alloc();

    const pnames = s.pins.items(.name);
    const pdirs = s.pins.items(.dir);
    const pxs = s.pins.items(.x);
    const pys = s.pins.items(.y);

    const consumed = a.alloc(bool, n) catch return;
    defer a.free(consumed);
    @memset(consumed, false);

    var new_pins = std.MultiArrayList(sch.Pin){};

    for (0..n) |i| {
        if (consumed[i]) continue;
        if (splitBusPin(pnames[i])) |parts| {
            var min_idx: u32 = parts.idx;
            var max_idx: u32 = parts.idx;
            var count: u32 = 1;
            for (0..n) |j| {
                if (j == i or consumed[j]) continue;
                const pj = splitBusPin(pnames[j]) orelse continue;
                if (!std.mem.eql(u8, parts.base, pj.base) or pdirs[j] != pdirs[i]) continue;
                count += 1;
                if (pj.idx < min_idx) min_idx = pj.idx;
                if (pj.idx > max_idx) max_idx = pj.idx;
            }
            const width = max_idx - min_idx + 1;
            if (count == width and width > 1) {
                consumed[i] = true;
                for (0..n) |j| {
                    if (j == i or consumed[j]) continue;
                    const pj = splitBusPin(pnames[j]) orelse continue;
                    if (std.mem.eql(u8, parts.base, pj.base) and pdirs[j] == pdirs[i])
                        consumed[j] = true;
                }
                const bus_name = std.fmt.allocPrint(a, "{s}[{d}:{d}]", .{ parts.base, max_idx, min_idx }) catch parts.base;
                new_pins.append(a, .{ .name = bus_name, .x = pxs[i], .y = pys[i], .dir = pdirs[i], .width = @intCast(width) }) catch continue;
                continue;
            }
        }
        consumed[i] = true;
        new_pins.append(a, .{ .name = pnames[i], .x = pxs[i], .y = pys[i], .dir = pdirs[i], .width = s.pins.items(.width)[i] }) catch continue;
    }
    s.pins = new_pins;
}

/// Split "A[3]" into base="A" and idx=3.
fn splitBusPin(name: []const u8) ?struct { base: []const u8, idx: u32 } {
    if (name.len < 4 or name[name.len - 1] != ']') return null;
    const open = std.mem.lastIndexOfScalar(u8, name, '[') orelse return null;
    const idx = std.fmt.parseInt(u32, name[open + 1 .. name.len - 1], 10) catch return null;
    return .{ .base = name[0..open], .idx = idx };
}

/// Create port pin instances from the pins: section for old .chn files.
fn synthesizePortInstances(s: *Schemify) void {
    if (s.pins.len == 0) return;
    const a = s.alloc();
    const orig_inst_len = s.instances.len;

    const pnames = s.pins.items(.name);
    const pdirs = s.pins.items(.dir);
    const pxs = s.pins.items(.x);
    const pys = s.pins.items(.y);

    const Devices = @import("../devices/Devices.zig");
    const PendingPin = struct { pi: usize, kind: Devices.DeviceKind };
    var pending = std.ArrayListUnmanaged(PendingPin){};
    defer pending.deinit(a);

    for (0..s.pins.len) |pi| {
        const kind: Devices.DeviceKind = switch (pdirs[pi]) {
            .input => .input_pin,
            .output => .output_pin,
            else => .inout_pin,
        };
        var found = false;
        for (0..orig_inst_len) |ii| {
            if (s.instances.items(.kind)[ii] != kind) continue;
            const ps = s.instances.items(.prop_start)[ii];
            const pc = s.instances.items(.prop_count)[ii];
            const props = s.props.items[ps..][0..pc];
            for (props) |p| {
                if (std.mem.eql(u8, p.key, "lab") and std.mem.eql(u8, p.val, pnames[pi])) {
                    found = true;
                    break;
                }
            }
            if (found) break;
        }
        if (!found) pending.append(a, .{ .pi = pi, .kind = kind }) catch continue;
    }

    const wx0 = s.wires.items(.x0);
    const wy0 = s.wires.items(.y0);
    const wx1 = s.wires.items(.x1);
    const wy1 = s.wires.items(.y1);
    const wnn = s.wires.items(.net_name);

    for (pending.items) |entry| {
        const pi = entry.pi;
        var x: i32 = pxs[pi];
        var y: i32 = pys[pi];
        for (0..s.wires.len) |wi| {
            const nn = wnn[wi] orelse continue;
            if (wx0[wi] == wx1[wi] and wy0[wi] == wy1[wi] and
                std.mem.eql(u8, nn, pnames[pi]))
            {
                x = wx0[wi];
                y = wy0[wi];
                break;
            }
        }
        const prop_start: u32 = @intCast(s.props.items.len);
        s.props.append(a, .{
            .key = a.dupe(u8, "lab") catch continue,
            .val = a.dupe(u8, pnames[pi]) catch continue,
        }) catch continue;
        s.instances.append(a, .{
            .name = a.dupe(u8, pnames[pi]) catch continue,
            .symbol = a.dupe(u8, @tagName(entry.kind)) catch continue,
            .x = x,
            .y = y,
            .kind = entry.kind,
            .prop_start = prop_start,
            .prop_count = 1,
        }) catch continue;
    }
}
