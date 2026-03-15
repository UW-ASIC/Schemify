//! Global application state — owns the project config, open schematics,
//! viewport, selection, and undo/redo history for the lifetime of the process.

const std = @import("std");
const builtin = @import("builtin");
const is_wasm = builtin.cpu.arch == .wasm32;
const toml = @import("Toml.zig");
const mkt = @import("Marketplace.zig");
const cmd = @import("commands");
const core = @import("core");
const Logger = core.Logger;

pub const CT = core.CT;
pub const Sim = core.Sim;
pub const FileType = core.FileType;
pub const Tool = core.Tool;
pub const CommandFlags = core.CommandFlags;
pub const ToolState = core.ToolState;

pub const ProjectConfig = toml.ProjectConfig;
pub const MarketplaceEntry = mkt.MarketplaceEntry;
pub const MktStatus = mkt.MktStatus;
pub const MarketplaceState = mkt.MarketplaceState;

// ── Document (was document.FileIO) ────────────────────────────────────────────
//
// One Document per open tab.  AppState owns a MultiArrayList(Document).
// All string slices inside are heap- or arena-owned by this struct.

pub const Document = struct {
    pub const Origin = union(enum) {
        unsaved,
        buffer,
        chn_file: []const u8,
        xschem_files: struct { sch: []const u8, sym: ?[]const u8 },
    };

    alloc: std.mem.Allocator,
    logger: *Logger,
    /// Display name for tabs / status bar.  Heap-owned.
    name: []const u8,
    sch: CT.Schematic,
    sym: ?CT.Symbol = null,
    origin: Origin = .unsaved,
    dirty: bool = true,

    pub fn initNew(alloc: std.mem.Allocator, logger: *Logger, name: []const u8) !Document {
        const name_owned = try alloc.dupe(u8, name);
        errdefer alloc.free(name_owned);
        return .{
            .alloc = alloc,
            .logger = logger,
            .name = name_owned,
            .sch = CT.Schematic.init(alloc, name),
            .origin = .unsaved,
            .dirty = true,
        };
    }

    pub fn initFromChn(alloc: std.mem.Allocator, logger: *Logger, path: []const u8) !Document {
        var doc = try initNew(alloc, logger, std.fs.path.stem(path));
        errdefer doc.deinit();
        doc.origin = .{ .chn_file = try alloc.dupe(u8, path) };
        doc.dirty = false;
        return doc;
    }

    pub fn initFromXSchem(alloc: std.mem.Allocator, logger: *Logger, sch_path: []const u8, sym_path: ?[]const u8) !Document {
        var doc = try initNew(alloc, logger, std.fs.path.stem(sch_path));
        errdefer doc.deinit();
        const sch_owned = try alloc.dupe(u8, sch_path);
        errdefer alloc.free(sch_owned);
        const sym_owned: ?[]const u8 = if (sym_path) |p| try alloc.dupe(u8, p) else null;
        doc.origin = .{ .xschem_files = .{ .sch = sch_owned, .sym = sym_owned } };
        doc.dirty = false;
        return doc;
    }

    pub fn deinit(self: *Document) void {
        self.alloc.free(self.name);
        switch (self.origin) {
            .chn_file => |p| self.alloc.free(p),
            .xschem_files => |xf| {
                self.alloc.free(xf.sch);
                if (xf.sym) |s| self.alloc.free(s);
            },
            .unsaved, .buffer => {},
        }
        self.sch.deinit();
        self.* = undefined;
    }

    pub fn isDirty(self: *const Document) bool {
        return self.dirty;
    }

    pub inline fn schematic(self: *Document) *CT.Schematic {
        return &self.sch;
    }

    pub inline fn symbol(self: *Document) ?*CT.Symbol {
        if (self.sym) |*s| return s;
        return null;
    }

    pub fn save(self: *Document) !void {
        switch (self.origin) {
            .chn_file => |p| try self.saveAsChn(p),
            else => {},
        }
    }

    pub fn saveAsChn(self: *Document, path: []const u8) !void {
        if (comptime is_wasm) return error.NotSupported;
        var out: std.ArrayListUnmanaged(u8) = .{};
        defer out.deinit(self.alloc);
        try out.writer(self.alloc).print("* Schemify placeholder CHN for {s}\n", .{self.name});
        try std.fs.cwd().writeFile(.{ .sub_path = path, .data = out.items });
        const path_owned = try self.alloc.dupe(u8, path);
        switch (self.origin) {
            .chn_file => |old| self.alloc.free(old),
            else => {},
        }
        self.origin = .{ .chn_file = path_owned };
        self.dirty = false;
    }

    pub fn placeSymbol(self: *Document, sym_path: []const u8, name: []const u8, pos: CT.Point, _: anytype) !u32 {
        const sa = self.sch.alloc();
        try self.sch.instances.append(sa, .{
            .name = sa.dupe(u8, name) catch name,
            .symbol = sa.dupe(u8, sym_path) catch sym_path,
            .pos = pos,
        });
        self.dirty = true;
        return @intCast(self.sch.instances.items.len - 1);
    }

    pub fn deleteInstanceAt(self: *Document, idx: usize) bool {
        if (idx >= self.sch.instances.items.len) return false;
        _ = self.sch.instances.orderedRemove(idx);
        self.dirty = true;
        return true;
    }

    pub fn moveInstanceBy(self: *Document, idx: usize, dx: i32, dy: i32) bool {
        if (idx >= self.sch.instances.items.len) return false;
        const inst = &self.sch.instances.items[idx];
        inst.pos[0] += dx;
        inst.pos[1] += dy;
        self.dirty = true;
        return true;
    }

    pub fn setProp(self: *Document, idx: usize, key: []const u8, val: []const u8) !void {
        if (idx >= self.sch.instances.items.len) return;
        const sa = self.sch.alloc();
        const inst = &self.sch.instances.items[idx];
        for (inst.props.items) |*p| {
            if (std.mem.eql(u8, p.key, key)) {
                p.val = sa.dupe(u8, val) catch val;
                self.dirty = true;
                return;
            }
        }
        try inst.props.append(sa, .{
            .key = sa.dupe(u8, key) catch key,
            .val = sa.dupe(u8, val) catch val,
        });
        self.dirty = true;
    }

    pub fn addWireSeg(self: *Document, p0: CT.Point, p1: CT.Point, net: ?[]const u8) !void {
        const sa = self.sch.alloc();
        try self.sch.wires.append(sa, .{
            .start = p0,
            .end = p1,
            .net_name = if (net) |n| sa.dupe(u8, n) catch n else null,
        });
        self.dirty = true;
    }

    pub fn deleteWireAt(self: *Document, idx: usize) bool {
        if (idx >= self.sch.wires.items.len) return false;
        _ = self.sch.wires.orderedRemove(idx);
        self.dirty = true;
        return true;
    }

    pub fn createNetlist(self: *Document, sim: Sim) ![]u8 {
        if (comptime is_wasm) return error.NotSupported;
        const mode: []const u8 = if (sim == .ngspice) "ngspice" else "xyce";
        const net = try std.fmt.allocPrint(self.alloc, "* placeholder {s} netlist for {s}\n.end\n", .{ mode, self.name });
        defer self.alloc.free(net);
        const path = try std.fmt.allocPrint(self.alloc, ".schemify_{d}.sp", .{std.time.timestamp()});
        try std.fs.cwd().writeFile(.{ .sub_path = path, .data = net });
        return path;
    }

    pub fn runSpiceSim(self: *Document, sim: Sim, path: []const u8) void {
        self.logger.info("SIM", "stub run {s} on {s}", .{ if (sim == .ngspice) "ngspice" else "xyce", path });
    }

    /// Display path (borrows from origin strings — no alloc).
    pub fn displayPath(self: *const Document) []const u8 {
        return switch (self.origin) {
            .chn_file => |p| p,
            .xschem_files => |xf| xf.sch,
            .unsaved, .buffer => self.name,
        };
    }
};

/// Backward-compat alias so external callers that name `FileIO` still compile.
pub const FileIO = Document;

// ── GUI / plugin types ────────────────────────────────────────────────────────

pub const GuiViewMode = enum { schematic, symbol };
pub const PluginPanelLayout = enum { overlay, left_sidebar, right_sidebar, bottom_bar };

pub const PluginKeybind = struct {
    key: u8,
    mods: u8,
    cmd_tag: []const u8,
};

/// A named command registered by a plugin.  All string slices are heap-owned.
/// Kept sorted by id so lookups use binary search (O(log n)).
pub const PluginCommand = struct {
    id: []const u8,
    display_name: []const u8,
    description: []const u8,
};

pub const PluginPanel = struct {
    id: []const u8 = "",
    title: []const u8 = "",
    vim_cmd: []const u8 = "",
    layout: PluginPanelLayout = .overlay,
    keybind: u8 = 0,
    visible: bool = false,
    panel_id: u16 = 0,
};

pub const CtxMenu = struct {
    open:     bool = false,
    inst_idx: i32  = -1,
    wire_idx: i32  = -1,
};

pub const GuiState = struct {
    ctx_menu: CtxMenu = .{},
    view_mode: GuiViewMode = .schematic,
    command_mode: bool = false,
    command_buf: [128]u8 = [_]u8{0} ** 128,
    command_len: usize = 0,
    plugin_panels: std.ArrayListUnmanaged(PluginPanel) = .{},
    key_to_panel: [256]i8 = [_]i8{-1} ** 256,
    marketplace: MarketplaceState = .{},
    plugin_keybinds: std.ArrayListUnmanaged(PluginKeybind) = .{},
    /// Sorted by `id` — use `bsearchPluginCommand` for lookup.
    plugin_commands: std.ArrayListUnmanaged(PluginCommand) = .{},
};

/// Simple clipboard holding copied instances and wires.
pub const Clipboard = struct {
    instances: std.ArrayListUnmanaged(CT.Instance) = .{},
    wires: std.ArrayListUnmanaged(CT.Wire) = .{},

    pub fn clear(self: *Clipboard) void {
        self.instances.clearRetainingCapacity();
        self.wires.clearRetainingCapacity();
    }

    pub fn deinit(self: *Clipboard, alloc: std.mem.Allocator) void {
        self.instances.deinit(alloc);
        self.wires.deinit(alloc);
    }
};

/// Ring buffer of recently closed tab paths (heap-owned strings).
/// CAP=16; oldest entry is freed on overflow so this never leaks.
pub const ClosedTabs = struct {
    const CAP = 16;
    buf: [CAP][]const u8 = undefined,
    head: u8 = 0,
    len: u8 = 0,

    pub fn push(self: *ClosedTabs, alloc: std.mem.Allocator, path: []const u8) void {
        const duped = alloc.dupe(u8, path) catch return;
        if (self.len == CAP) {
            alloc.free(self.buf[self.head]);
            self.buf[self.head] = duped;
            self.head = (self.head + 1) % CAP;
        } else {
            const slot: u8 = @intCast((self.head + self.len) % CAP);
            self.buf[slot] = duped;
            self.len += 1;
        }
    }

    pub fn popLast(self: *ClosedTabs) ?[]const u8 {
        if (self.len == 0) return null;
        self.len -= 1;
        const slot: u8 = @intCast((self.head + self.len) % CAP);
        return self.buf[slot];
    }

    pub fn deinit(self: *ClosedTabs, alloc: std.mem.Allocator) void {
        var i: u8 = 0;
        while (i < self.len) : (i += 1) {
            alloc.free(self.buf[@intCast((self.head + i) % CAP)]);
        }
        self.* = .{};
    }
};

// ── AppState ──────────────────────────────────────────────────────────────────

pub const AppState = struct {
    pub const HierEntry = struct { doc_idx: usize, instance_idx: usize };

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
            self.zoomReset();
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

    // ── Fields (hot → warm → cold) ────────────────────────────────────────────

    gpa: std.heap.GeneralPurposeAllocator(.{}),

    // Hot: read every frame by the renderer.
    documents: std.ArrayListUnmanaged(Document) = .{},
    active_idx: u32 = 0,
    view: Viewport = .{},
    canvas_w: f32 = 800.0,
    canvas_h: f32 = 600.0,
    show_grid: bool = true,
    status_msg: []const u8 = "Ready",
    selection: Selection = .{},
    tool: ToolState = .{},
    gui: GuiState = .{},

    // Warm: project config and command processing.
    project_dir: []const u8,
    config: toml.ProjectConfig,
    cmd_flags: CommandFlags = .{},
    history: cmd.History = .{},
    queue: cmd.CommandQueue = .{},
    clipboard: Clipboard = .{},
    highlighted_nets: std.DynamicBitSetUnmanaged = .{},

    // Cold: infrequently-accessed navigation and plugin state.
    hierarchy_stack: std.ArrayListUnmanaged(HierEntry) = .{},
    closed_tabs: ClosedTabs = .{},
    plugin_refresh_requested: bool = false,
    plugin_state: std.StringHashMapUnmanaged([]const u8) = .{},
    open_library_browser: bool = false,
    rescan_library_browser: bool = false,
    last_netlist: []u8 = &.{},
    last_netlist_len: usize = 0,

    log: Logger = undefined,

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
        errdefer self.config.deinit();
        return self;
    }

    pub fn initLogger(self: *AppState) void {
        self.log = Logger.init(.info);
    }

    pub fn deinit(self: *AppState) void {
        const alloc = self.gpa.allocator();

        for (self.documents.items) |*doc| doc.deinit();
        self.documents.deinit(alloc);

        self.hierarchy_stack.deinit(alloc);
        self.closed_tabs.deinit(alloc);

        self.history.deinit(alloc);
        self.queue.deinit(alloc);
        self.selection.deinit(alloc);

        for (self.gui.plugin_panels.items) |panel| {
            alloc.free(panel.id);
            alloc.free(panel.title);
            alloc.free(panel.vim_cmd);
        }
        self.gui.plugin_panels.deinit(alloc);
        self.gui.plugin_keybinds.deinit(alloc);
        for (self.gui.plugin_commands.items) |pc| {
            alloc.free(pc.id);
            alloc.free(pc.display_name);
            alloc.free(pc.description);
        }
        self.gui.plugin_commands.deinit(alloc);
        self.gui.marketplace.deinit(alloc);

        var ps_iter = self.plugin_state.iterator();
        while (ps_iter.next()) |entry| {
            alloc.free(entry.key_ptr.*);
            alloc.free(entry.value_ptr.*);
        }
        self.plugin_state.deinit(alloc);

        if (self.last_netlist.len > 0) alloc.free(self.last_netlist);
        self.clipboard.deinit(alloc);
        self.highlighted_nets.deinit(alloc);
        self.config.deinit();
        _ = self.gpa.deinit();

        self.* = undefined;
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
        if (comptime is_wasm) return;
        var i: usize = 0;
        while (i < self.log.len) : (i += 1) {
            const entry = &self.log.buf[(self.log.head + i) % Logger.RING_CAP];
            std.debug.print("[{s}] {s}: {s}\n", .{ entry.level.sym(), entry.src(), entry.msg() });
        }
        const err_count = self.log.countAt(.err);
        std.debug.print("[INF] LOG: entries={d} errors={d}\n", .{ self.log.len, err_count });
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    pub fn allocator(self: *AppState) std.mem.Allocator {
        return self.gpa.allocator();
    }

    pub fn active(self: *AppState) ?*Document {
        if (self.documents.items.len == 0) return null;
        return &self.documents.items[self.active_idx];
    }

    pub fn docCount(self: *const AppState) usize {
        return self.documents.items.len;
    }

    pub fn openPath(self: *AppState, path: []const u8) !void {
        const alloc = self.allocator();
        const ft = FileType.fromPath(path);
        const doc: Document = switch (ft) {
            .xschem_sch => try Document.initFromXSchem(alloc, &self.log, path, null),
            .chn, .chn_tb => try Document.initFromChn(alloc, &self.log, path),
            else => {
                self.setStatusErr("Unsupported file type");
                return error.InvalidFormat;
            },
        };
        try self.documents.append(alloc, doc);
        self.active_idx = @intCast(self.documents.items.len - 1);
        self.selection.clear();
        self.setStatus("Opened file");
    }

    pub fn newFile(self: *AppState, name: []const u8) !void {
        const alloc = self.allocator();
        const doc = try Document.initNew(alloc, &self.log, name);
        try self.documents.append(alloc, doc);
        self.active_idx = @intCast(self.documents.items.len - 1);
        self.selection.clear();
        self.setStatus("New file created");
    }

    pub fn saveActiveTo(self: *AppState, path: []const u8) !void {
        const doc = self.active() orelse {
            self.setStatusErr("No active document");
            return error.NoActiveDocument;
        };
        try doc.saveAsChn(path);
        self.setStatus("Saved file");
    }

    /// Select every instance and wire in the active schematic.
    pub fn selectAll(self: *AppState) void {
        const doc = self.active() orelse return;
        const sch = doc.schematic();
        const alloc = self.allocator();
        const n_inst = sch.instances.items.len;
        const n_wire = sch.wires.items.len;
        self.selection.instances.resize(alloc, n_inst, false) catch return;
        self.selection.wires.resize(alloc, n_wire, false) catch return;
        self.selection.instances.setRangeValue(.{ .start = 0, .end = n_inst }, true);
        self.selection.wires.setRangeValue(.{ .start = 0, .end = n_wire }, true);
    }

    pub fn registerPluginPanelEx(
        self: *AppState,
        id: []const u8,
        title: []const u8,
        vim_cmd: []const u8,
        layout: PluginPanelLayout,
        keybind: ?u8,
        panel_id: u16,
    ) bool {
        if (id.len == 0 or title.len == 0 or vim_cmd.len == 0) return false;
        const alloc = self.allocator();
        const lowered_keybind: u8 = if (keybind) |k| ascii_lower_table[k] else 0;

        for (self.gui.plugin_panels.items, 0..) |panel, i| {
            if (std.mem.eql(u8, panel.id, id)) {
                const p = &self.gui.plugin_panels.items[i];
                const new_title = alloc.dupe(u8, title) catch return false;
                const new_vim = alloc.dupe(u8, vim_cmd) catch {
                    alloc.free(new_title);
                    return false;
                };
                alloc.free(p.title);
                alloc.free(p.vim_cmd);
                p.title = new_title;
                p.vim_cmd = new_vim;
                p.layout = layout;
                p.keybind = lowered_keybind;
                p.panel_id = panel_id;
                rebuildKeyToPanelIndex(self);
                return true;
            }
        }

        const panel_id_str = alloc.dupe(u8, id) catch return false;
        errdefer alloc.free(panel_id_str);
        const panel_title = alloc.dupe(u8, title) catch return false;
        errdefer alloc.free(panel_title);
        const panel_vim = alloc.dupe(u8, vim_cmd) catch return false;
        errdefer alloc.free(panel_vim);

        self.gui.plugin_panels.append(alloc, .{
            .id = panel_id_str,
            .title = panel_title,
            .vim_cmd = panel_vim,
            .layout = layout,
            .keybind = lowered_keybind,
            .panel_id = panel_id,
        }) catch return false;
        rebuildKeyToPanelIndex(self);
        return true;
    }

    pub fn togglePluginPanelByVim(self: *AppState, vim_cmd: []const u8) bool {
        for (self.gui.plugin_panels.items) |*panel| {
            if (std.mem.eql(u8, panel.vim_cmd, vim_cmd)) {
                panel.visible = !panel.visible;
                self.status_msg = if (panel.visible) "Panel opened" else "Panel hidden";
                return true;
            }
        }
        return false;
    }

    pub fn togglePluginPanelByKey(self: *AppState, key: u8) bool {
        const idx = self.gui.key_to_panel[ascii_lower_table[key]];
        if (idx < 0) return false;
        const panel = &self.gui.plugin_panels.items[@intCast(idx)];
        panel.visible = !panel.visible;
        self.status_msg = if (panel.visible) "Panel opened" else "Panel hidden";
        return true;
    }

    pub fn pluginPanels(self: *const AppState) []const PluginPanel {
        return self.gui.plugin_panels.items;
    }

    pub fn registerPluginCommand(
        self: *AppState,
        id: []const u8,
        display_name: []const u8,
        description: []const u8,
    ) bool {
        if (id.len == 0) return false;
        const alloc = self.allocator();
        const items = self.gui.plugin_commands.items;

        const idx = bsearchPluginCommand(items, id);
        if (idx < items.len and std.mem.eql(u8, items[idx].id, id)) {
            const new_name = alloc.dupe(u8, display_name) catch return false;
            const new_desc = alloc.dupe(u8, description) catch {
                alloc.free(new_name);
                return false;
            };
            alloc.free(items[idx].display_name);
            alloc.free(items[idx].description);
            items[idx].display_name = new_name;
            items[idx].description = new_desc;
            return true;
        }

        const dup_id = alloc.dupe(u8, id) catch return false;
        errdefer alloc.free(dup_id);
        const dup_name = alloc.dupe(u8, display_name) catch return false;
        errdefer alloc.free(dup_name);
        const dup_desc = alloc.dupe(u8, description) catch return false;
        errdefer alloc.free(dup_desc);
        self.gui.plugin_commands.insert(alloc, idx, .{
            .id = dup_id,
            .display_name = dup_name,
            .description = dup_desc,
        }) catch return false;
        return true;
    }

    pub fn clearPluginCommands(self: *AppState) void {
        const alloc = self.allocator();
        for (self.gui.plugin_commands.items) |pc| {
            alloc.free(pc.id);
            alloc.free(pc.display_name);
            alloc.free(pc.description);
        }
        self.gui.plugin_commands.clearRetainingCapacity();
    }
};

// ── Private helpers ───────────────────────────────────────────────────────────

fn rebuildKeyToPanelIndex(self: *AppState) void {
    self.gui.key_to_panel = [_]i8{-1} ** 256;
    for (self.gui.plugin_panels.items, 0..) |panel, i| {
        if (panel.keybind != 0) {
            self.gui.key_to_panel[panel.keybind] = @intCast(i);
        }
    }
}

fn bsearchPluginCommand(items: []const PluginCommand, id: []const u8) usize {
    var lo: usize = 0;
    var hi: usize = items.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        switch (std.mem.order(u8, items[mid].id, id)) {
            .lt => lo = mid + 1,
            .gt => hi = mid,
            .eq => return mid,
        }
    }
    return lo;
}

const ascii_lower_table: [256]u8 = blk: {
    var t: [256]u8 = undefined;
    for (0..256) |i| {
        t[i] = if (i >= 'A' and i <= 'Z') @intCast(i + 32) else @intCast(i);
    }
    break :blk t;
};

test "Expose struct sizes" {
    const print = @import("std").debug.print;
    print("AppState: {d}B\n", .{@sizeOf(AppState)});
    print("Document: {d}B\n", .{@sizeOf(Document)});
}

test "ClosedTabs ring eviction" {
    var ct: ClosedTabs = .{};
    const alloc = std.testing.allocator;
    var i: usize = 0;
    while (i < ClosedTabs.CAP + 4) : (i += 1) {
        ct.push(alloc, "foo");
    }
    try std.testing.expectEqual(@as(u8, ClosedTabs.CAP), ct.len);
    ct.deinit(alloc);
}

test "registerPluginCommand sorted order" {
    var list: std.ArrayListUnmanaged(PluginCommand) = .{};
    defer {
        for (list.items) |pc| {
            std.testing.allocator.free(pc.id);
            std.testing.allocator.free(pc.display_name);
            std.testing.allocator.free(pc.description);
        }
        list.deinit(std.testing.allocator);
    }
    const alloc = std.testing.allocator;

    const ids = [_][]const u8{ "zzz", "aaa", "mmm" };
    for (ids) |id| {
        const idx = bsearchPluginCommand(list.items, id);
        try list.insert(alloc, idx, .{
            .id = try alloc.dupe(u8, id),
            .display_name = try alloc.dupe(u8, ""),
            .description = try alloc.dupe(u8, ""),
        });
    }
    try std.testing.expectEqualStrings("aaa", list.items[0].id);
    try std.testing.expectEqualStrings("mmm", list.items[1].id);
    try std.testing.expectEqualStrings("zzz", list.items[2].id);
}
