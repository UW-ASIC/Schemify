const std = @import("std");
const Allocator = std.mem.Allocator;
const MAL = std.MultiArrayList;
const List = std.ArrayListUnmanaged;

const types = @import("types.zig");
const helpers = @import("helpers.zig");
pub const StringRef = @import("string_pool.zig").StringRef;
pub const StringPool = @import("string_pool.zig").StringPool;

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
pub const ModelDef = types.ModelDef;
pub const SchematicType = types.SchematicType;
pub const DeviceKind = types.DeviceKind;
pub const InstanceFlags = types.InstanceFlags;
pub const Bounds = helpers.Bounds;
const applyRotFlip = helpers.applyRotFlip;

pub const Schemify = struct {
    strings: StringPool = .{},

    name: StringRef = .empty,

    instances: MAL(Instance) = .{},
    wires: MAL(Wire) = .{},
    lines: MAL(Line) = .{},
    rects: MAL(Rect) = .{},
    circles: MAL(Circle) = .{},
    arcs: MAL(Arc) = .{},
    texts: MAL(Text) = .{},
    pins: MAL(Pin) = .{},

    props: List(Property) = .{},
    sym_props: List(Property) = .{},
    sym_data: List(SymData) = .{},
    model_defs: List(ModelDef) = .{},
    globals: List(StringRef) = .{},
    plugin_blocks: List(PluginBlock) = .{},

    spice_body: StringRef = .empty,
    spice_sym_def: StringRef = .empty,
    inline_spice: StringRef = .empty,
    pyspice_source: StringRef = .empty,
    documentation: StringRef = .empty,
    measurements_decl: StringRef = .empty,
    skip_toplevel_code: bool = false,
    prim_cache_dirty: bool = true,
    stype: SchematicType = .schematic,

    prim_cache: []?PrimCacheEntry = &.{},

    // ── Convenience ─────────────────────────────────────────────────────────

    pub fn str(self: *const Schemify, ref: StringRef) []const u8 {
        return self.strings.get(ref);
    }

    // ── Lifecycle ────────────────────────────────────────────────────────────

    pub fn deinit(self: *Schemify, a: Allocator) void {
        // One free for ALL strings
        self.strings.deinit(a);

        // MAL deinits (no per-string frees needed — strings are in pool)
        self.instances.deinit(a);
        self.wires.deinit(a);
        self.lines.deinit(a);
        self.rects.deinit(a);
        self.circles.deinit(a);
        self.arcs.deinit(a);
        self.texts.deinit(a);
        self.pins.deinit(a);

        // List deinits (no per-string frees)
        self.props.deinit(a);
        self.sym_props.deinit(a);
        self.model_defs.deinit(a);
        self.globals.deinit(a);

        // sym_data: free .pins/.props slices only (string content is in pool)
        for (self.sym_data.items) |sd| {
            if (sd.pins.len > 0) a.free(sd.pins);
            if (sd.props.len > 0) a.free(sd.props);
        }
        self.sym_data.deinit(a);

        // plugin_blocks: deinit .entries list only (string content is in pool)
        for (self.plugin_blocks.items) |*pb| pb.entries.deinit(a);
        self.plugin_blocks.deinit(a);

        if (self.prim_cache.len > 0) a.free(self.prim_cache);
        self.* = .{};
    }

    pub fn clone(self: *const Schemify, a: Allocator) Allocator.Error!*Schemify {
        const out = try a.create(Schemify);
        errdefer a.destroy(out);
        out.* = .{
            .skip_toplevel_code = self.skip_toplevel_code,
            .prim_cache_dirty = true,
            .stype = self.stype,
            .name = self.name,
            .spice_body = self.spice_body,
            .spice_sym_def = self.spice_sym_def,
            .inline_spice = self.inline_spice,
            .pyspice_source = self.pyspice_source,
            .documentation = self.documentation,
        };

        // One memcpy for all strings
        out.strings = try self.strings.clonePool(a);
        errdefer out.strings.deinit(a);

        // MALs: StringRef is a u64 value type, copies like any int
        @setEvalBranchQuota(10_000);
        inline for (.{
            .{ "instances", Instance },
            .{ "wires", Wire },
            .{ "lines", Line },
            .{ "rects", Rect },
            .{ "circles", Circle },
            .{ "arcs", Arc },
            .{ "texts", Text },
            .{ "pins", Pin },
        }) |entry| {
            const name_str = entry[0];
            const src = &@field(self.*, name_str);
            const dst = &@field(out.*, name_str);
            try dst.resize(a, src.len);
            if (src.len > 0) {
                const src_slice = src.slice();
                const dst_slice = dst.slice();
                inline for (std.meta.fields(entry[1])) |f| {
                    @memcpy(
                        dst_slice.items(@field(std.meta.FieldEnum(entry[1]), f.name)),
                        src_slice.items(@field(std.meta.FieldEnum(entry[1]), f.name)),
                    );
                }
            }
        }

        // Lists of value types (Property, StringRef)
        try out.props.resize(a, self.props.items.len);
        if (self.props.items.len > 0) @memcpy(out.props.items, self.props.items);

        try out.sym_props.resize(a, self.sym_props.items.len);
        if (self.sym_props.items.len > 0) @memcpy(out.sym_props.items, self.sym_props.items);

        try out.globals.resize(a, self.globals.items.len);
        if (self.globals.items.len > 0) @memcpy(out.globals.items, self.globals.items);

        try out.model_defs.resize(a, self.model_defs.items.len);
        if (self.model_defs.items.len > 0) @memcpy(out.model_defs.items, self.model_defs.items);

        // sym_data: copy struct + dupe .pins/.props slices (no per-string dupe)
        try out.sym_data.resize(a, self.sym_data.items.len);
        for (self.sym_data.items, out.sym_data.items) |ssd, *dsd| {
            dsd.* = ssd;
            if (ssd.pins.len > 0) {
                const dp = try a.alloc(PinRef, ssd.pins.len);
                @memcpy(dp, ssd.pins);
                dsd.pins = dp;
            }
            if (ssd.props.len > 0) {
                const dp = try a.alloc(Property, ssd.props.len);
                @memcpy(dp, ssd.props);
                dsd.props = dp;
            }
        }

        // plugin_blocks: copy .name (StringRef) + resize+memcpy .entries
        try out.plugin_blocks.resize(a, self.plugin_blocks.items.len);
        for (self.plugin_blocks.items, out.plugin_blocks.items) |spb, *dpb| {
            dpb.name = spb.name;
            dpb.entries = .{};
            try dpb.entries.resize(a, spb.entries.items.len);
            if (spb.entries.items.len > 0) @memcpy(dpb.entries.items, spb.entries.items);
        }

        out.prim_cache = &.{};
        return out;
    }

    pub fn deinitClone(self: *Schemify, a: Allocator) void {
        self.deinit(a);
        a.destroy(self);
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
            .content = try self.strings.add(a, self.strings.get(text.content)),
            .x = text.x, .y = text.y,
            .layer = text.layer, .size = text.size, .rotation = text.rotation,
        });
    }

    pub fn drawTextStr(self: *Schemify, a: Allocator, content: []const u8, x: i32, y: i32) !void {
        try self.texts.append(a, .{
            .content = try self.strings.add(a, content),
            .x = x, .y = y,
        });
    }

    pub fn drawPin(self: *Schemify, a: Allocator, pin: Pin) !void {
        try self.pins.append(a, .{
            .name = try self.strings.add(a, self.strings.get(pin.name)),
            .x = pin.x, .y = pin.y,
            .dir = pin.dir, .num = pin.num, .width = pin.width,
        });
    }

    pub fn drawPinStr(self: *Schemify, a: Allocator, name: []const u8, x: i32, y: i32, dir: types.PinDir) !void {
        try self.pins.append(a, .{
            .name = try self.strings.add(a, name),
            .x = x, .y = y, .dir = dir,
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
            .net_name = if (!wire.net_name.isEmpty()) try self.strings.add(a, self.strings.get(wire.net_name)) else .empty,
            .color = wire.color,
            .thickness = wire.thickness,
            .bus = wire.bus,
        });
        return idx;
    }

    pub fn addWireWithNet(self: *Schemify, a: Allocator, x0: i32, y0: i32, x1: i32, y1: i32, net_name: []const u8) !usize {
        const idx = self.wires.len;
        try self.wires.append(a, .{
            .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1,
            .net_name = if (net_name.len > 0) try self.strings.add(a, net_name) else .empty,
        });
        return idx;
    }

    // ── Insert: instances ────────────────────────────────────────────────────

    pub fn symToKind(sym: []const u8) DeviceKind {
        const map = std.StaticStringMap(DeviceKind).initComptime(.{
            .{ "nmos", .nmos4 },
            .{ "pmos", .pmos4 },
            .{ "capacitors", .capacitor },
            .{ "resistors", .resistor },
            .{ "inductors", .inductor },
            .{ "diodes", .diode },
            .{ "ipin", .input_pin },
            .{ "opin", .output_pin },
            .{ "iopin", .inout_pin },
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
        props: []const struct { key: []const u8, val: []const u8 } = &.{},
        conns: []const struct { pin: []const u8, net: []const u8 } = &.{},
        spice_line: []const u8 = "",
        sym_data: ?SymData = null,
    };

    pub fn addComponent(self: *Schemify, a: Allocator, desc: ComponentDesc) !usize {
        const prop_start: u32 = @intCast(self.props.items.len);
        for (desc.props) |p| {
            try self.props.append(a, .{
                .key = try self.strings.add(a, p.key),
                .val = try self.strings.add(a, p.val),
            });
        }
        const idx = self.instances.len;
        try self.instances.append(a, .{
            .name = try self.strings.add(a, desc.name),
            .symbol = try self.strings.add(a, desc.symbol),
            .kind = if (desc.kind != .unknown) desc.kind else symToKind(desc.symbol),
            .x = desc.x, .y = desc.y,
            .prop_start = prop_start,
            .prop_count = @intCast(desc.props.len),
            .spice_line = if (desc.spice_line.len > 0) try self.strings.add(a, desc.spice_line) else .empty,
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

    pub fn setName(self: *Schemify, a: Allocator, name: []const u8) !void {
        self.name = try self.strings.add(a, name);
    }

    pub fn setDocumentation(self: *Schemify, a: Allocator, text: []const u8) !void {
        self.documentation = if (text.len > 0) try self.strings.add(a, text) else .empty;
    }

    pub fn setPySpiceSource(self: *Schemify, a: Allocator, source: []const u8) !void {
        self.pyspice_source = if (source.len > 0) try self.strings.add(a, source) else .empty;
    }

    pub fn addSymProp(self: *Schemify, a: Allocator, key: []const u8, val: []const u8) !void {
        try self.sym_props.append(a, .{
            .key = try self.strings.add(a, key),
            .val = try self.strings.add(a, val),
        });
    }

    pub fn addGlobal(self: *Schemify, a: Allocator, name: []const u8) !void {
        for (self.globals.items) |g| {
            if (std.mem.eql(u8, self.strings.get(g), name)) return;
        }
        try self.globals.append(a, try self.strings.add(a, name));
    }

    pub fn addPluginBlock(self: *Schemify, a: Allocator, name: []const u8, entries: []const struct { key: []const u8, val: []const u8 }) !void {
        var owned: List(Property) = .{};
        for (entries) |e| {
            try owned.append(a, .{
                .key = try self.strings.add(a, e.key),
                .val = try self.strings.add(a, e.val),
            });
        }
        try self.plugin_blocks.append(a, .{
            .name = try self.strings.add(a, name),
            .entries = owned,
        });
    }

    pub fn appendSymData(self: *Schemify, a: Allocator, data: SymData) !void {
        const duped_pins = try a.alloc(PinRef, data.pins.len);
        for (data.pins, 0..) |pin, i| {
            duped_pins[i] = .{
                .name = if (!pin.name.isEmpty()) try self.strings.addSafe(a, self.strings.get(pin.name)) else .empty,
                .dir = pin.dir, .x = pin.x, .y = pin.y, .propag = pin.propag,
            };
        }
        const duped_props = try a.alloc(Property, data.props.len);
        for (data.props, 0..) |prop, i| {
            duped_props[i] = .{
                .key = if (!prop.key.isEmpty()) try self.strings.addSafe(a, self.strings.get(prop.key)) else .empty,
                .val = if (!prop.val.isEmpty()) try self.strings.addSafe(a, self.strings.get(prop.val)) else .empty,
            };
        }
        try self.sym_data.append(a, .{
            .pins = duped_pins,
            .props = duped_props,
            .format = data.format,
            .lvs_format = data.lvs_format,
            .template = data.template,
        });
    }

    pub fn appendSymDataFromStrings(self: *Schemify, a: Allocator, pin_names: []const []const u8, pin_dirs: []const types.PinDir, pin_xs: []const i32, pin_ys: []const i32) !void {
        const n = pin_names.len;
        const duped_pins = try a.alloc(PinRef, n);
        for (0..n) |i| {
            duped_pins[i] = .{
                .name = try self.strings.add(a, pin_names[i]),
                .dir = if (i < pin_dirs.len) pin_dirs[i] else .inout,
                .x = if (i < pin_xs.len) pin_xs[i] else 0,
                .y = if (i < pin_ys.len) pin_ys[i] else 0,
            };
        }
        try self.sym_data.append(a, .{ .pins = duped_pins });
    }

    // ── Remove (swapRemove) ─────────────────────────────────────────────────

    pub fn removeInstance(self: *Schemify, a: Allocator, idx: usize) void {
        _ = a;
        if (idx >= self.instances.len) return;
        self.instances.swapRemove(idx);
        if (idx < self.sym_data.items.len) _ = self.sym_data.swapRemove(idx);
        self.prim_cache_dirty = true;
    }

    pub fn removeWire(self: *Schemify, a: Allocator, idx: usize) void {
        _ = a;
        if (idx >= self.wires.len) return;
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
        _ = a;
        if (idx >= self.texts.len) return;
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

    pub fn moveWire(self: *Schemify, idx: usize, dx: i32, dy: i32) void {
        if (idx >= self.wires.len) return;
        self.wires.items(.x0)[idx] += dx;
        self.wires.items(.y0)[idx] += dy;
        self.wires.items(.x1)[idx] += dx;
        self.wires.items(.y1)[idx] += dy;
    }

    pub fn setInstanceName(self: *Schemify, a: Allocator, idx: usize, name: []const u8) !void {
        if (idx >= self.instances.len) return;
        self.instances.items(.name)[idx] = try self.strings.add(a, name);
    }

    pub fn setWireNetName(self: *Schemify, a: Allocator, idx: usize, name: []const u8) !void {
        if (idx >= self.wires.len) return;
        self.wires.items(.net_name)[idx] = if (name.len > 0) try self.strings.add(a, name) else .empty;
    }

    pub fn setInstanceProperty(self: *Schemify, a: Allocator, idx: usize, key: []const u8, val: []const u8) !void {
        if (idx >= self.instances.len) return error.OutOfBounds;
        const prop_starts = self.instances.items(.prop_start);
        const prop_counts = self.instances.items(.prop_count);
        const start: usize = prop_starts[idx];
        const count: usize = prop_counts[idx];
        for (self.props.items[start .. start + count]) |*prop| {
            if (std.mem.eql(u8, self.strings.get(prop.key), key)) {
                prop.val = try self.strings.add(a, val);
                return;
            }
        }
        const end: usize = self.props.items.len;
        if (start + count != end) {
            const new_start: u32 = @intCast(end);
            var i: usize = 0;
            while (i < count) : (i += 1) {
                const prop = self.props.items[start + i];
                try self.props.append(a, prop);
            }
            prop_starts[idx] = new_start;
        }
        try self.props.append(a, .{
            .key = try self.strings.add(a, key),
            .val = try self.strings.add(a, val),
        });
        prop_counts[idx] += 1;
    }

    pub const OutOfBounds = error{OutOfBounds};

    // ── Prim cache ───────────────────────────────────────────────────────────

    pub fn rebuildPrimCache(self: *Schemify, a: Allocator) void {
        const n = self.instances.len;
        if (self.prim_cache.len > 0) a.free(self.prim_cache);
        self.prim_cache = a.alloc(?PrimCacheEntry, n) catch {
            self.prim_cache = &.{};
            return;
        };
        @memset(self.prim_cache, null);
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
};

test "Schemify basic lifecycle" {
    const a = std.testing.allocator;
    var s: Schemify = .{};
    defer s.deinit(a);

    const wi = try s.addWire(a, 0, 0, 100, 0);
    try std.testing.expectEqual(@as(usize, 0), wi);
    try std.testing.expectEqual(@as(usize, 1), s.wires.len);

    const ii = try s.addComponent(a, .{ .name = "R1", .symbol = "resistor", .x = 50, .y = 0 });
    try std.testing.expectEqual(@as(usize, 0), ii);
    try std.testing.expectEqual(@as(usize, 1), s.instances.len);
    try std.testing.expectEqualStrings("R1", s.str(s.instances.items(.name)[0]));

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

test "Schemify clone" {
    const a = std.testing.allocator;
    var s: Schemify = .{};
    defer s.deinit(a);

    try s.setName(a, "test_schematic");
    _ = try s.addComponent(a, .{ .name = "R1", .symbol = "resistor", .x = 10, .y = 20 });
    _ = try s.addWire(a, 0, 0, 100, 0);

    const c = try s.clone(a);
    defer c.deinitClone(a);

    try std.testing.expectEqualStrings("test_schematic", c.str(c.name));
    try std.testing.expectEqual(@as(usize, 1), c.instances.len);
    try std.testing.expectEqualStrings("R1", c.str(c.instances.items(.name)[0]));
    try std.testing.expectEqual(@as(usize, 1), c.wires.len);
}

test "Schemify string pool" {
    const a = std.testing.allocator;
    var s: Schemify = .{};
    defer s.deinit(a);

    _ = try s.addComponent(a, .{ .name = "M1", .symbol = "nmos4", .x = 0, .y = 0 });
    _ = try s.addComponent(a, .{ .name = "M2", .symbol = "pmos4", .x = 100, .y = 0 });

    try std.testing.expectEqualStrings("M1", s.str(s.instances.items(.name)[0]));
    try std.testing.expectEqualStrings("M2", s.str(s.instances.items(.name)[1]));
    try std.testing.expectEqualStrings("nmos4", s.str(s.instances.items(.symbol)[0]));
    try std.testing.expectEqualStrings("pmos4", s.str(s.instances.items(.symbol)[1]));
}
