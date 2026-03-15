//! Schemify — flat struct-of-arrays store with CHN read/write and net resolution.
//!
//! Storage: std.MultiArrayList for wires, instances, pins, lines, rects, arcs,
//! circles, texts. Arena-backed. No vtable, no anyopaque.
//!
//! FileIOIF contract (comptime duck-typed by FileIO.zig):
//!   readFile(data, backing, logger) Schemify
//!   writeFile(self, alloc, logger)  ?[]u8
//!
//! Error policy: parsers log warnings and continue; readFile always succeeds.
//! writeFile / resolveNets return null / void on failure; check logger.hasErrors().
//!
//! Symbol resolution: see SymbolLibrary.zig — comptime duck-typing, no vtable.
//!
//! Known issues
//! ────────────
//! 1. conn_count is always 0 in XSchem-sourced files. Connections are resolved
//!    geometrically. The Conn store is only populated after a round-trip through
//!    writeFile + readFile with an explicit netlist.
//! 2. resolveNets only injects net names for single-origin devices (gnd/vdd/
//!    lab_pin). Multi-pin instance connectivity relies on geometric proximity.

const std = @import("std");
const Allocator = std.mem.Allocator;
const MAL = std.MultiArrayList;
const List = std.ArrayListUnmanaged;
const log = @import("Logger.zig");
const dev = @import("Device.zig");
const simd = @import("Parse.zig");
const geo = @import("Geometry.zig");

pub const DeviceKind = dev.DeviceKind;
pub const Pdk = dev.Pdk;
pub const SpiceDialect = dev.SpiceDialect;
pub const ResolvedDevice = dev.ResolvedDevice;

pub const Point = geo.Point;
pub const Transform = geo.Transform;
pub const TransformOp = geo.TransformOp;
pub const PinDir = geo.PinDir;

// ── DOD element structs ──────────────────────────────────────────────────── //

pub const Line   = struct { layer: u8, x0: i32, y0: i32, x1: i32, y1: i32 };
/// Rect is not packed (carries optional image_data pointer).
pub const Rect   = struct {
    layer: u8, x0: i32, y0: i32, x1: i32, y1: i32,
    image_data: ?[]const u8 = null,
};
pub const Circle = struct { layer: u8, cx: i32, cy: i32, radius: i32 };

/// Arc on a layer. Angles in degrees.
pub const Arc = struct { layer: u8, cx: i32, cy: i32, radius: i32, start_angle: i16, sweep_angle: i16 };

/// Electrical wire. net_name is non-null when the wire carries an explicit label.
pub const Wire = struct {
    x0: i32, y0: i32, x1: i32, y1: i32,
    net_name: ?[]const u8 = null,
    bus: bool = false,
};

pub const Text = struct { content: []const u8, x: i32, y: i32, layer: u8 = 4, size: u8 = 10, rotation: u2 = 0 };
pub const Pin  = struct { name: []const u8, x: i32, y: i32, dir: PinDir = .inout, num: ?u16 = null };

/// Device placement. symbol is the fully-qualified symbol name for PDK lookup.
/// prop_start/count indexes into Schemify.props; conn_start/count into Schemify.conns.
pub const Instance = struct {
    name:       []const u8,
    symbol:     []const u8,
    kind:       DeviceKind = .unknown,
    x: i32, y: i32,
    rot:        u2   = 0,
    flip:       bool = false,
    prop_start: u32  = 0,
    prop_count: u16  = 0,
    conn_start: u32  = 0,
    conn_count: u16  = 0,
};

pub const Prop = struct { key: []const u8, val: []const u8 };
pub const Conn = struct { pin: []const u8, net: []const u8 };

pub const Net = struct { name: []const u8 };

pub const ConnKind = enum(u8) {
    instance_pin,
    wire_endpoint,
    label,

    const tag_table = std.StaticStringMap(ConnKind).initComptime(.{
        .{ "ip", .instance_pin },
        .{ "we", .wire_endpoint },
        .{ "lb", .label },
    });

    pub fn toTag(self: ConnKind) []const u8 {
        return switch (self) {
            .instance_pin => "ip",
            .wire_endpoint => "we",
            .label        => "lb",
        };
    }

    /// Returns `.label` for unrecognized tags — safe default for forward compatibility.
    pub fn fromTag(s: []const u8) ConnKind {
        return tag_table.get(s) orelse .label;
    }
};

/// One connection to a net.
/// instance_pin:           ref_a = instance index, ref_b = 0
/// wire_endpoint / label:  ref_a = x, ref_b = y
pub const NetConn = struct {
    net_id:        u32,
    kind:          ConnKind,
    ref_a:         i32,
    ref_b:         i32,
    pin_or_label:  ?[]const u8 = null,
};

/// Read-only view over resolved nets for geometric net lookup.
pub const NetMap = struct {
    root_to_name: std.AutoHashMapUnmanaged(u64, []const u8),
    point_to_root: std.AutoHashMapUnmanaged(u64, u64),

    pub fn init() NetMap {
        return .{ .root_to_name = .{}, .point_to_root = .{} };
    }

    pub fn deinit(self: *NetMap, a: Allocator) void {
        self.root_to_name.deinit(a);
        self.point_to_root.deinit(a);
    }

    pub fn pointKey(x: i32, y: i32) u64 {
        const ux: u64 = @as(u32, @bitCast(x));
        const uy: u64 = @as(u32, @bitCast(y));
        return (ux << 32) | uy;
    }

    pub fn getNetName(self: *const NetMap, x: i32, y: i32) ?[]const u8 {
        const root = self.point_to_root.get(pointKey(x, y)) orelse return null;
        return self.root_to_name.get(root);
    }
};

// ── Schemify store ────────────────────────────────────────────────────────── //

pub const SifyType = enum(u2) { primitive, component, testbench };

pub const Schemify = struct {
    name: []const u8 = "",

    lines:     MAL(Line)     = .{},
    rects:     MAL(Rect)     = .{},
    arcs:      MAL(Arc)      = .{},
    circles:   MAL(Circle)   = .{},
    wires:     MAL(Wire)     = .{},
    texts:     MAL(Text)     = .{},
    pins:      MAL(Pin)      = .{},
    instances: MAL(Instance) = .{},

    props:     List(Prop)    = .{},
    conns:     List(Conn)    = .{},
    nets:      List(Net)     = .{},
    net_conns: List(NetConn) = .{},
    sym_props: List(Prop)    = .{},

    verilog_body: ?[]const u8 = null,
    spice_body:   ?[]const u8 = null,
    stype:        SifyType    = .component,

    arena:  std.heap.ArenaAllocator,
    logger: ?*log.Logger = null,

    pub fn init(backing: Allocator) Schemify {
        return .{ .arena = std.heap.ArenaAllocator.init(backing) };
    }

    pub fn deinit(self: *Schemify) void { self.arena.deinit(); }
    pub fn alloc(self: *Schemify) Allocator { return self.arena.allocator(); }

    pub fn readFile(data: []const u8, backing: Allocator, logger: ?*log.Logger) Schemify {
        var s = Schemify.init(backing);
        s.logger = logger;
        const is_v2 = std.mem.startsWith(u8, data, "CHN2 ");
        const nl = std.mem.indexOfScalar(u8, data, '\n') orelse data.len;
        const hdr = std.mem.trim(u8, data[0..nl], " \t\r");
        s.stype = if (std.mem.endsWith(u8, hdr, " TB")) .testbench else .component;
        if (is_v2) {
            preScanAndReserve(&s, data, .v2);
            parseCHN2(&s, data);
        } else {
            preScanAndReserve(&s, data, .v1);
            parseCHN(&s, data);
        }
        return s;
    }

    /// Resolve geometric wire connectivity into Net/NetConn entries via union-find.
    /// Injects gnd/vdd/lab_pin names. Auto-names remaining nets _n0, _n1, …
    pub fn resolveNets(self: *Schemify) void {
        self.nets.items.len = 0;
        self.net_conns.items.len = 0;
        std.debug.assert(self.wires.len > 0 or self.instances.len == 0);
        const a = self.alloc();

        var uf = UnionFind{ .a = a };

        // Union wire endpoints
        const wx0 = self.wires.items(.x0); const wy0 = self.wires.items(.y0);
        const wx1 = self.wires.items(.x1); const wy1 = self.wires.items(.y1);
        for (0..self.wires.len) |i| {
            const k0 = NetMap.pointKey(wx0[i], wy0[i]);
            const k1 = NetMap.pointKey(wx1[i], wy1[i]);
            uf.makeSet(k0); uf.makeSet(k1); uf.unite(k0, k1);
        }

        // Sorted (root, name) list — deterministic net ordering, binary search.
        const RootName = struct { root: u64, name: []const u8 };
        var root_names = List(RootName){};

        const rnFind = struct {
            fn find(items: []const RootName, root: u64) ?usize {
                var lo: usize = 0; var hi: usize = items.len;
                while (lo < hi) {
                    const mid = lo + (hi - lo) / 2;
                    if (items[mid].root < root) lo = mid + 1 else hi = mid;
                }
                return if (lo < items.len and items[lo].root == root) lo else null;
            }
            fn insert(items: *List(RootName), alloc_: Allocator, root: u64, name: []const u8) void {
                var lo: usize = 0; var hi: usize = items.items.len;
                while (lo < hi) {
                    const mid = lo + (hi - lo) / 2;
                    if (items.items[mid].root < root) lo = mid + 1 else hi = mid;
                }
                items.insert(alloc_, lo, .{ .root = root, .name = name }) catch {};
            }
        };

        // Inject names from gnd/vdd built-ins and lab_pin devices.
        {
            const ikind = self.instances.items(.kind);
            const ix    = self.instances.items(.x);
            const iy    = self.instances.items(.y);
            const ips   = self.instances.items(.prop_start);
            const ipc   = self.instances.items(.prop_count);
            for (0..self.instances.len) |i| {
                const name: ?[]const u8 = blk: {
                    if (ikind[i].injectedNetName()) |n| break :blk n;
                    if (ikind[i] != .lab_pin) break :blk null;
                    for (self.props.items[ips[i]..][0..ipc[i]]) |p| {
                        if (std.mem.eql(u8, p.key, "lab")) break :blk p.val;
                    }
                    break :blk null;
                };
                const n = name orelse continue;
                const k = NetMap.pointKey(ix[i], iy[i]);
                uf.makeSet(k);
                const root = uf.find(k);
                if (rnFind.find(root_names.items, root)) |pos|
                    root_names.items[pos].name = n
                else
                    rnFind.insert(&root_names, a, root, n);
            }
        }

        // Wire labels (first-wins — do not overwrite injected names).
        {
            const wnn = self.wires.items(.net_name);
            for (0..self.wires.len) |i| {
                const name = wnn[i] orelse continue;
                const k    = NetMap.pointKey(wx0[i], wy0[i]);
                uf.makeSet(k);
                const root = uf.find(k);
                if (rnFind.find(root_names.items, root) == null)
                    rnFind.insert(&root_names, a, root, name);
            }
        }

        // Auto-name remaining roots.
        {
            var auto_idx: u32 = 0;
            for (0..self.wires.len) |i| {
                for ([2]u64{ NetMap.pointKey(wx0[i], wy0[i]), NetMap.pointKey(wx1[i], wy1[i]) }) |k| {
                    const root = uf.find(k);
                    if (rnFind.find(root_names.items, root) != null) continue;
                    const nm = std.fmt.allocPrint(a, "_n{d}", .{auto_idx}) catch continue;
                    rnFind.insert(&root_names, a, root, nm);
                    auto_idx += 1;
                }
            }
        }

        // Build Net list and root→id map.
        var root_to_id = std.AutoHashMapUnmanaged(u64, u32){};
        for (root_names.items) |rn| {
            const id: u32 = @intCast(self.nets.items.len);
            self.nets.append(a, .{ .name = rn.name }) catch continue;
            root_to_id.put(a, rn.root, id) catch {};
        }

        // Wire-endpoint NetConns.
        for (0..self.wires.len) |i| {
            for ([2][2]i32{ .{ wx0[i], wy0[i] }, .{ wx1[i], wy1[i] } }) |ep| {
                const root = uf.find(NetMap.pointKey(ep[0], ep[1]));
                const nid  = root_to_id.get(root) orelse continue;
                self.net_conns.append(a, .{
                    .net_id = nid, .kind = .wire_endpoint,
                    .ref_a = ep[0], .ref_b = ep[1],
                }) catch {};
            }
        }

        // Instance-origin NetConns.
        {
            const ix = self.instances.items(.x);
            const iy = self.instances.items(.y);
            for (0..self.instances.len) |i| {
                const k    = NetMap.pointKey(ix[i], iy[i]);
                uf.makeSet(k);
                const root = uf.find(k);
                const nid  = root_to_id.get(root) orelse continue;
                self.net_conns.append(a, .{
                    .net_id = nid, .kind = .instance_pin,
                    .ref_a = @intCast(i), .ref_b = 0,
                }) catch {};
            }
        }
    }

    pub fn writeFile(self: *Schemify, a: Allocator, logger: ?*log.Logger) ?[]u8 {
        self.logger = logger;
        var buf: List(u8) = .{};
        buf.ensureTotalCapacity(a, simd.estimateCHNSize(self)) catch {};
        self.emit(.info, "writing {s}: {d} instances, {d} wires", .{
            if (self.stype == .testbench) "testbench" else "component",
            self.instances.len, self.wires.len,
        });
        writeCHN(buf.writer(a), self) catch |e| {
            self.emit(.err, "write failed: {}", .{e});
            buf.deinit(a);
            return null;
        };
        return buf.toOwnedSlice(a) catch |e| {
            self.emit(.err, "write toOwnedSlice failed: {}", .{e});
            buf.deinit(a);
            return null;
        };
    }

    const LogLevel = enum { info, warn, err };

    fn emit(self: *Schemify, level: LogLevel, comptime fmt: []const u8, args: anytype) void {
        const l = self.logger orelse return;
        switch (level) {
            .info => l.info("schemify", fmt, args),
            .warn => l.warn("schemify", fmt, args),
            .err  => l.err("schemify", fmt, args),
        }
    }
};

// ── CHN pre-scan ─────────────────────────────────────────────────────────── //

const ChnVersion = enum { v1, v2 };

fn preScanAndReserve(s: *Schemify, input: []const u8, comptime ver: ChnVersion) void {
    const a = s.alloc();
    var it = simd.LineIterator.init(input);
    var wires: usize = 0; var instances: usize = 0; var texts: usize = 0;
    var line_count: usize = 0; var rects: usize = 0; var arcs: usize = 0;
    var pins: usize = 0; var net_count: usize = 0; var conn_count: usize = 0;

    const inst_sigil: u8 = if (ver == .v1) 'C' else 'I';
    const wire_sigil: u8 = if (ver == .v1) 'N' else 'W';

    const SchSection = enum { header, schematic, nets, symbol };
    var section: SchSection = .header;

    _ = it.next(); // skip header line
    while (it.next()) |raw| {
        if (raw.len == 0) continue;
        const first = raw[0];
        if (first == '#') continue;
        if (first == '[') {
            const t = std.mem.trim(u8, raw, " \t\r");
            if (ver == .v1) {
                if (std.mem.eql(u8, t, "[schematic]")) { section = .schematic; continue; }
                if (std.mem.eql(u8, t, "[symbol]"))    { section = .symbol;    continue; }
                if (std.mem.eql(u8, t, "[end]")) break;
            } else {
                if (std.mem.eql(u8, t, "[s]")) { section = .schematic; continue; }
                if (std.mem.eql(u8, t, "[n]")) { section = .nets;      continue; }
                if (std.mem.eql(u8, t, "[y]")) { section = .symbol;    continue; }
                if (std.mem.eql(u8, t, "[e]")) break;
            }
            continue;
        }
        switch (section) {
            .schematic => {
                if      (first == inst_sigil)  instances  += 1
                else if (first == wire_sigil)  wires      += 1
                else if (first == 'T')         texts      += 1
                else if (first == 'L')         line_count += 1
                else if (first == 'B')         rects      += 1
                else if (first == 'A')         arcs       += 1;
            },
            .symbol => {
                if      (first == 'P') pins       += 1
                else if (first == 'L') line_count += 1
                else if (first == 'B') rects      += 1
                else if (first == 'A') arcs       += 1
                else if (first == 'T') texts      += 1;
            },
            .nets => if (ver == .v2) {
                if      (first == 'N') net_count  += 1
                else if (first == '~') conn_count += 1;
            },
            .header => {},
        }
    }
    s.wires.ensureTotalCapacity(a, wires) catch {};
    s.instances.ensureTotalCapacity(a, instances) catch {};
    s.texts.ensureTotalCapacity(a, texts) catch {};
    s.lines.ensureTotalCapacity(a, line_count) catch {};
    s.rects.ensureTotalCapacity(a, rects) catch {};
    s.arcs.ensureTotalCapacity(a, arcs) catch {};
    s.pins.ensureTotalCapacity(a, pins) catch {};
    if (ver == .v2) {
        s.nets.ensureTotalCapacity(a, net_count) catch {};
        s.net_conns.ensureTotalCapacity(a, conn_count) catch {};
    }
}

// ── CHN v1 reader ─────────────────────────────────────────────────────────── //

const Section = enum { header, schematic, symbol };

fn parseCHN(s: *Schemify, input: []const u8) void {
    const a = s.alloc();
    var it = simd.LineIterator.init(input);
    var line_num: u32 = 0;
    var section: Section = .header;

    if (it.next()) |raw| {
        line_num += 1;
        const header = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, header, "CHN ")) {
            s.emit(.warn, "line {d}: bad CHN header", .{line_num});
        } else {
            var tok = std.mem.tokenizeAny(u8, header, " \t");
            _ = tok.next();
            const ver = tok.next() orelse "";
            if (!std.mem.eql(u8, ver, "v1")) s.emit(.warn, "unsupported version: {s}", .{ver});
            s.name = a.dupe(u8, tok.next() orelse "untitled") catch "untitled";
        }
    }

    while (it.next()) |raw| {
        line_num += 1;
        const line = std.mem.trimRight(u8, std.mem.trimLeft(u8, raw, " \t\r"), "\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line.len >= 5 and line[0] == '[') {
            if (std.mem.eql(u8, line, "[schematic]")) { section = .schematic; continue; }
            if (std.mem.eql(u8, line, "[symbol]"))    { section = .symbol;    continue; }
            if (std.mem.eql(u8, line, "[end]")) break;
        }
        switch (section) {
            .header    => {},
            .schematic => parseSchematicLine(a, s, line, line_num, 'C'),
            .symbol    => parseSymbolLine(a, s, line, line_num),
        }
    }

    s.emit(.info, "parsed {s} \"{s}\": {d} inst, {d} wire, {d} pin, {d} shape", .{
        if (s.stype == .testbench) "TB" else "comp", s.name,
        s.instances.len, s.wires.len, s.pins.len,
        s.lines.len + s.rects.len + s.arcs.len + s.circles.len,
    });
}

fn parseSchematicLine(a: Allocator, s: *Schemify, line: []const u8, ln: u32, inst_sigil: u8) void {
    if (line.len < 2) return;
    if (line[0] == inst_sigil) {
        parseInstance(a, s, line) catch |e| s.emit(.warn, "L{d}: inst: {}",  .{ ln, e });
        return;
    }
    switch (line[0]) {
        'N', 'W' => parseWireLine(a, s, line) catch |e| s.emit(.warn, "L{d}: wire: {}", .{ ln, e }),
        'T' => _ = parseTextLine(a, s, line) catch |e| s.emit(.warn, "L{d}: text: {}", .{ ln, e }),
        'L' => parseLineLine(a, s, line),
        'B' => if (line.len >= 2 and line[1] == 'I') parseRectImageData(a, s, line)
               else parseRectLine(a, s, line),
        'A' => parseArcOrCircle(a, s, line),
        'S' => parseSBody(a, s, line),
        else => {},
    }
}

fn parseSymbolLine(a: Allocator, s: *Schemify, line: []const u8, ln: u32) void {
    if (line.len < 2) return;
    switch (line[0]) {
        'P' => parsePinLine(a, s, line)    catch |e| s.emit(.warn, "L{d}: pin: {}",   .{ ln, e }),
        'K' => parseSymPropLine(a, s, line) catch |e| s.emit(.warn, "L{d}: sprop: {}", .{ ln, e }),
        'L' => parseLineLine(a, s, line),
        'B' => if (line.len >= 2 and line[1] == 'I') parseRectImageData(a, s, line)
               else parseRectLine(a, s, line),
        'A' => parseArcOrCircle(a, s, line),
        'T' => _ = parseTextLine(a, s, line) catch |e| s.emit(.warn, "L{d}: text: {}", .{ ln, e }),
        else => {},
    }
}

// ── Element parsers ─────────────────────────────────────────────────────── //

/// Find the position of the closing `}` that matches the `{` at `open`,
/// skipping over quoted string values (which may contain `}` characters).
fn findPropsEnd(line: []const u8, open: usize) ?usize {
    var i = open + 1;
    while (i < line.len) {
        switch (line[i]) {
            '"' => {
                i += 1;
                while (i < line.len) {
                    if (line[i] == '\\' and i + 1 < line.len and
                        (line[i + 1] == '"' or line[i + 1] == '\\'))
                    { i += 2; }
                    else if (line[i] == '"') { i += 1; break; }
                    else { i += 1; }
                }
            },
            '}' => return i,
            else => i += 1,
        }
    }
    return null;
}

fn parseInstance(a: Allocator, s: *Schemify, line: []const u8) !void {
    const data = line[2..];
    var pos: usize = 0;
    const sym_raw  = simd.nextToken(data, &pos) orelse return error.InvalidFormat;
    const x        = simd.nextI32(data, &pos) orelse return error.InvalidNumber;
    const y        = simd.nextI32(data, &pos) orelse return error.InvalidNumber;
    const rot: u2  = @truncate(@as(u32, @bitCast(simd.nextI32(data, &pos) orelse 0)));
    const flip_i: u8 = simd.nextU8(data, &pos) orelse 0;
    const kind_str = simd.nextToken(data, &pos) orelse "unknown";
    const sym        = try a.dupe(u8, sym_raw);
    const prop_start: u32 = @intCast(s.props.items.len);
    const conn_start: u32 = @intCast(s.conns.items.len);
    var inst_name: []const u8 = "";
    var props_end: usize = 0;
    if (std.mem.indexOfScalar(u8, line, '{')) |ps| {
        if (findPropsEnd(line, ps)) |pe| {
            try parsePropsInto(a, line[ps + 1 .. pe], &s.props, &inst_name);
            props_end = pe + 1;
        }
    }
    // Find '[' only after the props block to avoid matching '[' inside quoted prop values.
    if (std.mem.indexOfScalarPos(u8, line, props_end, '[')) |cs| {
        if (std.mem.indexOfScalarPos(u8, line, cs + 1, ']')) |ce|
            try parseConnsInto(a, line[cs + 1 .. ce], &s.conns);
    }
    try s.instances.append(a, .{
        .name       = inst_name,
        .symbol     = sym,
        .kind       = DeviceKind.fromStr(kind_str),
        .x = x, .y = y,
        .rot        = rot,
        .flip       = flip_i != 0,
        .prop_start = prop_start,
        .prop_count = @intCast(s.props.items.len - prop_start),
        .conn_start = conn_start,
        .conn_count = @intCast(s.conns.items.len - conn_start),
    });
}

fn parseWireLine(a: Allocator, s: *Schemify, line: []const u8) !void {
    if (line.len < 3) return;
    const data = line[2..];
    var pos: usize = 0;
    const x0 = simd.nextI32(data, &pos) orelse return;
    const y0 = simd.nextI32(data, &pos) orelse return;
    const x1 = simd.nextI32(data, &pos) orelse return;
    const y1 = simd.nextI32(data, &pos) orelse return;
    var net: ?[]const u8 = null;
    var bus: bool = false;
    // Read optional net name (may be quoted) then optional bus=true.
    while (pos < data.len and (data[pos] == ' ' or data[pos] == '\t')) pos += 1;
    if (pos < data.len and data[pos] == '"') {
        pos += 1;
        const ns = pos;
        while (pos < data.len and data[pos] != '"') pos += 1;
        net = try a.dupe(u8, data[ns..pos]);
        if (pos < data.len) pos += 1;
    }
    while (simd.nextToken(data, &pos)) |tok| {
        if (std.mem.eql(u8, tok, "bus=true")) bus = true
        else if (net == null) net = try a.dupe(u8, tok);
    }
    try s.wires.append(a, .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1, .net_name = net, .bus = bus });
}

fn parseTextLine(a: Allocator, s: *Schemify, line: []const u8) !bool {
    if (line.len < 3) return false;
    const data = line[2..];
    var pos: usize = 0;
    const x     = simd.nextI32(data, &pos) orelse return false;
    const y     = simd.nextI32(data, &pos) orelse return false;
    const layer: u8 = simd.nextU8(data, &pos) orelse 4;
    const size:  u8 = simd.nextU8(data, &pos) orelse 10;
    const rot:   u2 = @truncate(@as(u32, @bitCast(simd.nextI32(data, &pos) orelse 0)));
    const rest  = simd.restAfterWs(data, pos);
    if (rest.len == 0) return false;
    try s.texts.append(a, .{
        .content = try a.dupe(u8, rest),
        .x = x, .y = y, .layer = layer, .size = size, .rotation = rot,
    });
    return true;
}

fn parseLineLine(a: Allocator, s: *Schemify, line: []const u8) void {
    if (line.len < 3) return;
    const data = line[2..];
    var pos: usize = 0;
    const ly = simd.nextU8(data, &pos) orelse return;
    const x0 = simd.nextI32(data, &pos) orelse return;
    const y0 = simd.nextI32(data, &pos) orelse return;
    const x1 = simd.nextI32(data, &pos) orelse return;
    const y1 = simd.nextI32(data, &pos) orelse return;
    s.lines.append(a, .{ .layer = ly, .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1 }) catch {};
}

fn parseRectLine(a: Allocator, s: *Schemify, line: []const u8) void {
    if (line.len < 3) return;
    const data = line[2..];
    var pos: usize = 0;
    const ly = simd.nextU8(data, &pos) orelse return;
    const x0 = simd.nextI32(data, &pos) orelse return;
    const y0 = simd.nextI32(data, &pos) orelse return;
    const x1 = simd.nextI32(data, &pos) orelse return;
    const y1 = simd.nextI32(data, &pos) orelse return;
    s.rects.append(a, .{ .layer = ly, .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1 }) catch {};
}

/// Attach image data (from "BI <data>" line) to the most recently appended rect.
fn parseRectImageData(a: Allocator, s: *Schemify, line: []const u8) void {
    if (s.rects.len == 0) return;
    const data = if (line.len > 3) std.mem.trim(u8, line[3..], " \t\r") else return;
    if (data.len == 0) return;
    const id: []const u8 = if (data[0] == '"') blk: {
        // Quoted+escaped: strip outer quotes and unescape.
        const inner = if (data.len >= 2) data[1 .. (std.mem.lastIndexOfScalar(u8, data, '"') orelse data.len)] else data;
        break :blk unescapeVal(a, inner) catch a.dupe(u8, inner) catch inner;
    } else a.dupe(u8, data) catch data;
    s.rects.slice().items(.image_data)[s.rects.len - 1] = id;
}

/// Handle "S { body }" in a single CHN line (multi-line form handled by parseCHN2).
fn parseSBody(a: Allocator, s: *Schemify, line: []const u8) void {
    const open  = std.mem.indexOfScalar(u8, line, '{') orelse return;
    const close = std.mem.lastIndexOfScalar(u8, line, '}') orelse return;
    if (close <= open) return;
    const body = std.mem.trim(u8, line[open + 1 .. close], " \t\r\n");
    if (body.len > 0) s.spice_body = a.dupe(u8, body) catch null;
}

fn parseArcOrCircle(a: Allocator, s: *Schemify, line: []const u8) void {
    if (line.len < 3) return;
    const data = line[2..];
    var pos: usize = 0;
    const ly = simd.nextU8(data, &pos) orelse return;
    const cx = simd.nextI32(data, &pos) orelse return;
    const cy = simd.nextI32(data, &pos) orelse return;
    const r  = simd.nextI32(data, &pos) orelse return;
    const sa = simd.nextI16(data, &pos) orelse return;
    const sw = simd.nextI16(data, &pos) orelse return;
    if (sa == 0 and sw == 360)
        s.circles.append(a, .{ .layer = ly, .cx = cx, .cy = cy, .radius = r }) catch {}
    else
        s.arcs.append(a, .{ .layer = ly, .cx = cx, .cy = cy, .radius = r,
                             .start_angle = sa, .sweep_angle = sw }) catch {};
}

fn parsePinLine(a: Allocator, s: *Schemify, line: []const u8) !void {
    if (line.len < 3) return;
    const data = line[2..];
    var pos: usize = 0;
    const name_raw = simd.nextToken(data, &pos) orelse return error.InvalidFormat;
    const x        = simd.nextI32(data, &pos) orelse return error.InvalidNumber;
    const y        = simd.nextI32(data, &pos) orelse return error.InvalidNumber;
    const dir_str  = simd.nextToken(data, &pos) orelse "io";
    const num: ?u16 = simd.nextU16(data, &pos);
    try s.pins.append(a, .{
        .name = try a.dupe(u8, name_raw), .x = x, .y = y,
        .dir  = PinDir.fromStr(dir_str),  .num = num,
    });
}

fn parseSymPropLine(a: Allocator, s: *Schemify, line: []const u8) !void {
    if (line.len < 3) return;
    var tok = KVTokenizer.init(line[2..]);
    while (tok.next()) |p|
        try s.sym_props.append(a, .{ .key = try a.dupe(u8, p.key), .val = try unescapeVal(a, p.val) });
}

/// Unescape `\n` → newline, `\"` → `"`, `\\` → `\` sequences produced by writeEscapedPropVal.
fn unescapeVal(a: Allocator, raw: []const u8) ![]u8 {
    if (std.mem.indexOf(u8, raw, "\\") == null) return a.dupe(u8, raw);
    var out = try std.ArrayListUnmanaged(u8).initCapacity(a, raw.len);
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] == '\\' and i + 1 < raw.len) {
            switch (raw[i + 1]) {
                'n'  => { try out.append(a, '\n'); i += 2; },
                '"'  => { try out.append(a, '"');  i += 2; },
                '\\' => { try out.append(a, '\\'); i += 2; },
                else => { try out.append(a, raw[i]); i += 1; },
            }
        } else {
            try out.append(a, raw[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(a);
}

fn parsePropsInto(a: Allocator, src: []const u8, props: *List(Prop), name: *[]const u8) !void {
    var tok = KVTokenizer.init(src);
    while (tok.next()) |p| {
        const k = try a.dupe(u8, p.key);
        const v = try unescapeVal(a, p.val);
        if (std.mem.eql(u8, k, "name")) name.* = v;
        try props.append(a, .{ .key = k, .val = v });
    }
}

fn parseConnsInto(a: Allocator, src: []const u8, conns: *List(Conn)) !void {
    var tok = KVTokenizer.init(src);
    while (tok.next()) |p|
        try conns.append(a, .{ .pin = try a.dupe(u8, p.key), .net = try a.dupe(u8, p.val) });
}

// ── KV tokenizer ──────────────────────────────────────────────────────────── //

const KVTokenizer = struct {
    src: []const u8,
    pos: usize = 0,

    const Tok = struct { key: []const u8, val: []const u8 };

    fn init(src: []const u8) KVTokenizer { return .{ .src = src }; }

    fn next(self: *KVTokenizer) ?Tok {
        while (self.pos < self.src.len and isWs(self.src[self.pos])) self.pos += 1;
        if (self.pos >= self.src.len) return null;
        const ks = self.pos;
        while (self.pos < self.src.len and self.src[self.pos] != '=') self.pos += 1;
        if (self.pos >= self.src.len) return null;
        const key = self.src[ks..self.pos];
        self.pos += 1;
        if (self.pos >= self.src.len) return null;
        if (self.src[self.pos] == '"') {
            self.pos += 1;
            const vs = self.pos;
            // Skip over escape sequences so \" does not prematurely close the value.
            while (self.pos < self.src.len) {
                if (self.src[self.pos] == '\\' and self.pos + 1 < self.src.len and
                    (self.src[self.pos + 1] == '"' or self.src[self.pos + 1] == '\\'))
                {
                    self.pos += 2;
                } else if (self.src[self.pos] == '"') {
                    break;
                } else {
                    self.pos += 1;
                }
            }
            const val = self.src[vs..self.pos];
            if (self.pos < self.src.len) self.pos += 1;
            return .{ .key = key, .val = val };
        }
        const vs = self.pos;
        while (self.pos < self.src.len and !isWs(self.src[self.pos])) self.pos += 1;
        return .{ .key = key, .val = self.src[vs..self.pos] };
    }

    fn isWs(c: u8) bool { return c == ' ' or c == '\t' or c == '\n' or c == '\r'; }
};

// ── CHN v2 reader ─────────────────────────────────────────────────────────── //

const SectionV2 = enum { header, schematic, nets, symbol };

fn parseCHN2(s: *Schemify, input: []const u8) void {
    const a = s.alloc();
    var it = simd.LineIterator.init(input);
    var line_num: u32 = 0;
    var section: SectionV2 = .header;

    if (it.next()) |raw| {
        line_num += 1;
        const header = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, header, "CHN2 ")) {
            s.emit(.warn, "line {d}: bad CHN2 header", .{line_num});
        } else {
            var tok = std.mem.tokenizeAny(u8, header, " \t");
            _ = tok.next(); // "CHN2"
            s.name = a.dupe(u8, tok.next() orelse "untitled") catch "untitled";
        }
    }

    var in_spice_block = false;
    var spice_buf: List(u8) = .{};
    defer spice_buf.deinit(a);

    while (it.next()) |raw| {
        line_num += 1;
        const line = std.mem.trimRight(u8, std.mem.trimLeft(u8, raw, " \t\r"), "\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (in_spice_block) {
            if (std.mem.eql(u8, line, "}")) {
                in_spice_block = false;
                const body = std.mem.trim(u8, spice_buf.items, " \t\n\r");
                if (body.len > 0) s.spice_body = a.dupe(u8, body) catch null;
                spice_buf.clearRetainingCapacity();
            } else {
                spice_buf.appendSlice(a, raw) catch {};
                spice_buf.append(a, '\n') catch {};
            }
            continue;
        }
        if (line[0] == '[') {
            const sec: ?SectionV2 = blk: {
                if (std.mem.eql(u8, line, "[s]")) break :blk .schematic;
                if (std.mem.eql(u8, line, "[n]")) break :blk .nets;
                if (std.mem.eql(u8, line, "[y]")) break :blk .symbol;
                if (std.mem.eql(u8, line, "[e]")) break :blk null;
                break :blk section; // unknown tag — stay in current section
            };
            if (sec == null) break;
            section = sec.?;
            continue;
        }
        switch (section) {
            .header => {
                if (line.len >= 2 and line[0] == 'S' and (line[1] == ' ' or line[1] == '{')) {
                    const oi = std.mem.indexOfScalar(u8, line, '{') orelse continue;
                    const ci = std.mem.lastIndexOfScalar(u8, line, '}');
                    if (ci != null and ci.? > oi) {
                        const body = std.mem.trim(u8, line[oi + 1 .. ci.?], " \t\r\n");
                        if (body.len > 0) s.spice_body = a.dupe(u8, body) catch null;
                    } else {
                        in_spice_block = true;
                        spice_buf.clearRetainingCapacity();
                        const first = std.mem.trim(u8, line[oi + 1 ..], " \t");
                        if (first.len > 0) {
                            spice_buf.appendSlice(a, first) catch {};
                            spice_buf.append(a, '\n') catch {};
                        }
                    }
                }
            },
            .schematic => parseSchematicLine(a, s, line, line_num, 'I'),
            .symbol    => parseSymbolLine(a, s, line, line_num),
            .nets      => parseNetSectionLine(a, s, line, line_num),
        }
    }

    s.emit(.info, "parsed v2 {s} \"{s}\": {d} inst, {d} wire, {d} net, {d} pin", .{
        if (s.stype == .testbench) "TB" else "comp", s.name,
        s.instances.len, s.wires.len, s.nets.items.len, s.pins.len,
    });
}

fn parseNetSectionLine(a: Allocator, s: *Schemify, line: []const u8, ln: u32) void {
    if (line.len < 2) return;
    switch (line[0]) {
        'N' => {
            const data = line[2..];
            var pos: usize = 0;
            _ = simd.nextI32(data, &pos) orelse { s.emit(.warn, "L{d}: net def: bad id", .{ln}); return; };
            const name = simd.restAfterWs(data, pos);
            if (name.len == 0) { s.emit(.warn, "L{d}: net def: empty name", .{ln}); return; }
            s.nets.append(a, .{ .name = a.dupe(u8, name) catch return }) catch {};
        },
        '~' => {
            const data = line[2..];
            var pos: usize = 0;
            const net_id: u32 = @intCast(simd.nextI32(data, &pos) orelse { s.emit(.warn, "L{d}: net conn: bad id", .{ln}); return; });
            const kind_str = simd.nextToken(data, &pos) orelse { s.emit(.warn, "L{d}: net conn: no kind", .{ln}); return; };
            const ref_a = simd.nextI32(data, &pos) orelse { s.emit(.warn, "L{d}: net conn: no ref_a", .{ln}); return; };
            const ref_b = simd.nextI32(data, &pos) orelse { s.emit(.warn, "L{d}: net conn: no ref_b", .{ln}); return; };
            const rest  = simd.restAfterWs(data, pos);
            const pl: ?[]const u8 = if (rest.len > 0) a.dupe(u8, rest) catch null else null;
            s.net_conns.append(a, .{
                .net_id = net_id, .kind = ConnKind.fromTag(kind_str),
                .ref_a = ref_a, .ref_b = ref_b, .pin_or_label = pl,
            }) catch {};
        },
        else => {},
    }
}

// ── CHN writer ────────────────────────────────────────────────────────────── //

/// Write a "sigil layer x0 y0 x1 y1\n" line into buf, return bytes used.
inline fn writeLayerLine(buf: []u8, sigil: u8, layer: u8, x0: i32, y0: i32, x1: i32, y1: i32) usize {
    var n: usize = 0;
    buf[n] = sigil; n += 1; buf[n] = ' '; n += 1;
    n += simd.writeU8(buf[n..], layer);  buf[n] = ' '; n += 1;
    n += simd.writeI32(buf[n..], x0);   buf[n] = ' '; n += 1;
    n += simd.writeI32(buf[n..], y0);   buf[n] = ' '; n += 1;
    n += simd.writeI32(buf[n..], x1);   buf[n] = ' '; n += 1;
    n += simd.writeI32(buf[n..], y1);   buf[n] = '\n'; n += 1;
    return n;
}

/// Write a prop value quoted and with newlines/quotes escaped so it fits on one logical line.
fn writeEscapedPropVal(w: anytype, val: []const u8) !void {
    const needs_q = val.len == 0 or for (val) |c| {
        if (c == ' ' or c == '\t' or c == '\n' or c == '"' or c == '}' or c == '[') break true;
    } else false;
    if (!needs_q) return w.writeAll(val);
    try w.writeByte('"');
    for (val) |c| {
        switch (c) {
            '\n' => try w.writeAll("\\n"),
            '"'  => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            else => try w.writeByte(c),
        }
    }
    try w.writeByte('"');
}

fn writeCHN(w: anytype, s: *const Schemify) !void {
    try w.writeAll("CHN2 ");
    try w.writeAll(s.name);
    if (s.stype == .testbench) try w.writeAll(" TB");
    try w.writeAll("\n");
    if (s.spice_body) |sb| {
        try w.writeAll("S {\n");
        try w.writeAll(sb);
        try w.writeAll("\n}\n");
    }
    try w.writeAll("[s]\n");

    var buf: [80]u8 = undefined;

    // Wires
    {
        const wx0 = s.wires.items(.x0); const wy0 = s.wires.items(.y0);
        const wx1 = s.wires.items(.x1); const wy1 = s.wires.items(.y1);
        const wnn = s.wires.items(.net_name); const wbus = s.wires.items(.bus);
        for (0..s.wires.len) |i| {
            var n: usize = 0;
            buf[n] = 'W'; n += 1; buf[n] = ' '; n += 1;
            n += simd.writeI32(buf[n..], wx0[i]); buf[n] = ' '; n += 1;
            n += simd.writeI32(buf[n..], wy0[i]); buf[n] = ' '; n += 1;
            n += simd.writeI32(buf[n..], wx1[i]); buf[n] = ' '; n += 1;
            n += simd.writeI32(buf[n..], wy1[i]);
            try w.writeAll(buf[0..n]);
            if (wnn[i]) |nm| {
                try w.writeByte(' ');
                try writeEscapedPropVal(w, nm);
            }
            if (wbus[i]) try w.writeAll(" bus=true");
            try w.writeAll("\n");
        }
    }

    // Instances
    {
        const isym  = s.instances.items(.symbol);
        const ix    = s.instances.items(.x);    const iy    = s.instances.items(.y);
        const irot  = s.instances.items(.rot);  const iflip = s.instances.items(.flip);
        const ikind = s.instances.items(.kind);
        const ips   = s.instances.items(.prop_start); const ipc = s.instances.items(.prop_count);
        const ics   = s.instances.items(.conn_start); const icc = s.instances.items(.conn_count);
        for (0..s.instances.len) |i| {
            try w.writeAll("I ");
            try w.writeAll(isym[i]);
            var n: usize = 0;
            buf[n] = ' '; n += 1;
            n += simd.writeI32(buf[n..], ix[i]); buf[n] = ' '; n += 1;
            n += simd.writeI32(buf[n..], iy[i]); buf[n] = ' '; n += 1;
            n += simd.writeU8(buf[n..], @as(u8, irot[i])); buf[n] = ' '; n += 1;
            buf[n] = if (iflip[i]) '1' else '0'; n += 1; buf[n] = ' '; n += 1;
            try w.writeAll(buf[0..n]);
            try w.writeAll(@tagName(ikind[i]));
            if (ipc[i] > 0) {
                try w.writeAll(" {");
                for (s.props.items[ips[i]..][0..ipc[i]], 0..) |p, j| {
                    if (j > 0) try w.writeAll(" ");
                    try w.writeAll(p.key); try w.writeByte('='); try writeEscapedPropVal(w, p.val);
                }
                try w.writeAll("}");
            }
            if (icc[i] > 0) {
                try w.writeAll(" [");
                for (s.conns.items[ics[i]..][0..icc[i]], 0..) |c, j| {
                    if (j > 0) try w.writeAll(" ");
                    try w.writeAll(c.pin); try w.writeAll("="); try w.writeAll(c.net);
                }
                try w.writeAll("]");
            }
            try w.writeAll("\n");
        }
    }

    // Texts
    {
        const tx = s.texts.items(.x); const ty = s.texts.items(.y);
        const tl = s.texts.items(.layer); const tsz = s.texts.items(.size);
        const trot = s.texts.items(.rotation); const tcnt = s.texts.items(.content);
        for (0..s.texts.len) |i| {
            var n: usize = 0;
            buf[n] = 'T'; n += 1; buf[n] = ' '; n += 1;
            n += simd.writeI32(buf[n..], tx[i]); buf[n] = ' '; n += 1;
            n += simd.writeI32(buf[n..], ty[i]); buf[n] = ' '; n += 1;
            n += simd.writeU8(buf[n..], tl[i]);  buf[n] = ' '; n += 1;
            n += simd.writeU8(buf[n..], tsz[i]); buf[n] = ' '; n += 1;
            n += simd.writeU8(buf[n..], @as(u8, trot[i])); buf[n] = ' '; n += 1;
            try w.writeAll(buf[0..n]);
            try w.writeAll(tcnt[i]);
            try w.writeAll("\n");
        }
    }

    // Lines
    {
        const ll  = s.lines.items(.layer);
        const lx0 = s.lines.items(.x0); const ly0 = s.lines.items(.y0);
        const lx1 = s.lines.items(.x1); const ly1 = s.lines.items(.y1);
        for (0..s.lines.len) |i|
            try w.writeAll(buf[0..writeLayerLine(&buf, 'L', ll[i], lx0[i], ly0[i], lx1[i], ly1[i])]);
    }

    // Rects
    {
        const rl  = s.rects.items(.layer);
        const rx0 = s.rects.items(.x0); const ry0 = s.rects.items(.y0);
        const rx1 = s.rects.items(.x1); const ry1 = s.rects.items(.y1);
        const rid = s.rects.items(.image_data);
        for (0..s.rects.len) |i| {
            try w.writeAll(buf[0..writeLayerLine(&buf, 'B', rl[i], rx0[i], ry0[i], rx1[i], ry1[i])]);
            if (rid[i]) |id| { try w.writeAll("BI "); try writeEscapedPropVal(w, id); try w.writeAll("\n"); }
        }
    }

    // Arcs
    {
        const layer = s.arcs.items(.layer);
        const acx = s.arcs.items(.cx); const acy = s.arcs.items(.cy);
        const ar  = s.arcs.items(.radius);
        const asa = s.arcs.items(.start_angle); const asw = s.arcs.items(.sweep_angle);
        for (0..s.arcs.len) |i| {
            var n: usize = 0;
            buf[n] = 'A'; n += 1; buf[n] = ' '; n += 1;
            n += simd.writeU8(buf[n..], layer[i]);  buf[n] = ' '; n += 1;
            n += simd.writeI32(buf[n..], acx[i]);   buf[n] = ' '; n += 1;
            n += simd.writeI32(buf[n..], acy[i]);   buf[n] = ' '; n += 1;
            n += simd.writeI32(buf[n..], ar[i]);    buf[n] = ' '; n += 1;
            n += simd.writeI32(buf[n..], @as(i32, asa[i])); buf[n] = ' '; n += 1;
            n += simd.writeI32(buf[n..], @as(i32, asw[i])); buf[n] = '\n'; n += 1;
            try w.writeAll(buf[0..n]);
        }
    }

    // Circles (emitted as A … 0 360)
    {
        const layer = s.circles.items(.layer);
        const ccx = s.circles.items(.cx); const ccy = s.circles.items(.cy);
        const cr  = s.circles.items(.radius);
        for (0..s.circles.len) |i| {
            var n: usize = 0;
            buf[n] = 'A'; n += 1; buf[n] = ' '; n += 1;
            n += simd.writeU8(buf[n..], layer[i]); buf[n] = ' '; n += 1;
            n += simd.writeI32(buf[n..], ccx[i]);  buf[n] = ' '; n += 1;
            n += simd.writeI32(buf[n..], ccy[i]);  buf[n] = ' '; n += 1;
            n += simd.writeI32(buf[n..], cr[i]);
            @memcpy(buf[n..][0..7], " 0 360\n");
            n += 7;
            try w.writeAll(buf[0..n]);
        }
    }

    // [n] net section
    if (s.nets.items.len > 0) {
        try w.writeAll("[n]\n");
        for (s.nets.items, 0..) |net, idx| {
            var n: usize = 0;
            buf[n] = 'N'; n += 1; buf[n] = ' '; n += 1;
            n += simd.writeI32(buf[n..], @intCast(idx)); buf[n] = ' '; n += 1;
            try w.writeAll(buf[0..n]);
            try w.writeAll(net.name);
            try w.writeAll("\n");
        }
        for (s.net_conns.items) |nc| {
            var n: usize = 0;
            buf[n] = '~'; n += 1; buf[n] = ' '; n += 1;
            n += simd.writeI32(buf[n..], @intCast(nc.net_id)); buf[n] = ' '; n += 1;
            try w.writeAll(buf[0..n]);
            try w.writeAll(nc.kind.toTag());
            n = 0;
            buf[n] = ' '; n += 1;
            n += simd.writeI32(buf[n..], nc.ref_a); buf[n] = ' '; n += 1;
            n += simd.writeI32(buf[n..], nc.ref_b);
            try w.writeAll(buf[0..n]);
            if (nc.pin_or_label) |pl| { try w.writeAll(" "); try w.writeAll(pl); }
            try w.writeAll("\n");
        }
    }

    // [y] symbol section
    if (s.stype != .testbench) {
        try w.writeAll("[y]\n");
        for (s.sym_props.items) |p| {
            try w.writeAll("K "); try w.writeAll(p.key);
            try w.writeByte('='); try writeEscapedPropVal(w, p.val); try w.writeAll("\n");
        }
        const pname = s.pins.items(.name);
        const px = s.pins.items(.x); const py = s.pins.items(.y);
        const pdir = s.pins.items(.dir); const pnum = s.pins.items(.num);
        for (0..s.pins.len) |i| {
            try w.writeAll("P "); try w.writeAll(pname[i]);
            var n: usize = 0;
            buf[n] = ' '; n += 1;
            n += simd.writeI32(buf[n..], px[i]); buf[n] = ' '; n += 1;
            n += simd.writeI32(buf[n..], py[i]); buf[n] = ' '; n += 1;
            try w.writeAll(buf[0..n]);
            try w.writeAll(pdir[i].toStr());
            if (pnum[i]) |num| {
                var nb: [12]u8 = undefined;
                nb[0] = ' ';
                try w.writeAll(nb[0 .. 1 + simd.writeI32(nb[1..], @as(i32, num))]);
            }
            try w.writeAll("\n");
        }
    }
    try w.writeAll("[e]\n");
}

// ── Union-Find (pub — reused by netlist.zig) ─────────────────────────────── //

/// Union-Find with path compression (two-step path halving).
pub const UnionFind = struct {
    parent: std.AutoHashMapUnmanaged(u64, u64) = .{},
    a: Allocator,

    pub fn find(self: *UnionFind, x: u64) u64 {
        var cur = x;
        while (true) {
            const p  = self.parent.get(cur) orelse return cur;
            if (p == cur) return cur;
            const gp = self.parent.get(p) orelse p;
            self.parent.put(self.a, cur, gp) catch {};
            cur = gp;
        }
    }

    pub fn makeSet(self: *UnionFind, x: u64) void {
        const r = self.parent.getOrPut(self.a, x) catch return;
        if (!r.found_existing) r.value_ptr.* = x;
    }

    pub fn unite(self: *UnionFind, x: u64, y: u64) void {
        const rx = self.find(x);
        const ry = self.find(y);
        std.debug.assert(self.parent.get(rx) == null or self.parent.get(rx).? == rx);
        if (rx != ry) self.parent.put(self.a, ry, rx) catch {};
    }
};

// ── Tests ──────────────────────────────────────────────────────────────────── //

test "Expose struct size for schemify" {
    const print = @import("std").debug.print;
    print("Schemify: {d}B\n", .{@sizeOf(Schemify)});
}

test "Line is packed (17 bytes)" {
    try @import("std").testing.expect(@sizeOf(Line) == 17);
}

test "Rect carries image_data (not packed)" {
    var r = Rect{ .layer = 0, .x0 = 0, .y0 = 0, .x1 = 0, .y1 = 0 };
    try @import("std").testing.expect(r.image_data == null);
    r.image_data = "test";
    try @import("std").testing.expectEqualStrings("test", r.image_data.?);
}

test "Circle is packed (13 bytes)" {
    try @import("std").testing.expect(@sizeOf(Circle) == 13);
}

test "NetMap.pointKey round-trip" {
    const testing = @import("std").testing;
    const k  = NetMap.pointKey(-100, 200);
    const xr: i32 = @bitCast(@as(u32, @truncate(k >> 32)));
    const yr: i32 = @bitCast(@as(u32, @truncate(k)));
    try testing.expectEqual(@as(i32, -100), xr);
    try testing.expectEqual(@as(i32,  200), yr);
}
