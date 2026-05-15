const std = @import("std");
const Allocator = std.mem.Allocator;
const MAL = std.MultiArrayList;
const List = std.ArrayListUnmanaged;

const types = @import("types.zig");
const helpers = @import("helpers.zig");

pub const Instance = types.Instance;
pub const Wire = types.Wire;
pub const Pin = types.Pin;
pub const Property = types.Property;
pub const Conn = types.Conn;
pub const Net = types.Net;
pub const NetConn = types.NetConn;
pub const NetMap = types.NetMap;
pub const Line = types.Line;
pub const Rect = types.Rect;
pub const Circle = types.Circle;
pub const Arc = types.Arc;
pub const Text = types.Text;
pub const PinRef = types.PinRef;
pub const SymData = types.SymData;
pub const PrimCacheEntry = types.PrimCacheEntry;
pub const PluginBlock = types.PluginBlock;
pub const SchematicType = types.SchematicType;
pub const DeviceKind = types.DeviceKind;
pub const InstanceFlags = types.InstanceFlags;
pub const Bounds = helpers.Bounds;
const applyRotFlip = helpers.applyRotFlip;

pub const Schemify = struct {
    name: []const u8 = "",

    instances: MAL(Instance) = .{},
    wires: MAL(Wire) = .{},
    lines: MAL(Line) = .{},
    rects: MAL(Rect) = .{},
    circles: MAL(Circle) = .{},
    arcs: MAL(Arc) = .{},
    texts: MAL(Text) = .{},
    pins: MAL(Pin) = .{},

    props: List(Property) = .{},
    conns: List(Conn) = .{},
    nets: List(Net) = .{},
    net_conns: List(NetConn) = .{},
    sym_props: List(Property) = .{},
    sym_data: List(SymData) = .{},
    globals: List([]const u8) = .{},
    plugin_blocks: List(PluginBlock) = .{},

    spice_body: ?[]const u8 = null,
    spice_sym_def: ?[]const u8 = null,
    inline_spice: ?[]const u8 = null,
    skip_toplevel_code: bool = false,
    prim_cache_dirty: bool = true,
    stype: SchematicType = .schematic,

    prim_cache: []?PrimCacheEntry = &.{},

    // ── Lifecycle ────────────────────────────────────────────────────────────

    pub fn deinit(self: *Schemify, a: Allocator) void {
        // Free duped strings inside instances
        const inst_names = self.instances.items(.name);
        const inst_syms = self.instances.items(.symbol);
        const inst_spice = self.instances.items(.spice_line);
        for (0..self.instances.len) |i| {
            freeStr(a, inst_names[i]);
            freeStr(a, inst_syms[i]);
            freeOptStr(a, inst_spice[i]);
        }
        self.instances.deinit(a);

        // Free duped net_name inside wires
        const wire_nets = self.wires.items(.net_name);
        for (0..self.wires.len) |i| freeOptStr(a, wire_nets[i]);
        self.wires.deinit(a);

        self.lines.deinit(a);
        self.rects.deinit(a);
        self.circles.deinit(a);
        self.arcs.deinit(a);

        // Free duped content inside texts
        for (self.texts.items(.content)) |c| freeStr(a, c);
        self.texts.deinit(a);

        // Free duped name inside pins
        const pin_names = self.pins.items(.name);
        for (0..self.pins.len) |i| freeStr(a, pin_names[i]);
        self.pins.deinit(a);

        // Free duped key/val in props, sym_props
        for (self.props.items) |p| { freeStr(a, p.key); freeStr(a, p.val); }
        self.props.deinit(a);

        // Free duped pin/net in conns
        for (self.conns.items) |c| { freeStr(a, c.pin); freeStr(a, c.net); }
        self.conns.deinit(a);

        // Free duped name in nets
        for (self.nets.items) |n| freeStr(a, n.name);
        self.nets.deinit(a);

        // Free optional pin_or_label in net_conns
        for (self.net_conns.items) |nc| freeOptStr(a, nc.pin_or_label);
        self.net_conns.deinit(a);

        for (self.sym_props.items) |p| { freeStr(a, p.key); freeStr(a, p.val); }
        self.sym_props.deinit(a);

        self.sym_data.deinit(a);

        // Free duped globals
        for (self.globals.items) |g| freeStr(a, g);
        self.globals.deinit(a);

        // Free plugin blocks (name + entry key/vals)
        for (self.plugin_blocks.items) |*pb| {
            freeStr(a, pb.name);
            for (pb.entries.items) |e| { freeStr(a, e.key); freeStr(a, e.val); }
            pb.entries.deinit(a);
        }
        self.plugin_blocks.deinit(a);

        // Free optional allocated strings
        freeStr(a, self.name);
        freeOptStr(a, self.spice_body);
        freeOptStr(a, self.spice_sym_def);
        freeOptStr(a, self.inline_spice);

        if (self.prim_cache.len > 0) a.free(self.prim_cache);
        self.* = .{};
    }

    fn freeStr(a: Allocator, s: []const u8) void {
        if (s.len > 0) a.free(@constCast(s));
    }

    fn freeOptStr(a: Allocator, s: ?[]const u8) void {
        if (s) |str| freeStr(a, str);
    }

    // ── Delegation: fileio / simulation ──────────────────────────────────────

    pub fn readFile(data: []const u8, a: Allocator, logger: anytype) Schemify {
        _ = logger;
        return @import("fileio/Reader.zig").readCHN(data, a);
    }

    pub fn writeFile(self: *Schemify, a: Allocator, logger: anytype) ?[]u8 {
        _ = logger;
        return @import("fileio/Writer.zig").writeCHN(a, self);
    }

    pub fn emitSpice(self: *const Schemify, a: Allocator, pdk: anytype) ![]u8 {
        return @import("simulation/Netlist.zig").emitSpice(self, a, pdk);
    }

    // ── Insert: geometry ─────────────────────────────────────────────────────

    pub fn drawLine(self: *Schemify, a: Allocator, line: Line) !void {
        try self.lines.append(a, line);
    }

    pub fn drawRect(self: *Schemify, a: Allocator, rect: Rect) !void {
        try self.rects.append(a, rect);
    }

    pub fn drawCircle(self: *Schemify, a: Allocator, circle: Circle) !void {
        try self.circles.append(a, circle);
    }

    pub fn drawArc(self: *Schemify, a: Allocator, arc: Arc) !void {
        try self.arcs.append(a, arc);
    }

    pub fn drawText(self: *Schemify, a: Allocator, text: Text) !void {
        try self.texts.append(a, .{
            .content = try a.dupe(u8, text.content),
            .x = text.x, .y = text.y,
            .layer = text.layer, .size = text.size, .rotation = text.rotation,
        });
    }

    pub fn drawPin(self: *Schemify, a: Allocator, pin: Pin) !void {
        try self.pins.append(a, .{
            .name = try a.dupe(u8, pin.name),
            .x = pin.x, .y = pin.y,
            .dir = pin.dir, .num = pin.num, .width = pin.width,
        });
    }

    // ── Insert: wires ────────────────────────────────────────────────────────

    pub fn addWire(self: *Schemify, a: Allocator, x0: i32, y0: i32, x1: i32, y1: i32) !usize {
        const idx = self.wires.len;
        try self.wires.append(a, .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1 });
        return idx;
    }

    pub fn addWireFull(self: *Schemify, a: Allocator, wire: Wire) !usize {
        const idx = self.wires.len;
        try self.wires.append(a, .{
            .x0 = wire.x0, .y0 = wire.y0, .x1 = wire.x1, .y1 = wire.y1,
            .net_name = if (wire.net_name) |n| try a.dupe(u8, n) else null,
            .bus = wire.bus,
        });
        return idx;
    }

    // ── Insert: instances ────────────────────────────────────────────────────

    pub fn addInstance(self: *Schemify, a: Allocator, name: []const u8, symbol: []const u8, x: i32, y: i32) !usize {
        return self.addInstanceWithKind(a, name, symbol, x, y, symToKind(symbol));
    }

    pub fn addInstanceWithKind(self: *Schemify, a: Allocator, name: []const u8, symbol: []const u8, x: i32, y: i32, kind: DeviceKind) !usize {
        const idx = self.instances.len;
        try self.instances.append(a, .{
            .name = try a.dupe(u8, name),
            .symbol = try a.dupe(u8, symbol),
            .x = x, .y = y,
            .kind = kind,
        });
        try self.sym_data.append(a, .{});
        self.prim_cache_dirty = true;
        return idx;
    }

    pub fn symToKind(sym: []const u8) DeviceKind {
        const map = std.StaticStringMap(DeviceKind).initComptime(.{
            // Aliases from file format
            .{ "nmos", .nmos4 },
            .{ "pmos", .pmos4 },
            .{ "capacitors", .capacitor },
            .{ "resistors", .resistor },
            .{ "inductors", .inductor },
            .{ "diodes", .diode },
            .{ "ipin", .input_pin },
            .{ "opin", .output_pin },
            .{ "iopin", .inout_pin },
            // Block primitives
            .{ "digital_block", .digital_instance },
            .{ "verilog_a_block", .hdl },
            .{ "spice_block", .code },
        });
        if (map.get(sym)) |k| return k;
        return std.meta.stringToEnum(DeviceKind, sym) orelse .subckt;
    }

    pub const ComponentDesc = struct {
        name: []const u8,
        symbol: []const u8,
        kind: DeviceKind = .unknown,
        x: i32, y: i32,
        rot: u2 = 0, flip: bool = false,
        props: []const Property = &.{},
        conns: []const Conn = &.{},
        spice_line: ?[]const u8 = null,
        sym_data: ?SymData = null,
    };

    pub fn addComponent(self: *Schemify, a: Allocator, desc: ComponentDesc) !usize {
        const prop_start: u32 = @intCast(self.props.items.len);
        for (desc.props) |p| {
            try self.props.append(a, .{
                .key = try a.dupe(u8, p.key),
                .val = try a.dupe(u8, p.val),
            });
        }
        const conn_start: u32 = @intCast(self.conns.items.len);
        for (desc.conns) |c| {
            try self.conns.append(a, .{
                .pin = try a.dupe(u8, c.pin),
                .net = try a.dupe(u8, c.net),
            });
        }
        const idx = self.instances.len;
        try self.instances.append(a, .{
            .name = try a.dupe(u8, desc.name),
            .symbol = try a.dupe(u8, desc.symbol),
            .kind = desc.kind,
            .x = desc.x, .y = desc.y,
            .prop_start = prop_start,
            .prop_count = @intCast(desc.props.len),
            .conn_start = conn_start,
            .conn_count = @intCast(desc.conns.len),
            .spice_line = if (desc.spice_line) |s| try a.dupe(u8, s) else null,
            .flags = .{ .rot = desc.rot, .flip = desc.flip },
        });
        if (desc.sym_data) |sd| {
            try self.appendSymData(a, sd);
        } else {
            try self.sym_data.append(a, .{});
        }
        self.prim_cache_dirty = true;
        return idx;
    }

    // ── Insert: metadata ─────────────────────────────────────────────────────

    pub fn setName(self: *Schemify, a: Allocator, name: []const u8) void {
        freeStr(a, self.name);
        self.name = a.dupe(u8, name) catch name;
    }

    pub fn addSymProp(self: *Schemify, a: Allocator, key: []const u8, val: []const u8) !void {
        try self.sym_props.append(a, .{
            .key = try a.dupe(u8, key),
            .val = try a.dupe(u8, val),
        });
    }

    pub fn addGlobal(self: *Schemify, a: Allocator, name: []const u8) !void {
        for (self.globals.items) |g| if (std.mem.eql(u8, g, name)) return;
        try self.globals.append(a, try a.dupe(u8, name));
    }

    pub fn addPluginBlock(self: *Schemify, a: Allocator, name: []const u8, entries: []const Property) !void {
        var owned: List(Property) = .{};
        for (entries) |e| {
            try owned.append(a, .{
                .key = try a.dupe(u8, e.key),
                .val = try a.dupe(u8, e.val),
            });
        }
        try self.plugin_blocks.append(a, .{
            .name = try a.dupe(u8, name),
            .entries = owned,
        });
    }

    pub fn appendSymData(self: *Schemify, a: Allocator, data: SymData) !void {
        const duped_pins = try a.alloc(PinRef, data.pins.len);
        for (data.pins, 0..) |pin, i| {
            duped_pins[i] = .{
                .name = try a.dupe(u8, pin.name),
                .dir = pin.dir, .x = pin.x, .y = pin.y, .propag = pin.propag,
            };
        }
        const duped_props = try a.alloc(Property, data.props.len);
        for (data.props, 0..) |prop, i| {
            duped_props[i] = .{
                .key = try a.dupe(u8, prop.key),
                .val = try a.dupe(u8, prop.val),
            };
        }
        try self.sym_data.append(a, .{
            .pins = duped_pins,
            .props = duped_props,
            .format = if (data.format) |f| try a.dupe(u8, f) else null,
            .lvs_format = if (data.lvs_format) |f| try a.dupe(u8, f) else null,
            .template = if (data.template) |t| try a.dupe(u8, t) else null,
        });
    }

    // ── Remove (swapRemove — last element takes the removed index) ───────────

    pub fn removeInstance(self: *Schemify, a: Allocator, idx: usize) void {
        if (idx >= self.instances.len) return;
        const inst = self.instances.get(idx);
        freeStr(a, inst.name);
        freeStr(a, inst.symbol);
        freeOptStr(a, inst.spice_line);
        self.instances.swapRemove(idx);
        if (idx < self.sym_data.items.len) _ = self.sym_data.swapRemove(idx);
        self.prim_cache_dirty = true;
    }

    pub fn removeWire(self: *Schemify, a: Allocator, idx: usize) void {
        if (idx >= self.wires.len) return;
        freeOptStr(a, self.wires.items(.net_name)[idx]);
        self.wires.swapRemove(idx);
    }

    pub fn removeLine(self: *Schemify, a: Allocator, idx: usize) void {
        _ = a;
        if (idx >= self.lines.len) return;
        self.lines.swapRemove(idx);
    }

    pub fn removeRect(self: *Schemify, a: Allocator, idx: usize) void {
        _ = a;
        if (idx >= self.rects.len) return;
        self.rects.swapRemove(idx);
    }

    pub fn removeCircle(self: *Schemify, a: Allocator, idx: usize) void {
        _ = a;
        if (idx >= self.circles.len) return;
        self.circles.swapRemove(idx);
    }

    pub fn removeArc(self: *Schemify, a: Allocator, idx: usize) void {
        _ = a;
        if (idx >= self.arcs.len) return;
        self.arcs.swapRemove(idx);
    }

    pub fn removeText(self: *Schemify, a: Allocator, idx: usize) void {
        if (idx >= self.texts.len) return;
        freeStr(a, self.texts.items(.content)[idx]);
        self.texts.swapRemove(idx);
    }

    pub fn removePin(self: *Schemify, a: Allocator, idx: usize) void {
        _ = a;
        if (idx >= self.pins.len) return;
        self.pins.swapRemove(idx);
    }

    // ── Edit existing elements ───────────────────────────────────────────────

    pub fn moveInstance(self: *Schemify, idx: usize, dx: i32, dy: i32) void {
        if (idx >= self.instances.len) return;
        self.instances.items(.x)[idx] += dx;
        self.instances.items(.y)[idx] += dy;
    }

    pub fn setInstancePos(self: *Schemify, idx: usize, x: i32, y: i32) void {
        if (idx >= self.instances.len) return;
        self.instances.items(.x)[idx] = x;
        self.instances.items(.y)[idx] = y;
    }

    pub fn setInstanceTransform(self: *Schemify, idx: usize, rot: u2, flip: bool) void {
        if (idx >= self.instances.len) return;
        self.instances.items(.flags)[idx].rot = rot;
        self.instances.items(.flags)[idx].flip = flip;
    }

    pub fn setPinWidth(self: *Schemify, idx: usize, width: u16) void {
        if (idx >= self.pins.len) return;
        self.pins.items(.width)[idx] = if (width == 0) 1 else width;
    }

    // ── Net resolution ───────────────────────────────────────────────────────

    pub fn resolveNets(self: *Schemify, a: Allocator) void {
        self.nets.items.len = 0;
        self.net_conns.items.len = 0;
        self.conns.items.len = 0;
        @memset(self.instances.items(.conn_start), 0);
        @memset(self.instances.items(.conn_count), 0);
        if (self.wires.len == 0 and self.instances.len == 0) return;

        // Union-find on point keys
        var parents = std.AutoHashMapUnmanaged(u64, u64){};
        defer parents.deinit(a);

        const makeSet = struct {
            fn f(p: *std.AutoHashMapUnmanaged(u64, u64), alloc: Allocator, k: u64) void {
                _ = p.getOrPut(alloc, k) catch return;
            }
        }.f;

        const find = struct {
            fn f(p: *std.AutoHashMapUnmanaged(u64, u64), k: u64) u64 {
                var cur = k;
                while (true) {
                    const parent = p.get(cur) orelse return cur;
                    if (parent == cur) return cur;
                    cur = parent;
                }
            }
        }.f;

        const unite = struct {
            fn f(p: *std.AutoHashMapUnmanaged(u64, u64), alloc: Allocator, x: u64, y: u64) void {
                const rx = find(p, x);
                const ry = find(p, y);
                if (rx != ry) p.put(alloc, rx, ry) catch {};
            }
        }.f;

        // Wire endpoints
        const wx0 = self.wires.items(.x0);
        const wy0 = self.wires.items(.y0);
        const wx1 = self.wires.items(.x1);
        const wy1 = self.wires.items(.y1);

        for (0..self.wires.len) |i| {
            const k0 = NetMap.pointKey(wx0[i], wy0[i]);
            const k1 = NetMap.pointKey(wx1[i], wy1[i]);
            makeSet(&parents, a, k0);
            makeSet(&parents, a, k1);
            unite(&parents, a, k0, k1);
        }

        // T-junctions
        const wbus = self.wires.items(.bus);
        for (0..self.wires.len) |i| {
            for ([2]struct { x: i32, y: i32 }{
                .{ .x = wx0[i], .y = wy0[i] },
                .{ .x = wx1[i], .y = wy1[i] },
            }) |pt| {
                const kp = NetMap.pointKey(pt.x, pt.y);
                for (0..self.wires.len) |j| {
                    if (j == i or wbus[j]) continue;
                    const on_interior = blk: {
                        if (wy0[j] == wy1[j] and pt.y == wy0[j]) {
                            break :blk @min(wx0[j], wx1[j]) < pt.x and pt.x < @max(wx0[j], wx1[j]);
                        } else if (wx0[j] == wx1[j] and pt.x == wx0[j]) {
                            break :blk @min(wy0[j], wy1[j]) < pt.y and pt.y < @max(wy0[j], wy1[j]);
                        }
                        break :blk false;
                    };
                    if (on_interior) unite(&parents, a, kp, NetMap.pointKey(wx0[j], wy0[j]));
                }
            }
        }

        // Instance pin positions from sym_data
        if (self.sym_data.items.len > 0) {
            const ix = self.instances.items(.x);
            const iy = self.instances.items(.y);
            const iflags = self.instances.items(.flags);
            const ikind = self.instances.items(.kind);
            for (0..self.instances.len) |i| {
                if (ikind[i].isNonElectrical()) continue;
                if (i >= self.sym_data.items.len) continue;
                const sd = self.sym_data.items[i];
                for (sd.pins) |pin| {
                    const abs = applyRotFlip(pin.x, pin.y, iflags[i].rot, iflags[i].flip, ix[i], iy[i]);
                    const k = NetMap.pointKey(abs.x, abs.y);
                    makeSet(&parents, a, k);
                    // Try to unite with touching wire
                    for (0..self.wires.len) |wi| {
                        const touches = (abs.x == wx0[wi] and abs.y == wy0[wi]) or
                            (abs.x == wx1[wi] and abs.y == wy1[wi]);
                        if (touches) {
                            unite(&parents, a, k, NetMap.pointKey(wx0[wi], wy0[wi]));
                            break;
                        }
                    }
                }
            }
        }

        // Collect root -> name from wire net_name annotations
        const RootName = struct { root: u64, name: []const u8 };
        var root_names = List(RootName){};
        defer root_names.deinit(a);

        {
            const wnn = self.wires.items(.net_name);
            for (0..self.wires.len) |i| {
                const name = wnn[i] orelse continue;
                const k = NetMap.pointKey(wx0[i], wy0[i]);
                makeSet(&parents, a, k);
                const root = find(&parents, k);
                var found = false;
                for (root_names.items) |*rn| {
                    if (rn.root == root) {
                        if (netNameRank(name) > netNameRank(rn.name)) rn.name = name;
                        found = true;
                        break;
                    }
                }
                if (!found) root_names.append(a, .{ .root = root, .name = name }) catch {};
            }
        }

        // Auto-name unnamed nets
        var auto_idx: u32 = 1;
        for (root_names.items) |rn| {
            if (isAutoNetName(rn.name)) {
                const n = std.fmt.parseInt(u32, rn.name[3..], 10) catch continue;
                if (n >= auto_idx) auto_idx = n + 1;
            }
        }

        for (0..self.wires.len) |i| {
            for ([2]u64{ NetMap.pointKey(wx0[i], wy0[i]), NetMap.pointKey(wx1[i], wy1[i]) }) |k| {
                const root = find(&parents, k);
                var found = false;
                for (root_names.items) |rn| if (rn.root == root) { found = true; break; };
                if (!found) {
                    const nm = std.fmt.allocPrint(a, "net{d}", .{auto_idx}) catch continue;
                    auto_idx += 1;
                    root_names.append(a, .{ .root = root, .name = nm }) catch {};
                }
            }
        }

        // Build net list
        var root_to_id = std.AutoHashMapUnmanaged(u64, u32){};
        defer root_to_id.deinit(a);
        for (root_names.items) |rn| {
            const id: u32 = @intCast(self.nets.items.len);
            self.nets.append(a, .{ .name = rn.name }) catch continue;
            root_to_id.put(a, rn.root, id) catch {};
        }

        // Wire net_conns
        for (0..self.wires.len) |i| {
            for ([2][2]i32{ .{ wx0[i], wy0[i] }, .{ wx1[i], wy1[i] } }) |ep| {
                const root = find(&parents, NetMap.pointKey(ep[0], ep[1]));
                const nid = root_to_id.get(root) orelse continue;
                self.net_conns.append(a, .{
                    .net_id = nid, .kind = .wire_endpoint,
                    .ref_a = ep[0], .ref_b = ep[1],
                }) catch {};
            }
        }

        // Instance conns
        {
            const ix = self.instances.items(.x);
            const iy = self.instances.items(.y);
            const iflags = self.instances.items(.flags);
            var ics = self.instances.items(.conn_start);
            var icc = self.instances.items(.conn_count);
            for (0..self.instances.len) |i| {
                if (i >= self.sym_data.items.len) continue;
                const sd = self.sym_data.items[i];
                if (sd.pins.len == 0) continue;
                ics[i] = @intCast(self.conns.items.len);
                for (sd.pins) |pin| {
                    const abs = applyRotFlip(pin.x, pin.y, iflags[i].rot, iflags[i].flip, ix[i], iy[i]);
                    const k = NetMap.pointKey(abs.x, abs.y);
                    makeSet(&parents, a, k);
                    const root = find(&parents, k);
                    const nid = root_to_id.get(root);
                    const net_name: []const u8 = if (nid) |id|
                        (if (id < self.nets.items.len) self.nets.items[id].name else "?")
                    else
                        "?";
                    self.conns.append(a, .{
                        .pin = a.dupe(u8, pin.name) catch pin.name,
                        .net = net_name,
                    }) catch {};
                    if (nid) |id|
                        self.net_conns.append(a, .{
                            .net_id = id, .kind = .instance_pin,
                            .ref_a = abs.x, .ref_b = abs.y,
                        }) catch {};
                }
                icc[i] = @intCast(self.conns.items.len - ics[i]);
            }
        }
    }

    // ── Prim cache ───────────────────────────────────────────────────────────

    pub fn rebuildPrimCache(self: *Schemify, a: Allocator) void {
        const n = self.instances.len;
        if (self.prim_cache.len > 0) a.free(self.prim_cache);
        self.prim_cache = a.alloc(?PrimCacheEntry, n) catch {
            self.prim_cache = &.{};
            return;
        };
        @memset(self.prim_cache, null);
        // Actual population delegated to devices/ module at integration time.
        self.prim_cache_dirty = false;
    }

    pub fn rebuildSymData(self: *Schemify, a: Allocator) void {
        const n = self.instances.len;
        if (n == 0) return;
        while (self.sym_data.items.len < n) {
            self.sym_data.append(a, .{}) catch return;
        }
        for (0..n) |i| {
            if (self.sym_data.items[i].pins.len > 0) continue;
            if (i >= self.prim_cache.len) continue;
            const entry = self.prim_cache[i] orelse continue;
            if (entry.pin_positions.len == 0) continue;
            const pins = a.alloc(PinRef, entry.pin_positions.len) catch continue;
            for (entry.pin_positions, 0..) |p, pi| {
                pins[pi] = .{ .name = p.name, .x = p.x, .y = p.y };
            }
            self.sym_data.items[i] = .{ .pins = pins };
        }
    }

    // ── Bounding box ─────────────────────────────────────────────────────────

    fn bumpSegments(b: *Bounds, x0: []const i32, y0: []const i32, x1: []const i32, y1: []const i32) void {
        for (0..x0.len) |i| {
            b.bump(@floatFromInt(x0[i]), @floatFromInt(y0[i]));
            b.bump(@floatFromInt(x1[i]), @floatFromInt(y1[i]));
        }
    }

    pub fn bounds(self: *const Schemify, inst_pad: f32) Bounds {
        var b: Bounds = .{};
        if (self.lines.len > 0)
            bumpSegments(&b, self.lines.items(.x0), self.lines.items(.y0), self.lines.items(.x1), self.lines.items(.y1));
        if (self.rects.len > 0)
            bumpSegments(&b, self.rects.items(.x0), self.rects.items(.y0), self.rects.items(.x1), self.rects.items(.y1));
        if (self.wires.len > 0)
            bumpSegments(&b, self.wires.items(.x0), self.wires.items(.y0), self.wires.items(.x1), self.wires.items(.y1));
        if (self.circles.len > 0) {
            const cx = self.circles.items(.cx);
            const cy = self.circles.items(.cy);
            const cr = self.circles.items(.radius);
            for (0..self.circles.len) |i| {
                const fx: f32 = @floatFromInt(cx[i]);
                const fy: f32 = @floatFromInt(cy[i]);
                const fr: f32 = @floatFromInt(cr[i]);
                b.bump(fx - fr, fy - fr);
                b.bump(fx + fr, fy + fr);
            }
        }
        if (self.arcs.len > 0) {
            const acx = self.arcs.items(.cx);
            const acy = self.arcs.items(.cy);
            const acr = self.arcs.items(.radius);
            for (0..self.arcs.len) |i| {
                const fx: f32 = @floatFromInt(acx[i]);
                const fy: f32 = @floatFromInt(acy[i]);
                const fr: f32 = @floatFromInt(acr[i]);
                b.bump(fx - fr, fy - fr);
                b.bump(fx + fr, fy + fr);
            }
        }
        if (self.pins.len > 0) {
            const px = self.pins.items(.x);
            const py = self.pins.items(.y);
            for (0..self.pins.len) |i| b.bump(@floatFromInt(px[i]), @floatFromInt(py[i]));
        }
        if (self.texts.len > 0) {
            const tx = self.texts.items(.x);
            const ty = self.texts.items(.y);
            for (0..self.texts.len) |i| b.bump(@floatFromInt(tx[i]), @floatFromInt(ty[i]));
        }
        if (self.instances.len > 0) {
            const ix = self.instances.items(.x);
            const iy = self.instances.items(.y);
            for (0..self.instances.len) |i| {
                const fx: f32 = @floatFromInt(ix[i]);
                const fy: f32 = @floatFromInt(iy[i]);
                b.bump(fx - inst_pad, fy - inst_pad);
                b.bump(fx + inst_pad, fy + inst_pad);
            }
        }
        return b;
    }

    // ── Helpers (private) ────────────────────────────────────────────────────

    fn isAutoNetName(name: []const u8) bool {
        return name.len > 3 and std.mem.startsWith(u8, name, "net") and std.ascii.isDigit(name[3]);
    }

    fn netNameRank(name: []const u8) u8 {
        if (name.len == 0) return 0;
        if (isAutoNetName(name)) return 1;
        if (std.mem.eql(u8, name, "0")) return 2;
        return 3;
    }
};

test "Schemify basic lifecycle" {
    const a = std.testing.allocator;
    var s: Schemify = .{};
    defer s.deinit(a);

    const wi = try s.addWire(a, 0, 0, 100, 0);
    try std.testing.expectEqual(@as(usize, 0), wi);
    try std.testing.expectEqual(@as(usize, 1), s.wires.len);

    const ii = try s.addInstance(a, "R1", "resistor", 50, 0);
    try std.testing.expectEqual(@as(usize, 0), ii);
    try std.testing.expectEqual(@as(usize, 1), s.instances.len);

    s.removeWire(a, 0);
    try std.testing.expectEqual(@as(usize, 0), s.wires.len);

    s.removeInstance(a, 0);
    try std.testing.expectEqual(@as(usize, 0), s.instances.len);
}

test "Schemify bounds" {
    const a = std.testing.allocator;
    var s: Schemify = .{};
    defer s.deinit(a);

    _ = try s.addWire(a, -10, -20, 30, 40);
    const b = s.bounds(0);
    try std.testing.expect(b.has_data);
    try std.testing.expectEqual(@as(f32, -10), b.min_x);
    try std.testing.expectEqual(@as(f32, 30), b.max_x);
    try std.testing.expectEqual(@as(f32, -20), b.min_y);
    try std.testing.expectEqual(@as(f32, 40), b.max_y);
}
