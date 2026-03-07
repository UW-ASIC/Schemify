//! Global application state — owns the project config, open schematics,
//! viewport, selection, and undo/redo history for the lifetime of the process.

const std = @import("std");
const toml = @import("toml.zig");
const cmd = @import("command.zig");
const core = @import("core");
const Logger = core.Logger;
const PluginIF = @import("PluginIF");

pub const Sim = enum { ngspice, xyce };

pub const CT = struct {
    pub const Point = struct { x: i32, y: i32 };
    pub const Transform = struct { rot: u2 = 0, flip: bool = false };
    pub const Wire = struct {
        start: Point,
        end: Point,
        net_name: ?[]const u8 = null,
    };
    pub const InstanceProp = struct {
        key: []const u8,
        val: []const u8,
    };
    pub const Instance = struct {
        name: []const u8,
        symbol: []const u8,
        pos: Point,
        xform: Transform = .{},
        props: std.ArrayListUnmanaged(InstanceProp) = .{},
    };
    pub const Schematic = struct {
        arena: std.heap.ArenaAllocator,
        name: []const u8,
        instances: std.ArrayListUnmanaged(Instance) = .{},
        wires: std.ArrayListUnmanaged(Wire) = .{},

        pub fn init(backing: std.mem.Allocator, name: []const u8) Schematic {
            var arena = std.heap.ArenaAllocator.init(backing);
            const a = arena.allocator();
            // Dupe the name BEFORE the struct literal so that the arena's node
            // list is populated before `arena` is copied into the return value.
            // If we put the dupe inside the struct literal after `.arena = arena`,
            // Zig evaluates `.arena = arena` first (copying the empty arena), then
            // runs a.dupe() against the local arena — the new node is never seen
            // by the returned arena and leaks.
            const name_copy = a.dupe(u8, name) catch "untitled";
            return .{
                .arena = arena,
                .name = name_copy,
            };
        }

        pub fn alloc(self: *Schematic) std.mem.Allocator {
            return self.arena.allocator();
        }

        pub fn deinit(self: *Schematic) void {
            self.instances.deinit(self.alloc());
            self.wires.deinit(self.alloc());
            self.arena.deinit();
        }
    };

    pub const ShapeTag = enum { line, rect, other };
    pub const Shape = struct {
        tag: ShapeTag,
        data: union(ShapeTag) {
            line: struct { start: Point, end: Point },
            rect: struct { min: Point, max: Point },
            other: void,
        },
    };
    pub const SymbolPin = struct { pos: Point };
    pub const Symbol = struct {
        shapes: std.ArrayListUnmanaged(Shape) = .{},
        pins: std.ArrayListUnmanaged(SymbolPin) = .{},
    };
};

pub const FileType = enum {
    xschem_sch,
    chn,
    chn_tb,
    unknown,

    pub fn fromPath(path: []const u8) FileType {
        if (std.mem.endsWith(u8, path, ".sch")) return .xschem_sch;
        if (std.mem.endsWith(u8, path, ".chn_tb")) return .chn_tb;
        if (std.mem.endsWith(u8, path, ".chn")) return .chn;
        return .unknown;
    }
};

pub const FileIO = struct {
    pub const Origin = union(enum) {
        unsaved,
        buffer,
        chn_file: []const u8,
        xschem_files: struct { sch: []const u8, sym: ?[]const u8 },
    };

    alloc: std.mem.Allocator,
    logger: *Logger,
    comp: struct { name: []const u8 },
    sch: CT.Schematic,
    sym: ?CT.Symbol = null,
    origin: Origin = .unsaved,
    dirty: bool = true,

    pub fn initNew(alloc: std.mem.Allocator, logger: *Logger, name: []const u8, _: bool) !FileIO {
        const name_owned = try alloc.dupe(u8, name);
        return .{
            .alloc = alloc,
            .logger = logger,
            .comp = .{ .name = name_owned },
            .sch = CT.Schematic.init(alloc, name),
            .origin = .unsaved,
            .dirty = true,
        };
    }

    pub fn initFromChn(alloc: std.mem.Allocator, logger: *Logger, path: []const u8) !FileIO {
        var fio = try initNew(alloc, logger, std.fs.path.stem(path), false);
        fio.origin = .{ .chn_file = try alloc.dupe(u8, path) };
        fio.dirty = false;
        return fio;
    }

    pub fn initFromXSchem(alloc: std.mem.Allocator, logger: *Logger, sch_path: []const u8, sym_path: ?[]const u8) !FileIO {
        var fio = try initNew(alloc, logger, std.fs.path.stem(sch_path), false);
        fio.origin = .{ .xschem_files = .{
            .sch = try alloc.dupe(u8, sch_path),
            .sym = if (sym_path) |p| try alloc.dupe(u8, p) else null,
        } };
        fio.dirty = false;
        return fio;
    }

    pub fn deinit(self: *FileIO) void {
        self.alloc.free(self.comp.name);
        switch (self.origin) {
            .chn_file       => |p|  self.alloc.free(p),
            .xschem_files   => |xf| {
                self.alloc.free(xf.sch);
                if (xf.sym) |s| self.alloc.free(s);
            },
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
        var out: std.ArrayListUnmanaged(u8) = .{};
        defer out.deinit(self.alloc);
        try out.writer(self.alloc).print("* Schemify placeholder CHN for {s}\n", .{self.comp.name});
        try std.fs.cwd().writeFile(.{ .sub_path = path, .data = out.items });
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
};

pub const Tool = enum {
    select,
    wire,
    move,
    pan,
    line,
    rect,
    polygon,
    arc,
    circle,
    text,
};

pub const CommandFlags = struct {
    fullscreen: bool = false,
    dark_mode: bool = false,
    fill_rects: bool = false,
    text_in_symbols: bool = false,
    symbol_details: bool = false,
    show_all_layers: bool = true,
    show_netlist: bool = false,
    crosshair: bool = false,
    wire_routing: bool = false,
    orthogonal_routing: bool = false,
    flat_netlist: bool = false,
    line_width: i32 = 1,
};

pub const ToolState = struct {
    active: Tool = .select,
    snap_to_grid: bool = true,
    snap_size: f32 = 10.0,
    wire_start: ?[2]i32 = null,

    pub fn label(self: *const ToolState) []const u8 {
        return switch (self.active) {
            .select => "SELECT",
            .wire => "WIRE",
            .move => "MOVE",
            .pan => "PAN",
            .line => "LINE",
            .rect => "RECT",
            .polygon => "POLYGON",
            .arc => "ARC",
            .circle => "CIRCLE",
            .text => "TEXT",
        };
    }
};

pub const GuiViewMode = enum { schematic, symbol };
pub const PluginPanelLayout = enum { overlay, left_sidebar, right_sidebar, bottom_bar };

pub const PanelDrawFn = *const fn (ctx: *const PluginIF.UiCtx) callconv(.c) void;

pub const PluginKeybind = struct {
    key: u8,
    mods: u8,
    cmd_tag: []const u8,
};

pub const PluginPanel = struct {
    id: []const u8 = "",
    title: []const u8 = "",
    vim_cmd: []const u8 = "",
    layout: PluginPanelLayout = .overlay,
    keybind: u8 = 0,
    visible: bool = false,
    draw_fn: ?PanelDrawFn = null,
};

// ── Plugin Marketplace types ───────────────────────────────────────────────

pub const MKT_ENTRY_MAX: usize = 32;

/// One entry in the remote plugin registry.
pub const MarketplaceEntry = struct {
    id:         [48]u8  = [_]u8{0} ** 48,
    name:       [64]u8  = [_]u8{0} ** 64,
    author:     [48]u8  = [_]u8{0} ** 48,
    version:    [24]u8  = [_]u8{0} ** 24,
    desc:       [200]u8 = [_]u8{0} ** 200,
    tags:       [96]u8  = [_]u8{0} ** 96,   // comma-separated
    repo_url:   [200]u8 = [_]u8{0} ** 200,
    readme_url: [200]u8 = [_]u8{0} ** 200,
    dl_linux:   [200]u8 = [_]u8{0} ** 200,
    installed:  bool = false,
};

/// 0 = idle, 1 = fetching, 2 = done, 3 = failed
pub const MktStatus = enum(u8) { idle, fetching, done, failed };

pub const MarketplaceState = struct {
    visible:          bool = false,
    entries:          [MKT_ENTRY_MAX]MarketplaceEntry = [_]MarketplaceEntry{.{}} ** MKT_ENTRY_MAX,
    entry_count:      u8 = 0,
    registry_status:  MktStatus = .idle,
    selected:         i16 = -1,
    readme_text:      [8192]u8 = [_]u8{0} ** 8192,
    readme_len:       u32 = 0,
    readme_status:    MktStatus = .idle,
    search_buf:       [128]u8 = [_]u8{0} ** 128,
    custom_url_buf:   [512]u8 = [_]u8{0} ** 512,
    install_msg:      [256]u8 = [_]u8{0} ** 256,
    install_msg_len:  u8 = 0,
    install_status:   MktStatus = .idle,
};

pub const GuiState = struct {
    view_mode: GuiViewMode = .schematic,
    command_mode: bool = false,
    command_buf: [256]u8 = [_]u8{0} ** 256,
    command_len: usize = 0,
    plugin_panels: std.ArrayListUnmanaged(PluginPanel) = .{},
    key_to_panel: [256]i16 = [_]i16{-1} ** 256,
    marketplace: MarketplaceState = .{},
    plugin_keybinds: std.ArrayListUnmanaged(PluginKeybind) = .{},
};

pub const AppState = struct {
    gpa: std.heap.GeneralPurposeAllocator(.{}),

    project_dir: []const u8,
    config: toml.ProjectConfig,

    schematics: std.ArrayListUnmanaged(*FileIO) = .{},
    active_idx: usize = 0,

    history: cmd.History = .{},
    queue: cmd.CommandQueue = .{},

    view: Viewport = .{},
    selection: Selection = .{},
    tool: ToolState = .{},
    cmd_flags: CommandFlags = .{},
    gui: GuiState = .{},
    show_grid: bool = true,
    status_msg: []const u8 = "Ready",
    plugin_refresh_requested: bool = false,
    plugin_state: std.StringHashMapUnmanaged([]const u8) = .{},
    log: Logger = undefined,

    // ── Viewport ──────────────────────────────────────────────────────────────

    pub const Viewport = struct {
        pan: [2]f32 = .{ 0, 0 },
        zoom: f32 = 1.0,

        pub fn zoomIn(self: *Viewport) void {
            self.zoom = @min(self.zoom * 1.25, 50.0);
        }

        pub fn zoomOut(self: *Viewport) void {
            self.zoom = @max(self.zoom / 1.25, 0.01);
        }

        pub fn zoomReset(self: *Viewport) void {
            self.zoom = 1.0;
            self.pan = .{ 0, 0 };
        }

        pub fn zoomFit(self: *Viewport) void {
            self.zoomReset(); // TODO: compute bounding box
        }

        pub fn panBy(self: *Viewport, dx: f32, dy: f32) void {
            self.pan[0] += dx / self.zoom;
            self.pan[1] += dy / self.zoom;
        }
    };

    // ── Selection ─────────────────────────────────────────────────────────────

    pub const Selection = struct {
        instances: std.DynamicBitSetUnmanaged = .{},
        wires: std.DynamicBitSetUnmanaged = .{},

        pub fn clear(self: *Selection) void {
            self.instances.unsetAll();
            self.wires.unsetAll();
        }

        pub fn isEmpty(self: *const Selection) bool {
            return self.instances.count() == 0 and self.wires.count() == 0;
        }

        pub fn deinit(self: *Selection, alloc: std.mem.Allocator) void {
            self.instances.deinit(alloc);
            self.wires.deinit(alloc);
        }
    };

    // ── Lifecycle ─────────────────────────────────────────────────────────────

    pub fn init(project_dir: []const u8) !AppState {
        var self: AppState = .{
            .gpa = .{},
            .project_dir = project_dir,
            .config = undefined,
        };
        self.config = try toml.ProjectConfig.parseFromPath(
            self.gpa.allocator(),
            project_dir,
        );
        self.seedDefaultPluginPanels();
        return self;
    }

    pub fn initLogger(self: *AppState) void {
        self.log = Logger.init(self.gpa.allocator(), .info);
    }

    pub fn deinit(self: *AppState) void {
        const alloc = self.gpa.allocator();
        for (self.schematics.items) |fio| {
            fio.deinit();
            alloc.destroy(fio);
        }
        self.schematics.deinit(alloc);
        self.history.deinit(alloc);
        self.selection.deinit(alloc);
        for (self.gui.plugin_panels.items) |panel| {
            alloc.free(panel.id);
            alloc.free(panel.title);
            alloc.free(panel.vim_cmd);
        }
        self.gui.plugin_panels.deinit(alloc);
        self.gui.plugin_keybinds.deinit(alloc);
        var ps_iter = self.plugin_state.iterator();
        while (ps_iter.next()) |entry| {
            alloc.free(entry.key_ptr.*);
            alloc.free(entry.value_ptr.*);
        }
        self.plugin_state.deinit(alloc);
        self.config.deinit();
        self.log.deinit();
        _ = self.gpa.deinit();
    }

    pub fn setStatus(self: *AppState, msg: []const u8) void {
        self.status_msg = msg;
        self.log.info("STATUS", "{s}", .{msg});
    }

    pub fn setStatusErr(self: *AppState, msg: []const u8) void {
        self.status_msg = msg;
        self.log.err("STATUS", "{s}", .{msg});
    }

    pub fn dumpLog(self: *AppState) void {
        const entries = self.log.entries();
        for (entries) |entry| {
            std.debug.print("[{s}] {s}: {s}\n", .{ entry.level.sym(), entry.src, entry.msg });
        }
        const err_count = self.log.countAt(.err);
        std.debug.print("[INF] LOG: entries={d} errors={d}\n", .{ entries.len, err_count });
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    pub fn allocator(self: *AppState) std.mem.Allocator {
        return self.gpa.allocator();
    }

    pub fn active(self: *AppState) ?*FileIO {
        if (self.schematics.items.len == 0) return null;
        return self.schematics.items[self.active_idx];
    }

    pub fn openPath(self: *AppState, path: []const u8) !void {
        const alloc = self.allocator();
        const fio = try alloc.create(FileIO);
        errdefer alloc.destroy(fio);

        const ft = FileType.fromPath(path);
        fio.* = switch (ft) {
            .xschem_sch => try FileIO.initFromXSchem(alloc, &self.log, path, null),
            .chn, .chn_tb => try FileIO.initFromChn(alloc, &self.log, path),
            else => {
                self.setStatusErr("Unsupported file type");
                return error.InvalidFormat;
            },
        };

        try self.schematics.append(alloc, fio);
        self.active_idx = self.schematics.items.len - 1;
        self.selection.clear();
        self.setStatus("Opened file");
    }

    pub fn newFile(self: *AppState, name: []const u8) !void {
        const alloc = self.allocator();
        const fio = try alloc.create(FileIO);
        errdefer alloc.destroy(fio);
        fio.* = try FileIO.initNew(alloc, &self.log, name, false);
        try self.schematics.append(alloc, fio);
        self.active_idx = self.schematics.items.len - 1;
        self.selection.clear();
        self.setStatus("New file created");
    }

    pub fn saveActiveTo(self: *AppState, path: []const u8) !void {
        const fio = self.active() orelse {
            self.setStatusErr("No active document");
            return error.NoActiveDocument;
        };
        try fio.saveAsChn(path);
        self.setStatus("Saved file");
    }

    /// Select every instance and wire in the active schematic.
    pub fn selectAll(self: *AppState) void {
        const fio = self.active() orelse return;
        const sch = fio.schematic();
        const alloc = self.allocator();
        self.selection.instances.resize(alloc, sch.instances.items.len, false) catch return;
        self.selection.wires.resize(alloc, sch.wires.items.len, false) catch return;
        self.selection.instances.setRangeValue(.{ .start = 0, .end = sch.instances.items.len }, true);
        self.selection.wires.setRangeValue(.{ .start = 0, .end = sch.wires.items.len }, true);
    }

    pub fn registerPluginPanel(
        self: *AppState,
        id: []const u8,
        title: []const u8,
        vim_cmd: []const u8,
        layout: PluginPanelLayout,
        keybind: ?u8,
    ) bool {
        return self.registerPluginPanelEx(id, title, vim_cmd, layout, keybind, null);
    }

    pub fn registerPluginPanelEx(
        self: *AppState,
        id: []const u8,
        title: []const u8,
        vim_cmd: []const u8,
        layout: PluginPanelLayout,
        keybind: ?u8,
        draw_fn: ?PanelDrawFn,
    ) bool {
        if (id.len == 0 or title.len == 0 or vim_cmd.len == 0) return false;
        const alloc = self.allocator();

        if (self.findPluginPanelById(id)) |existing| {
            var panel = &self.gui.plugin_panels.items[existing];
            const new_title = alloc.dupe(u8, title) catch return false;
            const new_vim = alloc.dupe(u8, vim_cmd) catch {
                alloc.free(new_title);
                return false;
            };
            alloc.free(panel.title);
            alloc.free(panel.vim_cmd);
            panel.title = new_title;
            panel.vim_cmd = new_vim;
            panel.layout = layout;
            panel.keybind = if (keybind) |k| asciiLower(k) else 0;
            panel.draw_fn = draw_fn;
            self.rebuildPluginPanelIndexes();
            return true;
        }

        const panel_id = alloc.dupe(u8, id) catch return false;
        errdefer alloc.free(panel_id);
        const panel_title = alloc.dupe(u8, title) catch return false;
        errdefer alloc.free(panel_title);
        const panel_vim = alloc.dupe(u8, vim_cmd) catch return false;
        errdefer alloc.free(panel_vim);

        self.gui.plugin_panels.append(alloc, .{
            .id = panel_id,
            .title = panel_title,
            .vim_cmd = panel_vim,
            .layout = layout,
            .keybind = if (keybind) |k| asciiLower(k) else 0,
            .draw_fn = draw_fn,
        }) catch return false;
        self.rebuildPluginPanelIndexes();
        return true;
    }

    pub fn togglePluginPanelByVim(self: *AppState, vim_cmd: []const u8) bool {
        for (self.gui.plugin_panels.items, 0..) |panel, i| {
            if (std.mem.eql(u8, panel.vim_cmd, vim_cmd)) {
                self.gui.plugin_panels.items[i].visible = !self.gui.plugin_panels.items[i].visible;
                self.status_msg = if (self.gui.plugin_panels.items[i].visible) "Panel opened" else "Panel hidden";
                return true;
            }
        }
        return false;
    }

    pub fn togglePluginPanelByKey(self: *AppState, key: u8) bool {
        const lowered = asciiLower(key);
        const idx = self.gui.key_to_panel[lowered];
        if (idx >= 0) {
            const i: usize = @intCast(idx);
            self.gui.plugin_panels.items[i].visible = !self.gui.plugin_panels.items[i].visible;
            self.status_msg = if (self.gui.plugin_panels.items[i].visible) "Panel opened" else "Panel hidden";
            return true;
        }
        return false;
    }

    /// Dynamic registry of plugin panels (name + draw callback link).
    pub fn pluginPanels(self: *const AppState) []const PluginPanel {
        return self.gui.plugin_panels.items;
    }

    fn findPluginPanelById(self: *const AppState, id: []const u8) ?usize {
        for (self.gui.plugin_panels.items, 0..) |panel, i| {
            if (std.mem.eql(u8, panel.id, id)) return i;
        }
        return null;
    }

    fn seedDefaultPluginPanels(self: *AppState) void {
        _ = self;
    }

    fn rebuildPluginPanelIndexes(self: *AppState) void {
        self.gui.key_to_panel = [_]i16{-1} ** 256;

        for (self.gui.plugin_panels.items, 0..) |panel, i| {
            if (panel.keybind != 0) {
                self.gui.key_to_panel[panel.keybind] = @intCast(i);
            }
        }
    }

    fn asciiLower(ch: u8) u8 {
        if (ch >= 'A' and ch <= 'Z') return ch + 32;
        return ch;
    }
};
