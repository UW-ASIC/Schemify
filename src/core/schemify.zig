//! Schemify CHN DOD Format — flat struct-of-arrays storage with all operations.
//!
//! Imports device.zig for DeviceKind, SpiceDevice, PdkInfo.
//! Satisfies the FileIOIF interface: readFile, writeFile, convertToSchemify,
//! generateNetlist.
//!
//! Contains:
//!   DOD element structs (Point, Line, Rect, Arc, Circle, Wire, Text, Pin, Instance, Prop, Conn)
//!   Schemify store (MAL-based, arena-backed)
//!   CHN reader/writer
//!   Net resolution (union-find)
//!   Netlist generation (ngspice / Xyce)
//!   Geometry transforms (move, rotate, flip)
//!   SymbolLibrary interface (vtable for symbol resolution)
//!
//! Dependency: device.zig → pdk.zig
//!
//! ── Error Handling ────────────────────────────────────────────────────────
//!
//! Parser functions (`parseSchematicLine`, `parseCHN`, etc.) never propagate
//! errors to the caller — they log warnings via `s.logWarn` and continue.
//! This is intentional: partial parse results are better than a crash for
//! malformed schematic files.
//!
//! `readFile` always succeeds (returns Schemify, not !Schemify). After calling
//! it, check `s.logger.hasErrors()` to detect parse failures.
//!
//! `writeFile` and `generateNetlist` return `?[]u8` (null on failure). Errors
//! are logged to the Schemify's own `logger` field.
//!
//! To surface errors more visibly, set `s.logger` before calling these:
//!   s.logger = &app_state.logger;  // share the GUI log panel's logger
//!
//! ── Known Issues / Dead Code ──────────────────────────────────────────────
//!
//! 1. BUG: `writeNetlist` resolves nets into `net_map` but then suppresses the
//!    variable with `_ = &net_map`. The resolved net names are never passed to
//!    `emitInstances`. Instance nets are instead resolved via `findConnNet` and
//!    `findNearestUnclaimedNet`. This means wire-label net names are not used
//!    to drive top-level instance connectivity. Fix: remove `_ = &net_map`
//!    and pass `&net_map` to `emitInstances` for the top-level call (it already
//!    accepts a `*const NetMap`).
//!
//! 2. DEAD: Phase 3 of `resolveNetsFromSlices` receives `conns_pool` but
//!    immediately discards it: `_ = conns_pool;`. The intent was to union
//!    conn pin positions with wire endpoints so that multi-pin instance
//!    connectivity is resolved geometrically. Currently only single-origin
//!    devices (gnd, vdd, lab_pin) inject net names. Multi-pin instances rely
//!    entirely on `conn_count > 0` in the CHN serialisation format, which
//!    XSchem-sourced schematics never populate (conn_count is always 0 after
//!    convertToSchemify).
//!
//! 3. DEAD: `Schemify.convertToSchemify()` just returns `self`. It exists
//!    solely to satisfy the FileIOIF comptime interface check. Remove the
//!    check constraint for `convertToSchemify` when `generateNetlist` is
//!    present, or collapse both paths in FileIOIF.
//!
//! ── PDKLoader Extension ────────────────────────────────────────────────────
//!
//! The `SymbolLibrary` vtable is the intended extension point for an EasyPDK
//! loader. Implement a lazy-loading library that opens .chn / .chn_sym files
//! from the EasyPDK directory on first `resolve()` call:
//!
//!   pub const EasyPDKLibrary = struct {
//!       primitives: List([]const u8),  // .chn_sym paths
//!       components: List([]const u8),  // .chn paths
//!       cache: HashMap([]const u8, *Schemify),
//!       alloc: Allocator,
//!
//!       pub fn resolve(self: *@This(), name: []const u8) ?*const Schemify {
//!           if (self.cache.get(name)) |cached| return cached;
//!           for (self.components.items) |path| {
//!               if (std.mem.endsWith(u8, path, name)) {
//!                   const data = Vfs.readAlloc(self.alloc, path) catch return null;
//!                   defer self.alloc.free(data);
//!                   const s = self.alloc.create(Schemify) catch return null;
//!                   s.* = Schemify.readFile(data, self.alloc, null);
//!                   self.cache.put(self.alloc, name, s) catch {};
//!                   return s;
//!               }
//!           }
//!           return null;
//!       }
//!   };
const std = @import("std");
const Allocator = std.mem.Allocator;
const MAL = std.MultiArrayList;
const List = std.ArrayListUnmanaged;
const log = @import("logger.zig");
const dev = @import("device.zig");
const simd = @import("simd.zig");

// Re-export types that fileio.zig and callers need
pub const DeviceKind = dev.DeviceKind;
pub const PdkInfo = dev.PdkDeviceRegistry;
pub const SpiceDialect = dev.SpiceDialect;
pub const SpiceFormat = dev.SpiceFormat;
pub const SpiceDevice = dev.SpiceDevice;

// ── Value Types ─────────────────────────────────────────────────────────── //

/// 2D integer coordinate. `extern struct` for C ABI compatibility.
/// All Schemify coordinates are in schematic grid units (integers).
/// XSchem f64 coordinates are rounded to i32 during convertToSchemify.
pub const Point = extern struct {
    x: i32,
    y: i32,
    pub fn init(x: i32, y: i32) Point {
        return .{ .x = x, .y = y };
    }
    pub fn eql(a: Point, b: Point) bool {
        return a.x == b.x and a.y == b.y;
    }
    pub fn add(a: Point, b: Point) Point {
        return .{ .x = a.x + b.x, .y = a.y + b.y };
    }
    pub fn sub(a: Point, b: Point) Point {
        return .{ .x = a.x - b.x, .y = a.y - b.y };
    }
};

/// Compact 8-bit transform encoding (rotation + flip) for Instance placement.
/// rot: 0–3 quarter-turn CW steps; flip: horizontal mirror before rotation.
/// Fits in a single byte; no heap allocation required.
///
/// IMPROVE: `compose` handles flip–rotation interaction correctly but the
/// logic is non-obvious. Consider a truth-table comment or unit tests for
/// all 8 combinations (4 rotations × 2 flip states).
pub const Transform = packed struct {
    rot: u2 = 0,
    flip: bool = false,
    _pad: u5 = 0,
    pub const identity = Transform{};

    pub fn compose(self: Transform, other: Transform) Transform {
        var result = self;
        if (other.flip) result.flip = !result.flip;
        if (result.flip) {
            result.rot = self.rot -% other.rot;
        } else {
            result.rot = self.rot +% other.rot;
        }
        return result;
    }
};

pub const TransformOp = enum {
    move,
    rotate_cw,
    rotate_ccw,
    flip_x,
    flip_y,
};

pub const PinDir = enum(u8) {
    input,
    output,
    inout,
    power,
    ground,
    pub fn fromStr(s: []const u8) PinDir {
        if (s.len == 0) return .inout;
        return switch (s[0]) {
            'i' => if (std.mem.eql(u8, s, "io") or std.mem.eql(u8, s, "inout")) .inout else .input,
            'o' => .output,
            'p' => .power,
            'g' => .ground,
            else => .inout,
        };
    }
    pub fn toStr(self: PinDir) []const u8 {
        return switch (self) {
            .input => "i",
            .output => "o",
            .inout => "io",
            .power => "p",
            .ground => "g",
        };
    }
};

// ── DOD Element Structs ─────────────────────────────────────────────────── //
//
// All element structs are value types stored in MultiArrayList (MAL).
// Accessing a field for all elements is cache-efficient:
//   const xs = schemify.wires.slice();
//   for (xs.items(.x0)) |x0| { ... }
// Avoid AOS iteration (`for (wires.items) |w|`) — prefer slices.

/// A line segment on a specific layer. Used for symbol body graphics.
pub const Line = struct { layer: u8, x0: i32, y0: i32, x1: i32, y1: i32 };
pub const Rect = struct { layer: u8, x0: i32, y0: i32, x1: i32, y1: i32 };
pub const Arc = struct { layer: u8, cx: i32, cy: i32, radius: i32, start_angle: i16, sweep_angle: i16 };
pub const Circle = struct { layer: u8, cx: i32, cy: i32, radius: i32 };
/// Electrical wire. `net_name` is set when the wire carries an explicit label
/// (from an XSchem `lab=` attribute or a CHN net-name token). Null means the
/// net name is resolved geometrically by union-find during `resolveNets`.
pub const Wire = struct { x0: i32, y0: i32, x1: i32, y1: i32, net_name: ?[]const u8 = null };
pub const Text = struct { content: []const u8, x: i32, y: i32, layer: u8 = 4, size: u8 = 10, rotation: u2 = 0 };
pub const Pin = struct { name: []const u8, x: i32, y: i32, dir: PinDir = .inout, num: ?u16 = null };
/// A device placement. `symbol` is the fully-qualified symbol name used to
/// look up the device definition in SymbolLibrary or PdkInfo.
///
/// `prop_start/count` indexes into Schemify.props (key=value instance params).
/// `conn_start/count` indexes into Schemify.conns (pin→net explicit connectivity).
///
/// NOTE: For XSchem-sourced schematics, conn_count is always 0 — connections
/// are resolved geometrically via wire endpoints and net labels. The conn slots
/// are only populated when .chn files are written and re-read with explicit
/// netlist-resolved connectivity.
pub const Instance = struct {
    name: []const u8,
    symbol: []const u8,
    kind: DeviceKind = .unknown,
    x: i32,
    y: i32,
    rot: u2 = 0,
    flip: bool = false,
    prop_start: u32 = 0,
    prop_count: u16 = 0,
    conn_start: u32 = 0,
    conn_count: u16 = 0,
};
/// Instance property: a key=value pair (e.g. value="10k", model="nmos").
/// Strings owned by Schemify's arena.
pub const Prop = struct { key: []const u8, val: []const u8 };

/// Explicit pin→net connectivity entry. Only populated when a schematic has
/// been previously netlisted and the results written back into the .chn.
/// XSchem-sourced files always have conn_count=0; nets are resolved geometrically.
pub const Conn = struct { pin: []const u8, net: []const u8 };

// ═══════════════════════════════════════════════════════════════════════════ //
//  Symbol Library Interface
// ═══════════════════════════════════════════════════════════════════════════ //

/// Vtable interface for resolving symbol names → Schemify definitions.
///
/// The netlister calls resolve() to:
///   - Get .pins (port names + order) for .subckt declarations / X instance pin ordering
///   - Get .instances, .conns, .wires for subcircuit body emission (recursive)
///   - Get .name for the .subckt identifier
///   - Check .is_testbench (must be false for subcircuit definitions)
///
/// Return null if the symbol is unknown — the netlister treats unresolved
/// symbols as PDK primitives or external .lib models.
///
/// Implementations could be:
///   - A HashMap([]const u8, *Schemify) of pre-loaded symbols
///   - A lazy file loader reading .chn files from a library directory
///   - A cache-on-demand hybrid
pub const SymbolLibrary = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        resolve: *const fn (ctx: *anyopaque, symbol_name: []const u8) ?*const Schemify,
    };

    pub fn resolve(self: SymbolLibrary, symbol_name: []const u8) ?*const Schemify {
        return self.vtable.resolve(self.ctx, symbol_name);
    }

    /// Convenience: create from a concrete pointer type.
    /// `Impl` must have `pub fn resolve(self: *Impl, name: []const u8) ?*const Schemify`.
    pub fn from(ptr: anytype) SymbolLibrary {
        const Impl = @typeInfo(ptr).Pointer.child;
        const gen = struct {
            fn resolve(ctx: *anyopaque, name: []const u8) ?*const Schemify {
                const self: *Impl = @ptrCast(@alignCast(ctx));
                return self.resolve(name);
            }
        };
        return .{
            .ctx = @ptrCast(ptr),
            .vtable = &.{ .resolve = gen.resolve },
        };
    }
};

// ── Relational Connectivity (CHN v2) ────────────────────────────────────── //

/// A named net in the schematic. `name` is arena-owned.
pub const Net = struct { name: []const u8 };

/// What kind of connection a NetConn represents.
pub const ConnKind = enum(u8) {
    instance_pin,
    wire_endpoint,
    label,

    /// Serialize to the short v2 tag.
    pub fn toTag(self: ConnKind) []const u8 {
        return switch (self) {
            .instance_pin => "ip",
            .wire_endpoint => "we",
            .label => "lb",
        };
    }

    /// Parse from the short v2 tag.
    pub fn fromTag(s: []const u8) ConnKind {
        if (std.mem.eql(u8, s, "ip")) return .instance_pin;
        if (std.mem.eql(u8, s, "we")) return .wire_endpoint;
        return .label;
    }
};

/// One connection to a net. `ref_a`/`ref_b` meaning depends on `kind`:
///   instance_pin: ref_a = instance index, ref_b = 0
///   wire_endpoint: ref_a = x, ref_b = y
///   label: ref_a = x, ref_b = y
pub const NetConn = struct {
    net_id: u32,
    kind: ConnKind,
    ref_a: i32,
    ref_b: i32,
    pin_or_label: ?[]const u8 = null,
};

// ── Net Resolution types ────────────────────────────────────────────────── //

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
        const xu: u32 = @bitCast(x);
        const yu: u32 = @bitCast(y);
        return (@as(u64, xu) << 32) | @as(u64, yu);
    }
    pub fn getNetName(self: *const NetMap, x: i32, y: i32) ?[]const u8 {
        const k = pointKey(x, y);
        const root = self.point_to_root.get(k) orelse return null;
        return self.root_to_name.get(root);
    }
};

// ═══════════════════════════════════════════════════════════════════════════ //
//  Schemify Store
// ═══════════════════════════════════════════════════════════════════════════ //

pub const SifyType = enum(u2) {
    primitive,
    component,
    testbench,
};

pub const Schemify = struct {
    name: []const u8 = "",

    lines: MAL(Line) = .{},
    rects: MAL(Rect) = .{},
    arcs: MAL(Arc) = .{},
    circles: MAL(Circle) = .{},
    wires: MAL(Wire) = .{},
    texts: MAL(Text) = .{},
    pins: MAL(Pin) = .{},
    instances: MAL(Instance) = .{},
    props: List(Prop) = .{},
    conns: List(Conn) = .{},
    nets: List(Net) = .{},
    net_conns: List(NetConn) = .{},
    sym_props: List(Prop) = .{},
    verilog_body: ?[]const u8 = null,

    stype: SifyType = .component,

    arena: std.heap.ArenaAllocator,
    logger: ?*log.Logger = null,

    // Initialization Functions
    pub fn init(backing: Allocator) Schemify {
        return .{ .arena = std.heap.ArenaAllocator.init(backing) };
    }
    pub fn deinit(self: *Schemify) void {
        self.arena.deinit();
    }

    // Utilities Functions
    pub fn alloc(self: *Schemify) Allocator {
        return self.arena.allocator();
    }
    fn logWarn(self: *Schemify, comptime fmt: []const u8, args: anytype) void {
        if (self.logger) |l| l.warn("schemify", fmt, args);
    }
    fn logErr(self: *Schemify, comptime fmt: []const u8, args: anytype) void {
        if (self.logger) |l| l.err("schemify", fmt, args);
    }
    fn logInfo(self: *Schemify, comptime fmt: []const u8, args: anytype) void {
        if (self.logger) |l| l.info("schemify", fmt, args);
    }

    // ── FileIOIF interface ──────────────────────────────────────────── //

    pub fn readFile(data: []const u8, backing: Allocator, logger: ?*log.Logger) Schemify {
        var s = Schemify.init(backing);
        s.logger = logger;
        const is_v2 = isCHN2(data);
        s.stype = if (is_v2) detectTestbenchV2(data) else detectTestbench(data);
        if (s.stype == .testbench) {
            s.logInfo("detected testbench format", .{});
        } else {
            s.logInfo("detected component format", .{});
        }
        if (is_v2) {
            preScanAndReserveV2(&s, data);
            parseCHN2(&s, data);
        } else {
            preScanAndReserve(&s, data);
            parseCHN(&s, data);
        }
        return s;
    }

    /// Resolve geometric wire connectivity into explicit Net/NetConn entries.
    /// Uses union-find on wire endpoints. Injects gnd/vdd/lab_pin names.
    /// Auto-names unnamed nets _n0, _n1, etc. Populates nets + net_conns.
    pub fn resolveNets(self: *Schemify) void {
        self.nets.items.len = 0;
        self.net_conns.items.len = 0;
        const a = self.alloc();
        var uf = UnionFind.init();
        unionFindWires(&uf, self, a);
        var root_names = std.AutoHashMapUnmanaged(u64, []const u8){};
        injectSpecialNames(&root_names, &uf, self, a);
        injectWireLabels(&root_names, &uf, self, a);
        assignAutoNames(&root_names, &uf, self, a);
        buildNetsAndConns(self, &uf, &root_names, a);
    }

    pub fn writeFile(self: *Schemify, a: Allocator, logger: ?*log.Logger) ?[]u8 {
        self.logger = logger;
        var buf: List(u8) = .{};
        buf.ensureTotalCapacity(a, simd.estimateCHNSize(self)) catch {};
        const writer = buf.writer(a);
        self.logInfo("writing {s}: {d} instances, {d} wires", .{
            if (self.stype == .testbench) "testbench" else "component",
            self.instances.len,
            self.wires.len,
        });
        writeCHN(writer, self) catch |e| {
            self.logErr("write failed: {}", .{e});
            buf.deinit(a);
            return null;
        };
        return buf.toOwnedSlice(a) catch |e| {
            self.logErr("write toOwnedSlice failed: {}", .{e});
            buf.deinit(a);
            return null;
        };
    }
};

// ═══════════════════════════════════════════════════════════════════════════ //
//  Format Detection
// ═══════════════════════════════════════════════════════════════════════════ //

fn detectTestbench(input: []const u8) SifyType {
    const nl = std.mem.indexOfScalar(u8, input, '\n') orelse input.len;
    const header = std.mem.trim(u8, input[0..nl], " \t\r");
    return if (std.mem.endsWith(u8, header, " TB")) .testbench else .component;
}

// ═══════════════════════════════════════════════════════════════════════════ //
//  CHN Reader
// ═══════════════════════════════════════════════════════════════════════════ //

/// Quick pre-scan to count elements and reserve MAL capacity, eliminating
/// O(log N) resize-and-copy operations during the main parse pass.
fn preScanAndReserve(s: *Schemify, input: []const u8) void {
    const a = s.alloc();
    var it = simd.LineIterator.init(input);
    var section: Section = .header;
    var wires: usize = 0;
    var instances: usize = 0;
    var texts: usize = 0;
    var line_count: usize = 0;
    var rects: usize = 0;
    var arcs: usize = 0;
    var pins: usize = 0;
    _ = it.next(); // skip header
    while (it.next()) |raw| {
        if (raw.len == 0) continue;
        const first = raw[0];
        if (first == '#') continue;
        if (first == '[') {
            const trimmed = std.mem.trim(u8, raw, " \t\r");
            if (std.mem.eql(u8, trimmed, "[schematic]")) {
                section = .schematic;
                continue;
            }
            if (std.mem.eql(u8, trimmed, "[symbol]")) {
                section = .symbol;
                continue;
            }
            if (std.mem.eql(u8, trimmed, "[end]")) break;
        }
        if (section == .schematic) {
            switch (first) {
                'N' => wires += 1,
                'C' => instances += 1,
                'T' => texts += 1,
                'L' => line_count += 1,
                'B' => rects += 1,
                'A' => arcs += 1,
                else => {},
            }
        } else if (section == .symbol) {
            switch (first) {
                'P' => pins += 1,
                'L' => line_count += 1,
                'B' => rects += 1,
                'A' => arcs += 1,
                'T' => texts += 1,
                else => {},
            }
        }
    }
    s.wires.ensureTotalCapacity(a, wires) catch {};
    s.instances.ensureTotalCapacity(a, instances) catch {};
    s.texts.ensureTotalCapacity(a, texts) catch {};
    s.lines.ensureTotalCapacity(a, line_count) catch {};
    s.rects.ensureTotalCapacity(a, rects) catch {};
    s.arcs.ensureTotalCapacity(a, arcs) catch {};
    s.pins.ensureTotalCapacity(a, pins) catch {};
}

fn parseCHN(s: *Schemify, input: []const u8) void {
    const a = s.alloc();
    var it = simd.LineIterator.init(input);
    var line_num: u32 = 0;
    var section: Section = .header;

    if (it.next()) |raw| {
        line_num += 1;
        const header = std.mem.trim(u8, raw, " \t\r");
        parseHeader(a, header, s) catch |e| {
            s.logWarn("line {d}: header: {}", .{ line_num, e });
        };
    }

    while (it.next()) |raw| {
        line_num += 1;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '#') continue;
        if (line.len >= 5 and line[0] == '[') {
            if (std.mem.eql(u8, line, "[schematic]")) {
                section = .schematic;
                continue;
            }
            if (std.mem.eql(u8, line, "[symbol]")) {
                section = .symbol;
                continue;
            }
            if (std.mem.eql(u8, line, "[end]")) break;
        }
        switch (section) {
            .header => {},
            .schematic => parseSchematicLine(a, s, line, line_num),
            .symbol => parseSymbolLine(a, s, line, line_num),
        }
    }

    s.logInfo("parsed {s} \"{s}\": {d} inst, {d} wire, {d} pin, {d} shape", .{
        if (s.stype == .testbench) "TB" else "comp",
        s.name,
        s.instances.len,
        s.wires.len,
        s.pins.len,
        s.lines.len + s.rects.len + s.arcs.len + s.circles.len,
    });
}

const Section = enum { header, schematic, symbol };

fn parseHeader(a: Allocator, header: []const u8, s: *Schemify) !void {
    if (!std.mem.startsWith(u8, header, "CHN ")) return error.InvalidFormat;
    var tok = std.mem.tokenizeAny(u8, header, " \t");
    _ = tok.next();
    const ver = tok.next() orelse return error.InvalidFormat;
    if (!std.mem.eql(u8, ver, "v1")) {
        s.logWarn("unsupported version: {s}", .{ver});
        return error.UnsupportedVersion;
    }
    s.name = try a.dupe(u8, tok.next() orelse "untitled");
}

fn parseSchematicLine(a: Allocator, s: *Schemify, line: []const u8, ln: u32) void {
    if (line.len < 2) return;
    switch (line[0]) {
        'C' => parseInstance(a, s, line) catch |e| {
            s.logWarn("L{d}: inst: {}", .{ ln, e });
        },
        'N' => parseWireLine(a, s, line) catch |e| {
            s.logWarn("L{d}: wire: {}", .{ ln, e });
        },
        'T' => _ = parseTextLine(a, s, line) catch |e| {
            s.logWarn("L{d}: text: {}", .{ ln, e });
        },
        'L' => parseLineLine(a, s, line),
        'B' => parseRectLine(a, s, line),
        'A' => parseArcOrCircle(a, s, line),
        else => {},
    }
}

fn parseSymbolLine(a: Allocator, s: *Schemify, line: []const u8, ln: u32) void {
    if (line.len < 2) return;
    switch (line[0]) {
        'P' => parsePinLine(a, s, line) catch |e| {
            s.logWarn("L{d}: pin: {}", .{ ln, e });
        },
        'K' => parseSymPropLine(a, s, line) catch |e| {
            s.logWarn("L{d}: sprop: {}", .{ ln, e });
        },
        'L' => parseLineLine(a, s, line),
        'B' => parseRectLine(a, s, line),
        'A' => parseArcOrCircle(a, s, line),
        'T' => _ = parseTextLine(a, s, line) catch |e| {
            s.logWarn("L{d}: text: {}", .{ ln, e });
        },
        else => {},
    }
}

fn parseInstance(a: Allocator, s: *Schemify, line: []const u8) !void {
    const data = line[2..];
    var pos: usize = 0;
    const sym_raw = simd.nextToken(data, &pos) orelse return error.InvalidFormat;
    const x = simd.nextI32(data, &pos) orelse return error.InvalidNumber;
    const y = simd.nextI32(data, &pos) orelse return error.InvalidNumber;
    const rot: u2 = @truncate(@as(u32, @bitCast(simd.nextI32(data, &pos) orelse 0)));
    const flip_i: u8 = simd.nextU8(data, &pos) orelse 0;
    const kind_str = simd.nextToken(data, &pos) orelse "unknown";
    const sym = try a.dupe(u8, sym_raw);
    const prop_start: u32 = @intCast(s.props.items.len);
    const conn_start: u32 = @intCast(s.conns.items.len);
    var inst_name: []const u8 = "";
    if (std.mem.indexOfScalar(u8, line, '{')) |ps| {
        if (std.mem.indexOfScalarPos(u8, line, ps + 1, '}')) |pe|
            try parsePropsInto(a, line[ps + 1 .. pe], &s.props, &inst_name);
    }
    if (std.mem.indexOfScalar(u8, line, '[')) |cs| {
        if (std.mem.indexOfScalarPos(u8, line, cs + 1, ']')) |ce|
            try parseConnsInto(a, line[cs + 1 .. ce], &s.conns);
    }
    try s.instances.append(a, .{
        .name = inst_name,
        .symbol = sym,
        .kind = DeviceKind.fromStr(kind_str),
        .x = x,
        .y = y,
        .rot = rot,
        .flip = flip_i != 0,
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
    if (simd.nextToken(data, &pos)) |n| net = try a.dupe(u8, n);
    try s.wires.append(a, .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1, .net_name = net });
}

fn parseTextLine(a: Allocator, s: *Schemify, line: []const u8) !bool {
    if (line.len < 3) return false;
    const data = line[2..];
    var pos: usize = 0;
    const x = simd.nextI32(data, &pos) orelse return false;
    const y = simd.nextI32(data, &pos) orelse return false;
    const layer: u8 = simd.nextU8(data, &pos) orelse 4;
    const size: u8 = simd.nextU8(data, &pos) orelse 10;
    const rot: u2 = @truncate(@as(u32, @bitCast(simd.nextI32(data, &pos) orelse 0)));
    const rest = simd.restAfterWs(data, pos);
    if (rest.len == 0) return false;
    try s.texts.append(a, .{ .content = try a.dupe(u8, rest), .x = x, .y = y, .layer = layer, .size = size, .rotation = rot });
    return true;
}

fn parseLineLine(a: Allocator, s: *Schemify, line: []const u8) void {
    if (line.len < 3) return;
    const data = line[2..];
    var pos: usize = 0;
    const ly: u8 = simd.nextU8(data, &pos) orelse return;
    const x0 = simd.nextI32(data, &pos) orelse return;
    const y0 = simd.nextI32(data, &pos) orelse return;
    const x1 = simd.nextI32(data, &pos) orelse return;
    const y1 = simd.nextI32(data, &pos) orelse return;
    s.lines.append(a, .{ .layer = ly, .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1 }) catch return;
}

fn parseRectLine(a: Allocator, s: *Schemify, line: []const u8) void {
    if (line.len < 3) return;
    const data = line[2..];
    var pos: usize = 0;
    const ly: u8 = simd.nextU8(data, &pos) orelse return;
    const x0 = simd.nextI32(data, &pos) orelse return;
    const y0 = simd.nextI32(data, &pos) orelse return;
    const x1 = simd.nextI32(data, &pos) orelse return;
    const y1 = simd.nextI32(data, &pos) orelse return;
    s.rects.append(a, .{ .layer = ly, .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1 }) catch return;
}

fn parseArcOrCircle(a: Allocator, s: *Schemify, line: []const u8) void {
    if (line.len < 3) return;
    const data = line[2..];
    var pos: usize = 0;
    const ly: u8 = simd.nextU8(data, &pos) orelse return;
    const cx = simd.nextI32(data, &pos) orelse return;
    const cy = simd.nextI32(data, &pos) orelse return;
    const r = simd.nextI32(data, &pos) orelse return;
    const sa = simd.nextI16(data, &pos) orelse return;
    const sw = simd.nextI16(data, &pos) orelse return;
    if (sa == 0 and sw == 360) {
        s.circles.append(a, .{ .layer = ly, .cx = cx, .cy = cy, .radius = r }) catch return;
    } else {
        s.arcs.append(a, .{ .layer = ly, .cx = cx, .cy = cy, .radius = r, .start_angle = sa, .sweep_angle = sw }) catch return;
    }
}

fn parsePinLine(a: Allocator, s: *Schemify, line: []const u8) !void {
    if (line.len < 3) return;
    const data = line[2..];
    var pos: usize = 0;
    const name_raw = simd.nextToken(data, &pos) orelse return error.InvalidFormat;
    const x = simd.nextI32(data, &pos) orelse return error.InvalidNumber;
    const y = simd.nextI32(data, &pos) orelse return error.InvalidNumber;
    const dir_str = simd.nextToken(data, &pos) orelse "io";
    const num: ?u16 = simd.nextU16(data, &pos);
    try s.pins.append(a, .{ .name = try a.dupe(u8, name_raw), .x = x, .y = y, .dir = PinDir.fromStr(dir_str), .num = num });
}

fn parseSymPropLine(a: Allocator, s: *Schemify, line: []const u8) !void {
    if (line.len < 3) return;
    var ptok = KVTokenizer.init(line[2..]);
    while (ptok.next()) |p|
        try s.sym_props.append(a, .{ .key = try a.dupe(u8, p.key), .val = try a.dupe(u8, p.val) });
}

fn parsePropsInto(a: Allocator, s: []const u8, props: *List(Prop), name: *[]const u8) !void {
    var tok = KVTokenizer.init(s);
    while (tok.next()) |p| {
        const k = try a.dupe(u8, p.key);
        const v = try a.dupe(u8, p.val);
        if (std.mem.eql(u8, k, "name")) name.* = v;
        try props.append(a, .{ .key = k, .val = v });
    }
}

fn parseConnsInto(a: Allocator, s: []const u8, conns: *List(Conn)) !void {
    var tok = KVTokenizer.init(s);
    while (tok.next()) |p|
        try conns.append(a, .{ .pin = try a.dupe(u8, p.key), .net = try a.dupe(u8, p.val) });
}

// ═══════════════════════════════════════════════════════════════════════════ //
//  CHN Writer
// ═══════════════════════════════════════════════════════════════════════════ //

fn bufShapePrefix(buf: *[80]u8, prefix: u8, layer: u8) usize {
    buf[0] = prefix;
    buf[1] = ' ';
    return 2 + simd.writeU8(buf[2..], layer);
}

fn bufWriteI32_3(buf: *[80]u8, start: usize, a: i32, b: i32, c: i32) usize {
    var n: usize = 0;
    buf[start + n] = ' ';
    n += 1;
    n += simd.writeI32(buf[start + n ..], a);
    buf[start + n] = ' ';
    n += 1;
    n += simd.writeI32(buf[start + n ..], b);
    buf[start + n] = ' ';
    n += 1;
    n += simd.writeI32(buf[start + n ..], c);
    return n;
}

fn bufWriteI32_4(buf: *[80]u8, start: usize, a: i32, b: i32, c: i32, d: i32) usize {
    var n = bufWriteI32_3(buf, start, a, b, c);
    buf[start + n] = ' ';
    n += 1;
    n += simd.writeI32(buf[start + n ..], d);
    return n;
}

fn writeCHN(w: anytype, s: *const Schemify) !void {
    try w.writeAll("CHN2 ");
    try w.writeAll(s.name);
    if (s.stype == .testbench) try w.writeAll(" TB");
    try w.writeAll("\n[s]\n");

    var buf: [80]u8 = undefined;

    const ws = s.wires.slice();
    const wx0 = ws.items(.x0);
    const wy0 = ws.items(.y0);
    const wx1 = ws.items(.x1);
    const wy1 = ws.items(.y1);
    const wnn = ws.items(.net_name);
    for (0..s.wires.len) |i| {
        var n: usize = 0;
        buf[n] = 'W';
        n += 1;
        buf[n] = ' ';
        n += 1;
        n += simd.writeI32(buf[n..], wx0[i]);
        buf[n] = ' ';
        n += 1;
        n += simd.writeI32(buf[n..], wy0[i]);
        buf[n] = ' ';
        n += 1;
        n += simd.writeI32(buf[n..], wx1[i]);
        buf[n] = ' ';
        n += 1;
        n += simd.writeI32(buf[n..], wy1[i]);
        try w.writeAll(buf[0..n]);
        if (wnn[i]) |name| {
            try w.writeAll(" ");
            try w.writeAll(name);
        }
        try w.writeAll("\n");
    }

    const ins = s.instances.slice();
    const isym = ins.items(.symbol);
    const ix = ins.items(.x);
    const iy = ins.items(.y);
    const irot = ins.items(.rot);
    const iflip = ins.items(.flip);
    const ikind = ins.items(.kind);
    const ips = ins.items(.prop_start);
    const ipc = ins.items(.prop_count);
    const ics = ins.items(.conn_start);
    const icc = ins.items(.conn_count);
    for (0..s.instances.len) |i| {
        try w.writeAll("I ");
        try w.writeAll(isym[i]);
        var n: usize = 0;
        buf[n] = ' ';
        n += 1;
        n += simd.writeI32(buf[n..], ix[i]);
        buf[n] = ' ';
        n += 1;
        n += simd.writeI32(buf[n..], iy[i]);
        buf[n] = ' ';
        n += 1;
        n += simd.writeU8(buf[n..], @as(u8, irot[i]));
        buf[n] = ' ';
        n += 1;
        buf[n] = if (iflip[i]) '1' else '0';
        n += 1;
        buf[n] = ' ';
        n += 1;
        try w.writeAll(buf[0..n]);
        try w.writeAll(ikind[i].toStr());
        const ps = ips[i];
        const pc = ipc[i];
        if (pc > 0) {
            try w.writeAll(" {");
            for (s.props.items[ps..][0..pc], 0..) |p, j| {
                if (j > 0) try w.writeAll(" ");
                try w.writeAll(p.key);
                try w.writeAll("=");
                try w.writeAll(p.val);
            }
            try w.writeAll("}");
        }
        const cs2 = ics[i];
        const cc = icc[i];
        if (cc > 0) {
            try w.writeAll(" [");
            for (s.conns.items[cs2..][0..cc], 0..) |c, j| {
                if (j > 0) try w.writeAll(" ");
                try w.writeAll(c.pin);
                try w.writeAll("=");
                try w.writeAll(c.net);
            }
            try w.writeAll("]");
        }
        try w.writeAll("\n");
    }

    const ts = s.texts.slice();
    const tx = ts.items(.x);
    const ty = ts.items(.y);
    const tl = ts.items(.layer);
    const tsz = ts.items(.size);
    const trot = ts.items(.rotation);
    const tcnt = ts.items(.content);
    for (0..s.texts.len) |i| {
        var n: usize = 0;
        buf[n] = 'T';
        n += 1;
        buf[n] = ' ';
        n += 1;
        n += simd.writeI32(buf[n..], tx[i]);
        buf[n] = ' ';
        n += 1;
        n += simd.writeI32(buf[n..], ty[i]);
        buf[n] = ' ';
        n += 1;
        n += simd.writeU8(buf[n..], tl[i]);
        buf[n] = ' ';
        n += 1;
        n += simd.writeU8(buf[n..], tsz[i]);
        buf[n] = ' ';
        n += 1;
        n += simd.writeU8(buf[n..], @as(u8, trot[i]));
        buf[n] = ' ';
        n += 1;
        try w.writeAll(buf[0..n]);
        try w.writeAll(tcnt[i]);
        try w.writeAll("\n");
    }

    const ls = s.lines.slice();
    for (0..s.lines.len) |i| {
        var n = bufShapePrefix(&buf, 'L', ls.items(.layer)[i]);
        n += bufWriteI32_4(&buf, n, ls.items(.x0)[i], ls.items(.y0)[i], ls.items(.x1)[i], ls.items(.y1)[i]);
        buf[n] = '\n';
        n += 1;
        try w.writeAll(buf[0..n]);
    }

    const rs = s.rects.slice();
    for (0..s.rects.len) |i| {
        var n = bufShapePrefix(&buf, 'B', rs.items(.layer)[i]);
        n += bufWriteI32_4(&buf, n, rs.items(.x0)[i], rs.items(.y0)[i], rs.items(.x1)[i], rs.items(.y1)[i]);
        buf[n] = '\n';
        n += 1;
        try w.writeAll(buf[0..n]);
    }

    const as_ = s.arcs.slice();
    for (0..s.arcs.len) |i| {
        var n = bufShapePrefix(&buf, 'A', as_.items(.layer)[i]);
        n += bufWriteI32_4(&buf, n, as_.items(.cx)[i], as_.items(.cy)[i], as_.items(.radius)[i], @as(i32, as_.items(.start_angle)[i]));
        buf[n] = ' ';
        n += 1;
        n += simd.writeI32(buf[n..], @as(i32, as_.items(.sweep_angle)[i]));
        buf[n] = '\n';
        n += 1;
        try w.writeAll(buf[0..n]);
    }

    const circles = s.circles.slice();
    for (0..s.circles.len) |i| {
        var n = bufShapePrefix(&buf, 'A', circles.items(.layer)[i]);
        n += bufWriteI32_3(&buf, n, circles.items(.cx)[i], circles.items(.cy)[i], circles.items(.radius)[i]);
        @memcpy(buf[n..][0..7], " 0 360\n");
        n += 7;
        try w.writeAll(buf[0..n]);
    }

    // ── [n] net section ──
    try writeNetSection(w, s);

    if (s.stype != .testbench) {
        try w.writeAll("[y]\n");
        for (s.sym_props.items) |p| {
            try w.writeAll("K ");
            try w.writeAll(p.key);
            try w.writeAll("=");
            try w.writeAll(p.val);
            try w.writeAll("\n");
        }
        const pns = s.pins.slice();
        for (0..s.pins.len) |i| {
            try w.writeAll("P ");
            try w.writeAll(pns.items(.name)[i]);
            var n: usize = 0;
            buf[n] = ' ';
            n += 1;
            n += simd.writeI32(buf[n..], pns.items(.x)[i]);
            buf[n] = ' ';
            n += 1;
            n += simd.writeI32(buf[n..], pns.items(.y)[i]);
            buf[n] = ' ';
            n += 1;
            try w.writeAll(buf[0..n]);
            try w.writeAll(pns.items(.dir)[i].toStr());
            if (pns.items(.num)[i]) |num| {
                var nb: [12]u8 = undefined;
                nb[0] = ' ';
                const nlen = simd.writeI32(nb[1..], @as(i32, num));
                try w.writeAll(nb[0 .. 1 + nlen]);
            }
            try w.writeAll("\n");
        }
    }
    try w.writeAll("[e]\n");
}

/// Write the [n] net section for CHN v2.
fn writeNetSection(w: anytype, s: *const Schemify) !void {
    if (s.nets.items.len == 0) return;
    try w.writeAll("[n]\n");
    var buf: [80]u8 = undefined;
    for (s.nets.items, 0..) |net, i| {
        buf[0] = 'N';
        buf[1] = ' ';
        var n: usize = 2;
        n += simd.writeI32(buf[n..], @intCast(i));
        buf[n] = ' ';
        n += 1;
        try w.writeAll(buf[0..n]);
        try w.writeAll(net.name);
        try w.writeAll("\n");
    }
    for (s.net_conns.items) |nc| {
        buf[0] = '~';
        buf[1] = ' ';
        var n: usize = 2;
        n += simd.writeI32(buf[n..], @intCast(nc.net_id));
        buf[n] = ' ';
        n += 1;
        try w.writeAll(buf[0..n]);
        try w.writeAll(nc.kind.toTag());
        n = 0;
        buf[n] = ' ';
        n += 1;
        n += simd.writeI32(buf[n..], nc.ref_a);
        buf[n] = ' ';
        n += 1;
        n += simd.writeI32(buf[n..], nc.ref_b);
        try w.writeAll(buf[0..n]);
        if (nc.pin_or_label) |pl| {
            try w.writeAll(" ");
            try w.writeAll(pl);
        }
        try w.writeAll("\n");
    }
}

// ── KV Tokenizer ────────────────────────────────────────────────────────── //

const KVTokenizer = struct {
    src: []const u8,
    pos: usize = 0,
    const Tok = struct { key: []const u8, val: []const u8 };
    fn init(src: []const u8) KVTokenizer {
        return .{ .src = src };
    }
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
            while (self.pos < self.src.len and self.src[self.pos] != '"') self.pos += 1;
            const val = self.src[vs..self.pos];
            if (self.pos < self.src.len) self.pos += 1;
            return .{ .key = key, .val = val };
        }
        const vs = self.pos;
        while (self.pos < self.src.len and !isWs(self.src[self.pos])) self.pos += 1;
        return .{ .key = key, .val = self.src[vs..self.pos] };
    }
    fn isWs(c: u8) bool {
        return c == ' ' or c == '\t' or c == '\n' or c == '\r';
    }
};

// ═══════════════════════════════════════════════════════════════════════════ //
//  CHN v2 Detection + Parsing
// ═══════════════════════════════════════════════════════════════════════════ //

fn isCHN2(input: []const u8) bool {
    return std.mem.startsWith(u8, input, "CHN2 ");
}

fn detectTestbenchV2(input: []const u8) SifyType {
    const nl = std.mem.indexOfScalar(u8, input, '\n') orelse input.len;
    const header = std.mem.trim(u8, input[0..nl], " \t\r");
    return if (std.mem.endsWith(u8, header, " TB")) .testbench else .component;
}

const SectionV2 = enum { header, schematic, nets, symbol };

fn preScanAndReserveV2(s: *Schemify, input: []const u8) void {
    const a = s.alloc();
    var it = simd.LineIterator.init(input);
    var section: SectionV2 = .header;
    var wires: usize = 0;
    var instances: usize = 0;
    var texts: usize = 0;
    var line_count: usize = 0;
    var rects: usize = 0;
    var arcs: usize = 0;
    var pins: usize = 0;
    var net_count: usize = 0;
    var conn_count: usize = 0;
    _ = it.next(); // skip header
    while (it.next()) |raw| {
        if (raw.len == 0) continue;
        const first = raw[0];
        if (first == '#') continue;
        if (first == '[') {
            const trimmed = std.mem.trim(u8, raw, " \t\r");
            section = parseSectionV2(trimmed) orelse break;
            continue;
        }
        switch (section) {
            .schematic => switch (first) {
                'W' => wires += 1,
                'I' => instances += 1,
                'T' => texts += 1,
                'L' => line_count += 1,
                'B' => rects += 1,
                'A' => arcs += 1,
                else => {},
            },
            .symbol => switch (first) {
                'P' => pins += 1,
                'L' => line_count += 1,
                'B' => rects += 1,
                'A' => arcs += 1,
                'T' => texts += 1,
                else => {},
            },
            .nets => switch (first) {
                'N' => net_count += 1,
                '~' => conn_count += 1,
                else => {},
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
    s.nets.ensureTotalCapacity(a, net_count) catch {};
    s.net_conns.ensureTotalCapacity(a, conn_count) catch {};
}

fn parseSectionV2(trimmed: []const u8) ?SectionV2 {
    if (std.mem.eql(u8, trimmed, "[s]")) return .schematic;
    if (std.mem.eql(u8, trimmed, "[n]")) return .nets;
    if (std.mem.eql(u8, trimmed, "[y]")) return .symbol;
    if (std.mem.eql(u8, trimmed, "[e]")) return null;
    return .header; // unknown section, skip
}

fn parseCHN2(s: *Schemify, input: []const u8) void {
    const a = s.alloc();
    var it = simd.LineIterator.init(input);
    var line_num: u32 = 0;
    var section: SectionV2 = .header;

    if (it.next()) |raw| {
        line_num += 1;
        const header = std.mem.trim(u8, raw, " \t\r");
        parseHeaderV2(a, header, s) catch |e| {
            s.logWarn("line {d}: header: {}", .{ line_num, e });
        };
    }

    while (it.next()) |raw| {
        line_num += 1;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') {
            section = parseSectionV2(line) orelse break;
            continue;
        }
        switch (section) {
            .header => {},
            .schematic => parseSchematicLineV2(a, s, line, line_num),
            .symbol => parseSymbolLine(a, s, line, line_num),
            .nets => parseNetSectionLine(a, s, line, line_num),
        }
    }

    s.logInfo("parsed v2 {s} \"{s}\": {d} inst, {d} wire, {d} net, {d} pin", .{
        if (s.stype == .testbench) "TB" else "comp",
        s.name,
        s.instances.len,
        s.wires.len,
        s.nets.items.len,
        s.pins.len,
    });
}

fn parseHeaderV2(a: Allocator, header: []const u8, s: *Schemify) !void {
    if (!std.mem.startsWith(u8, header, "CHN2 ")) return error.InvalidFormat;
    var tok = std.mem.tokenizeAny(u8, header, " \t");
    _ = tok.next(); // "CHN2"
    const name = tok.next() orelse "untitled";
    s.name = try a.dupe(u8, name);
}

fn parseSchematicLineV2(a: Allocator, s: *Schemify, line: []const u8, ln: u32) void {
    if (line.len < 2) return;
    switch (line[0]) {
        'I' => parseInstance(a, s, line) catch |e| {
            s.logWarn("L{d}: inst: {}", .{ ln, e });
        },
        'W' => parseWireLine(a, s, line) catch |e| {
            s.logWarn("L{d}: wire: {}", .{ ln, e });
        },
        'T' => _ = parseTextLine(a, s, line) catch |e| {
            s.logWarn("L{d}: text: {}", .{ ln, e });
        },
        'L' => parseLineLine(a, s, line),
        'B' => parseRectLine(a, s, line),
        'A' => parseArcOrCircle(a, s, line),
        else => {},
    }
}

fn parseNetSectionLine(a: Allocator, s: *Schemify, line: []const u8, ln: u32) void {
    if (line.len < 2) return;
    switch (line[0]) {
        'N' => parseNetDef(a, s, line) catch |e| {
            s.logWarn("L{d}: net def: {}", .{ ln, e });
        },
        '~' => parseNetConn(a, s, line) catch |e| {
            s.logWarn("L{d}: net conn: {}", .{ ln, e });
        },
        else => {},
    }
}

fn parseNetDef(a: Allocator, s: *Schemify, line: []const u8) !void {
    const data = line[2..];
    var pos: usize = 0;
    _ = simd.nextI32(data, &pos) orelse return error.InvalidFormat; // net_id (ordinal)
    const name = simd.restAfterWs(data, pos);
    if (name.len == 0) return error.InvalidFormat;
    try s.nets.append(a, .{ .name = try a.dupe(u8, name) });
}

fn parseNetConn(a: Allocator, s: *Schemify, line: []const u8) !void {
    const data = line[2..];
    var pos: usize = 0;
    const net_id: u32 = @intCast(simd.nextI32(data, &pos) orelse return error.InvalidFormat);
    const kind_str = simd.nextToken(data, &pos) orelse return error.InvalidFormat;
    const ref_a = simd.nextI32(data, &pos) orelse return error.InvalidFormat;
    const ref_b = simd.nextI32(data, &pos) orelse return error.InvalidFormat;
    const rest = simd.restAfterWs(data, pos);
    const pl: ?[]const u8 = if (rest.len > 0) try a.dupe(u8, rest) else null;
    try s.net_conns.append(a, .{
        .net_id = net_id,
        .kind = ConnKind.fromTag(kind_str),
        .ref_a = ref_a,
        .ref_b = ref_b,
        .pin_or_label = pl,
    });
}

// ═══════════════════════════════════════════════════════════════════════════ //
//  Union-Find for resolveNets
// ═══════════════════════════════════════════════════════════════════════════ //

const UnionFind = struct {
    parent: std.AutoHashMapUnmanaged(u64, u64) = .{},

    fn init() UnionFind {
        return .{};
    }

    fn find(self: *UnionFind, x: u64, a: Allocator) u64 {
        var cur = x;
        while (true) {
            const p = self.parent.get(cur) orelse return cur;
            if (p == cur) return cur;
            // Path compression: grandparent
            const gp = self.parent.get(p) orelse p;
            self.parent.put(a, cur, gp) catch {};
            cur = gp;
        }
    }

    fn makeSet(self: *UnionFind, x: u64, a: Allocator) void {
        const r = self.parent.getOrPut(a, x) catch return;
        if (!r.found_existing) r.value_ptr.* = x;
    }

    fn unite(self: *UnionFind, x: u64, y: u64, a: Allocator) void {
        const rx = self.find(x, a);
        const ry = self.find(y, a);
        if (rx == ry) return;
        self.parent.put(a, ry, rx) catch {};
    }
};

fn unionFindWires(uf: *UnionFind, s: *const Schemify, a: Allocator) void {
    const ws = s.wires.slice();
    const wx0 = ws.items(.x0);
    const wy0 = ws.items(.y0);
    const wx1 = ws.items(.x1);
    const wy1 = ws.items(.y1);
    for (0..s.wires.len) |i| {
        const k0 = NetMap.pointKey(wx0[i], wy0[i]);
        const k1 = NetMap.pointKey(wx1[i], wy1[i]);
        uf.makeSet(k0, a);
        uf.makeSet(k1, a);
        uf.unite(k0, k1, a);
    }
}

/// Inject net names from explicit wire labels (net_name field on wires).
/// This handles `{lab=VDD}` style annotations in xschem .sch files.
fn injectWireLabels(
    root_names: *std.AutoHashMapUnmanaged(u64, []const u8),
    uf: *UnionFind,
    s: *const Schemify,
    a: Allocator,
) void {
    const ws = s.wires.slice();
    const wx0 = ws.items(.x0);
    const wy0 = ws.items(.y0);
    const wnn = ws.items(.net_name);
    for (0..s.wires.len) |i| {
        const name = wnn[i] orelse continue;
        const k = NetMap.pointKey(wx0[i], wy0[i]);
        uf.makeSet(k, a);
        const root = uf.find(k, a);
        if (!root_names.contains(root)) {
            root_names.put(a, root, name) catch {};
        }
    }
}

fn injectSpecialNames(
    root_names: *std.AutoHashMapUnmanaged(u64, []const u8),
    uf: *UnionFind,
    s: *const Schemify,
    a: Allocator,
) void {
    const ins = s.instances.slice();
    const ikind = ins.items(.kind);
    const ix = ins.items(.x);
    const iy = ins.items(.y);
    const ips = ins.items(.prop_start);
    const ipc = ins.items(.prop_count);
    for (0..s.instances.len) |i| {
        const name = getInjectedName(ikind[i], ips[i], ipc[i], s);
        if (name == null) continue;
        const k = NetMap.pointKey(ix[i], iy[i]);
        uf.makeSet(k, a);
        const root = uf.find(k, a);
        root_names.put(a, root, name.?) catch {};
    }
}

fn getInjectedName(kind: DeviceKind, ps: u32, pc: u16, s: *const Schemify) ?[]const u8 {
    if (kind.injectedNetName()) |n| return n;
    if (kind != .lab_pin) return null;
    const props = s.props.items[ps..][0..pc];
    for (props) |p| {
        if (std.mem.eql(u8, p.key, "lab")) return p.val;
    }
    return null;
}

fn assignAutoNames(
    root_names: *std.AutoHashMapUnmanaged(u64, []const u8),
    uf: *UnionFind,
    s: *const Schemify,
    a: Allocator,
) void {
    var auto_idx: u32 = 0;
    const ws = s.wires.slice();
    const wx0 = ws.items(.x0);
    const wy0 = ws.items(.y0);
    const wx1 = ws.items(.x1);
    const wy1 = ws.items(.y1);
    for (0..s.wires.len) |i| {
        const endpoints = [2]u64{ NetMap.pointKey(wx0[i], wy0[i]), NetMap.pointKey(wx1[i], wy1[i]) };
        for (endpoints) |k| {
            const root = uf.find(k, a);
            if (root_names.contains(root)) continue;
            const name = std.fmt.allocPrint(a, "_n{d}", .{auto_idx}) catch continue;
            root_names.put(a, root, name) catch {};
            auto_idx += 1;
        }
    }
}

fn buildNetsAndConns(
    s: *Schemify,
    uf: *UnionFind,
    root_names: *std.AutoHashMapUnmanaged(u64, []const u8),
    a: Allocator,
) void {
    var root_to_id = std.AutoHashMapUnmanaged(u64, u32){};
    // Build net list from root_names
    var rn_it = root_names.iterator();
    while (rn_it.next()) |entry| {
        const id: u32 = @intCast(s.nets.items.len);
        s.nets.append(a, .{ .name = entry.value_ptr.* }) catch continue;
        root_to_id.put(a, entry.key_ptr.*, id) catch {};
    }
    // Wire endpoint conns
    const ws = s.wires.slice();
    for (0..s.wires.len) |i| {
        const endpoints = [_]struct { x: i32, y: i32 }{
            .{ .x = ws.items(.x0)[i], .y = ws.items(.y0)[i] },
            .{ .x = ws.items(.x1)[i], .y = ws.items(.y1)[i] },
        };
        for (endpoints) |ep| {
            const root = uf.find(NetMap.pointKey(ep.x, ep.y), a);
            const nid = root_to_id.get(root) orelse continue;
            s.net_conns.append(a, .{
                .net_id = nid,
                .kind = .wire_endpoint,
                .ref_a = ep.x,
                .ref_b = ep.y,
            }) catch {};
        }
    }
    // Instance pin conns
    addInstanceConns(s, uf, &root_to_id, a);
}

fn addInstanceConns(
    s: *Schemify,
    uf: *UnionFind,
    root_to_id: *std.AutoHashMapUnmanaged(u64, u32),
    a: Allocator,
) void {
    const ins = s.instances.slice();
    const ix = ins.items(.x);
    const iy = ins.items(.y);
    for (0..s.instances.len) |i| {
        const k = NetMap.pointKey(ix[i], iy[i]);
        uf.makeSet(k, a);
        const root = uf.find(k, a);
        const nid = root_to_id.get(root) orelse continue;
        s.net_conns.append(a, .{
            .net_id = nid,
            .kind = .instance_pin,
            .ref_a = @intCast(i),
            .ref_b = 0,
        }) catch {};
    }
}
