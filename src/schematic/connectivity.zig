const std = @import("std");
const Allocator = std.mem.Allocator;
const MAL = std.MultiArrayList;
const List = std.ArrayListUnmanaged;

const types = @import("types.zig");
const helpers = @import("helpers.zig");
const string_pool = @import("string_pool.zig");
const StringRef = string_pool.StringRef;
const StringPool = string_pool.StringPool;
const Instance = types.Instance;
const Wire = types.Wire;
const SymData = types.SymData;
const Conn = types.Conn;
const Net = types.Net;
const NetConn = types.NetConn;
const NetMap = types.NetMap;
const PinRef = types.PinRef;
const ConnKind = types.ConnKind;
const applyRotFlip = helpers.applyRotFlip;

pub const Connectivity = struct {
    nets: List(Net) = .{},
    conns: List(Conn) = .{},
    net_conns: List(NetConn) = .{},
    /// Parallel to instances: start index into conns
    conn_starts: []u32 = &.{},
    /// Parallel to instances: count of conns
    conn_counts: []u16 = &.{},
    /// Owns auto-generated net names and conn strings
    pool: StringPool = .{},
    dirty: bool = true,

    pub fn deinit(self: *Connectivity, a: Allocator) void {
        self.freeContents(a);
        self.nets.deinit(a);
        self.conns.deinit(a);
        self.net_conns.deinit(a);
        self.pool.deinit(a);
        self.* = .{};
    }

    fn freeContents(self: *Connectivity, a: Allocator) void {
        if (self.conn_starts.len > 0) a.free(self.conn_starts);
        if (self.conn_counts.len > 0) a.free(self.conn_counts);
        self.conn_starts = &.{};
        self.conn_counts = &.{};
    }

    /// Pure function: source data in, connectivity out.
    /// Clears and rebuilds all derived data.
    /// `src_pool` is the source StringPool for reading wire/pin names.
    pub fn resolve(
        self: *Connectivity,
        a: Allocator,
        instances: *const MAL(Instance),
        wires: *const MAL(Wire),
        sym_data: []const SymData,
        src_pool: *const StringPool,
    ) void {
        // Clear old data
        self.freeContents(a);
        self.nets.items.len = 0;
        self.net_conns.items.len = 0;
        self.conns.items.len = 0;
        self.pool.bytes.items.len = 0;

        if (wires.len == 0 and instances.len == 0) {
            self.dirty = false;
            return;
        }

        // Allocate parallel arrays for instances
        if (instances.len > 0) {
            self.conn_starts = a.alloc(u32, instances.len) catch {
                self.dirty = false;
                return;
            };
            self.conn_counts = a.alloc(u16, instances.len) catch {
                a.free(self.conn_starts);
                self.conn_starts = &.{};
                self.dirty = false;
                return;
            };
            @memset(self.conn_starts, 0);
            @memset(self.conn_counts, 0);
        }

        // Union-find on point keys
        var parents = std.AutoHashMapUnmanaged(u64, u64){};
        defer parents.deinit(a);

        // Wire endpoints
        const wx0 = wires.items(.x0);
        const wy0 = wires.items(.y0);
        const wx1 = wires.items(.x1);
        const wy1 = wires.items(.y1);
        const wbus = wires.items(.bus);
        const w_net = wires.items(.net_name);

        // Step 1: Connect each wire's two endpoints via position key
        for (0..wires.len) |i| {
            const k0 = NetMap.pointKey(wx0[i], wy0[i]);
            const k1 = NetMap.pointKey(wx1[i], wy1[i]);
            makeSet(&parents, a, k0);
            makeSet(&parents, a, k1);
            unite(&parents, a, k0, k1);
        }

        // Step 2: T-junctions — wire endpoint touching interior of another wire
        for (0..wires.len) |i| {
            for ([2]struct { x: i32, y: i32 }{
                .{ .x = wx0[i], .y = wy0[i] },
                .{ .x = wx1[i], .y = wy1[i] },
            }) |pt| {
                const kp = NetMap.pointKey(pt.x, pt.y);
                for (0..wires.len) |j| {
                    if (j == i or wbus[j]) continue;
                    // Don't merge wires with different explicit net names
                    if (!w_net[i].isEmpty() and !w_net[j].isEmpty()) {
                        const ni = src_pool.get(w_net[i]);
                        const nj = src_pool.get(w_net[j]);
                        if (!std.mem.eql(u8, ni, nj)) continue;
                    }
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

        // Step 3: Instance pin positions from sym_data
        if (sym_data.len > 0) {
            const ix = instances.items(.x);
            const iy = instances.items(.y);
            const iflags = instances.items(.flags);
            const ikind = instances.items(.kind);
            for (0..instances.len) |i| {
                if (ikind[i].isNonElectrical()) continue;
                if (i >= sym_data.len) continue;
                const sd = sym_data[i];
                for (sd.pins) |pin| {
                    const abs = applyRotFlip(pin.x, pin.y, iflags[i].rot, iflags[i].flip, ix[i], iy[i]);
                    const k = NetMap.pointKey(abs.x, abs.y);
                    makeSet(&parents, a, k);

                    // Find first touching wire and check for contested point
                    var first_wire: ?usize = null;
                    var first_net_str: []const u8 = "";
                    var contested = false;
                    for (0..wires.len) |wi| {
                        const touches = (abs.x == wx0[wi] and abs.y == wy0[wi]) or
                            (abs.x == wx1[wi] and abs.y == wy1[wi]);
                        if (touches) {
                            const wn_str = if (!w_net[wi].isEmpty()) src_pool.get(w_net[wi]) else "";
                            if (first_wire == null) {
                                first_wire = wi;
                                first_net_str = wn_str;
                            } else if (wn_str.len > 0 and first_net_str.len > 0 and
                                !std.mem.eql(u8, wn_str, first_net_str))
                            {
                                contested = true;
                                break;
                            }
                        }
                    }

                    if (!contested) {
                        if (first_wire) |wi| {
                            unite(&parents, a, k, NetMap.pointKey(wx0[wi], wy0[wi]));
                        }
                    }
                }
            }
        }

        // Collect root -> name from wire net_name annotations and label/power instances
        const RootName = struct { root: u64, name: StringRef };
        var root_names = List(RootName){};
        defer root_names.deinit(a);

        {
            for (0..wires.len) |i| {
                if (w_net[i].isEmpty()) continue;
                const name_str = src_pool.get(w_net[i]);
                const k = NetMap.pointKey(wx0[i], wy0[i]);
                makeSet(&parents, a, k);
                const root = find(&parents, k);
                const ref = self.pool.add(a, name_str) catch continue;
                var found = false;
                for (root_names.items) |*rn| {
                    if (rn.root == root) {
                        const existing_str = self.pool.get(rn.name);
                        if (netNameRank(name_str) > netNameRank(existing_str)) rn.name = ref;
                        found = true;
                        break;
                    }
                }
                if (!found) root_names.append(a, .{ .root = root, .name = ref }) catch {};
            }
        }

        // Collect net names from label pins and power instances
        if (sym_data.len > 0) {
            const ix = instances.items(.x);
            const iy = instances.items(.y);
            const iflags = instances.items(.flags);
            const ikind = instances.items(.kind);
            const iname = instances.items(.name);
            for (0..instances.len) |i| {
                if (i >= sym_data.len) continue;
                const kind = ikind[i];
                const name_str: []const u8 = if (kind.isLabel())
                    src_pool.get(iname[i])
                else if (kind == .gnd)
                    "0"
                else if (kind == .vdd)
                    "vdd"
                else
                    continue;

                const sd = sym_data[i];
                if (sd.pins.len == 0) continue;
                const abs = applyRotFlip(sd.pins[0].x, sd.pins[0].y, iflags[i].rot, iflags[i].flip, ix[i], iy[i]);
                const k = NetMap.pointKey(abs.x, abs.y);
                makeSet(&parents, a, k);
                const root = find(&parents, k);

                const net_ref = self.pool.add(a, name_str) catch continue;

                var found = false;
                for (root_names.items) |*rn| {
                    if (rn.root == root) {
                        const existing_str = self.pool.get(rn.name);
                        if (netNameRank(name_str) > netNameRank(existing_str)) rn.name = net_ref;
                        found = true;
                        break;
                    }
                }
                if (!found) root_names.append(a, .{ .root = root, .name = net_ref }) catch {};
            }
        }

        // Auto-name unnamed nets
        var auto_idx: u32 = 1;
        for (root_names.items) |rn| {
            const s = self.pool.get(rn.name);
            if (isAutoNetName(s)) {
                const n = std.fmt.parseInt(u32, s[3..], 10) catch continue;
                if (n >= auto_idx) auto_idx = n + 1;
            }
        }

        for (0..wires.len) |i| {
            for ([2]u64{ NetMap.pointKey(wx0[i], wy0[i]), NetMap.pointKey(wx1[i], wy1[i]) }) |k| {
                const root = find(&parents, k);
                var found = false;
                for (root_names.items) |rn| if (rn.root == root) {
                    found = true;
                    break;
                };
                if (!found) {
                    var buf: [32]u8 = undefined;
                    const nm = std.fmt.bufPrint(&buf, "net{d}", .{auto_idx}) catch continue;
                    const ref = self.pool.add(a, nm) catch continue;
                    auto_idx += 1;
                    root_names.append(a, .{ .root = root, .name = ref }) catch {};
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
        for (0..wires.len) |i| {
            for ([2][2]i32{ .{ wx0[i], wy0[i] }, .{ wx1[i], wy1[i] } }) |ep| {
                const root = find(&parents, NetMap.pointKey(ep[0], ep[1]));
                const nid = root_to_id.get(root) orelse continue;
                self.net_conns.append(a, .{
                    .net_id = nid,
                    .kind = .wire_endpoint,
                    .ref_a = ep[0],
                    .ref_b = ep[1],
                }) catch {};
            }
        }

        // Instance conns
        {
            const ix = instances.items(.x);
            const iy = instances.items(.y);
            const iflags = instances.items(.flags);
            const unknown_ref = self.pool.add(a, "?") catch StringRef.empty;
            for (0..instances.len) |i| {
                if (i >= sym_data.len) continue;
                const sd = sym_data[i];
                if (sd.pins.len == 0) continue;
                self.conn_starts[i] = @intCast(self.conns.items.len);
                for (sd.pins) |pin| {
                    // Explicit net from import: use directly, skip geometry
                    if (!pin.net.isEmpty()) {
                        const net_str = src_pool.get(pin.net);
                        const net_ref = self.pool.add(a, net_str) catch unknown_ref;
                        self.conns.append(a, .{
                            .pin = pin.name,
                            .net = net_ref,
                        }) catch {};
                        continue;
                    }
                    const abs = applyRotFlip(pin.x, pin.y, iflags[i].rot, iflags[i].flip, ix[i], iy[i]);
                    const k = NetMap.pointKey(abs.x, abs.y);
                    makeSet(&parents, a, k);
                    const root = find(&parents, k);
                    const nid = root_to_id.get(root);
                    const net_ref: StringRef = if (nid) |id|
                        (if (id < self.nets.items.len) self.nets.items[id].name else unknown_ref)
                    else
                        unknown_ref;
                    self.conns.append(a, .{
                        .pin = pin.name,
                        .net = net_ref,
                    }) catch {};
                    if (nid) |id|
                        self.net_conns.append(a, .{
                            .net_id = id,
                            .kind = .instance_pin,
                            .ref_a = abs.x,
                            .ref_b = abs.y,
                        }) catch {};
                }
                self.conn_counts[i] = @intCast(self.conns.items.len - self.conn_starts[i]);
            }
        }

        self.dirty = false;
    }

    /// Connection slice for instance i
    pub fn connSlice(self: *const Connectivity, idx: usize) []const Conn {
        if (idx >= self.conn_starts.len) return &.{};
        const start = self.conn_starts[idx];
        const count = self.conn_counts[idx];
        if (start + count > self.conns.items.len) return &.{};
        return self.conns.items[start..][0..count];
    }

    /// Resolve a StringRef from either the source pool or our local pool.
    /// Net names from wire annotations live in src_pool; auto-generated names
    /// live in self.pool.
    pub fn getNetName(self: *const Connectivity, ref: StringRef, src_pool: *const StringPool) []const u8 {
        const local = self.pool.get(ref);
        if (local.len > 0) return local;
        return src_pool.get(ref);
    }

    // ── Union-find helpers ───────────────────────────────────────────────────

    fn makeSet(p: *std.AutoHashMapUnmanaged(u64, u64), alloc: Allocator, k: u64) void {
        const gop = p.getOrPut(alloc, k) catch return;
        if (!gop.found_existing) gop.value_ptr.* = k;
    }

    fn find(p: *std.AutoHashMapUnmanaged(u64, u64), k: u64) u64 {
        var cur = k;
        while (true) {
            const parent = p.get(cur) orelse return cur;
            if (parent == cur) return cur;
            cur = parent;
        }
    }

    fn unite(p: *std.AutoHashMapUnmanaged(u64, u64), alloc: Allocator, x: u64, y: u64) void {
        const rx = find(p, x);
        const ry = find(p, y);
        if (rx != ry) p.put(alloc, rx, ry) catch {};
    }

    // ── Net naming helpers ───────────────────────────────────────────────────

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

// ── Tests ────────────────────────────────────────────────────────────────────

test "empty resolve" {
    const a = std.testing.allocator;
    var c: Connectivity = .{};
    defer c.deinit(a);

    var instances: MAL(Instance) = .{};
    var wires: MAL(Wire) = .{};
    var src_pool: StringPool = .{};
    defer src_pool.deinit(a);

    c.resolve(a, &instances, &wires, &.{}, &src_pool);

    try std.testing.expectEqual(@as(usize, 0), c.nets.items.len);
    try std.testing.expectEqual(@as(usize, 0), c.conns.items.len);
    try std.testing.expectEqual(@as(usize, 0), c.net_conns.items.len);
    try std.testing.expect(!c.dirty);
}

test "simple wire net" {
    const a = std.testing.allocator;
    var c: Connectivity = .{};
    defer c.deinit(a);

    var instances: MAL(Instance) = .{};
    var wires: MAL(Wire) = .{};
    defer wires.deinit(a);
    var src_pool: StringPool = .{};
    defer src_pool.deinit(a);

    // Two wires sharing endpoint at (100, 0):
    // Wire 0: (0,0) -> (100,0)
    // Wire 1: (100,0) -> (200,0)
    try wires.append(a, .{ .x0 = 0, .y0 = 0, .x1 = 100, .y1 = 0 });
    try wires.append(a, .{ .x0 = 100, .y0 = 0, .x1 = 200, .y1 = 0 });

    c.resolve(a, &instances, &wires, &.{}, &src_pool);

    // Shared endpoint means one net
    try std.testing.expectEqual(@as(usize, 1), c.nets.items.len);
    try std.testing.expect(!c.dirty);
}

test "resolve marks not dirty" {
    const a = std.testing.allocator;
    var c: Connectivity = .{};
    defer c.deinit(a);

    try std.testing.expect(c.dirty);

    var instances: MAL(Instance) = .{};
    var wires: MAL(Wire) = .{};
    var src_pool: StringPool = .{};
    defer src_pool.deinit(a);

    c.resolve(a, &instances, &wires, &.{}, &src_pool);

    try std.testing.expect(!c.dirty);
}

test "t-junction detection" {
    const a = std.testing.allocator;
    var c: Connectivity = .{};
    defer c.deinit(a);

    var instances: MAL(Instance) = .{};
    var wires: MAL(Wire) = .{};
    defer wires.deinit(a);
    var src_pool: StringPool = .{};
    defer src_pool.deinit(a);

    // Horizontal wire: (0,0) -> (200,0)
    // Vertical wire endpoint touches interior at (100,0)
    try wires.append(a, .{ .x0 = 0, .y0 = 0, .x1 = 200, .y1 = 0 });
    try wires.append(a, .{ .x0 = 100, .y0 = -50, .x1 = 100, .y1 = 0 });

    c.resolve(a, &instances, &wires, &.{}, &src_pool);

    // T-junction merges into single net
    try std.testing.expectEqual(@as(usize, 1), c.nets.items.len);
}

test "named wire overrides auto name" {
    const a = std.testing.allocator;
    var c: Connectivity = .{};
    defer c.deinit(a);

    var instances: MAL(Instance) = .{};
    var wires: MAL(Wire) = .{};
    defer wires.deinit(a);
    var src_pool: StringPool = .{};
    defer src_pool.deinit(a);

    // Two connected wires, one with explicit name
    const vdd_ref = try src_pool.add(a, "VDD");
    try wires.append(a, .{ .x0 = 0, .y0 = 0, .x1 = 100, .y1 = 0, .net_name = vdd_ref });
    try wires.append(a, .{ .x0 = 100, .y0 = 0, .x1 = 200, .y1 = 0 });

    c.resolve(a, &instances, &wires, &.{}, &src_pool);

    try std.testing.expectEqual(@as(usize, 1), c.nets.items.len);
    try std.testing.expectEqualStrings("VDD", src_pool.get(c.nets.items[0].name));
}

test "connSlice out of bounds returns empty" {
    var c: Connectivity = .{};
    const slice = c.connSlice(999);
    try std.testing.expectEqual(@as(usize, 0), slice.len);
}

test "isAutoNetName" {
    try std.testing.expect(Connectivity.isAutoNetName("net1"));
    try std.testing.expect(Connectivity.isAutoNetName("net42"));
    try std.testing.expect(!Connectivity.isAutoNetName("VDD"));
    try std.testing.expect(!Connectivity.isAutoNetName("net"));
    try std.testing.expect(!Connectivity.isAutoNetName("ne"));
}

test "netNameRank" {
    try std.testing.expectEqual(@as(u8, 0), Connectivity.netNameRank(""));
    try std.testing.expectEqual(@as(u8, 1), Connectivity.netNameRank("net1"));
    try std.testing.expectEqual(@as(u8, 2), Connectivity.netNameRank("0"));
    try std.testing.expectEqual(@as(u8, 3), Connectivity.netNameRank("VDD"));
}
