//! Global application state — pure data, no implementation logic.
//! Methods that operate on these types live in their respective modules.

const std = @import("std");
const toml = @import("toml.zig");
const cmd = @import("commands");
const core = @import("core");
const utility = @import("utility");

// ── Re-exports ───────────────────────────────────────────────────────────────

pub const ProjectConfig = toml.ProjectConfig;
pub const Point = [2]i32;
pub const Instance = core.Instance;
pub const Wire = core.Wire;
pub const Sim = core.SpiceBackend;

// ── Global ───────────────────────────────────────────────────────────────────

pub var app: AppState = undefined;

// ── Document ─────────────────────────────────────────────────────────────────

pub const Origin = union(enum) {
    unsaved,
    buffer,
    chn_file: []const u8,
};

pub const Document = struct {
    alloc: std.mem.Allocator,
    logger: ?*utility.Logger = null,
    name: []const u8,
    sch: core.Schemify,
    origin: Origin = .unsaved,
    dirty: bool = true,

    pub fn open(a: std.mem.Allocator, logger: ?*utility.Logger, path: []const u8) !Document {
        const data = try utility.Vfs.readAlloc(a, path);
        const s = core.Schemify.readFile(data, a, logger);
        return .{
            .alloc = a,
            .logger = logger,
            .name = path,
            .sch = s,
            .origin = .{ .chn_file = path },
            .dirty = false,
        };
    }

    pub fn deinit(self: *Document) void {
        self.sch.deinit();
    }

    pub fn createNetlist(self: *Document, sim: Sim) ![]u8 {
        return self.sch.emitSpice(self.alloc, sim, core.pdk, .sim);
    }

    pub fn setProp(self: *Document, idx: usize, key: []const u8, val: []const u8) !void {
        _ = self;
        _ = idx;
        _ = key;
        _ = val;
        // TODO: implement property mutation
    }

    pub fn placeSymbol(self: *Document, sym_path: []const u8, name: []const u8, pos: Point, opts: anytype) !usize {
        _ = opts;
        const a = self.sch.alloc();
        try self.sch.instances.append(a, .{ .name = name, .symbol = sym_path, .x = pos[0], .y = pos[1] });
        self.dirty = true;
        return self.sch.instances.len - 1;
    }

    pub fn saveAsChn(self: *Document, path: []const u8) !void {
        const out = self.sch.writeFile(self.alloc, self.logger) orelse return error.WriteFailed;
        try utility.Vfs.writeAll(path, out);
        self.origin = .{ .chn_file = path };
        self.dirty = false;
    }

    pub fn runSpiceSim(self: *Document, sim: Sim, netlist_path: []u8) void {
        _ = self;
        _ = sim;
        _ = netlist_path;
        // TODO: wire up SpiceIF bridge
    }

    pub fn deleteInstanceAt(self: *Document, idx: usize) void {
        if (idx < self.sch.instances.len) {
            self.sch.instances.swapRemove(idx);
            self.dirty = true;
        }
    }

    pub fn moveInstanceBy(self: *Document, idx: usize, dx: i32, dy: i32) void {
        if (idx < self.sch.instances.len) {
            self.sch.instances.items(.x)[idx] += dx;
            self.sch.instances.items(.y)[idx] += dy;
            self.dirty = true;
        }
    }

    pub fn addWireSeg(self: *Document, start: Point, end: Point, net_name: ?[]const u8) !void {
        const a = self.sch.alloc();
        try self.sch.wires.append(a, .{
            .x0 = start[0], .y0 = start[1],
            .x1 = end[0], .y1 = end[1],
            .net_name = net_name,
        });
        self.dirty = true;
    }

    pub fn deleteWireAt(self: *Document, idx: usize) void {
        if (idx < self.sch.wires.len) {
            self.sch.wires.swapRemove(idx);
            self.dirty = true;
        }
    }
};

// ── Viewport / Selection ─────────────────────────────────────────────────────

pub const Viewport = struct {
    pan: [2]f32 = .{ 0, 0 },
    zoom: f32 = 1.0,

    pub fn zoomIn(self: *Viewport) void {
        self.zoom = @min(50.0, self.zoom * 1.2);
    }

    pub fn zoomOut(self: *Viewport) void {
        self.zoom = @max(0.01, self.zoom / 1.2);
    }

    pub fn zoomReset(self: *Viewport) void {
        self.zoom = 1.0;
        self.pan = .{ 0, 0 };
    }
};

pub const Selection = struct {
    instances: std.DynamicBitSetUnmanaged = .{},
    wires: std.DynamicBitSetUnmanaged = .{},

    pub fn clear(self: *Selection) void {
        if (self.instances.bit_length > 0) self.instances.unsetAll();
        if (self.wires.bit_length > 0) self.wires.unsetAll();
    }

    pub fn isEmpty(self: *const Selection) bool {
        if (self.instances.bit_length > 0) {
            var it = self.instances.iterator(.{});
            if (it.next() != null) return false;
        }
        if (self.wires.bit_length > 0) {
            var it = self.wires.iterator(.{});
            if (it.next() != null) return false;
        }
        return true;
    }
};

// ── Clipboard / Tab history ──────────────────────────────────────────────────

pub const Clipboard = struct {
    instances: std.ArrayListUnmanaged(core.Instance) = .{},
    wires: std.ArrayListUnmanaged(core.Wire) = .{},

    pub fn clear(self: *Clipboard) void {
        self.instances.clearRetainingCapacity();
        self.wires.clearRetainingCapacity();
    }
};

pub const ClosedTabs = struct {
    pub const CAP = 16;
    buf: [CAP][]const u8 = undefined,
    head: u8 = 0,
    len: u8 = 0,

    pub fn push(self: *ClosedTabs, _: std.mem.Allocator, path: []const u8) void {
        self.buf[self.head] = path;
        self.head = (self.head + 1) % CAP;
        if (self.len < CAP) self.len += 1;
    }

    pub fn popLast(self: *ClosedTabs) ?[]const u8 {
        if (self.len == 0) return null;
        self.head = if (self.head == 0) CAP - 1 else self.head - 1;
        self.len -= 1;
        return self.buf[self.head];
    }
};

// ── Tool / Command flags ────────────────────────────────────────────────────

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

    pub fn label(self: Tool) []const u8 {
        return switch (self) {
            .select  => "SELECT",
            .wire    => "WIRE",
            .move    => "MOVE",
            .pan     => "PAN",
            .line    => "LINE",
            .rect    => "RECT",
            .polygon => "POLYGON",
            .arc     => "ARC",
            .circle  => "CIRCLE",
            .text    => "TEXT",
        };
    }
};

pub const CommandFlags = packed struct {
    fullscreen:         bool = false,
    dark_mode:          bool = false,
    fill_rects:         bool = false,
    text_in_symbols:    bool = false,
    symbol_details:     bool = false,
    show_all_layers:    bool = true,
    show_netlist:       bool = false,
    crosshair:          bool = false,
    wire_routing:       bool = false,
    orthogonal_routing: bool = false,
    flat_netlist:       bool = false,
    _pad:               u5  = 0,
    line_width:         i16 = 1,
};

pub const ToolState = struct {
    active:       Tool    = .select,
    snap_to_grid: bool    = true,
    snap_size:    f32     = 10.0,
    wire_start:   ?[2]i32 = null,
};

// ── GUI / Plugin types ───────────────────────────────────────────────────────

pub const GuiViewMode = enum { schematic, symbol };
pub const PluginPanelLayout = enum { overlay, left_sidebar, right_sidebar, bottom_bar };

pub const PluginKeybind = struct {
    key: u8,
    mods: u8,
    cmd_tag: []const u8,
};

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
    open: bool = false,
    inst_idx: i32 = -1,
    wire_idx: i32 = -1,
};

pub const GuiState = struct {
    ctx_menu: CtxMenu = .{},
    keybinds_open: bool = false,
    view_mode: GuiViewMode = .schematic,
    command_mode: bool = false,
    command_buf: [128]u8 = [_]u8{0} ** 128,
    command_len: usize = 0,
    plugin_panels: std.ArrayListUnmanaged(PluginPanel) = .{},
    key_to_panel: [256]i8 = [_]i8{-1} ** 256,
    marketplace: MarketplaceState = .{},
    plugin_keybinds: std.ArrayListUnmanaged(PluginKeybind) = .{},
    plugin_commands: std.ArrayListUnmanaged(PluginCommand) = .{},
};

// ── AppState ─────────────────────────────────────────────────────────────────

pub const HierEntry = struct { doc_idx: usize, instance_idx: usize };

pub const AppState = struct {
    gpa: std.heap.GeneralPurposeAllocator(.{}),

    // Hot: read every frame.
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
    project_dir: []const u8 = ".",
    config: ProjectConfig = undefined,
    cmd_flags: CommandFlags = .{},
    history: cmd.History = .{},
    queue: cmd.CommandQueue = .{},
    clipboard: Clipboard = .{},
    highlighted_nets: std.DynamicBitSetUnmanaged = .{},

    // Cold: infrequently-accessed.
    hierarchy_stack: std.ArrayListUnmanaged(HierEntry) = .{},
    closed_tabs: ClosedTabs = .{},
    plugin_refresh_requested: bool = false,
    plugin_state: std.StringHashMapUnmanaged([]const u8) = .{},
    plugin_runtime_ptr: ?*anyopaque = null,
    open_library_browser: bool = false,
    rescan_library_browser: bool = false,
    open_file_explorer: bool = false,
    last_netlist: []u8 = &.{},
    last_netlist_len: usize = 0,

    log: utility.Logger = undefined,

    // ── Lifecycle ────────────────────────────────────────────────────────── //

    pub fn init(project_dir: []const u8) AppState {
        var self = AppState{ .gpa = .{}, .project_dir = project_dir };
        self.config = ProjectConfig.init(self.gpa.allocator());
        return self;
    }

    pub fn deinit(self: *AppState) void {
        const a = self.gpa.allocator();
        for (self.documents.items) |*doc| doc.deinit();
        self.documents.deinit(a);
        self.hierarchy_stack.deinit(a);
        self.gui.plugin_panels.deinit(a);
        self.gui.plugin_keybinds.deinit(a);
        self.gui.plugin_commands.deinit(a);
        self.gui.marketplace.deinit(a);
        self.clipboard.instances.deinit(a);
        self.clipboard.wires.deinit(a);
        self.selection.instances.deinit(a);
        self.selection.wires.deinit(a);
        self.highlighted_nets.deinit(a);
        self.plugin_state.deinit(a);
        _ = self.gpa.deinit();
    }

    pub fn allocator(self: *AppState) std.mem.Allocator {
        return self.gpa.allocator();
    }

    // ── Config / Logger ──────────────────────────────────────────────────── //

    pub fn loadConfig(self: *AppState) !void {
        self.config = ProjectConfig.parseFromPath(self.allocator(), self.project_dir) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
    }

    pub fn initLogger(self: *AppState) void {
        self.log = utility.Logger.init(.info);
    }

    // ── Document management ──────────────────────────────────────────────── //

    pub fn active(self: *AppState) ?*Document {
        if (self.documents.items.len == 0) return null;
        const idx = @min(self.active_idx, @as(u32, @intCast(self.documents.items.len - 1)));
        return &self.documents.items[idx];
    }

    pub fn newFile(self: *AppState, name: []const u8) !void {
        const a = self.allocator();
        try self.documents.append(a, .{
            .alloc = a,
            .name = name,
            .sch = core.Schemify.init(a),
        });
        self.active_idx = @intCast(self.documents.items.len - 1);
    }

    pub fn openPath(self: *AppState, path: []const u8) !void {
        const a = self.allocator();
        const doc = try Document.open(a, &self.log, path);
        try self.documents.append(a, doc);
        self.active_idx = @intCast(self.documents.items.len - 1);
    }

    pub fn saveActiveTo(self: *AppState, path: []const u8) !void {
        const doc = self.active() orelse return;
        const out = doc.sch.writeFile(self.allocator(), &self.log) orelse return;
        try utility.Vfs.writeAll(path, out);
        doc.origin = .{ .chn_file = path };
        doc.dirty = false;
    }

    // ── Status ───────────────────────────────────────────────────────────── //

    pub fn setStatus(self: *AppState, msg: []const u8) void {
        self.status_msg = msg;
    }

    pub fn setStatusErr(self: *AppState, msg: []const u8) void {
        self.status_msg = msg;
    }

    // ── Selection helpers ────────────────────────────────────────────────── //

    pub fn selectAll(self: *AppState) void {
        const doc = self.active() orelse return;
        const a = self.allocator();
        self.selection.instances.resize(a, doc.sch.instances.len, true) catch return;
        self.selection.wires.resize(a, doc.sch.wires.len, true) catch return;
        self.selection.instances.setAll();
        self.selection.wires.setAll();
    }

    // ── Plugin helpers ───────────────────────────────────────────────────── //

    pub fn clearPluginCommands(self: *AppState) void {
        self.gui.plugin_commands.clearRetainingCapacity();
        self.gui.plugin_keybinds.clearRetainingCapacity();
        self.gui.key_to_panel = [_]i8{-1} ** 256;
    }

    pub fn registerPluginPanelEx(self: *AppState, id: []const u8, title: []const u8, vim_cmd: []const u8, layout: PluginPanelLayout, keybind: u8, panel_id: u16) u16 {
        const a = self.allocator();
        const new_panel = PluginPanel{ .id = id, .title = title, .vim_cmd = vim_cmd, .layout = layout, .keybind = keybind, .panel_id = panel_id };
        self.gui.plugin_panels.append(a, new_panel) catch return 0;
        if (keybind > 0) self.gui.key_to_panel[keybind] = @intCast(self.gui.plugin_panels.items.len - 1);
        return panel_id;
    }

    pub fn registerPluginCommand(self: *AppState, id: []const u8, display_name: []const u8, description: []const u8) void {
        const a = self.allocator();
        self.gui.plugin_commands.append(a, .{
            .id = id,
            .display_name = display_name,
            .description = description,
        }) catch {};
    }
};

/// One entry in the remote plugin registry.
/// All string fields are fixed-size buffers — no heap allocation needed.
pub const MarketplaceEntry = struct {
    id: [48]u8 = [_]u8{0} ** 48,
    name: [64]u8 = [_]u8{0} ** 64,
    author: [48]u8 = [_]u8{0} ** 48,
    version: [24]u8 = [_]u8{0} ** 24,
    desc: [200]u8 = [_]u8{0} ** 200,
    tags: [96]u8 = [_]u8{0} ** 96,
    repo_url: [200]u8 = [_]u8{0} ** 200,
    readme_url: [200]u8 = [_]u8{0} ** 200,
    dl_linux: [200]u8 = [_]u8{0} ** 200,
    installed: bool = false,
};

pub const MktStatus = enum(u8) { idle, fetching, done, failed };

pub const MarketplaceState = struct {
    visible: bool = false,
    entries: std.ArrayListUnmanaged(MarketplaceEntry) = .{},
    registry_status: MktStatus = .idle,
    selected: i16 = -1,
    readme_text: std.ArrayListUnmanaged(u8) = .{},
    readme_status: MktStatus = .idle,
    search_buf: [128]u8 = [_]u8{0} ** 128,
    custom_url_buf: [512]u8 = [_]u8{0} ** 512,
    install_msg: [256]u8 = [_]u8{0} ** 256,
    install_msg_len: u8 = 0,
    install_status: MktStatus = .idle,

    pub fn deinit(self: *MarketplaceState, alloc: std.mem.Allocator) void {
        self.entries.deinit(alloc);
        self.readme_text.deinit(alloc);
        self.* = .{};
    }
};
