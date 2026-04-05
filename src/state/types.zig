//! Shared data types for the state module.
//! Public within the module; externally visible only where re-exported by lib.zig.

const std = @import("std");
const core = @import("core");

// ── Aliases ──────────────────────────────────────────────────────────────────

pub const Point = [2]i32;

// ── Document origin ──────────────────────────────────────────────────────────

pub const Origin = union(enum) {
    unsaved,
    buffer,
    chn_file: []const u8,
};

// ── Viewport ─────────────────────────────────────────────────────────────────

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

// ── Selection ────────────────────────────────────────────────────────────────

pub const Selection = struct {
    instances: std.DynamicBitSetUnmanaged = .{},
    wires: std.DynamicBitSetUnmanaged = .{},

    fn hasAny(bits: *const std.DynamicBitSetUnmanaged) bool {
        if (bits.bit_length == 0) return false;
        var it = bits.iterator(.{});
        return it.next() != null;
    }

    pub fn clear(self: *Selection) void {
        if (self.instances.bit_length > 0) self.instances.unsetAll();
        if (self.wires.bit_length > 0) self.wires.unsetAll();
    }

    pub fn isEmpty(self: *const Selection) bool {
        return !hasAny(&self.instances) and !hasAny(&self.wires);
    }
};

// ── Clipboard ────────────────────────────────────────────────────────────────

pub const Clipboard = struct {
    instances: std.ArrayListUnmanaged(core.Instance) = .{},
    wires: std.ArrayListUnmanaged(core.Wire) = .{},

    pub fn clear(self: *Clipboard) void {
        self.instances.clearRetainingCapacity();
        self.wires.clearRetainingCapacity();
    }
};

// ── Closed-tab ring buffer ───────────────────────────────────────────────────

pub const ClosedTabs = struct {
    pub const CAP = 16;

    buf: [CAP][]const u8 = undefined,
    head: u8 = 0,
    len: u8 = 0,

    pub fn push(self: *ClosedTabs, a: std.mem.Allocator, path: []const u8) void {
        const owned = a.dupe(u8, path) catch return;
        if (self.len == CAP) a.free(self.buf[self.head]);
        self.buf[self.head] = owned;
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

// ── Tool / Command flags ─────────────────────────────────────────────────────

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

pub const CommandFlags = packed struct {
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
    _pad: u5 = 0,
    line_width: i16 = 1,
};

pub const ToolState = struct {
    // 4-byte aligned
    snap_size: f32 = 10.0,
    wire_start: ?[2]i32 = null,
    // 1-byte aligned
    active: Tool = .select,
    snap_to_grid: bool = true,
};

// ── Window / Dialog state ────────────────────────────────────────────────────

/// Window rectangle for floating windows. Layout-compatible with dvui.Rect.
/// Used in state module because dvui is not a state dependency.
pub const WinRect = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,
};

pub const CanvasState = struct {
    // Interaction state (from Renderer struct fields)
    dragging: bool = false,
    drag_last: [2]f32 = .{ 0, 0 },
    space_held: bool = false,
    last_click_time: f64 = 0,
    last_click_pos: [2]f32 = .{ 0, 0 },
};

pub const FileExplorerState = struct {
    selected_section: i32 = -1,
    selected_file: i32 = -1,
    scanned: bool = false,
    preview_name: []const u8 = "",
    win_rect: WinRect = .{ .x = 60, .y = 40, .w = 720, .h = 500 },
};

pub const LibraryBrowserState = struct {
    selected_prim: i32 = -1,
    win_rect: WinRect = .{ .x = 100, .y = 60, .w = 440, .h = 460 },
};

pub const FindDialogState = struct {
    is_open: bool = false,
    query_buf: [128]u8 = [_]u8{0} ** 128,
    query_len: usize = 0,
    result_count: usize = 0,
    win_rect: WinRect = .{ .x = 80, .y = 80, .w = 340, .h = 220 },
};

pub const PropsDialogState = struct {
    is_open: bool = false,
    view_only: bool = false,
    inst_idx: usize = 0,
    win_rect: WinRect = .{ .x = 120, .y = 100, .w = 480, .h = 380 },
};

pub const KeybindsDialogState = struct {
    open: bool = false,
    win_rect: WinRect = .{ .x = 100, .y = 80, .w = 520, .h = 420 },
};

pub const MarketplaceWinState = struct {
    win_rect: WinRect = .{ .x = 80, .y = 50, .w = 820, .h = 560 },
};

// ── GUI / Plugin types ───────────────────────────────────────────────────────

pub const GuiViewMode = enum { schematic, symbol };
pub const PluginPanelLayout = enum { overlay, left_sidebar, right_sidebar, bottom_bar };

pub const PluginKeybind = struct {
    // pointers (8-byte) first
    cmd_tag: []const u8,
    // 1-byte
    key: u8,
    mods: u8,
};

pub const PluginCommand = struct {
    // pointers (8-byte) first
    id: []const u8,
    display_name: []const u8,
    description: []const u8,
};

pub const PluginPanel = struct {
    // pointers (8-byte / slice = ptr+len) first
    id: []const u8 = "",
    title: []const u8 = "",
    vim_cmd: []const u8 = "",
    // 2-byte
    panel_id: u16 = 0,
    // 1-byte
    layout: PluginPanelLayout = .overlay,
    keybind: u8 = 0,
    visible: bool = false,
};

pub const CtxMenu = struct {
    // 4-byte
    inst_idx: i32 = -1,
    wire_idx: i32 = -1,
    // 1-byte
    open: bool = false,
};

pub const GuiState = struct {
    // 8-byte aligned (slices / arraylists contain pointer+len)
    plugin_panels: std.ArrayListUnmanaged(PluginPanel) = .{},
    plugin_keybinds: std.ArrayListUnmanaged(PluginKeybind) = .{},
    plugin_commands: std.ArrayListUnmanaged(PluginCommand) = .{},
    marketplace: MarketplaceState = .{},
    // GUI sub-states (per D-09)
    canvas: CanvasState = .{},
    file_explorer: FileExplorerState = .{},
    library_browser: LibraryBrowserState = .{},
    find_dialog: FindDialogState = .{},
    props_dialog: PropsDialogState = .{},
    keybinds_dialog: KeybindsDialogState = .{},
    marketplace_win: MarketplaceWinState = .{},
    // 4-byte aligned
    ctx_menu: CtxMenu = .{},
    command_len: usize = 0,
    // 1-byte arrays
    command_buf: [128]u8 = [_]u8{0} ** 128,
    key_to_panel: [256]i8 = [_]i8{-1} ** 256,
    // 1-byte
    view_mode: GuiViewMode = .schematic,
    keybinds_open: bool = false,
    command_mode: bool = false,
};

// ── Hierarchy ────────────────────────────────────────────────────────────────

pub const HierEntry = struct {
    doc_idx: usize,
    instance_idx: usize,
};

// ── Marketplace ──────────────────────────────────────────────────────────────

pub const MktStatus = enum(u8) { idle, fetching, done, failed };

pub const MarketplaceEntry = struct {
    // Fixed-size buffers — no heap allocation.  Ordered largest first.
    dl_linux: [200]u8 = [_]u8{0} ** 200,
    readme_url: [200]u8 = [_]u8{0} ** 200,
    repo_url: [200]u8 = [_]u8{0} ** 200,
    desc: [200]u8 = [_]u8{0} ** 200,
    tags: [96]u8 = [_]u8{0} ** 96,
    name: [64]u8 = [_]u8{0} ** 64,
    id: [48]u8 = [_]u8{0} ** 48,
    author: [48]u8 = [_]u8{0} ** 48,
    version: [24]u8 = [_]u8{0} ** 24,
    installed: bool = false,
};

pub const MarketplaceState = struct {
    // 8-byte aligned
    entries: std.ArrayListUnmanaged(MarketplaceEntry) = .{},
    readme_text: std.ArrayListUnmanaged(u8) = .{},
    // 2-byte
    selected: i16 = -1,
    // 1-byte arrays
    custom_url_buf: [512]u8 = [_]u8{0} ** 512,
    install_msg: [256]u8 = [_]u8{0} ** 256,
    search_buf: [128]u8 = [_]u8{0} ** 128,
    // 1-byte
    registry_status: MktStatus = .idle,
    readme_status: MktStatus = .idle,
    install_status: MktStatus = .idle,
    install_msg_len: u8 = 0,
    visible: bool = false,

    pub fn deinit(self: *MarketplaceState, alloc: std.mem.Allocator) void {
        self.entries.deinit(alloc);
        self.readme_text.deinit(alloc);
        self.* = .{};
    }
};
