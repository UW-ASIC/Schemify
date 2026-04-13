//! A single open schematic document.
//! One `pub` struct per file — Document owns its schematic data and file origin.

const std = @import("std");
const core = @import("core");
const utility = @import("utility");
const cmd = @import("commands");
const types = @import("types.zig");

const Point = types.Point;
const Origin = types.Origin;
const Viewport = types.Viewport;
const Selection = types.Selection;

const Document = @This();

// ── Subcircuit symbol cache ──────────────────────────────────────────────────
// Owned by the document; lifetime matches the document's arena. Cleared on
// reload/close so stale file-based symbols are never rendered.

pub const SubcktSymbol = struct {
    pin_x:    []i16,
    pin_y:    []i16,
    pin_dir:  []core.PinDir,
    pin_name: [][]const u8,
    box_w: i16,
    box_h: i16,
};
pub const SubcktCache = std.StringHashMapUnmanaged(SubcktSymbol);

// ── Fields (ordered by alignment: 8-byte, 4-byte, 1-byte) ───────────────────

// 8-byte aligned (pointers / slices / fat structs)
alloc: std.mem.Allocator,
sch: core.Schemify,
name: []const u8,
subckt_cache: SubcktCache = .{},
subckt_arena: ?std.heap.ArenaAllocator = null,
logger: ?*utility.Logger = null,
origin: Origin = .unsaved,
view: Viewport = .{},
selection: Selection = .{},
history: cmd.History = .{},
missing_symbols: std.StringArrayHashMapUnmanaged(void) = .{},
// 1-byte
dirty: bool = true,

// ── Private helpers ──────────────────────────────────────────────────────────

fn swapRemoveIfValid(list: anytype, idx: usize) bool {
    if (idx >= list.len) return false;
    list.swapRemove(idx);
    return true;
}

// ── Lifecycle ────────────────────────────────────────────────────────────────

pub fn open(a: std.mem.Allocator, logger: ?*utility.Logger, path: []const u8) !Document {
    const data = try utility.Vfs.readAlloc(a, path);
    defer a.free(data);
    const s = core.Schemify.readFile(data, a, logger);
    const owned_name = try a.dupe(u8, path);
    errdefer a.free(owned_name);
    const owned_origin = try a.dupe(u8, path);
    return .{
        .alloc = a,
        .logger = logger,
        .name = owned_name,
        .sch = s,
        .origin = .{ .chn_file = owned_origin },
        .dirty = false,
    };
}

pub fn deinit(self: *Document) void {
    self.clearSubcktCache();
    self.selection.instances.deinit(self.alloc);
    self.selection.wires.deinit(self.alloc);
    for (self.missing_symbols.keys()) |k| self.alloc.free(k);
    self.missing_symbols.deinit(self.alloc);
    self.alloc.free(self.name);
    switch (self.origin) {
        .chn_file => |p| self.alloc.free(p),
        else => {},
    }
    self.sch.deinit();
}

pub fn addMissingSymbol(self: *Document, name: []const u8) void {
    if (name.len == 0) return;
    if (self.missing_symbols.contains(name)) return;
    const owned = self.alloc.dupe(u8, name) catch return;
    self.missing_symbols.put(self.alloc, owned, {}) catch {
        self.alloc.free(owned);
    };
}

pub fn clearMissingSymbols(self: *Document) void {
    for (self.missing_symbols.keys()) |k| self.alloc.free(k);
    self.missing_symbols.clearRetainingCapacity();
}

/// Lazily initialize and return the subckt arena allocator.
pub fn subcktAllocator(self: *Document) std.mem.Allocator {
    if (self.subckt_arena == null)
        self.subckt_arena = std.heap.ArenaAllocator.init(self.alloc);
    return self.subckt_arena.?.allocator();
}

/// Free all cached subcircuit symbols and reset the arena.
/// Called on document close and reload.
pub fn clearSubcktCache(self: *Document) void {
    if (self.subckt_arena) |*a| {
        a.deinit();
        self.subckt_arena = null;
    }
    self.subckt_cache = .{};
}

// ── Netlist / Simulation ─────────────────────────────────────────────────────

pub fn createNetlist(self: *Document, sim: core.SpiceBackend) ![]u8 {
    return self.sch.emitSpice(self.alloc, sim, core.pdk, .sim);
}

pub fn runSpiceSim(self: *Document, sim: core.SpiceBackend, netlist_content: []const u8) !std.process.Child.Term {
    _ = sim;
    const builtin = @import("builtin");
    if (builtin.cpu.arch == .wasm32) return error.UnsupportedFeature;

    const base_name = switch (self.origin) {
        .chn_file => |p| std.fs.path.stem(p),
        else => self.name,
    };

    var sp_buf: [512]u8 = undefined;
    var raw_buf: [512]u8 = undefined;
    const sp_path = std.fmt.bufPrint(&sp_buf, "/tmp/{s}.sp", .{base_name}) catch return error.Overflow;
    const raw_path = std.fmt.bufPrint(&raw_buf, "/tmp/{s}.raw", .{base_name}) catch return error.Overflow;

    utility.Vfs.writeAll(sp_path, netlist_content) catch return error.WriteFailed;

    var child = std.process.Child.init(
        &.{ "ngspice", "-b", sp_path, "-r", raw_path },
        self.alloc,
    );
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    try child.spawn();
    const term = try child.wait();
    return term;
}

// ── Properties ───────────────────────────────────────────────────────────────

pub fn setProp(self: *Document, idx: usize, key: []const u8, val: []const u8) !void {
    _ = self;
    _ = idx;
    _ = key;
    _ = val;
    // TODO: implement property mutation
}

// ── Save ─────────────────────────────────────────────────────────────────────

pub fn saveAsChn(self: *Document, path: []const u8) !void {
    const out = self.sch.writeFile(self.alloc, self.logger) orelse return error.WriteFailed;
    try utility.Vfs.writeAll(path, out);
    const new_origin = try self.alloc.dupe(u8, path);
    errdefer self.alloc.free(new_origin);
    const new_name = try self.alloc.dupe(u8, path);
    switch (self.origin) {
        .chn_file => |p| self.alloc.free(p),
        else => {},
    }
    self.alloc.free(self.name);
    self.origin = .{ .chn_file = new_origin };
    self.name = new_name;
    self.dirty = false;
}

// ── Instance manipulation ────────────────────────────────────────────────────

pub fn placeSymbol(self: *Document, sym_path: []const u8, name: []const u8, pos: Point, opts: anytype) !usize {
    _ = opts;
    const a = self.sch.alloc();
    try self.sch.instances.append(a, .{ .name = name, .symbol = sym_path, .x = pos[0], .y = pos[1] });
    self.dirty = true;
    return self.sch.instances.len - 1;
}

pub fn deleteInstanceAt(self: *Document, idx: usize) void {
    if (swapRemoveIfValid(&self.sch.instances, idx)) self.dirty = true;
}

pub fn moveInstanceBy(self: *Document, idx: usize, dx: i32, dy: i32) void {
    if (idx < self.sch.instances.len) {
        self.sch.instances.items(.x)[idx] += dx;
        self.sch.instances.items(.y)[idx] += dy;
        self.dirty = true;
    }
}

// ── Wire manipulation ────────────────────────────────────────────────────────

pub fn addWireSeg(self: *Document, start: Point, end: Point, net_name: ?[]const u8) !void {
    const a = self.sch.alloc();
    try self.sch.wires.append(a, .{
        .x0 = start[0],
        .y0 = start[1],
        .x1 = end[0],
        .y1 = end[1],
        .net_name = net_name,
    });
    self.dirty = true;
}

pub fn deleteWireAt(self: *Document, idx: usize) void {
    if (swapRemoveIfValid(&self.sch.wires, idx)) self.dirty = true;
}
