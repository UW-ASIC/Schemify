//! Document I/O — open, save, and mutate schematic/symbol files.

const std = @import("std");
const core = @import("core");
const Logger = core.Logger;
const types = @import("types.zig");
const CT = types.CT;
pub const FileType = types.FileType;
pub const Sim = types.Sim;

pub const FileIO = struct {
    pub const Origin = union(enum) {
        unsaved,
        buffer,
        chn_file:     []const u8,
        chn_sym_file: []const u8,
    };

    alloc:     std.mem.Allocator,
    logger:    *Logger,
    comp:      struct { name: []const u8 },
    sch:       CT.Schematic,
    sym:       ?CT.Symbol = null,
    origin:    Origin = .unsaved,
    file_type: FileType = .unknown,
    dirty:     bool = true,

    pub fn initNew(alloc: std.mem.Allocator, logger: *Logger, name: []const u8, _: bool) !FileIO {
        const name_owned = try alloc.dupe(u8, name);
        return .{
            .alloc     = alloc,
            .logger    = logger,
            .comp      = .{ .name = name_owned },
            .sch       = CT.Schematic.init(alloc, name),
            .origin    = .unsaved,
            .file_type = .chn,
            .dirty     = true,
        };
    }

    /// Returns the FileType of this document (set at open time).
    pub fn fileType(self: *const FileIO) FileType {
        return self.file_type;
    }

    pub fn initFromChn(alloc: std.mem.Allocator, logger: *Logger, path: []const u8) !FileIO {
        var fio = try initNew(alloc, logger, std.fs.path.stem(path), false);
        fio.origin    = .{ .chn_file = try alloc.dupe(u8, path) };
        fio.file_type = FileType.fromPath(path); // .chn or .chn_tb
        fio.dirty     = false;

        // Read and parse the CHN file into CT.Schematic.
        const data = std.fs.cwd().readFileAlloc(alloc, path, 1024 * 1024 * 4) catch |err| {
            logger.err("FileIO", "failed to read {s}: {}", .{ path, err });
            return fio;
        };
        defer alloc.free(data);

        var parsed = core.Schemify.readFile(data, alloc, logger);
        defer parsed.deinit();

        const ins = parsed.instances.slice();
        for (0..parsed.instances.len) |i| {
            const prop_start = ins.items(.prop_start)[i];
            const prop_count = ins.items(.prop_count)[i];
            var inst: CT.Instance = .{
                .name   = fio.sch.alloc().dupe(u8, ins.items(.name)[i])   catch ins.items(.name)[i],
                .symbol = fio.sch.alloc().dupe(u8, ins.items(.symbol)[i]) catch ins.items(.symbol)[i],
                .pos    = .{ .x = ins.items(.x)[i], .y = ins.items(.y)[i] },
                .xform  = .{ .rot = ins.items(.rot)[i], .flip = ins.items(.flip)[i] },
            };
            for (parsed.props.items[prop_start..][0..prop_count]) |p| {
                inst.props.append(fio.sch.alloc(), .{
                    .key = fio.sch.alloc().dupe(u8, p.key) catch p.key,
                    .val = fio.sch.alloc().dupe(u8, p.val) catch p.val,
                }) catch {};
            }
            fio.sch.instances.append(fio.sch.alloc(), inst) catch {};
        }

        const ws = parsed.wires.slice();
        for (0..parsed.wires.len) |i| {
            fio.sch.wires.append(fio.sch.alloc(), .{
                .start    = .{ .x = ws.items(.x0)[i], .y = ws.items(.y0)[i] },
                .end      = .{ .x = ws.items(.x1)[i], .y = ws.items(.y1)[i] },
                .net_name = if (ws.items(.net_name)[i]) |n|
                    fio.sch.alloc().dupe(u8, n) catch null
                else
                    null,
            }) catch {};
        }

        return fio;
    }

    pub fn initFromChnSym(alloc: std.mem.Allocator, logger: *Logger, path: []const u8) !FileIO {
        var fio = try initNew(alloc, logger, std.fs.path.stem(path), false);
        fio.origin    = .{ .chn_sym_file = try alloc.dupe(u8, path) };
        fio.file_type = .chn_sym;
        fio.dirty     = false;
        return fio;
    }

    pub fn deinit(self: *FileIO) void {
        self.alloc.free(self.comp.name);
        switch (self.origin) {
            .chn_file, .chn_sym_file => |p| self.alloc.free(p),
            .unsaved, .buffer => {},
        }
        self.sch.deinit();
    }

    pub fn schematic(self: *FileIO) *CT.Schematic {
        return &self.sch;
    }

    pub fn symbol(self: *FileIO) ?*CT.Symbol {
        if (self.sym) |*s| return s;
        return null;
    }

    pub fn save(self: *FileIO) !void {
        switch (self.origin) {
            .chn_file => |p| try self.saveAsChn(p),
            else => {},
        }
    }

    pub fn saveAsChn(self: *FileIO, path: []const u8) !void {
        var s = core.Schemify.init(self.alloc);
        defer s.deinit();
        s.name = self.comp.name;

        for (self.sch.instances.items) |inst| {
            const prop_start: u32 = @intCast(s.props.items.len);
            for (inst.props.items) |p| {
                s.props.append(s.alloc(), .{
                    .key = s.alloc().dupe(u8, p.key) catch p.key,
                    .val = s.alloc().dupe(u8, p.val) catch p.val,
                }) catch {};
            }
            s.instances.append(s.alloc(), .{
                .name       = s.alloc().dupe(u8, inst.name)   catch inst.name,
                .symbol     = s.alloc().dupe(u8, inst.symbol) catch inst.symbol,
                .x          = inst.pos.x,
                .y          = inst.pos.y,
                .rot        = inst.xform.rot,
                .flip       = inst.xform.flip,
                .kind       = .unknown,
                .prop_start = prop_start,
                .prop_count = @intCast(s.props.items.len - prop_start),
                .conn_start = 0,
                .conn_count = 0,
            }) catch {};
        }
        for (self.sch.wires.items) |wire| {
            s.wires.append(s.alloc(), .{
                .x0       = wire.start.x,
                .y0       = wire.start.y,
                .x1       = wire.end.x,
                .y1       = wire.end.y,
                .net_name = if (wire.net_name) |n| s.alloc().dupe(u8, n) catch null else null,
            }) catch {};
        }

        if (s.writeFile(self.alloc, self.logger)) |bytes| {
            defer self.alloc.free(bytes);
            try std.fs.cwd().writeFile(.{ .sub_path = path, .data = bytes });
        } else {
            var out: std.ArrayListUnmanaged(u8) = .{};
            defer out.deinit(self.alloc);
            try out.writer(self.alloc).print("* Schemify CHN for {s}\n.end\n", .{self.comp.name});
            try std.fs.cwd().writeFile(.{ .sub_path = path, .data = out.items });
        }

        self.origin = .{ .chn_file = self.alloc.dupe(u8, path) catch path };
        self.dirty = false;
    }

    pub fn isDirty(self: *const FileIO) bool {
        return self.dirty;
    }

    pub fn placeSymbol(self: *FileIO, sym_path: []const u8, name: []const u8, pos: CT.Point, _: anytype) !u32 {
        const inst: CT.Instance = .{
            .name = self.sch.alloc().dupe(u8, name) catch name,
            .symbol = self.sch.alloc().dupe(u8, sym_path) catch sym_path,
            .pos = pos,
        };
        try self.sch.instances.append(self.sch.alloc(), inst);
        self.dirty = true;
        return @intCast(self.sch.instances.items.len - 1);
    }

    pub fn deleteInstanceAt(self: *FileIO, idx: usize) bool {
        if (idx >= self.sch.instances.items.len) return false;
        _ = self.sch.instances.orderedRemove(idx);
        self.dirty = true;
        return true;
    }

    pub fn moveInstanceBy(self: *FileIO, idx: usize, dx: i32, dy: i32) bool {
        if (idx >= self.sch.instances.items.len) return false;
        self.sch.instances.items[idx].pos.x += dx;
        self.sch.instances.items[idx].pos.y += dy;
        self.dirty = true;
        return true;
    }

    pub fn setProp(self: *FileIO, idx: usize, key: []const u8, val: []const u8) !void {
        if (idx >= self.sch.instances.items.len) return;
        var inst = &self.sch.instances.items[idx];
        for (inst.props.items) |*p| {
            if (std.mem.eql(u8, p.key, key)) {
                p.val = self.sch.alloc().dupe(u8, val) catch val;
                self.dirty = true;
                return;
            }
        }
        try inst.props.append(self.sch.alloc(), .{
            .key = self.sch.alloc().dupe(u8, key) catch key,
            .val = self.sch.alloc().dupe(u8, val) catch val,
        });
        self.dirty = true;
    }

    pub fn addWireSeg(self: *FileIO, p0: CT.Point, p1: CT.Point, net: ?[]const u8) !void {
        try self.sch.wires.append(self.sch.alloc(), .{
            .start = p0,
            .end = p1,
            .net_name = if (net) |n| self.sch.alloc().dupe(u8, n) catch n else null,
        });
        self.dirty = true;
    }

    pub fn deleteWireAt(self: *FileIO, idx: usize) bool {
        if (idx >= self.sch.wires.items.len) return false;
        _ = self.sch.wires.orderedRemove(idx);
        self.dirty = true;
        return true;
    }

    pub fn createNetlist(self: *FileIO, sim: Sim) ![]u8 {
        const mode = if (sim == .ngspice) "ngspice" else "xyce";
        const net = try std.fmt.allocPrint(self.alloc, "* placeholder {s} netlist for {s}\n.end\n", .{ mode, self.comp.name });
        defer self.alloc.free(net);

        const path = try std.fmt.allocPrint(self.alloc, ".schemify_{d}.sp", .{std.time.timestamp()});
        try std.fs.cwd().writeFile(.{ .sub_path = path, .data = net });
        return path;
    }

    pub fn runSpiceSim(self: *FileIO, sim: Sim, path: []const u8) void {
        self.logger.info("SIM", "stub run {s} on {s}", .{ if (sim == .ngspice) "ngspice" else "xyce", path });
    }

    /// Determines netlist path from origin and logs simulation intent.
    /// TODO: spawn std.process.Child with argv = [ngspice/xyce, "-b", netlist_path]
    pub fn runSpiceSimAuto(self: *FileIO, sim: Sim) !void {
        const chn_path: []const u8 = switch (self.origin) {
            .chn_file => |p| p,
            else => return error.NoNetlist,
        };
        const base = std.fs.path.stem(chn_path);
        const dir = std.fs.path.dirname(chn_path) orelse ".";
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const netlist_path = std.fmt.bufPrint(&path_buf, "{s}/{s}.sp", .{ dir, base }) catch chn_path;
        _ = netlist_path;
        self.logger.info("SIM", "runSpiceSim stub — would run {s}", .{@tagName(sim)});
    }
};
