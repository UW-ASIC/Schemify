//! Global application state — owns the project config, open schematics,
//! viewport, selection, and undo/redo history for the lifetime of the process.

const std = @import("std");
const toml = @import("toml.zig");
const cmd = @import("command.zig");
const core = @import("core");
const Logger = core.Logger;
const PluginIF = @import("PluginIF");

// ── Re-exports from sub-modules ───────────────────────────────────────────────

pub const CT           = @import("types.zig").CT;
pub const Sim          = @import("types.zig").Sim;
pub const FileType     = @import("types.zig").FileType;
pub const Tool         = @import("types.zig").Tool;
pub const CommandFlags = @import("types.zig").CommandFlags;
pub const ToolState    = @import("types.zig").ToolState;

pub const FileIO       = @import("document.zig").FileIO;

// ── GUI-layer types (stay here — they ARE global GUI state) ───────────────────

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

/// GUI display state: view mode, command bar, plugin panels.
/// Dialog-local state (find query, props buffers, lib browser, etc.) lives
/// in the respective gui/*.zig State structs, not here.
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

pub const Clipboard = struct {
    instances: std.ArrayListUnmanaged(CT.Instance) = .{},
    wires: std.ArrayListUnmanaged(CT.Wire) = .{},

    pub fn clear(self: *Clipboard, alloc: std.mem.Allocator) void {
        for (self.instances.items) |inst| {
            alloc.free(inst.name);
            alloc.free(inst.symbol);
        }
        self.instances.clearRetainingCapacity();
        for (self.wires.items) |wire| {
            if (wire.net_name) |n| alloc.free(n);
        }
        self.wires.clearRetainingCapacity();
    }

    pub fn deinit(self: *Clipboard, alloc: std.mem.Allocator) void {
        self.clear(alloc);
        self.instances.deinit(alloc);
        self.wires.deinit(alloc);
    }
};

pub const AppState = struct {
    pub const HierEntry = struct { doc_idx: usize, instance_idx: usize };

    gpa: std.heap.GeneralPurposeAllocator(.{}),

    project_dir: []const u8,
    config: toml.ProjectConfig,

    schematics: std.ArrayListUnmanaged(*FileIO) = .{},
    active_idx: usize = 0,
    hierarchy_stack: std.ArrayListUnmanaged(HierEntry) = .{},
    closed_tabs: std.ArrayListUnmanaged([]const u8) = .{},

    history: cmd.History = .{},
    queue: cmd.CommandQueue = .{},

    view: Viewport = .{},
    selection: Selection = .{},
    tool: ToolState = .{},
    cmd_flags: CommandFlags = .{},
    gui: GuiState = .{},
    clipboard: Clipboard = .{},
    highlighted_nets: std.DynamicBitSetUnmanaged = .{},
    canvas_w: f32 = 800.0,
    canvas_h: f32 = 600.0,
    show_grid: bool = true,
    status_msg: []const u8 = "Ready",
    plugin_refresh_requested: bool = false,
    plugin_state: std.StringHashMapUnmanaged([]const u8) = .{},
    log: Logger = undefined,
    last_netlist: [8192]u8 = [_]u8{0} ** 8192,
    last_netlist_len: usize = 0,

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
        @import("state_ops.zig").seedDefaultPluginPanels(&self);
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
        self.hierarchy_stack.deinit(alloc);
        for (self.closed_tabs.items) |p| alloc.free(p);
        self.closed_tabs.deinit(alloc);
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
        self.clipboard.deinit(alloc);
        self.highlighted_nets.deinit(alloc);
        self.config.deinit();
        self.log.deinit();
        _ = self.gpa.deinit();
    }

    // ── Accessor ──────────────────────────────────────────────────────────────

    pub fn allocator(self: *AppState) std.mem.Allocator {
        return self.gpa.allocator();
    }

    // ── Forwarding wrappers (delegate to state_ops) ───────────────────────────
    // These keep existing call-sites working while we migrate callers to use
    // state_ops directly. New code should call state_ops.func(app, ...) directly.

    pub fn setStatus(self: *AppState, msg: []const u8) void {
        @import("state_ops.zig").setStatus(self, msg);
    }

    pub fn setStatusErr(self: *AppState, msg: []const u8) void {
        @import("state_ops.zig").setStatusErr(self, msg);
    }

    pub fn dumpLog(self: *AppState) void {
        @import("state_ops.zig").dumpLog(self);
    }

    pub fn active(self: *AppState) ?*FileIO {
        return @import("state_ops.zig").active(self);
    }

    pub fn openPath(self: *AppState, path: []const u8) !void {
        return @import("state_ops.zig").openPath(self, path);
    }

    pub fn newFile(self: *AppState, name: []const u8) !void {
        return @import("state_ops.zig").newFile(self, name);
    }

    pub fn saveActiveTo(self: *AppState, path: []const u8) !void {
        return @import("state_ops.zig").saveActiveTo(self, path);
    }

    pub fn selectAll(self: *AppState) void {
        @import("state_ops.zig").selectAll(self);
    }

    pub fn registerPluginPanel(
        self: *AppState,
        id: []const u8,
        title: []const u8,
        vim_cmd: []const u8,
        layout: PluginPanelLayout,
        keybind: ?u8,
    ) bool {
        return @import("state_ops.zig").registerPluginPanel(self, id, title, vim_cmd, layout, keybind);
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
        return @import("state_ops.zig").registerPluginPanelEx(self, id, title, vim_cmd, layout, keybind, draw_fn);
    }

    pub fn togglePluginPanelByVim(self: *AppState, vim_cmd: []const u8) bool {
        return @import("state_ops.zig").togglePluginPanelByVim(self, vim_cmd);
    }

    pub fn togglePluginPanelByKey(self: *AppState, key: u8) bool {
        return @import("state_ops.zig").togglePluginPanelByKey(self, key);
    }

    pub fn pluginPanels(self: *const AppState) []const PluginPanel {
        return @import("state_ops.zig").pluginPanels(self);
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// Module-level exported globals
//
// These are the process-wide singletons accessible from any file via
//   const state = @import("state.zig");
//   state.app.something
// without threading *AppState through every function signature.
//
// Initialised by appInit() in main.zig; valid for the entire process lifetime.
// ─────────────────────────────────────────────────────────────────────────────

/// Process-wide application state singleton. Call AppState.init() before use.
pub var app: AppState = undefined;
