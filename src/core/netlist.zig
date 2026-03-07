const std = @import("std");
const Allocator = std.mem.Allocator;
const List = std.ArrayListUnmanaged;
const MAL = std.MultiArrayList;
const sch = @import("schemify.zig");
const xs = @import("xschem.zig");
const dev = @import("device.zig");

// ── Legacy types (kept for backward compat) ─────────────────────────────── //

pub const WireSeg = struct {
    x0: i32,
    y0: i32,
    x1: i32,
    y1: i32,
    net_name: ?[]const u8,
};

pub const DeviceRef = struct {
    name: []const u8,
    symbol: []const u8,
    kind: sch.DeviceKind = .unknown,
    x: i32,
    y: i32,
    rot: u2,
    flip: bool,
    prop_start: u32,
    prop_count: u16,
};

pub const DeviceProp = struct {
    key: []const u8,
    value: []const u8,
};

// ── New relational types ────────────────────────────────────────────────── //

/// A pin reference with name and direction.
pub const PinRef = struct {
    name: []const u8,
    dir: sch.PinDir,
};

/// Maps a device+pin to a net.
pub const DeviceNet = struct {
    device_idx: u32,
    pin_name: []const u8,
    net_id: u32,
};

// ── UniversalNetlistForm ────────────────────────────────────────────────── //

/// Universal intermediate representation shared across all source formats.
/// Uses SoA containers for cache-friendly transformations and backend export.
///
/// Supports two construction paths:
///   1. `fromSchemify` — uses relational nets/net_conns from `resolveNets()`
///   2. `fromXSchem` — converts via `toSchemify()` then delegates to (1)
pub const UniversalNetlistForm = struct {
    arena: std.heap.ArenaAllocator,

    // Legacy geometric data
    wires: MAL(WireSeg) = .{},
    devices: MAL(DeviceRef) = .{},
    props: List(DeviceProp) = .{},

    // Relational netlist data
    name: []const u8 = "",
    pins: List(PinRef) = .{},
    net_names: List([]const u8) = .{},
    device_nets: List(DeviceNet) = .{},

    /// Create with a backing allocator for the internal arena.
    pub fn init(backing: Allocator) UniversalNetlistForm {
        return .{ .arena = std.heap.ArenaAllocator.init(backing) };
    }

    /// Release all memory.
    pub fn deinit(self: *UniversalNetlistForm) void {
        self.arena.deinit();
    }

    fn alloc(self: *UniversalNetlistForm) Allocator {
        return self.arena.allocator();
    }

    /// Build from a Schemify schematic (legacy geometric path).
    /// Copies wires, devices, and props into arena-owned storage.
    pub fn fromSchemifyLegacy(src: *const sch.Schemify, backing: Allocator) !UniversalNetlistForm {
        var out = UniversalNetlistForm.init(backing);
        const a = out.alloc();
        try copyWires(&out, src, a);
        try copyDevices(&out, src, a);
        return out;
    }

    /// Build from a Schemify (uses nets/net_conns if present, else geometric fallback).
    ///
    /// If `resolveNets()` has not been called, calls it automatically.
    /// Populates `net_names`, `device_nets`, and `pins` from the relational data.
    pub fn fromSchemify(a: Allocator, s: *sch.Schemify) !UniversalNetlistForm {
        var out = UniversalNetlistForm.init(a);
        const arena = out.alloc();

        if (s.nets.items.len == 0) {
            s.resolveNets();
        }

        out.name = if (s.name.len > 0) (arena.dupe(u8, s.name) catch "") else "";
        try copyDevices(&out, s, arena);
        try buildNetNames(&out, s, arena);
        try buildDeviceNets(&out, s, arena);
        try buildPins(&out, s, arena);
        return out;
    }

    /// Build from an XSchem schematic by calling toSchemify() first.
    ///
    /// Converts the XSchem representation to Schemify, resolves nets,
    /// then extracts relational netlist data.
    pub fn fromXSchem(a: Allocator, x: *const xs.XSchem) !UniversalNetlistForm {
        var s = try x.toSchemify(a);
        defer s.deinit();
        return fromSchemify(a, &s);
    }

    /// Generate a SPICE netlist string. Caller owns the returned slice.
    ///
    /// Emits title, PDK preamble, instance lines, and `.end`.
    /// Non-electrical devices (gnd, vdd, lab_pin, graph) are skipped.
    /// Unconnected pins are emitted as `_unknown_`.
    pub fn generateSpice(
        self: *const UniversalNetlistForm,
        a: Allocator,
        registry: *const dev.PdkDeviceRegistry,
    ) ![]u8 {
        var buf: List(u8) = .{};
        errdefer buf.deinit(a);
        const w = buf.writer(a);

        try emitTitle(w, self.name);
        try emitPreamble(w, a, self, registry);
        try w.writeAll("* Instances\n");
        try emitInstances(w, a, self, registry);
        try w.writeAll(".end\n");

        return buf.toOwnedSlice(a);
    }
};

// ── fromSchemify helpers ────────────────────────────────────────────────── //

fn buildNetNames(out: *UniversalNetlistForm, s: *const sch.Schemify, a: Allocator) !void {
    try out.net_names.ensureTotalCapacity(a, s.nets.items.len);
    for (s.nets.items) |net| {
        try out.net_names.append(a, try a.dupe(u8, net.name));
    }
}

fn buildDeviceNets(out: *UniversalNetlistForm, s: *const sch.Schemify, a: Allocator) !void {
    for (s.net_conns.items) |nc| {
        if (nc.kind != .instance_pin) continue;
        try out.device_nets.append(a, .{
            .device_idx = @intCast(nc.ref_a),
            .pin_name = if (nc.pin_or_label) |p| try a.dupe(u8, p) else "",
            .net_id = nc.net_id,
        });
    }
}

fn buildPins(out: *UniversalNetlistForm, s: *const sch.Schemify, a: Allocator) !void {
    const pin_slice = s.pins.slice();
    try out.pins.ensureTotalCapacity(a, s.pins.len);
    for (0..s.pins.len) |i| {
        try out.pins.append(a, .{
            .name = try a.dupe(u8, pin_slice.items(.name)[i]),
            .dir = pin_slice.items(.dir)[i],
        });
    }
}

// ── Legacy copy helpers ─────────────────────────────────────────────────── //

fn copyWires(out: *UniversalNetlistForm, src: *const sch.Schemify, a: Allocator) !void {
    try out.wires.ensureTotalCapacity(a, src.wires.len);
    const ws = src.wires.slice();
    for (0..src.wires.len) |i| {
        try out.wires.append(a, .{
            .x0 = ws.items(.x0)[i],
            .y0 = ws.items(.y0)[i],
            .x1 = ws.items(.x1)[i],
            .y1 = ws.items(.y1)[i],
            .net_name = if (ws.items(.net_name)[i]) |name| try a.dupe(u8, name) else null,
        });
    }
}

fn copyDevices(out: *UniversalNetlistForm, src: *const sch.Schemify, a: Allocator) !void {
    try out.devices.ensureTotalCapacity(a, src.instances.len);
    try out.props.ensureTotalCapacity(a, src.props.items.len);
    const ins = src.instances.slice();
    for (0..src.instances.len) |i| {
        const prop_start: u32 = @intCast(out.props.items.len);
        const src_start = ins.items(.prop_start)[i];
        const src_count = ins.items(.prop_count)[i];
        for (src.props.items[src_start..][0..src_count]) |p| {
            try out.props.append(a, .{
                .key = try a.dupe(u8, p.key),
                .value = try a.dupe(u8, p.val),
            });
        }
        try out.devices.append(a, .{
            .name = try a.dupe(u8, ins.items(.name)[i]),
            .symbol = try a.dupe(u8, ins.items(.symbol)[i]),
            .kind = ins.items(.kind)[i],
            .x = ins.items(.x)[i],
            .y = ins.items(.y)[i],
            .rot = ins.items(.rot)[i],
            .flip = ins.items(.flip)[i],
            .prop_start = prop_start,
            .prop_count = @intCast(out.props.items.len - prop_start),
        });
    }
}

// ── SPICE generation helpers ────────────────────────────────────────────── //

fn emitTitle(w: anytype, name: []const u8) !void {
    try w.print(".title {s}\n", .{if (name.len > 0) name else "untitled"});
}

fn emitPreamble(
    w: anytype,
    a: Allocator,
    form: *const UniversalNetlistForm,
    registry: *const dev.PdkDeviceRegistry,
) !void {
    var cell_names: List([]const u8) = .{};
    defer cell_names.deinit(a);
    for (form.device_nets.items) |dn| {
        _ = dn;
    }
    // Collect unique cell names from devices
    const devices_slice = form.devices.slice();
    for (0..form.devices.len) |i| {
        try cell_names.append(a, devices_slice.items(.symbol)[i]);
    }
    const preamble = registry.emitPreamble(a, cell_names.items, null) catch return;
    defer a.free(preamble);
    if (preamble.len > 0) try w.writeAll(preamble);
}

fn emitInstances(
    w: anytype,
    a: Allocator,
    form: *const UniversalNetlistForm,
    registry: *const dev.PdkDeviceRegistry,
) !void {
    const devices_slice = form.devices.slice();
    for (0..form.devices.len) |i| {
        const kind_val = devices_slice.items(.kind)[i];
        if (kind_val.isNonElectrical()) continue;
        try emitOneInstance(w, a, form, @intCast(i), kind_val, registry);
    }
}

fn emitOneInstance(
    w: anytype,
    a: Allocator,
    form: *const UniversalNetlistForm,
    idx: u32,
    kind: dev.DeviceKind,
    registry: *const dev.PdkDeviceRegistry,
) !void {
    const devices_slice = form.devices.slice();
    const sym = devices_slice.items(.symbol)[idx];
    const inst_name = devices_slice.items(.name)[idx];
    const spice_dev = registry.resolveDevice(sym, kind) orelse return;

    // Instance names from xschem already include the SPICE prefix (e.g. "R1", "V1").
    // Only prepend the prefix if the name doesn't already start with it.
    if (inst_name.len == 0 or std.ascii.toUpper(inst_name[0]) != spice_dev.prefix) {
        try w.writeByte(spice_dev.prefix);
    }
    try w.writeAll(inst_name);

    try emitNets(w, a, form, idx, spice_dev.pin_order);
    if (spice_dev.model_name) |model| {
        try w.writeByte(' ');
        try w.writeAll(model);
    }
    try emitParams(w, form, idx);
    try w.writeByte('\n');
}

fn emitNets(
    w: anytype,
    a: Allocator,
    form: *const UniversalNetlistForm,
    device_idx: u32,
    pin_order: []const []const u8,
) !void {
    _ = a;
    for (pin_order) |pin_name| {
        try w.writeByte(' ');
        const net = findNetForPin(form, device_idx, pin_name);
        try w.writeAll(net orelse "_unknown_");
    }
}

fn findNetForPin(form: *const UniversalNetlistForm, device_idx: u32, pin_name: []const u8) ?[]const u8 {
    for (form.device_nets.items) |dn| {
        if (dn.device_idx != device_idx) continue;
        if (!std.mem.eql(u8, dn.pin_name, pin_name)) continue;
        if (dn.net_id < form.net_names.items.len) return form.net_names.items[dn.net_id];
        return null;
    }
    return null;
}

fn emitParams(w: anytype, form: *const UniversalNetlistForm, device_idx: u32) !void {
    const devices_slice = form.devices.slice();
    const start = devices_slice.items(.prop_start)[device_idx];
    const count = devices_slice.items(.prop_count)[device_idx];
    for (form.props.items[start..][0..count]) |p| {
        if (std.mem.eql(u8, p.key, "name")) continue;
        if (std.mem.eql(u8, p.key, "symbol")) continue;
        try w.print(" {s}={s}", .{ p.key, p.value });
    }
}

fn baseSymbol(sym: []const u8) []const u8 {
    // Strip path: "devices/resistor.sym" → "resistor"
    const after_slash = if (std.mem.lastIndexOfScalar(u8, sym, '/')) |idx| sym[idx + 1 ..] else sym;
    // Strip extension: "resistor.sym" → "resistor"
    return if (std.mem.indexOfScalar(u8, after_slash, '.')) |idx| after_slash[0..idx] else after_slash;
}

// ── Legacy entry point (kept for backward compat) ───────────────────────── //

/// Placeholder for legacy callers. Use `UniversalNetlistForm.generateSpice` instead.
pub fn GenerateNetlist(obj: UniversalNetlistForm) ?[]u8 {
    _ = obj;
    return null;
}
