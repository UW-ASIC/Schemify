const std = @import("std");
const Allocator = std.mem.Allocator;
const MAL = std.MultiArrayList;
const List = std.ArrayListUnmanaged;

const utility = @import("utility");
const UnionFindType = utility.UnionFind;
pub const Devices = @import("devices/Devices.zig");
pub const HdlParser = @import("digital/HdlParser.zig");
pub const Toml = @import("fileio/Toml.zig");
const log = utility;

const types = @import("types.zig");

pub const DeviceKind = Devices.DeviceKind;
pub const primitives = Devices.primitives;
pub const SpiceBackend = @import("simulation/SpiceIF.zig").Backend;
pub const NetlistMode = @import("simulation/SpiceIF.zig").NetlistMode;
pub const pdk = &Devices.global_pdk;

// ── Type aliases from types.zig ───────────────────────────────────────────── //
pub const PinDir = types.PinDir;
pub const Line = types.Line;
pub const Rect = types.Rect;
pub const Circle = types.Circle;
pub const Arc = types.Arc;
pub const Wire = types.Wire;
pub const Text = types.Text;
pub const Pin = types.Pin;
pub const Instance = types.Instance;
pub const Prop = types.Prop;
pub const Conn = types.Conn;
pub const Net = types.Net;
pub const ConnKind = types.ConnKind;
pub const NetConn = types.NetConn;
pub const NetMap = types.NetMap;
pub const SifyType = types.SifyType;
pub const SymDataPin = types.SymDataPin;
pub const PinRef = types.PinRef;
pub const SymData = types.SymData;
pub const SourceMode = types.SourceMode;
pub const HdlLanguage = types.HdlLanguage;
pub const BehavioralModel = types.BehavioralModel;
pub const SynthesizedModel = types.SynthesizedModel;
pub const DigitalConfig = types.DigitalConfig;

/// Self-reference so test files can alias: `const sch = core.sch;`
pub const sch = @This();


// ── FileType ─────────────────────────────────────────────────────────────── //

pub const FileType = enum {
    chn,
    chn_prim,
    chn_tb,
    xschem_sch,
    unknown,

    pub fn fromPath(path: []const u8) FileType {
        if (std.mem.endsWith(u8, path, ".chn_prim")) return .chn_prim;
        if (std.mem.endsWith(u8, path, ".chn_tb")) return .chn_tb;
        if (std.mem.endsWith(u8, path, ".chn")) return .chn;
        if (std.mem.endsWith(u8, path, ".sch")) return .xschem_sch;
        return .unknown;
    }
};

// ── Transform ────────────────────────────────────────────────────────────── //

/// Rotation + flip transform applied to schematic instances.
pub const Transform = struct {
    rot: u2 = 0,
    flip: bool = false,

    pub const identity: Transform = .{ .rot = 0, .flip = false };

    /// Compose two transforms: `self` applied first, then `other`.
    pub fn compose(self: Transform, other: Transform) Transform {
        const new_rot: u2 = @truncate(@as(u8, self.rot) +% @as(u8, other.rot));
        const new_flip = self.flip != other.flip;
        return .{ .rot = new_rot, .flip = new_flip };
    }
};

// ── Shape ─────────────────────────────────────────────────────────────────── //

/// A discriminated union of all drawable primitive shapes.
pub const Shape = union(enum) {
    line: struct { start: [2]i32, end: [2]i32 },
    rect: struct { min: [2]i32, max: [2]i32 },
    arc: struct { center: [2]i32, radius: i32, start_angle: i16, sweep_angle: i16 },
    circle: struct { center: [2]i32, radius: i32 },
    other: void,
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

/// Plugin-authored data block, serialised as a top-level `PLUGIN <name>` section.
/// Unknown plugin blocks are preserved on read and re-emitted on write (round-trip).
/// If the owning plugin is not installed the runtime ignores the block; the data
/// is still kept so saving the file does not lose it.
pub const PluginBlock = struct {
    /// Canonical plugin identifier — no spaces (e.g. `"circuit_visionary"`).
    name:    []const u8,
    /// Arbitrary key-value pairs stored by the plugin.
    entries: List(Prop) = .{},
};

// ── Schemify Public Mutation Interface ───────────────────────────────────── //
//
// ALL mutations to a Schemify must go through the methods listed below.
// Do NOT write to struct fields directly from gui/ or plugin code.
//
// INSERT  (append, arena-dupes all strings):
//   drawLine / drawRect / drawCircle / drawArc   — symbol geometry
//   drawText / drawPin                            — text annotations and pins
//   addWire(Wire)                                 — net wire segment
//   addComponent(ComponentDesc)                   — placed component instance
//   setName / setStype                            — schematic metadata
//   setSpiceBody / setSpiceSymDef                 — raw SPICE body / symbol def
//   addSymProp / addGlobal / addPluginBlock       — symbol props, globals, plugin data
//
// REMOVE  (by 0-based index; uses swapRemove — index of last element changes):
//   removeInstance(idx) / removeWire(idx)
//   removeLine(idx) / removeRect(idx) / removeCircle(idx)
//   removeArc(idx) / removeText(idx) / removePin(idx)
//
// EDIT  (mutate a single field of an existing element):
//   moveInstance(idx, dx, dy)              — translate by delta
//   setInstancePos(idx, x, y)              — set absolute position
//   setInstanceTransform(idx, rot, flip)   — set rotation / flip
//
// READ  (const access — fields may be read freely, but not written):
//   .instances.len / .wires.len / etc.
//   .instances.get(i) / .wires.get(i) / etc.
//   .props.items[prop_start..][0..prop_count]
//   bounds(inst_pad)  — world-space AABB
//   resolveNets()     — rebuild net connectivity (call after bulk mutations)

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
    plugin_blocks: List(PluginBlock) = .{},

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

    /// Per-instance prim lookup cache, parallel to instances MAL.
    /// Allocated from the arena; rebuilt when prim_cache_dirty is true.
    prim_cache: []?*const primitives.PrimEntry = &.{},
    prim_cache_dirty: bool = true,

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
        return @import("fileio/Reader.zig").Reader.readCHN(data, backing, logger);
    }

    pub fn writeFile(self: *Schemify, a: Allocator, logger: ?*log.Logger) ?[]u8 {
        return @import("fileio/Writer.zig").Writer.writeCHN(a, self, logger);
    }

    pub fn emitSpice(
        self: *const Schemify,
        gpa: Allocator,
        backend: @import("simulation/SpiceIF.zig").Backend,
        pdk_: ?*const Devices.Pdk,
        mode: @import("simulation/SpiceIF.zig").NetlistMode,
    ) ![]u8 {
        return @import("simulation/Netlist.zig").Netlist.emitSpice(self, gpa, backend, pdk_, mode);
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

        // Register global nets: instances backed by a primitive with injected_net
        // (e.g. vdd, gnd) use the wire-resolved net name at their position so that
        // renamed power nets (e.g. VCC instead of VDD) are captured correctly.
        {
            const isym = self.instances.items(.symbol);
            const ikind3 = self.instances.items(.kind);
            const gix = self.instances.items(.x);
            const giy = self.instances.items(.y);
            for (0..self.instances.len) |i| {
                const prim = primLookup(isym[i], ikind3[i]) orelse continue;
                if (prim.injected_net == null) continue;
                const k = NetMap.pointKey(gix[i], giy[i]);
                uf.makeSet(k);
                const root = uf.find(k);
                const nid = root_to_id.get(root) orelse continue;
                if (nid < self.nets.items.len)
                    self.addGlobal(self.nets.items[nid].name) catch {};
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

    /// Add a global net name (e.g. "VDD", "GND"). Deduplicates — safe to call multiple times.
    pub fn addGlobal(self: *Schemify, name: []const u8) !void {
        for (self.globals.items) |g| {
            if (std.mem.eql(u8, g, name)) return;
        }
        const a = self.alloc();
        try self.globals.append(a, try a.dupe(u8, name));
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

    // ── Mutation interface: metadata setters ─────────────────────────────── //

    pub fn setSpiceBody(self: *Schemify, body: []const u8) void {
        self.spice_body = body;
    }

    pub fn setSpiceSymDef(self: *Schemify, def: []const u8) void {
        self.spice_sym_def = def;
    }

    /// Append a named plugin data block (e.g. provenance records from EasyImport).
    /// All strings are duped into the arena.
    pub fn addPluginBlock(self: *Schemify, name: []const u8, entries: []const Prop) !void {
        const a = self.alloc();
        var owned: List(Prop) = .{};
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

    // ── Mutation interface: remove by index (swapRemove) ─────────────────── //

    pub fn removeInstance(self: *Schemify, idx: u32) void {
        if (idx >= self.instances.len) return;
        self.instances.swapRemove(idx);
        if (idx < self.sym_data.items.len) _ = self.sym_data.swapRemove(idx);
        self.prim_cache_dirty = true;
    }

    pub fn removeWire(self: *Schemify, idx: u32) void {
        if (idx >= self.wires.len) return;
        self.wires.swapRemove(idx);
    }

    pub fn removeLine(self: *Schemify, idx: u32) void {
        if (idx >= self.lines.len) return;
        self.lines.swapRemove(idx);
    }

    pub fn removeRect(self: *Schemify, idx: u32) void {
        if (idx >= self.rects.len) return;
        self.rects.swapRemove(idx);
    }

    pub fn removeCircle(self: *Schemify, idx: u32) void {
        if (idx >= self.circles.len) return;
        self.circles.swapRemove(idx);
    }

    pub fn removeArc(self: *Schemify, idx: u32) void {
        if (idx >= self.arcs.len) return;
        self.arcs.swapRemove(idx);
    }

    pub fn removeText(self: *Schemify, idx: u32) void {
        if (idx >= self.texts.len) return;
        self.texts.swapRemove(idx);
    }

    pub fn removePin(self: *Schemify, idx: u32) void {
        if (idx >= self.pins.len) return;
        self.pins.swapRemove(idx);
    }

    // ── Mutation interface: edit existing elements ────────────────────────── //

    pub fn moveInstance(self: *Schemify, idx: u32, dx: i32, dy: i32) void {
        if (idx >= self.instances.len) return;
        self.instances.items(.x)[idx] += dx;
        self.instances.items(.y)[idx] += dy;
    }

    pub fn setInstancePos(self: *Schemify, idx: u32, x: i32, y: i32) void {
        if (idx >= self.instances.len) return;
        self.instances.items(.x)[idx] = x;
        self.instances.items(.y)[idx] = y;
    }

    pub fn setInstanceTransform(self: *Schemify, idx: u32, rot: u2, flip: bool) void {
        if (idx >= self.instances.len) return;
        self.instances.items(.rot)[idx] = rot;
        self.instances.items(.flip)[idx] = flip;
    }

    /// Set the bus width of a pin (1 = scalar, >1 = bus).
    /// Handles IPin/Opin/IOPin to support multi-bit ports.
    pub fn setPinWidth(self: *Schemify, idx: u32, width: u16) void {
        if (idx >= self.pins.len) return;
        self.pins.items(.width)[idx] = if (width == 0) 1 else width;
    }

    // ── Bounding box ─────────────────────────────────────────────────────── //

    pub const Bounds = struct {
        min_x: f32 = 0,
        max_x: f32 = 0,
        min_y: f32 = 0,
        max_y: f32 = 0,
        has_data: bool = false,

        inline fn bump(b: *Bounds, x: f32, y: f32) void {
            if (!b.has_data) {
                b.* = .{ .min_x = x, .max_x = x, .min_y = y, .max_y = y, .has_data = true };
                return;
            }
            if (x < b.min_x) b.min_x = x;
            if (x > b.max_x) b.max_x = x;
            if (y < b.min_y) b.min_y = y;
            if (y > b.max_y) b.max_y = y;
        }
    };

    /// Compute the world-space bounding box of all drawable elements.
    /// Covers lines, rects, circles, arcs, wires, pins, texts, and
    /// instance origins (padded by `inst_pad`).
    pub fn bounds(self: *const Schemify, inst_pad: f32) Bounds {
        var b: Bounds = .{};

        if (self.lines.len > 0) {
            const x0 = self.lines.items(.x0);
            const x1 = self.lines.items(.x1);
            const y0 = self.lines.items(.y0);
            const y1 = self.lines.items(.y1);
            for (0..self.lines.len) |i| {
                b.bump(@floatFromInt(x0[i]), @floatFromInt(y0[i]));
                b.bump(@floatFromInt(x1[i]), @floatFromInt(y1[i]));
            }
        }
        if (self.rects.len > 0) {
            const x0 = self.rects.items(.x0);
            const x1 = self.rects.items(.x1);
            const y0 = self.rects.items(.y0);
            const y1 = self.rects.items(.y1);
            for (0..self.rects.len) |i| {
                b.bump(@floatFromInt(x0[i]), @floatFromInt(y0[i]));
                b.bump(@floatFromInt(x1[i]), @floatFromInt(y1[i]));
            }
        }
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
            const cx = self.arcs.items(.cx);
            const cy = self.arcs.items(.cy);
            const cr = self.arcs.items(.radius);
            for (0..self.arcs.len) |i| {
                const fx: f32 = @floatFromInt(cx[i]);
                const fy: f32 = @floatFromInt(cy[i]);
                const fr: f32 = @floatFromInt(cr[i]);
                b.bump(fx - fr, fy - fr);
                b.bump(fx + fr, fy + fr);
            }
        }
        if (self.wires.len > 0) {
            const x0 = self.wires.items(.x0);
            const x1 = self.wires.items(.x1);
            const y0 = self.wires.items(.y0);
            const y1 = self.wires.items(.y1);
            for (0..self.wires.len) |i| {
                b.bump(@floatFromInt(x0[i]), @floatFromInt(y0[i]));
                b.bump(@floatFromInt(x1[i]), @floatFromInt(y1[i]));
            }
        }
        if (self.pins.len > 0) {
            const px = self.pins.items(.x);
            const py = self.pins.items(.y);
            for (0..self.pins.len) |i| {
                b.bump(@floatFromInt(px[i]), @floatFromInt(py[i]));
            }
        }
        if (self.texts.len > 0) {
            const tx = self.texts.items(.x);
            const ty = self.texts.items(.y);
            for (0..self.texts.len) |i| {
                b.bump(@floatFromInt(tx[i]), @floatFromInt(ty[i]));
            }
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

    // ── Prim lookup cache ─────────────────────────────────────────────────── //

    /// Rebuild the per-instance primitive lookup cache.
    /// Allocates from the Schemify arena (old slice is reclaimed on arena reset).
    /// Call after any structural mutation: instance append/remove or file load.
    pub fn rebuildPrimCache(self: *Schemify) void {
        const n = self.instances.len;
        self.prim_cache = self.alloc().alloc(?*const primitives.PrimEntry, n) catch &.{};
        const isymbol = self.instances.items(.symbol);
        const ikind = self.instances.items(.kind);
        for (0..self.prim_cache.len) |i| {
            self.prim_cache[i] = primLookup(isymbol[i], ikind[i]);
        }
        self.prim_cache_dirty = false;
    }

    /// Rebuild sym_data from prim_cache pin positions for instances that lost
    /// their sym_data during a write/read round-trip. Only fills entries that
    /// are currently empty (preserves any sym_data populated by the importer).
    pub fn rebuildSymData(self: *Schemify) void {
        const n = self.instances.len;
        if (n == 0) return;
        const a = self.alloc();

        // Grow sym_data list to match instance count if needed.
        while (self.sym_data.items.len < n) {
            self.sym_data.append(a, .{}) catch return;
        }

        for (0..n) |i| {
            // Skip instances that already have sym_data (e.g. from EasyImport).
            if (self.sym_data.items[i].pins.len > 0) continue;

            const prim = if (i < self.prim_cache.len) self.prim_cache[i] else null;
            const entry = prim orelse continue;
            const pp = entry.pinPositions();
            if (pp.len == 0) continue;

            const pins = a.alloc(PinRef, pp.len) catch continue;
            for (pp, 0..) |p, pi| {
                pins[pi] = .{
                    .name = p.nameSlice(),
                    .x = p.x,
                    .y = p.y,
                };
            }
            self.sym_data.items[i] = .{ .pins = pins };
        }
    }

    fn primLookup(symbol_name: []const u8, kind: DeviceKind) ?*const primitives.PrimEntry {
        if (kindToPrimName(kind)) |name| {
            if (primitives.findByNameRuntime(name)) |e| return e;
        }
        var base = symbol_name;
        if (std.mem.startsWith(u8, base, "devices/")) base = base["devices/".len..];
        if (std.mem.endsWith(u8, base, ".sym")) base = base[0 .. base.len - ".sym".len];
        if (primitives.findByNameRuntime(base)) |e| return e;
        const alias_map = std.StaticStringMap([]const u8).initComptime(.{
            .{ "nmos",         "nmos4"     },
            .{ "pmos",         "pmos4"     },
            .{ "resistors",    "resistor"  },
            .{ "capacitors",   "capacitor" },
            .{ "inductors",    "inductor"  },
            .{ "diodes",       "diode"     },
            .{ "ipin",         "input_pin" },
            .{ "opin",         "output_pin"},
            .{ "iopin",        "inout_pin" },
            .{ "vsource_arith","vsource"   },
            .{ "parax_cap",    "capacitor" },
        });
        if (alias_map.get(base)) |alias| {
            if (primitives.findByNameRuntime(alias)) |e| return e;
        }
        const name_kind = DeviceKind.fromStr(base);
        if (name_kind != .unknown) {
            if (kindToPrimName(name_kind)) |n| {
                if (primitives.findByNameRuntime(n)) |e| return e;
            }
        }
        return null;
    }

    fn kindToPrimName(kind: DeviceKind) ?[]const u8 {
        return switch (kind) {
            .nmos3                                       => "nmos3",
            .pmos3                                       => "pmos3",
            .nmos4, .nmos4_depl, .nmos_sub, .nmoshv4,
            .rnmos4                                      => "nmos4",
            .pmos4, .pmos_sub, .pmoshv4                 => "pmos4",
            .resistor, .var_resistor                     => "resistor",
            .resistor3                                   => "resistor3",
            .capacitor                                   => "capacitor",
            .inductor                                    => "inductor",
            .diode                                       => "diode",
            .zener                                       => "zener",
            .vsource, .sqwsource                        => "vsource",
            .isource                                     => "isource",
            .ammeter                                     => "ammeter",
            .behavioral                                  => "behavioral",
            .npn                                         => "npn",
            .pnp                                         => "pnp",
            .njfet                                       => "njfet",
            .pjfet                                       => "pjfet",
            .mesfet                                      => "njfet",
            .vcvs                                        => "vcvs",
            .vccs                                        => "vccs",
            .ccvs                                        => "ccvs",
            .cccs                                        => "cccs",
            .vswitch                                     => "vswitch",
            .iswitch                                     => "iswitch",
            .tline, .tline_lossy                        => "tline",
            .coupling                                    => "coupling",
            .gnd                                         => "gnd",
            .vdd                                         => "vdd",
            .lab_pin                                     => "lab_pin",
            .input_pin                                   => "input_pin",
            .output_pin                                  => "output_pin",
            .inout_pin                                   => "inout_pin",
            .probe, .probe_diff                         => "probe",
            .annotation, .title, .param, .code, .graph,
            .launcher, .rgb_led, .hdl, .noconn, .subckt,
            .digital_instance, .generic, .unknown       => null,
        };
    }
};

test "struct size" {
    std.debug.print("Schemify: {d}B\n", .{@sizeOf(Schemify)});
}
