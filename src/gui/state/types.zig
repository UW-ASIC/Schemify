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
    wire_start:   ?[2]i32 = null,  // 8-byte aligned (optional [2]i32)
    snap_size:    f32     = 10.0,  // 4-byte
    active:       Tool    = .select, // 1-byte enum
    snap_to_grid: bool    = true,  // 1-byte
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

/// Pan gesture modes.
/// * `.off`  — no special pan state.
/// * `.grab` — sticky "grab" mode entered via a tap of Space. Motion pans
///             without any mouse button held; a left-click exits.
pub const PanMode = enum { off, grab };

pub const CanvasState = struct {
    // 8-byte aligned
    last_click_time: f64 = 0,
    // 4-byte aligned
    drag_last: [2]f32 = .{ 0, 0 },
    last_click_pos: [2]f32 = .{ 0, 0 },
    /// Pixel position of the initial left-press on an already-selected
    /// instance. Used to measure the drag-threshold that promotes the
    /// press into a drag-to-move gesture.
    move_press_pixel: [2]f32 = .{ 0, 0 },
    /// World-space position of the primary hit instance at press time.
    /// The live drag mutates instance coordinates directly; this is kept
    /// for future undo/coalesce support.
    move_start_world: [2]i32 = .{ 0, 0 },
    /// Index of the instance hit on left-press (drag-to-move candidate).
    /// `-1` means "no potential move".
    move_hit_idx: i32 = -1,
    // 1-byte
    /// True while a left-button drag is in progress (pan or move).
    dragging: bool = false,
    /// True while the Space key is physically held down.
    space_held: bool = false,
    /// Set when a drag actually started during a Space hold. Used to
    /// distinguish "hold-and-drag to pan" (consumed) from "tap Space"
    /// (promotes into sticky grab mode on release).
    space_drag_happened: bool = false,
    /// Sticky pan mode — when `.grab`, mouse motion pans without any
    /// button held. Entered via a tap of Space, exited on left-click.
    pan_mode: PanMode = .off,
    /// True once the `.move_hit_idx` candidate has crossed the drag
    /// threshold and we're actively moving selected instances.
    move_active: bool = false,
};

pub const FileExplorerState = struct {
    // Pointer-sized first.
    /// Heap-allocated cached preview schematic, owned by the FileExplorer's
    /// preview arena. Stored as an opaque pointer so this struct does not
    /// need a stable definition of `core.Schemify` (FileExplorer.zig casts
    /// it back to `*core.Schemify`).
    preview_sch: ?*anyopaque = null,
    preview_name: []const u8 = "",
    preview_path: []const u8 = "",
    /// Fuzzy-search query buffer (UTF-8). `query_len` is the byte length of
    /// the live portion. Filled by FileExplorer key handling in lib.zig.
    query_buf: [128]u8 = [_]u8{0} ** 128,
    query_len: usize = 0,
    // 4-byte aligned.
    win_rect: WinRect = .{ .x = 0, .y = 0, .w = 760, .h = 520 },
    selected_section: i32 = -1,
    selected_file: i32 = -1,
    // 1-byte.
    scanned: bool = false,
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
pub const PanelLoadState = enum { lazy_pending, loading, failed, loaded };

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

/// Cold: string metadata, rarely accessed during frame render.
pub const PluginPanelMeta = struct {
    id: []const u8 = "",
    title: []const u8 = "",
    vim_cmd: []const u8 = "",
};

/// Hot: state checked every frame for visibility and layout routing.
pub const PluginPanelState = struct {
    // 2-byte
    panel_id: u16 = 0,
    // 1-byte
    layout: PluginPanelLayout = .overlay,
    keybind: u8 = 0,
    load_state: PanelLoadState = .loaded,
    visible: bool = false,
};

pub const CtxMenu = struct {
    // 4-byte
    /// Cursor anchor (physical pixels) captured when the menu was opened.
    pixel_x: f32 = 0,
    pixel_y: f32 = 0,
    inst_idx: i32 = -1,
    wire_idx: i32 = -1,
    // 1-byte
    open: bool = false,
};

pub const GuiStateHot = struct {
    canvas:       CanvasState = .{},
    command_mode: bool        = false,
    command_len:  usize       = 0,
    view_mode:    GuiViewMode = .schematic,
};

pub const GuiStateCold = struct {
    plugin_panels_meta:  std.ArrayListUnmanaged(PluginPanelMeta)  = .{},
    plugin_panels_state: std.ArrayListUnmanaged(PluginPanelState) = .{},
    plugin_keybinds: std.ArrayListUnmanaged(PluginKeybind) = .{},
    plugin_commands: std.ArrayListUnmanaged(PluginCommand) = .{},
    marketplace:     MarketplaceState    = .{},
    file_explorer:   FileExplorerState   = .{},
    library_browser: LibraryBrowserState = .{},
    find_dialog:     FindDialogState     = .{},
    props_dialog:    PropsDialogState    = .{},
    keybinds_dialog: KeybindsDialogState = .{},
    marketplace_win: MarketplaceWinState = .{},
    ctx_menu:        CtxMenu            = .{},
    command_buf:     [128]u8            = [_]u8{0} ** 128,
    key_to_panel:    [256]i8            = [_]i8{-1} ** 256,
    keybinds_open:   bool               = false,
};

pub const GuiState = struct {
    hot:  GuiStateHot  = .{},
    cold: GuiStateCold = .{},
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
