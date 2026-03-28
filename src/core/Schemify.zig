const std = @import("std");
const Allocator = std.mem.Allocator;
const MAL = std.MultiArrayList;
const List = std.ArrayListUnmanaged;

const utility = @import("utility");
const UnionFindType = utility.UnionFind;
const Devices = @import("Devices.zig");
const HdlParser = @import("HdlParser.zig");
const log = utility;

pub const DeviceKind = Devices.DeviceKind;
pub const primitives = Devices.primitives;
pub const SpiceBackend = @import("SpiceIF.zig").Backend;
pub const NetlistMode = @import("SpiceIF.zig").NetlistMode;
pub const pdk = &Devices.global_pdk;

pub const PinDir = enum(u8) {
    input,
    output,
    inout,
    power,
    ground,

    pub fn fromStr(s: []const u8) PinDir {
        if (s.len == 0) return .inout;
        return switch (s[0]) {
            'i' => if (s.len >= 5 and s[1] == 'n' and s[2] == 'o') .inout
                else if (s.len == 2 and s[1] == 'o') .inout
                else .input,
            'o' => .output,
            'p' => .power,
            'g' => .ground,
            else => .inout,
        };
    }

    pub fn toStr(self: PinDir) []const u8 {
        return switch (self) {
            .input  => "i",
            .output => "o",
            .inout  => "io",
            .power  => "p",
            .ground => "g",
        };
    }
};

// ── DOD element structs ──────────────────────────────────────────────────── //

pub const Line   = struct { layer: u8, x0: i32, y0: i32, x1: i32, y1: i32 };
pub const Rect   = struct {
    layer: u8, x0: i32, y0: i32, x1: i32, y1: i32,
    image_data: ?[]const u8 = null,
};
pub const Circle = struct { layer: u8, cx: i32, cy: i32, radius: i32 };
pub const Arc    = struct { layer: u8, cx: i32, cy: i32, radius: i32, start_angle: i16, sweep_angle: i16 };

pub const Wire = struct {
    x0: i32, y0: i32, x1: i32, y1: i32,
    net_name: ?[]const u8 = null,
    bus: bool = false,
};

pub const Text = struct { content: []const u8, x: i32, y: i32, layer: u8 = 4, size: u8 = 10, rotation: u2 = 0 };
pub const Pin  = struct { name: []const u8, x: i32, y: i32, dir: PinDir = .inout, num: ?u16 = null, width: u16 = 1 };

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
    spice_line: ?[]const u8 = null,
};

pub const Prop = struct { key: []const u8, val: []const u8 };
pub const Conn = struct { pin: []const u8, net: []const u8 };
pub const Net  = struct { name: []const u8 };

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
            .instance_pin  => "ip",
            .wire_endpoint => "we",
            .label         => "lb",
        };
    }

    pub fn fromTag(s: []const u8) ConnKind {
        return tag_table.get(s) orelse .label;
    }
};

pub const NetConn = struct {
    net_id:       u32,
    kind:         ConnKind,
    ref_a:        i32,
    ref_b:        i32,
    pin_or_label: ?[]const u8 = null,
};

pub const NetMap = struct {
    root_to_name:  std.AutoHashMapUnmanaged(u64, []const u8),
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

pub const SifyType = enum(u2) { primitive, component, testbench };

pub const SymDataPin = struct {
    name: []const u8,
    x: i32,
    y: i32,
    props: []const Prop = &.{},
};

pub const PinRef = struct {
    name: []const u8,
    dir: PinDir = .inout,
    x: i32 = 0,
    y: i32 = 0,
    propag: bool = true,
};

pub const SymData = struct {
    pins: []const PinRef = &.{},
    props: []const Prop = &.{},
    format: ?[]const u8 = null,
    lvs_format: ?[]const u8 = null,
    template: ?[]const u8 = null,
};

pub const SourceMode = enum { @"inline", file };

pub const HdlLanguage = enum {
    verilog,
    vhdl,
    xspice,
    xyce_digital,

    pub fn fromStr(s: []const u8) ?HdlLanguage {
        if (std.mem.eql(u8, s, "verilog")) return .verilog;
        if (std.mem.eql(u8, s, "vhdl")) return .vhdl;
        if (std.mem.eql(u8, s, "xspice")) return .xspice;
        if (std.mem.eql(u8, s, "xyce_digital")) return .xyce_digital;
        return null;
    }

    pub fn toStr(self: HdlLanguage) []const u8 {
        return switch (self) {
            .verilog => "verilog",
            .vhdl => "vhdl",
            .xspice => "xspice",
            .xyce_digital => "xyce_digital",
        };
    }
};

pub const BehavioralModel = struct {
    source: ?[]const u8 = null,
    mode: SourceMode = .file,
    top_module: ?[]const u8 = null,
};

pub const SynthesizedModel = struct {
    source: ?[]const u8 = null,
    mode: SourceMode = .file,
    liberty: ?[]const u8 = null,
    mapping: ?[]const u8 = null,
    supply_map: List(Prop) = .{},
};

pub const DigitalConfig = struct {
    language: HdlLanguage = .verilog,
    behavioral: BehavioralModel = .{},
    synthesized: SynthesizedModel = .{},
};

fn isAutoNetName(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "net") and name.len > 3 and std.ascii.isDigit(name[3]);
}

fn isZeroNetName(name: []const u8) bool {
    return std.mem.eql(u8, name, "0");
}

/// Naming priority used when multiple labels map to the same resolved root.
/// Higher rank wins. Keeps labels deterministic while avoiding accidental
/// collapse to "0" when a stronger semantic net label exists.
fn netNameRank(name: []const u8) u8 {
    if (name.len == 0) return 0;
    if (isAutoNetName(name)) return 1;
    if (isZeroNetName(name)) return 2;
    return 3;
}

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
    sym_data: List(SymData) = .{},
    globals: List([]const u8) = .{},

    verilog_body: ?[]const u8 = null,
    spice_body:   ?[]const u8 = null,
    /// When set, contains the SPICE definition for this symbol (e.g., ".include foo.cir").
    /// Used instead of inline subcircuit expansion during hierarchy resolution.
    spice_sym_def: ?[]const u8 = null,
    /// Inline subckt definitions to emit after .ends (populated by renderInlineSubckts).
    /// Not serialized; computed at netlist-emission time.
    inline_spice: ?[]const u8 = null,
    /// When true, emitSpice skips code blocks that have only_toplevel=true
    /// (the default for code.sym). Set by resolveHierarchy when emitting
    /// inline subcircuit definitions.
    skip_toplevel_code: bool = false,
    stype: SifyType = .component,
    digital: ?DigitalConfig = null,

    arena: std.heap.ArenaAllocator,
    logger: ?*log.Logger = null,

    // ── Lifecycle ────────────────────────────────────────────────────────── //

    pub fn init(backing: Allocator) Schemify {
        return .{ .arena = std.heap.ArenaAllocator.init(backing) };
    }

    pub fn deinit(self: *Schemify) void {
        self.arena.deinit();
    }

    pub fn alloc(self: *Schemify) Allocator {
        return self.arena.allocator();
    }

    // ── Delegation to Reader / Writer / Netlist ──────────────────────────── //

    pub fn readFile(data: []const u8, backing: Allocator, logger: ?*log.Logger) Schemify {
        return @import("Reader.zig").Reader.readCHN(data, backing, logger);
    }

    pub fn writeFile(self: *Schemify, a: Allocator, logger: ?*log.Logger) ?[]u8 {
        return @import("Writer.zig").Writer.writeCHN(a, self, logger);
    }

    pub fn emitSpice(
        self: *const Schemify,
        gpa: Allocator,
        backend: @import("SpiceIF.zig").Backend,
        pdk_: ?*const Devices.Pdk,
        mode: @import("SpiceIF.zig").NetlistMode,
    ) ![]u8 {
        return @import("Netlist.zig").Netlist.emitSpice(self, gpa, backend, pdk_, mode);
    }

    // ── Net resolution ───────────────────────────────────────────────────── //

    fn applyRotFlip(px: i32, py: i32, rot: u2, flip: bool, ox: i32, oy: i32) struct { x: i32, y: i32 } {
        const fx: i32 = if (flip) -px else px;
        const fy: i32 = py;
        return .{
            .x = ox + switch (rot) {
                0 => fx,
                1 => -fy,
                2 => -fx,
                3 => fy,
            },
            .y = oy + switch (rot) {
                0 => fy,
                1 => fx,
                2 => -fy,
                3 => -fx,
            },
        };
    }

    /// Try to unite a point (px, py) with any wire it touches (within tolerance=2).
    fn unitePointWithWire(uf: *UnionFindType, px: i32, py: i32, k: u64, wx0: []const i32, wy0: []const i32, wx1: []const i32, wy1: []const i32, wire_count: usize) void {
        const tolerance = 2;
        for (0..wire_count) |wi| {
            const on_wire = blk: {
                if (wy0[wi] == wy1[wi] and @abs(wy0[wi] - py) <= tolerance) {
                    break :blk px >= @min(wx0[wi], wx1[wi]) - tolerance and px <= @max(wx0[wi], wx1[wi]) + tolerance;
                } else if (wx0[wi] == wx1[wi] and @abs(wx0[wi] - px) <= tolerance) {
                    break :blk py >= @min(wy0[wi], wy1[wi]) - tolerance and py <= @max(wy0[wi], wy1[wi]) + tolerance;
                }
                break :blk false;
            };
            if (on_wire) {
                uf.unite(NetMap.pointKey(wx0[wi], wy0[wi]), k);
                break;
            }
        }
    }

    pub fn resolveNets(self: *Schemify) void {
        self.nets.items.len = 0;
        self.net_conns.items.len = 0;
        self.conns.items.len = 0;
        // Zero stale conn indices from a previous parse — conns was just cleared
        // so the old conn_start/conn_count values would be out-of-bounds.
        @memset(self.instances.items(.conn_start), 0);
        @memset(self.instances.items(.conn_count), 0);
        if (self.wires.len == 0 and self.instances.len == 0) return;
        const a = self.alloc();

        var uf = UnionFindType{ .a = a };

        const wx0 = self.wires.items(.x0);
        const wy0 = self.wires.items(.y0);
        const wx1 = self.wires.items(.x1);
        const wy1 = self.wires.items(.y1);
        for (0..self.wires.len) |i| {
            const k0 = NetMap.pointKey(wx0[i], wy0[i]);
            const k1 = NetMap.pointKey(wx1[i], wy1[i]);
            uf.makeSet(k0);
            uf.makeSet(k1);
            uf.unite(k0, k1);
        }

        // T-junctions: wire endpoint landing on the interior of another wire.
        {
            const wbus = self.wires.items(.bus);
            for (0..self.wires.len) |i| {
                for ([2]struct { x: i32, y: i32 }{
                    .{ .x = wx0[i], .y = wy0[i] },
                    .{ .x = wx1[i], .y = wy1[i] },
                }) |pt| {
                    const kp = NetMap.pointKey(pt.x, pt.y);
                    for (0..self.wires.len) |j| {
                        if (j == i) continue;
                        if (wbus[j]) continue;
                        const on_interior = blk: {
                            if (wy0[j] == wy1[j] and pt.y == wy0[j]) {
                                const lo = @min(wx0[j], wx1[j]);
                                const hi = @max(wx0[j], wx1[j]);
                                break :blk lo < pt.x and pt.x < hi;
                            } else if (wx0[j] == wx1[j] and pt.x == wx0[j]) {
                                const lo = @min(wy0[j], wy1[j]);
                                const hi = @max(wy0[j], wy1[j]);
                                break :blk lo < pt.y and pt.y < hi;
                            } else break :blk false;
                        };
                        if (on_interior) uf.unite(kp, NetMap.pointKey(wx0[j], wy0[j]));
                    }
                }
            }
        }

        // Per-pin union-find registration from sym_data.
        if (self.sym_data.items.len > 0) {
            const ix_p = self.instances.items(.x);
            const iy_p = self.instances.items(.y);
            const irot_p = self.instances.items(.rot);
            const iflip_p = self.instances.items(.flip);
            const ikind_p = self.instances.items(.kind);
            for (0..self.instances.len) |i| {
                const kind_p = ikind_p[i];
                // Plain probe instances (spice_probe.sym) have their single pin at
                // origin (0,0), so use the instance origin as the connection point.
                // Differential probe instances (spice_probe_vdiff.sym) have two pins
                // at non-zero offsets (p at y=-20, m at y=+20) and must use the
                // sym_data pin positions instead — fall through to the sym_data path.
                if (kind_p == .probe) {
                    const k = NetMap.pointKey(ix_p[i], iy_p[i]);
                    uf.makeSet(k);
                    unitePointWithWire(&uf, ix_p[i], iy_p[i], k, wx0, wy0, wx1, wy1, self.wires.len);
                    continue;
                }
                if (kind_p.isNonElectrical() and kind_p != .probe_diff) continue;
                if (i >= self.sym_data.items.len) continue;
                const sd = self.sym_data.items[i];
                for (sd.pins) |pin| {
                    const abs = applyRotFlip(pin.x, pin.y, irot_p[i], iflip_p[i], ix_p[i], iy_p[i]);
                    const k = NetMap.pointKey(abs.x, abs.y);
                    uf.makeSet(k);
                    unitePointWithWire(&uf, abs.x, abs.y, k, wx0, wy0, wx1, wy1, self.wires.len);
                }
                // Same-name pin unification (doublepin/bidirectional symbols).
                var first_key_for_pin = std.StringHashMapUnmanaged(u64){};
                defer first_key_for_pin.deinit(a);
                for (sd.pins) |pin| {
                    const abs = applyRotFlip(pin.x, pin.y, irot_p[i], iflip_p[i], ix_p[i], iy_p[i]);
                    const k = NetMap.pointKey(abs.x, abs.y);
                    if (first_key_for_pin.get(pin.name)) |fk| {
                        uf.unite(fk, k);
                    } else {
                        first_key_for_pin.put(a, pin.name, k) catch {};
                    }
                }
            }
        }

        const RootName = struct { root: u64, name: []const u8 };
        var root_names = List(RootName){};

        const rnFind = struct {
            fn find(items: []const RootName, root: u64) ?usize {
                var lo: usize = 0;
                var hi: usize = items.len;
                while (lo < hi) {
                    const mid = lo + (hi - lo) / 2;
                    if (items[mid].root < root) lo = mid + 1 else hi = mid;
                }
                return if (lo < items.len and items[lo].root == root) lo else null;
            }
            fn insert(items: *List(RootName), alloc_: Allocator, root: u64, name: []const u8) void {
                var lo: usize = 0;
                var hi: usize = items.items.len;
                while (lo < hi) {
                    const mid = lo + (hi - lo) / 2;
                    if (items.items[mid].root < root) lo = mid + 1 else hi = mid;
                }
                items.insert(alloc_, lo, .{ .root = root, .name = name }) catch {};
            }
        };

        {
            const wnn = self.wires.items(.net_name);
            for (0..self.wires.len) |i| {
                const name = wnn[i] orelse continue;
                const k = NetMap.pointKey(wx0[i], wy0[i]);
                uf.makeSet(k);
                const root = uf.find(k);
                if (rnFind.find(root_names.items, root)) |pos| {
                    const prev = root_names.items[pos].name;
                    const prev_rank = netNameRank(prev);
                    const new_rank = netNameRank(name);
                    const take_new = new_rank > prev_rank;
                    if (take_new) root_names.items[pos].name = name;
                } else {
                    rnFind.insert(&root_names, a, root, name);
                }
            }

            // Disambiguation: when multiple disjoint union-find groups share
            // the same non-auto net name, SPICE would treat them as a single net.
            //
            // In XSchem, label instances (lab_pin, lab_wire, etc.) with the same
            // `lab` create implicit connections — all are on the same net.  Wire
            // display annotations ({lab=...} on N-lines) do NOT create such
            // connections; they're merely display hints.
            //
            // Strategy:
            // - For each name that appears on multiple roots, collect which roots
            //   have a label instance (zero-length wire) backing the name.
            // - Strip the name from roots that lack label instances (those roots
            //   got the name from wire display annotations, not real labels).
            // - Do NOT unite roots — that would change physical topology.
            //
            // 1. Detect names that appear on multiple roots.
            const NameInfo = struct { count: u32, label_count: u32 };
            var name_info = std.StringHashMapUnmanaged(NameInfo){};
            defer name_info.deinit(a);
            for (root_names.items) |rn| {
                if (isAutoNetName(rn.name)) continue;
                const gop = name_info.getOrPut(a, rn.name) catch continue;
                if (!gop.found_existing) gop.value_ptr.* = .{ .count = 0, .label_count = 0 };
                gop.value_ptr.count += 1;
            }
            // 2. Count label instances per conflicted name.
            var label_roots = std.StringHashMapUnmanaged(std.ArrayListUnmanaged(u64)){};
            defer {
                var lr_it = label_roots.iterator();
                while (lr_it.next()) |entry| entry.value_ptr.deinit(a);
                label_roots.deinit(a);
            }
            {
                var ni_it = name_info.iterator();
                while (ni_it.next()) |entry| {
                    if (entry.value_ptr.count <= 1) continue;
                    const cname = entry.key_ptr.*;
                    var roots_list = std.ArrayListUnmanaged(u64){};
                    for (0..self.wires.len) |i| {
                        const wn = wnn[i] orelse continue;
                        if (!std.mem.eql(u8, wn, cname)) continue;
                        if (wx0[i] == wx1[i] and wy0[i] == wy1[i]) {
                            const k = NetMap.pointKey(wx0[i], wy0[i]);
                            const root = uf.find(k);
                            // Avoid duplicates
                            var found = false;
                            for (roots_list.items) |r| if (r == root) { found = true; break; };
                            if (!found) roots_list.append(a, root) catch {};
                        }
                    }
                    entry.value_ptr.label_count = @intCast(roots_list.items.len);
                    label_roots.put(a, cname, roots_list) catch {};
                }
            }
            // 3. For each conflicted name where at least one root has a label
            //    instance: strip the name from roots that lack label instances.
            //    Do NOT unite roots — that would change physical topology.
            {
                var lr_it = label_roots.iterator();
                while (lr_it.next()) |entry| {
                    const cname = entry.key_ptr.*;
                    const lroots = entry.value_ptr.items;
                    // Only strip if there are label-instance roots (wire-only
                    // roots borrowed the name from display annotations).
                    if (lroots.len > 0) {
                        var remove_indices = std.ArrayListUnmanaged(usize){};
                        defer remove_indices.deinit(a);
                        for (root_names.items, 0..) |rn, ri| {
                            if (!std.mem.eql(u8, rn.name, cname)) continue;
                            var is_label = false;
                            for (lroots) |lr| if (rn.root == lr) { is_label = true; break; };
                            if (!is_label) {
                                remove_indices.append(a, ri) catch {};
                            }
                        }
                        var ri_idx: usize = remove_indices.items.len;
                        while (ri_idx > 0) {
                            ri_idx -= 1;
                            _ = root_names.orderedRemove(remove_indices.items[ri_idx]);
                        }
                    }
                }
            }
        }

        {
            // Determine the starting index for auto-generated net names.
            // We must skip any net\d+ numbers already claimed by named wires
            // (e.g. from XSchem's #net1, #net2, ... wire labels which are stored
            // as "net1", "net2", ... after stripping the '#' prefix).
            // Not skipping causes two different nets to share the same name.
            var max_named_auto: u32 = 0;
            for (root_names.items) |rn| {
                if (isAutoNetName(rn.name)) {
                    const digits = rn.name[3..];
                    const n = std.fmt.parseInt(u32, digits, 10) catch continue;
                    if (n > max_named_auto) max_named_auto = n;
                }
            }
            var auto_idx: u32 = max_named_auto + 1;

            // Build a set of already-used auto-net names for O(1) skip checks.
            var used_auto = std.StringHashMapUnmanaged(void){};
            defer used_auto.deinit(a);
            for (root_names.items) |rn| {
                if (isAutoNetName(rn.name)) used_auto.put(a, rn.name, {}) catch {};
            }

            const nextAutoIdx = struct {
                fn next(idx: *u32, used: *std.StringHashMapUnmanaged(void), a2: std.mem.Allocator) u32 {
                    while (true) {
                        const candidate = std.fmt.allocPrint(a2, "net{d}", .{idx.*}) catch {
                            idx.* += 1;
                            continue;
                        };
                        if (used.contains(candidate)) {
                            a2.free(candidate);
                            idx.* += 1;
                            continue;
                        }
                        a2.free(candidate);
                        const result = idx.*;
                        idx.* += 1;
                        return result;
                    }
                }
            }.next;

            // 1. Wires
            for (0..self.wires.len) |i| {
                for ([2]u64{ NetMap.pointKey(wx0[i], wy0[i]), NetMap.pointKey(wx1[i], wy1[i]) }) |k| {
                    const root = uf.find(k);
                    if (rnFind.find(root_names.items, root) != null) continue;
                    const n = nextAutoIdx(&auto_idx, &used_auto, a);
                    const nm = std.fmt.allocPrint(a, "net{d}", .{n}) catch continue;
                    used_auto.put(a, nm, {}) catch {};
                    rnFind.insert(&root_names, a, root, nm);
                }
            }
            // 2. Pins (for nets that are pin-to-pin only)
            if (self.sym_data.items.len > 0) {
                const ix_p = self.instances.items(.x);
                const iy_p = self.instances.items(.y);
                const irot_p = self.instances.items(.rot);
                const iflip_p = self.instances.items(.flip);
                const ikind_p = self.instances.items(.kind);
                for (0..self.instances.len) |i| {
                    if (ikind_p[i].isNonElectrical()) continue;
                    if (i >= self.sym_data.items.len) continue;
                    const sd = self.sym_data.items[i];
                    for (sd.pins) |pin| {
                        const abs = applyRotFlip(pin.x, pin.y, irot_p[i], iflip_p[i], ix_p[i], iy_p[i]);
                        const k = NetMap.pointKey(abs.x, abs.y);
                        const root = uf.find(k);
                        if (rnFind.find(root_names.items, root) != null) continue;
                        const n = nextAutoIdx(&auto_idx, &used_auto, a);
                        const nm = std.fmt.allocPrint(a, "net{d}", .{n}) catch continue;
                        used_auto.put(a, nm, {}) catch {};
                        rnFind.insert(&root_names, a, root, nm);
                    }
                }
            }
        }

        var root_to_id = std.AutoHashMapUnmanaged(u64, u32){};
        for (root_names.items) |rn| {
            const id: u32 = @intCast(self.nets.items.len);
            self.nets.append(a, .{ .name = rn.name }) catch continue;
            root_to_id.put(a, rn.root, id) catch {};
        }

        for (0..self.wires.len) |i| {
            for ([2][2]i32{ .{ wx0[i], wy0[i] }, .{ wx1[i], wy1[i] } }) |ep| {
                const root = uf.find(NetMap.pointKey(ep[0], ep[1]));
                const nid = root_to_id.get(root) orelse continue;
                self.net_conns.append(a, .{ .net_id = nid, .kind = .wire_endpoint, .ref_a = ep[0], .ref_b = ep[1] }) catch {};
            }
        }

        // Build conns from sym_data pin positions; fallback to origin for instances without sym_data.
        {
            const ix = self.instances.items(.x);
            const iy = self.instances.items(.y);
            const irot = self.instances.items(.rot);
            const iflip = self.instances.items(.flip);
            const ikind2 = self.instances.items(.kind);
            var ics = self.instances.items(.conn_start);
            var icc = self.instances.items(.conn_count);
            for (0..self.instances.len) |i| {
                // Plain probe instances (spice_probe.sym) have their single pin at
                // origin.  Build a synthetic conn entry for pin "p".
                // Differential probes (spice_probe_vdiff.sym) have pins at non-zero
                // offsets and use the sym_data path below instead.
                if (ikind2[i] == .probe) {
                    const k = NetMap.pointKey(ix[i], iy[i]);
                    uf.makeSet(k);
                    const root = uf.find(k);
                    const nid = root_to_id.get(root) orelse continue;
                    const net_name: []const u8 = if (nid < self.nets.items.len)
                        self.nets.items[nid].name
                    else
                        "?";
                    ics[i] = @intCast(self.conns.items.len);
                    self.conns.append(a, .{
                        .pin = "p",
                        .net = net_name,
                    }) catch {};
                    icc[i] = @intCast(self.conns.items.len - ics[i]);
                    self.net_conns.append(a, .{ .net_id = nid, .kind = .instance_pin, .ref_a = ix[i], .ref_b = iy[i] }) catch {};
                    continue;
                }
                if (i < self.sym_data.items.len and self.sym_data.items[i].pins.len > 0) {
                    const sd = self.sym_data.items[i];
                    ics[i] = @intCast(self.conns.items.len);
                    for (sd.pins) |pin| {
                        const abs = applyRotFlip(pin.x, pin.y, irot[i], iflip[i], ix[i], iy[i]);
                        const k = NetMap.pointKey(abs.x, abs.y);
                        uf.makeSet(k);
                        const root = uf.find(k);
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
                            self.net_conns.append(a, .{ .net_id = id, .kind = .instance_pin, .ref_a = abs.x, .ref_b = abs.y }) catch {};
                    }
                    icc[i] = @intCast(self.conns.items.len - ics[i]);
                } else {
                    const k = NetMap.pointKey(ix[i], iy[i]);
                    uf.makeSet(k);
                    const root = uf.find(k);
                    const nid = root_to_id.get(root) orelse continue;
                    self.net_conns.append(a, .{ .net_id = nid, .kind = .instance_pin, .ref_a = @intCast(i), .ref_b = 0 }) catch {};
                }
            }
        }
    }

    // ── Builder: Geometry Primitives ─────────────────────────────────────── //

    pub fn drawLine(self: *Schemify, line: Line) !void {
        try self.lines.append(self.alloc(), line);
    }

    pub fn drawRect(self: *Schemify, rect: Rect) !void {
        try self.rects.append(self.alloc(), rect);
    }

    pub fn drawCircle(self: *Schemify, circle: Circle) !void {
        try self.circles.append(self.alloc(), circle);
    }

    pub fn drawArc(self: *Schemify, arc: Arc) !void {
        try self.arcs.append(self.alloc(), arc);
    }

    pub fn drawText(self: *Schemify, text: Text) !void {
        const a = self.alloc();
        try self.texts.append(a, .{
            .content = try a.dupe(u8, text.content),
            .x = text.x,
            .y = text.y,
            .layer = text.layer,
            .size = text.size,
            .rotation = text.rotation,
        });
    }

    pub fn drawPin(self: *Schemify, pin: Pin) !void {
        const a = self.alloc();
        try self.pins.append(a, .{
            .name = try a.dupe(u8, pin.name),
            .x = pin.x,
            .y = pin.y,
            .dir = pin.dir,
            .num = pin.num,
            .width = pin.width,
        });
    }

    pub fn addWire(self: *Schemify, wire: Wire) !void {
        const a = self.alloc();
        try self.wires.append(a, .{
            .x0 = wire.x0,
            .y0 = wire.y0,
            .x1 = wire.x1,
            .y1 = wire.y1,
            .net_name = if (wire.net_name) |n| try a.dupe(u8, n) else null,
            .bus = wire.bus,
        });
    }

    // ── Builder: Component Insertion ─────────────────────────────────────── //

    pub const ComponentDesc = struct {
        name: []const u8,
        symbol: []const u8,
        kind: DeviceKind = .unknown,
        x: i32,
        y: i32,
        rot: u2 = 0,
        flip: bool = false,
        props: []const Prop = &.{},
        conns: []const Conn = &.{},
        spice_line: ?[]const u8 = null,
        sym_data: ?SymData = null,
    };

    pub fn addComponent(self: *Schemify, desc: ComponentDesc) !u32 {
        const a = self.alloc();
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
        const idx: u32 = @intCast(self.instances.len);
        try self.instances.append(a, .{
            .name = try a.dupe(u8, desc.name),
            .symbol = try a.dupe(u8, desc.symbol),
            .kind = desc.kind,
            .x = desc.x,
            .y = desc.y,
            .rot = desc.rot,
            .flip = desc.flip,
            .prop_start = prop_start,
            .prop_count = @intCast(desc.props.len),
            .conn_start = conn_start,
            .conn_count = @intCast(desc.conns.len),
            .spice_line = if (desc.spice_line) |s| try a.dupe(u8, s) else null,
        });
        // Keep sym_data parallel with instances — always append an entry.
        if (desc.sym_data) |sd| {
            try self.appendSymData(sd);
        } else {
            try self.sym_data.append(a, .{});
        }
        return idx;
    }

    // ── Builder: Metadata ──────────────────────────────────────────────── //

    pub fn setName(self: *Schemify, name: []const u8) void {
        self.name = self.alloc().dupe(u8, name) catch name;
    }

    pub fn setStype(self: *Schemify, stype: SifyType) void {
        self.stype = stype;
    }

    pub fn addSymProp(self: *Schemify, key: []const u8, val: []const u8) !void {
        const a = self.alloc();
        try self.sym_props.append(a, .{
            .key = try a.dupe(u8, key),
            .val = try a.dupe(u8, val),
        });
    }

    pub fn appendSymData(self: *Schemify, data: SymData) !void {
        const a = self.alloc();
        // Dupe pins with their names into the arena.
        var duped_pins = try a.alloc(PinRef, data.pins.len);
        for (data.pins, 0..) |pin, i| {
            duped_pins[i] = .{
                .name = try a.dupe(u8, pin.name),
                .dir = pin.dir,
                .x = pin.x,
                .y = pin.y,
                .propag = pin.propag,
            };
        }
        // Dupe props into the arena.
        var duped_props = try a.alloc(Prop, data.props.len);
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

    pub fn clearPins(self: *Schemify) void {
        self.pins = .{};
    }

    pub fn addGlobal(self: *Schemify, name: []const u8) !void {
        const a = self.alloc();
        for (self.globals.items) |existing| {
            if (std.mem.eql(u8, existing, name)) return;
        }
        try self.globals.append(a, try a.dupe(u8, name));
    }

    // ── Validation ────────────────────────────────────────────────────── //

    pub const DiagLevel = enum { @"error", warning, info };

    pub const Diagnostic = struct {
        level: DiagLevel,
        code: []const u8, // e.g. "hdl_pin_mismatch"
        message: []const u8, // human-readable description
    };

    /// Validate the digital configuration of this Schemify.
    /// Returns a slice of diagnostics allocated on the arena.
    /// If there is no digital section, returns an empty slice.
    pub fn validateDigital(self: *Schemify) []const Diagnostic {
        const digital = self.digital orelse return &.{};
        const a = self.alloc();

        var diags = List(Diagnostic){};

        // no_behavioral_source: digital section present but no behavioral model
        if (digital.behavioral.source == null) {
            diags.append(a, .{
                .level = .@"error",
                .code = "no_behavioral_source",
                .message = "digital section present but no behavioral model source specified",
            }) catch {};
        }

        // no_synthesized_source: component with digital but no synth model
        if (self.stype == .component and digital.synthesized.source == null) {
            diags.append(a, .{
                .level = .warning,
                .code = "no_synthesized_source",
                .message = "digital block in component has no synthesized model source; layout mode will fail",
            }) catch {};
        }

        // hdl_pin_mismatch: compare inline HDL ports against symbol pins
        if (digital.behavioral.source) |source| {
            if (digital.behavioral.mode == .@"inline") {
                const lang = digital.language;
                if (lang == .verilog or lang == .vhdl) {
                    const parse_result = if (lang == .verilog)
                        HdlParser.parseVerilog(source, digital.behavioral.top_module, a)
                    else
                        HdlParser.parseVhdl(source, digital.behavioral.top_module, a);

                    if (parse_result) |hdl_mod| {
                        const pin_names = self.pins.items(.name);
                        const pin_count = self.pins.len;
                        const hdl_pins = hdl_mod.pins;

                        // Check for count mismatch
                        if (hdl_pins.len != pin_count) {
                            const msg = std.fmt.allocPrint(a,
                                "symbol has {d} pin(s) but HDL source declares {d} port(s)",
                                .{ pin_count, hdl_pins.len },
                            ) catch "pin count mismatch between symbol and HDL source";
                            diags.append(a, .{
                                .level = .warning,
                                .code = "hdl_pin_mismatch",
                                .message = msg,
                            }) catch {};
                        } else {
                            // Same count — check for name mismatches
                            for (hdl_pins) |hp| {
                                var found = false;
                                for (pin_names[0..pin_count]) |sn| {
                                    if (std.mem.eql(u8, sn, hp.name)) {
                                        found = true;
                                        break;
                                    }
                                }
                                if (!found) {
                                    const msg = std.fmt.allocPrint(a,
                                        "HDL port '{s}' not found in symbol pins",
                                        .{hp.name},
                                    ) catch "HDL port not found in symbol pins";
                                    diags.append(a, .{
                                        .level = .warning,
                                        .code = "hdl_pin_mismatch",
                                        .message = msg,
                                    }) catch {};
                                }
                            }
                        }
                    } else |_| {
                        // Parse failed — emit a diagnostic about it
                        diags.append(a, .{
                            .level = .warning,
                            .code = "hdl_pin_mismatch",
                            .message = "could not parse inline HDL source to verify pin match",
                        }) catch {};
                    }
                }
            }
            // file mode: skip — validation should be cheap, avoid file I/O
        }

        return diags.items;
    }

    /// Validate bus pin widths between an instantiation and the symbol definition.
    /// `instance_conns` are the connections for this instance.
    /// `instance_symbol` is the Schemify describing the instantiated symbol.
    /// Returns a slice of diagnostics allocated on this Schemify's arena.
    pub fn validateBusPinWidths(
        self: *Schemify,
        instance_conns: []const Conn,
        instance_symbol: *const Schemify,
    ) []const Diagnostic {
        // Only relevant if the instantiated symbol has a digital section
        if (instance_symbol.digital == null) return &.{};
        const a = self.alloc();

        var diags = List(Diagnostic){};

        const sym_pin_names = instance_symbol.pins.items(.name);
        const sym_pin_widths = instance_symbol.pins.items(.width);
        const sym_pin_count = instance_symbol.pins.len;

        for (0..sym_pin_count) |pi| {
            const expected_width = sym_pin_widths[pi];
            if (expected_width <= 1) continue; // scalar pin — skip

            const sym_pin_name = sym_pin_names[pi];

            // Find the matching connection in instance_conns
            for (instance_conns) |conn| {
                if (!std.mem.eql(u8, conn.pin, sym_pin_name)) continue;

                // Infer effective width from the net name.
                // Bus nets use bracket notation: "data[7:0]" or "addr[15:0]".
                const eff_width = inferNetWidth(conn.net);
                if (eff_width != 0 and eff_width != expected_width) {
                    const msg = std.fmt.allocPrint(a,
                        "bus pin '{s}' expects width {d} but connected net '{s}' has effective width {d}",
                        .{ sym_pin_name, expected_width, conn.net, eff_width },
                    ) catch "bus pin width mismatch";
                    diags.append(a, .{
                        .level = .warning,
                        .code = "bus_pin_width_mismatch",
                        .message = msg,
                    }) catch {};
                }
                break;
            }
        }

        return diags.items;
    }

    /// Infer the effective width of a net from its name.
    /// Returns 0 if the width cannot be determined (scalar or unknown format).
    /// Recognizes bracket notation: "name[H:L]" -> H - L + 1
    fn inferNetWidth(net: []const u8) u16 {
        // Look for "[H:L]" suffix
        const lbracket = std.mem.lastIndexOfScalar(u8, net, '[') orelse return 0;
        const rbracket = std.mem.lastIndexOfScalar(u8, net, ']') orelse return 0;
        if (rbracket <= lbracket) return 0;
        const inside = net[lbracket + 1 .. rbracket];
        const colon = std.mem.indexOfScalar(u8, inside, ':') orelse return 0;
        const hi_str = std.mem.trim(u8, inside[0..colon], " ");
        const lo_str = std.mem.trim(u8, inside[colon + 1 ..], " ");
        const hi = std.fmt.parseInt(i32, hi_str, 10) catch return 0;
        const lo = std.fmt.parseInt(i32, lo_str, 10) catch return 0;
        const diff = if (hi >= lo) hi - lo + 1 else lo - hi + 1;
        return if (diff > 0 and diff <= std.math.maxInt(u16)) @intCast(diff) else 0;
    }

    /// Merge all geometry (lines, rects, arcs, circles, pins) from `src` into
    /// this Schemify. Strings are duped into the receiver's arena.
    pub fn mergeSymbolGeometry(self: *Schemify, src: *const Schemify) !void {
        const a = self.alloc();
        for (0..src.lines.len) |i| try self.lines.append(a, src.lines.get(i));
        for (0..src.rects.len) |i| try self.rects.append(a, src.rects.get(i));
        for (0..src.arcs.len) |i| try self.arcs.append(a, src.arcs.get(i));
        for (0..src.circles.len) |i| try self.circles.append(a, src.circles.get(i));
        self.pins = .{};
        for (0..src.pins.len) |i| {
            const p = src.pins.get(i);
            try self.pins.append(a, .{
                .name = try a.dupe(u8, p.name),
                .x = p.x,
                .y = p.y,
                .dir = p.dir,
                .num = p.num,
                .width = p.width,
            });
        }
    }

    // ── HDL Symbol Sync ───────────────────────────────────────────────── //

    pub const PinChange = struct {
        name: []const u8,
        change: []const u8, // e.g. "width 4 -> 8", "direction in -> out"
    };

    pub const SyncReport = struct {
        pins_added: []const HdlParser.HdlPin,
        pins_removed: []const []const u8,
        pins_modified: []const PinChange,
        symbol_updated: bool,
    };

    pub const HdlMismatch = struct {
        pin_name: []const u8,
        issue: []const u8, // "missing in HDL", "missing in symbol", "width mismatch", "direction mismatch"
    };

    const SyncError = error{
        NoDigitalConfig,
        NoBehavioralSource,
        UnsupportedLanguage,
        HdlParseError,
        FileReadError,
        OutOfMemory,
    };

    /// Reads the HDL source from the digital config, parses ports, diffs
    /// against current pins, and updates pins to match.
    pub fn syncSymbolFromHdl(self: *Schemify) SyncError!SyncReport {
        const a = self.alloc();
        const hdl_mod = try self.parseHdlSource();

        // Build lookup of existing pins by name.
        const pin_names = self.pins.items(.name);
        const pin_dirs = self.pins.items(.dir);
        const pin_widths = self.pins.items(.width);

        var existing_map = std.StringHashMapUnmanaged(usize){};
        existing_map.ensureTotalCapacity(a, @intCast(self.pins.len)) catch return error.OutOfMemory;
        for (0..self.pins.len) |i| {
            existing_map.put(a, pin_names[i], i) catch return error.OutOfMemory;
        }

        // Track which existing pins are matched.
        var matched = a.alloc(bool, self.pins.len) catch return error.OutOfMemory;
        @memset(matched, false);

        var added = std.ArrayListUnmanaged(HdlParser.HdlPin){};
        var modified = std.ArrayListUnmanaged(PinChange){};

        // Diff HDL pins against existing.
        for (hdl_mod.pins) |hp| {
            const sym_dir = hdlDirToSymDir(hp.direction);
            if (existing_map.get(hp.name)) |idx| {
                matched[idx] = true;
                // Check for width changes.
                if (pin_widths[idx] != hp.width) {
                    const desc = std.fmt.allocPrint(a, "width {d} -> {d}", .{ pin_widths[idx], hp.width }) catch return error.OutOfMemory;
                    modified.append(a, .{
                        .name = a.dupe(u8, hp.name) catch return error.OutOfMemory,
                        .change = desc,
                    }) catch return error.OutOfMemory;
                    pin_widths[idx] = hp.width;
                }
                // Check for direction changes.
                if (pin_dirs[idx] != sym_dir) {
                    const desc = std.fmt.allocPrint(a, "direction {s} -> {s}", .{ pin_dirs[idx].toStr(), sym_dir.toStr() }) catch return error.OutOfMemory;
                    modified.append(a, .{
                        .name = a.dupe(u8, hp.name) catch return error.OutOfMemory,
                        .change = desc,
                    }) catch return error.OutOfMemory;
                    pin_dirs[idx] = sym_dir;
                }
            } else {
                // New pin — add it.
                added.append(a, hp) catch return error.OutOfMemory;
                self.pins.append(a, .{
                    .name = a.dupe(u8, hp.name) catch return error.OutOfMemory,
                    .x = 0,
                    .y = 0,
                    .dir = sym_dir,
                    .num = null,
                    .width = hp.width,
                }) catch return error.OutOfMemory;
            }
        }

        // Collect removed pins (in symbol but not in HDL).
        var removed = std.ArrayListUnmanaged([]const u8){};
        var remove_indices = std.ArrayListUnmanaged(usize){};
        for (0..matched.len) |i| {
            if (!matched[i]) {
                removed.append(a, a.dupe(u8, pin_names[i]) catch return error.OutOfMemory) catch return error.OutOfMemory;
                remove_indices.append(a, i) catch return error.OutOfMemory;
            }
        }
        // Remove in reverse order to keep indices valid.
        var ri: usize = remove_indices.items.len;
        while (ri > 0) {
            ri -= 1;
            self.pins.swapRemove(remove_indices.items[ri]);
        }

        const updated = added.items.len > 0 or removed.items.len > 0 or modified.items.len > 0;

        return SyncReport{
            .pins_added = added.items,
            .pins_removed = removed.items,
            .pins_modified = modified.items,
            .symbol_updated = updated,
        };
    }

    /// Auto-generates drawing geometry (lines, rects, texts) for a digital
    /// block based on its current pin list. Clears existing drawing data first.
    pub fn generateDigitalSymbolDrawing(self: *Schemify) !void {
        const a = self.alloc();

        // Clear existing drawing geometry.
        self.lines = .{};
        self.rects = .{};
        self.texts = .{};

        if (self.pins.len == 0) return;

        // Classify pins by direction.
        const dirs = self.pins.items(.dir);
        const names = self.pins.items(.name);
        const widths = self.pins.items(.width);

        var left_pins = std.ArrayListUnmanaged(usize){};
        var right_pins = std.ArrayListUnmanaged(usize){};

        for (0..self.pins.len) |i| {
            switch (dirs[i]) {
                .input, .power, .ground => left_pins.append(a, i) catch return error.OutOfMemory,
                .output => right_pins.append(a, i) catch return error.OutOfMemory,
                .inout => {
                    // Split inout evenly: fewer side gets the next one.
                    if (left_pins.items.len <= right_pins.items.len) {
                        left_pins.append(a, i) catch return error.OutOfMemory;
                    } else {
                        right_pins.append(a, i) catch return error.OutOfMemory;
                    }
                },
            }
        }

        const pin_spacing: i32 = 20;
        const stub_len: i32 = 10;
        const layer: u8 = 4;

        const left_count: i32 = @intCast(left_pins.items.len);
        const right_count: i32 = @intCast(right_pins.items.len);
        const max_pins: i32 = @max(left_count, right_count);

        // Box height based on max side pin count.
        const box_height: i32 = (max_pins + 1) * pin_spacing;

        // Box width: minimum 120, wider if name is long.
        const name_width: i32 = @as(i32, @intCast(self.name.len)) * 8;
        const box_width: i32 = @max(120, name_width + 40);

        const box_x0: i32 = 0;
        const box_y0: i32 = 0;
        const box_x1: i32 = box_width;
        const box_y1: i32 = box_height;

        // Draw bounding rectangle (4 lines).
        try self.lines.append(a, .{ .layer = layer, .x0 = box_x0, .y0 = box_y0, .x1 = box_x1, .y1 = box_y0 }); // top
        try self.lines.append(a, .{ .layer = layer, .x0 = box_x1, .y0 = box_y0, .x1 = box_x1, .y1 = box_y1 }); // right
        try self.lines.append(a, .{ .layer = layer, .x0 = box_x1, .y0 = box_y1, .x1 = box_x0, .y1 = box_y1 }); // bottom
        try self.lines.append(a, .{ .layer = layer, .x0 = box_x0, .y0 = box_y1, .x1 = box_x0, .y1 = box_y0 }); // left

        // Center the @name text in the box.
        const name_text = std.fmt.allocPrint(a, "@{s}", .{self.name}) catch return error.OutOfMemory;
        try self.texts.append(a, .{
            .content = name_text,
            .x = @divTrunc(box_width, 2),
            .y = @divTrunc(box_height, 2),
            .layer = layer,
            .size = 10,
            .rotation = 0,
        });

        // Place left-side pins (inputs, power, ground, some inout).
        const pin_xs = self.pins.items(.x);
        const pin_ys = self.pins.items(.y);
        for (left_pins.items, 0..) |pi, slot| {
            const py: i32 = @as(i32, @intCast(slot + 1)) * pin_spacing;
            const px: i32 = box_x0 - stub_len;

            pin_xs[pi] = px;
            pin_ys[pi] = py;

            if (isClock(names[pi])) {
                // Clock triangle marker: small triangle pointing inward at box edge.
                try self.lines.append(a, .{ .layer = layer, .x0 = box_x0, .y0 = py - 4, .x1 = box_x0 + 6, .y1 = py });
                try self.lines.append(a, .{ .layer = layer, .x0 = box_x0 + 6, .y0 = py, .x1 = box_x0, .y1 = py + 4 });
                try self.lines.append(a, .{ .layer = layer, .x0 = box_x0, .y0 = py + 4, .x1 = box_x0, .y1 = py - 4 });
                // Stub from pin to box edge.
                try self.lines.append(a, .{ .layer = layer, .x0 = px, .y0 = py, .x1 = box_x0, .y1 = py });
            } else if (widths[pi] > 1) {
                // Bus pin: 3 parallel short stubs.
                try self.lines.append(a, .{ .layer = layer, .x0 = px, .y0 = py - 2, .x1 = box_x0, .y1 = py - 2 });
                try self.lines.append(a, .{ .layer = layer, .x0 = px, .y0 = py, .x1 = box_x0, .y1 = py });
                try self.lines.append(a, .{ .layer = layer, .x0 = px, .y0 = py + 2, .x1 = box_x0, .y1 = py + 2 });
            } else {
                // Single-line stub.
                try self.lines.append(a, .{ .layer = layer, .x0 = px, .y0 = py, .x1 = box_x0, .y1 = py });
            }

            // Pin name label just inside the box.
            try self.texts.append(a, .{
                .content = a.dupe(u8, names[pi]) catch return error.OutOfMemory,
                .x = box_x0 + 4,
                .y = py,
                .layer = layer,
                .size = 8,
                .rotation = 0,
            });
        }

        // Place right-side pins (outputs, some inout).
        for (right_pins.items, 0..) |pi, slot| {
            const py: i32 = @as(i32, @intCast(slot + 1)) * pin_spacing;
            const px: i32 = box_x1 + stub_len;

            pin_xs[pi] = px;
            pin_ys[pi] = py;

            if (widths[pi] > 1) {
                // Bus pin: 3 parallel short stubs.
                try self.lines.append(a, .{ .layer = layer, .x0 = box_x1, .y0 = py - 2, .x1 = px, .y1 = py - 2 });
                try self.lines.append(a, .{ .layer = layer, .x0 = box_x1, .y0 = py, .x1 = px, .y1 = py });
                try self.lines.append(a, .{ .layer = layer, .x0 = box_x1, .y0 = py + 2, .x1 = px, .y1 = py + 2 });
            } else {
                // Single-line stub.
                try self.lines.append(a, .{ .layer = layer, .x0 = box_x1, .y0 = py, .x1 = px, .y1 = py });
            }

            // Pin name label just inside the box (right-aligned).
            try self.texts.append(a, .{
                .content = a.dupe(u8, names[pi]) catch return error.OutOfMemory,
                .x = box_x1 - 4,
                .y = py,
                .layer = layer,
                .size = 8,
                .rotation = 0,
            });
        }
    }

    /// Read-only comparison of symbol pins vs HDL source. Returns mismatches
    /// without modifying the symbol.
    pub fn validateHdlPinMatch(self: *Schemify) SyncError![]const HdlMismatch {
        const a = self.alloc();
        const hdl_mod = try self.parseHdlSource();

        var mismatches = std.ArrayListUnmanaged(HdlMismatch){};

        // Build lookup of existing symbol pins by name.
        const pin_names = self.pins.items(.name);
        const pin_dirs = self.pins.items(.dir);
        const pin_widths = self.pins.items(.width);

        var sym_map = std.StringHashMapUnmanaged(usize){};
        sym_map.ensureTotalCapacity(a, @intCast(self.pins.len)) catch return error.OutOfMemory;
        for (0..self.pins.len) |i| {
            sym_map.put(a, pin_names[i], i) catch return error.OutOfMemory;
        }

        // Track which symbol pins are seen in HDL.
        var seen = a.alloc(bool, self.pins.len) catch return error.OutOfMemory;
        @memset(seen, false);

        // Check each HDL pin against the symbol.
        for (hdl_mod.pins) |hp| {
            if (sym_map.get(hp.name)) |idx| {
                seen[idx] = true;
                const sym_dir = hdlDirToSymDir(hp.direction);
                if (pin_widths[idx] != hp.width) {
                    const desc = std.fmt.allocPrint(a, "width mismatch: symbol={d} hdl={d}", .{ pin_widths[idx], hp.width }) catch return error.OutOfMemory;
                    mismatches.append(a, .{
                        .pin_name = a.dupe(u8, hp.name) catch return error.OutOfMemory,
                        .issue = desc,
                    }) catch return error.OutOfMemory;
                }
                if (pin_dirs[idx] != sym_dir) {
                    const desc = std.fmt.allocPrint(a, "direction mismatch: symbol={s} hdl={s}", .{ pin_dirs[idx].toStr(), sym_dir.toStr() }) catch return error.OutOfMemory;
                    mismatches.append(a, .{
                        .pin_name = a.dupe(u8, hp.name) catch return error.OutOfMemory,
                        .issue = desc,
                    }) catch return error.OutOfMemory;
                }
            } else {
                mismatches.append(a, .{
                    .pin_name = a.dupe(u8, hp.name) catch return error.OutOfMemory,
                    .issue = "missing in symbol",
                }) catch return error.OutOfMemory;
            }
        }

        // Pins in symbol but not in HDL.
        for (0..self.pins.len) |i| {
            if (!seen[i]) {
                mismatches.append(a, .{
                    .pin_name = a.dupe(u8, pin_names[i]) catch return error.OutOfMemory,
                    .issue = "missing in HDL",
                }) catch return error.OutOfMemory;
            }
        }

        return mismatches.items;
    }

    // ── HDL Sync helpers ────────────────────────────────────────────────── //

    /// Parses the HDL source from the digital config, returning the module.
    fn parseHdlSource(self: *Schemify) SyncError!HdlParser.HdlModule {
        const dc = self.digital orelse return error.NoDigitalConfig;
        const raw_source = dc.behavioral.source orelse return error.NoBehavioralSource;
        const a = self.alloc();

        const source: []const u8 = switch (dc.behavioral.mode) {
            .file => utility.Vfs.readAlloc(a, raw_source) catch return error.FileReadError,
            .@"inline" => raw_source,
        };

        return switch (dc.language) {
            .verilog => HdlParser.parseVerilog(source, dc.behavioral.top_module, a) catch return error.HdlParseError,
            .vhdl => HdlParser.parseVhdl(source, dc.behavioral.top_module, a) catch return error.HdlParseError,
            .xspice, .xyce_digital => error.UnsupportedLanguage,
        };
    }

    /// Converts HdlParser.PinDir to Schemify.PinDir (same variants, but distinct types).
    fn hdlDirToSymDir(hdir: HdlParser.PinDir) PinDir {
        return switch (hdir) {
            .input => .input,
            .output => .output,
            .inout => .inout,
            .power => .power,
            .ground => .ground,
        };
    }

    /// Returns true if the pin name matches a clock pattern.
    fn isClock(name: []const u8) bool {
        if (name.len == 0) return false;
        if (std.ascii.eqlIgnoreCase(name, "clk")) return true;
        if (std.ascii.eqlIgnoreCase(name, "clock")) return true;
        // Also match names containing "clk" or "clock" as a substring.
        if (name.len > 3) {
            var buf: [64]u8 = undefined;
            const max = @min(name.len, 64);
            for (0..max) |i| buf[i] = std.ascii.toLower(name[i]);
            const lower = buf[0..max];
            if (std.mem.indexOf(u8, lower, "clk") != null) return true;
            if (std.mem.indexOf(u8, lower, "clock") != null) return true;
        }
        return false;
    }

    // ── Logging ──────────────────────────────────────────────────────────── //

    pub const LogLevel = enum { info, warn, err };

    pub fn emit(self: *Schemify, level: LogLevel, comptime fmt: []const u8, args: anytype) void {
        const l = self.logger orelse return;
        switch (level) {
            .info => l.info("schemify", fmt, args),
            .warn => l.warn("schemify", fmt, args),
            .err => l.err("schemify", fmt, args),
        }
    }
};

test "struct size" {
    std.debug.print("Schemify: {d}B\n", .{@sizeOf(Schemify)});
}
