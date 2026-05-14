const std = @import("std");
const core = @import("schematic");
const simulation = @import("simulation");
const toml = core.fileio.Toml;
const cmd = @import("commands");
const utility = @import("utility");

// NOTE: import path depends on build.zig module configuration.
// If plugins is a build module: @import("plugins")
// If relative: @import("../plugins/PluginHost.zig")
const settings = @import("settings");
pub const SettingsDialogState = settings.SettingsDialogState;
const plugin_mod = @import("plugins");
pub const PluginHost = plugin_mod.PluginHost.PluginHost;

// ── Aliases ──────────────────────────────────────────────────────────────────

pub const Point = [2]i32;
pub const Instance = core.types.Instance;
pub const Wire = core.types.Wire;
pub const ProjectConfig = toml.ProjectConfig;

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

    pub fn zoomIn(self: *Viewport) void { self.zoom = @min(50.0, self.zoom * 1.2); }
    pub fn zoomOut(self: *Viewport) void { self.zoom = @max(0.01, self.zoom / 1.2); }
    pub fn zoomReset(self: *Viewport) void { self.zoom = 1.0; self.pan = .{ 0, 0 }; }
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

    pub fn deinit(self: *Selection, a: std.mem.Allocator) void {
        self.instances.deinit(a);
        self.wires.deinit(a);
    }

    pub fn ensureCapacity(self: *Selection, a: std.mem.Allocator, inst_len: usize, wire_len: usize, fill: bool) !void {
        if (inst_len > self.instances.bit_length) try self.instances.resize(a, inst_len, fill);
        if (wire_len > self.wires.bit_length) try self.wires.resize(a, wire_len, fill);
    }
};

// ── Clipboard ────────────────────────────────────────────────────────────────

pub const Clipboard = struct {
    instances: std.ArrayListUnmanaged(Instance) = .{},
    wires: std.ArrayListUnmanaged(Wire) = .{},

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
    select, wire, move, pan, line, rect, polygon, arc, circle, text,

    pub fn label(self: Tool) []const u8 {
        return switch (self) {
            .select => "SELECT", .wire => "WIRE", .move => "MOVE", .pan => "PAN",
            .line => "LINE", .rect => "RECT", .polygon => "POLYGON",
            .arc => "ARC", .circle => "CIRCLE", .text => "TEXT",
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
    wire_start: ?[2]i32 = null, // 8-byte
    snap_size: f32 = 10.0,     // 4-byte
    active: Tool = .select,     // 1-byte
    snap_to_grid: bool = true,  // 1-byte
};

// ── Window / Dialog state ────────────────────────────────────────────────────

pub const WinRect = struct { x: f32 = 0, y: f32 = 0, w: f32 = 0, h: f32 = 0 };
pub const PanMode = enum { off, grab };

pub const TbOverlayCache = struct {
    pub const MAX_CACHED_WIRES = 512;
    hovered_idx: i32 = -1,
    cached_for_idx: i32 = -1,
    cached_wire_count: usize = 0,
    last_mouse_x: f32 = 0,
    last_mouse_y: f32 = 0,
    cached_x0: [MAX_CACHED_WIRES]i32 = [_]i32{0} ** MAX_CACHED_WIRES,
    cached_y0: [MAX_CACHED_WIRES]i32 = [_]i32{0} ** MAX_CACHED_WIRES,
    cached_x1: [MAX_CACHED_WIRES]i32 = [_]i32{0} ** MAX_CACHED_WIRES,
    cached_y1: [MAX_CACHED_WIRES]i32 = [_]i32{0} ** MAX_CACHED_WIRES,
    cache_arena: ?std.heap.ArenaAllocator = null,
};

pub const CanvasState = struct {
    // 8-byte
    last_click_time: f64 = 0,
    // 4-byte
    drag_last: [2]f32 = .{ 0, 0 },
    last_click_pos: [2]f32 = .{ 0, 0 },
    move_press_pixel: [2]f32 = .{ 0, 0 },
    move_start_world: [2]i32 = .{ 0, 0 },
    move_hit_idx: i32 = -1,
    rubber_band_start: [2]i32 = .{ 0, 0 },
    rubber_band_end: [2]i32 = .{ 0, 0 },
    cursor_world: [2]i32 = .{ 0, 0 },
    // 1-byte
    dragging: bool = false,
    drag_is_pan: bool = false,
    space_held: bool = false,
    space_drag_happened: bool = false,
    pan_mode: PanMode = .off,
    move_active: bool = false,
    rubber_band_active: bool = false,
    // Overlay
    tb_overlay: TbOverlayCache = .{},
};

// Consolidated dialog states — combine similar small structs.

pub const FileExplorerState = struct {
    preview_sch: ?*anyopaque = null,
    preview_name: []const u8 = "",
    preview_path: []const u8 = "",
    query_buf: [128]u8 = [_]u8{0} ** 128,
    query_len: usize = 0,
    win_rect: WinRect = .{ .x = 0, .y = 0, .w = 760, .h = 520 },
    selected_section: i32 = -1,
    selected_file: i32 = -1,
    scanned: bool = false,
};

pub const LibraryBrowserState = struct {
    selected_prim: i32 = -1,
    win_rect: WinRect = .{ .x = 100, .y = 60, .w = 440, .h = 460 },
};

/// Unified dialog state for small single-purpose dialogs.
pub const DialogState = struct {
    is_open: bool = false,
    win_rect: WinRect = .{},
};

pub const ImportDialogState = struct {
    pub const Format = enum(u8) { xschem, spice, virtuoso, unknown };

    is_open: bool = false,
    win_rect: WinRect = .{ .x = 100, .y = 80, .w = 520, .h = 300 },
    format: Format = .unknown,
    status_msg: []const u8 = "",
    path_buf: [512]u8 = [_]u8{0} ** 512,
    path_len: usize = 0,

    pub fn setPath(self: *ImportDialogState, path: []const u8) void {
        const len = @min(path.len, self.path_buf.len);
        @memcpy(self.path_buf[0..len], path[0..len]);
        self.path_len = len;
    }

    pub fn getPath(self: *const ImportDialogState) []const u8 {
        return self.path_buf[0..self.path_len];
    }
};

pub const FindDialogState = struct {
    is_open: bool = false,
    query_buf: [128]u8 = [_]u8{0} ** 128,
    query_len: usize = 0,
    result_count: usize = 0,
    win_rect: WinRect = .{ .x = 80, .y = 80, .w = 340, .h = 220 },
};

pub const PropsDialogState = struct {
    pub const MAX_PROPS = 16;
    pub const VAL_BUF_LEN = 128;
    pub const NAME_BUF_LEN = 64;

    is_open: bool = false,
    view_only: bool = false,
    initialized: bool = false,
    inst_idx: usize = 0,
    win_rect: WinRect = .{ .x = 120, .y = 100, .w = 520, .h = 460 },
    // Edit buffers — populated when the dialog opens
    name_buf: [NAME_BUF_LEN]u8 = [_]u8{0} ** NAME_BUF_LEN,
    name_len: usize = 0,
    prop_val_bufs: [MAX_PROPS][VAL_BUF_LEN]u8 = [_][VAL_BUF_LEN]u8{[_]u8{0} ** VAL_BUF_LEN} ** MAX_PROPS,
    prop_val_lens: [MAX_PROPS]usize = [_]usize{0} ** MAX_PROPS,
    prop_count: usize = 0,

    pub fn populateFrom(self: *PropsDialogState, inst: core.types.Instance, props: []const core.types.Property) void {
        // Instance name
        const nlen = @min(inst.name.len, NAME_BUF_LEN - 1);
        @memcpy(self.name_buf[0..nlen], inst.name[0..nlen]);
        self.name_buf[nlen] = 0;
        self.name_len = nlen;
        // Properties
        const start: usize = inst.prop_start;
        const count = @min(@as(usize, inst.prop_count), MAX_PROPS);
        self.prop_count = count;
        for (0..count) |i| {
            const pi = start + i;
            if (pi >= props.len) break;
            const vlen = @min(props[pi].val.len, VAL_BUF_LEN - 1);
            @memcpy(self.prop_val_bufs[i][0..vlen], props[pi].val[0..vlen]);
            self.prop_val_bufs[i][vlen] = 0;
            self.prop_val_lens[i] = vlen;
        }
        self.initialized = true;
    }
};

/// State for the New Primitive dialog.
pub const NewPrimDialogState = struct {
    pub const BUF_LEN = 64;
    pub const CODE_BUF_LEN = 2048;
    pub const PrimType = enum(u8) { behavioral, spice, digital };

    is_open: bool = false,
    win_rect: WinRect = .{ .x = 100, .y = 80, .w = 560, .h = 480 },
    prim_type: PrimType = .spice,
    name_buf: [BUF_LEN]u8 = [_]u8{0} ** BUF_LEN,
    name_len: usize = 0,
    pins_buf: [256]u8 = [_]u8{0} ** 256,
    pins_len: usize = 0,
    status_msg: []const u8 = "",
};

pub const SpiceCodeDialogState = struct {
    is_open: bool = false,
    buf: [8192]u8 = [_]u8{0} ** 8192,
    buf_len: usize = 0,
    win_rect: WinRect = .{ .x = 100, .y = 80, .w = 700, .h = 500 },
};

pub const OptimizerDialogState = struct {
    // 8-byte aligned
    win_rect: WinRect = .{ .x = 120, .y = 80, .w = 480, .h = 400 },
    status_msg: []const u8 = "",
    // 4-byte
    selected_inst: i32 = -1,
    target_gm_id_len: usize = 2,
    power_budget_len: usize = 2,
    bandwidth_len: usize = 2,
    // Fixed-size edit buffers
    target_gm_id_buf: [32]u8 = [_]u8{0} ** 32,
    power_budget_buf: [32]u8 = [_]u8{0} ** 32,
    bandwidth_buf: [32]u8 = [_]u8{0} ** 32,
    // 1-byte
    is_open: bool = false,

    pub fn init() OptimizerDialogState {
        var self = OptimizerDialogState{};
        // Default "15" for gm/Id target
        self.target_gm_id_buf[0] = '1';
        self.target_gm_id_buf[1] = '5';
        // Default "1m" for power budget
        self.power_budget_buf[0] = '1';
        self.power_budget_buf[1] = 'm';
        // Default "1M" for bandwidth
        self.bandwidth_buf[0] = '1';
        self.bandwidth_buf[1] = 'M';
        return self;
    }
};

// ── GUI / Plugin types ───────────────────────────────────────────────────────

pub const GuiViewMode = enum { schematic, symbol };
pub const PluginPanelLayout = enum { overlay, left_sidebar, right_sidebar, bottom_bar };
pub const PanelLoadState = enum { lazy_pending, loading, failed, loaded };

pub const PluginKeybind = struct {
    cmd_tag: []const u8,
    key: u8,
    mods: u8,
};

pub const PluginCommand = struct {
    id: []const u8,
    display_name: []const u8,
    description: []const u8,
};

pub const PluginPanelMeta = struct {
    id: []const u8 = "",
    title: []const u8 = "",
    vim_cmd: []const u8 = "",
};

pub const PluginPanelState = struct {
    panel_id: u16 = 0,
    layout: PluginPanelLayout = .overlay,
    keybind: u8 = 0,
    load_state: PanelLoadState = .loaded,
    visible: bool = false,
};

pub const CtxMenu = struct {
    pixel_x: f32 = 0,
    pixel_y: f32 = 0,
    inst_idx: i32 = -1,
    wire_idx: i32 = -1,
    open: bool = false,
};

pub const GuiStateHot = struct {
    canvas: CanvasState = .{},
    command_len: usize = 0,
    view_mode: GuiViewMode = .schematic,
    command_mode: bool = false,
};

pub const MultiPropsDialogState = struct {
    pub const MAX_COMMON_PROPS = 16;
    pub const KEY_BUF_LEN = 64;
    pub const VAL_BUF_LEN = 128;

    is_open: bool = false,
    win_rect: WinRect = .{ .x = 100, .y = 80, .w = 540, .h = 420 },
    /// Number of common property keys found across all selected instances.
    common_count: usize = 0,
    /// Property key names (copied at populate time).
    key_bufs: [MAX_COMMON_PROPS][KEY_BUF_LEN]u8 = [_][KEY_BUF_LEN]u8{[_]u8{0} ** KEY_BUF_LEN} ** MAX_COMMON_PROPS,
    /// Editable value buffers — initialized to "<mixed>" or the shared value.
    val_bufs: [MAX_COMMON_PROPS][VAL_BUF_LEN]u8 = [_][VAL_BUF_LEN]u8{[_]u8{0} ** VAL_BUF_LEN} ** MAX_COMMON_PROPS,
    /// Whether the property had the same value across all selected instances at open time.
    /// If false, the field was initialized with "" (user must type a value to apply).
    was_uniform: [MAX_COMMON_PROPS]bool = [_]bool{false} ** MAX_COMMON_PROPS,
    /// Original uniform value (for change detection).  Null-terminated in buffer.
    orig_vals: [MAX_COMMON_PROPS][VAL_BUF_LEN]u8 = [_][VAL_BUF_LEN]u8{[_]u8{0} ** VAL_BUF_LEN} ** MAX_COMMON_PROPS,

    /// Populate common keys from the intersection of properties on all selected instances.
    pub fn populateFrom(
        self: *MultiPropsDialogState,
        instances: anytype, // MultiArrayList slice type
        inst_len: usize,
        sel_bits: *const std.DynamicBitSetUnmanaged,
        props: []const core.types.Property,
    ) void {
        self.common_count = 0;
        // Reset buffers
        for (0..MAX_COMMON_PROPS) |i| {
            self.key_bufs[i] = [_]u8{0} ** KEY_BUF_LEN;
            self.val_bufs[i] = [_]u8{0} ** VAL_BUF_LEN;
            self.orig_vals[i] = [_]u8{0} ** VAL_BUF_LEN;
            self.was_uniform[i] = false;
        }

        // Collect all unique property keys from selected instances.
        // For each key, track whether all instances have it and whether values match.
        var key_count: usize = 0;
        var keys: [MAX_COMMON_PROPS][]const u8 = undefined;
        var first_vals: [MAX_COMMON_PROPS][]const u8 = undefined;
        var all_same: [MAX_COMMON_PROPS]bool = [_]bool{true} ** MAX_COMMON_PROPS;
        var all_have: [MAX_COMMON_PROPS]usize = [_]usize{0} ** MAX_COMMON_PROPS;
        var sel_count: usize = 0;

        var it = sel_bits.iterator(.{});
        while (it.next()) |idx| {
            if (idx >= inst_len) continue;
            sel_count += 1;
            const inst = instances.get(idx);
            const start: usize = inst.prop_start;
            const count: usize = @min(@as(usize, inst.prop_count), props.len -| start);
            for (0..count) |pi| {
                const prop = props[start + pi];
                // Find or insert key
                var ki: usize = 0;
                while (ki < key_count) : (ki += 1) {
                    if (std.mem.eql(u8, keys[ki], prop.key)) break;
                }
                if (ki == key_count) {
                    if (key_count >= MAX_COMMON_PROPS) continue;
                    keys[key_count] = prop.key;
                    first_vals[key_count] = prop.val;
                    all_have[key_count] = 1;
                    key_count += 1;
                } else {
                    all_have[ki] += 1;
                    if (!std.mem.eql(u8, first_vals[ki], prop.val)) {
                        all_same[ki] = false;
                    }
                }
            }
        }

        // Keep only keys that ALL selected instances share.
        var out: usize = 0;
        for (0..key_count) |ki| {
            if (all_have[ki] != sel_count) continue;
            if (out >= MAX_COMMON_PROPS) break;

            // Copy key
            const klen = @min(keys[ki].len, KEY_BUF_LEN - 1);
            @memcpy(self.key_bufs[out][0..klen], keys[ki][0..klen]);
            self.key_bufs[out][klen] = 0;

            // Copy value (or leave empty if mixed)
            if (all_same[ki]) {
                const vlen = @min(first_vals[ki].len, VAL_BUF_LEN - 1);
                @memcpy(self.val_bufs[out][0..vlen], first_vals[ki][0..vlen]);
                self.val_bufs[out][vlen] = 0;
                @memcpy(self.orig_vals[out][0..vlen], first_vals[ki][0..vlen]);
                self.orig_vals[out][vlen] = 0;
                self.was_uniform[out] = true;
            } else {
                self.was_uniform[out] = false;
                // Leave val_bufs as zeroed (empty) so user must type to apply
            }

            out += 1;
        }
        self.common_count = out;
    }
};

pub const GuiStateCold = struct {
    plugin_panels_meta: std.ArrayListUnmanaged(PluginPanelMeta) = .{},
    plugin_panels_state: std.ArrayListUnmanaged(PluginPanelState) = .{},
    plugin_keybinds: std.ArrayListUnmanaged(PluginKeybind) = .{},
    plugin_commands: std.ArrayListUnmanaged(PluginCommand) = .{},
    marketplace: MarketplaceState = .{},
    file_explorer: FileExplorerState = .{},
    library_browser: LibraryBrowserState = .{},
    find_dialog: FindDialogState = .{},
    props_dialog: PropsDialogState = .{},
    keybinds_dialog: DialogState = .{ .win_rect = .{ .x = 100, .y = 80, .w = 520, .h = 420 } },
    spice_code_dialog: SpiceCodeDialogState = .{},
    new_prim_dialog: NewPrimDialogState = .{},
    marketplace_win: DialogState = .{ .win_rect = .{ .x = 80, .y = 50, .w = 820, .h = 560 } },
    settings_dialog: settings.SettingsDialogState = .{},
    import_project: ImportDialogState = .{},
    multi_props_dialog: MultiPropsDialogState = .{},
    optimizer_dialog: OptimizerDialogState = OptimizerDialogState.init(),
    ctx_menu: CtxMenu = .{},
    command_buf: [128]u8 = [_]u8{0} ** 128,
    key_to_panel: [256]i8 = [_]i8{-1} ** 256,
    keybinds_open: bool = false,
};

pub const GuiState = struct {
    hot: GuiStateHot = .{},
    cold: GuiStateCold = .{},
};

// ── Hierarchy ────────────────────────────────────────────────────────────────

pub const HierEntry = struct { doc_idx: usize, instance_idx: usize };

// ── Startup plugin download ──────────────────────────────────────────────────

pub const StartupDownload = struct {
    active: bool = false,
    total: u32 = 0,
    done: u32 = 0,
    failed: bool = false,
    retry_requested: bool = false,
    error_msg: [256]u8 = [_]u8{0} ** 256,
    error_len: u8 = 0,
    current_name: [64]u8 = [_]u8{0} ** 64,
    current_name_len: u8 = 0,
};

// ── Marketplace ──────────────────────────────────────────────────────────────

pub const MktStatus = enum(u8) { idle, fetching, done, failed };

pub const MarketplaceEntry = struct {
    dl_linux: [200]u8 = [_]u8{0} ** 200,
    readme_url: [200]u8 = [_]u8{0} ** 200,
    logo_url: [200]u8 = [_]u8{0} ** 200,
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
    entries: std.ArrayListUnmanaged(MarketplaceEntry) = .{},
    readme_text: std.ArrayListUnmanaged(u8) = .{},
    selected: i16 = -1,
    custom_url_buf: [512]u8 = [_]u8{0} ** 512,
    install_msg: [256]u8 = [_]u8{0} ** 256,
    search_buf: [128]u8 = [_]u8{0} ** 128,
    registry_status: MktStatus = .idle,
    readme_status: MktStatus = .idle,
    install_status: MktStatus = .idle,
    install_msg_len: u8 = 0,
    visible: bool = false,

    pub fn deinit(self: *MarketplaceState, a: std.mem.Allocator) void {
        self.entries.deinit(a);
        self.readme_text.deinit(a);
        self.* = .{};
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// TbIndex — reverse index: cell name -> list of .chn_tb paths
// ═══════════════════════════════════════════════════════════════════════════

pub const TbIndex = struct {
    map: std.StringHashMapUnmanaged(std.ArrayListUnmanaged([]const u8)) = .{},
    alloc: std.mem.Allocator,

    pub fn init(a: std.mem.Allocator) TbIndex { return .{ .alloc = a }; }

    pub fn deinit(self: *TbIndex) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            self.alloc.free(entry.key_ptr.*);
            for (entry.value_ptr.items) |path| self.alloc.free(path);
            entry.value_ptr.deinit(self.alloc);
        }
        self.map.deinit(self.alloc);
    }

    pub fn indexTb(self: *TbIndex, tb_path: []const u8, sch: *const core.Schemify) void {
        const symbols = sch.instances.items(.symbol);
        for (symbols) |sym| {
            const cell = normalizeSymbol(sym);
            if (cell.len == 0) continue;
            const gop = self.map.getOrPut(self.alloc, cell) catch continue;
            if (!gop.found_existing) {
                const owned_key = self.alloc.dupe(u8, cell) catch { _ = self.map.remove(cell); continue; };
                gop.key_ptr.* = owned_key;
                gop.value_ptr.* = .{};
            }
            for (gop.value_ptr.items) |existing| {
                if (std.mem.eql(u8, existing, tb_path)) break;
            } else {
                const owned = self.alloc.dupe(u8, tb_path) catch continue;
                gop.value_ptr.append(self.alloc, owned) catch self.alloc.free(owned);
            }
        }
    }

    pub fn deindexTb(self: *TbIndex, tb_path: []const u8) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            var i: usize = 0;
            while (i < entry.value_ptr.items.len) {
                if (std.mem.eql(u8, entry.value_ptr.items[i], tb_path)) {
                    self.alloc.free(entry.value_ptr.swapRemove(i));
                } else i += 1;
            }
        }
    }

    pub fn testbenchesFor(self: *const TbIndex, cell_name: []const u8) []const []const u8 {
        const cell = normalizeSymbol(cell_name);
        if (self.map.get(cell)) |list| return list.items;
        return &.{};
    }

    pub fn normalizeSymbol(sym: []const u8) []const u8 {
        const base = if (std.mem.lastIndexOfScalar(u8, sym, '/')) |i| sym[i + 1 ..] else if (std.mem.lastIndexOfScalar(u8, sym, '\\')) |i| sym[i + 1 ..] else sym;
        const exts = [_][]const u8{ ".chn_prim", ".chn_tb", ".chn", ".sym" };
        inline for (exts) |ext| {
            if (std.mem.endsWith(u8, base, ext)) return base[0 .. base.len - ext.len];
        }
        return base;
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// Document — per-open-schematic state
// ═══════════════════════════════════════════════════════════════════════════

pub const SubcktSymbol = struct {
    pin_x: []i16,
    pin_y: []i16,
    pin_dir: []core.types.PinDir,
    pin_name: [][]const u8,
    box_w: i16,
    box_h: i16,
};
pub const SubcktCache = std.StringHashMapUnmanaged(SubcktSymbol);

pub const Document = struct {
    // 8-byte aligned
    alloc: std.mem.Allocator,
    sch: core.Schemify,
    name: []const u8,
    subckt_cache: SubcktCache = .{},
    subckt_arena: ?std.heap.ArenaAllocator = null,
    logger: ?*utility.Logger = null,
    origin: Origin = .unsaved,
    view: Viewport = .{},
    selection: Selection = .{},
    undo_history: cmd.handlers.History = .{},
    redo_history: cmd.handlers.History = .{},
    missing_symbols: std.StringArrayHashMapUnmanaged(void) = .{},
    sim_results: ?simulation.results.SimResult = null,
    // 1-byte
    dirty: bool = true,

    // ── Lifecycle ──

    pub fn open(a: std.mem.Allocator, logger: ?*utility.Logger, path: []const u8) !Document {
        const data = try utility.platform.fs.cwd().readFileAlloc(a, path, std.math.maxInt(usize));
        defer a.free(data);
        const s = core.Schemify.readFile(data, a, logger);
        const owned_name = try a.dupe(u8, path);
        errdefer a.free(owned_name);
        const owned_origin = try a.dupe(u8, path);
        return .{
            .alloc = a, .logger = logger, .name = owned_name, .sch = s,
            .origin = .{ .chn_file = owned_origin }, .dirty = false,
        };
    }

    pub fn deinit(self: *Document) void {
        self.clearSubcktCache();
        self.selection.deinit(self.alloc);
        for (self.missing_symbols.keys()) |k| self.alloc.free(k);
        self.missing_symbols.deinit(self.alloc);
        self.alloc.free(self.name);
        switch (self.origin) { .chn_file => |p| self.alloc.free(p), else => {} }
        self.sch.deinit(self.alloc);
    }

    pub fn addMissingSymbol(self: *Document, name: []const u8) void {
        if (name.len == 0 or self.missing_symbols.contains(name)) return;
        const owned = self.alloc.dupe(u8, name) catch return;
        self.missing_symbols.put(self.alloc, owned, {}) catch { self.alloc.free(owned); };
    }

    pub fn clearMissingSymbols(self: *Document) void {
        for (self.missing_symbols.keys()) |k| self.alloc.free(k);
        self.missing_symbols.clearRetainingCapacity();
    }

    pub fn subcktAllocator(self: *Document) std.mem.Allocator {
        if (self.subckt_arena == null) self.subckt_arena = std.heap.ArenaAllocator.init(self.alloc);
        return self.subckt_arena.?.allocator();
    }

    pub fn clearSubcktCache(self: *Document) void {
        if (self.subckt_arena) |*a| { a.deinit(); self.subckt_arena = null; }
        self.subckt_cache = .{};
    }

    // ── Netlist ──

    pub fn createNetlist(self: *Document) ![]u8 {
        return self.sch.emitSpice(self.alloc, null);
    }

    // ── Save ──

    pub fn saveAsChn(self: *Document, path: []const u8) !void {
        const out = self.sch.writeFile(self.alloc, self.logger) orelse return error.WriteFailed;
        try utility.platform.fs.cwd().writeFile(.{ .sub_path = path, .data = out });
        const new_origin = try self.alloc.dupe(u8, path);
        errdefer self.alloc.free(new_origin);
        const new_name = try self.alloc.dupe(u8, path);
        switch (self.origin) { .chn_file => |p| self.alloc.free(p), else => {} }
        self.alloc.free(self.name);
        self.origin = .{ .chn_file = new_origin };
        self.name = new_name;
        self.dirty = false;
    }

    // ── Instance manipulation ──

    pub fn placeSymbol(self: *Document, sym_path: []const u8, name: []const u8, pos: Point) !usize {
        // Generate unique instance name if the caller passed the raw kind name
        const kind = core.Schemify.symToKind(sym_path);
        const pfx: u8 = core.devices.Devices.prefix_lut[@intFromEnum(kind)];
        const pfx_ch: u8 = if (pfx != 0) pfx else 'X';
        var inst_name: []const u8 = name;
        var name_buf: [32]u8 = undefined;
        // If name doesn't start with the expected prefix, auto-generate one
        if (name.len == 0 or name[0] != pfx_ch) {
            var counter: u32 = 1;
            const names = self.sch.instances.items(.name);
            for (0..self.sch.instances.len) |ci| {
                if (names[ci].len > 0 and names[ci][0] == pfx_ch) counter += 1;
            }
            inst_name = std.fmt.bufPrint(&name_buf, "{c}{d}", .{ pfx_ch, counter }) catch "X1";
        }
        const idx = try self.sch.addInstance(self.alloc, inst_name, sym_path, pos[0], pos[1]);
        self.dirty = true;
        return idx;
    }

    pub fn deleteInstanceAt(self: *Document, idx: usize) void {
        if (idx < self.sch.instances.len) { self.sch.instances.swapRemove(idx); self.dirty = true; }
    }

    pub fn moveInstanceBy(self: *Document, idx: usize, dx: i32, dy: i32) void {
        if (idx < self.sch.instances.len) {
            self.sch.instances.items(.x)[idx] += dx;
            self.sch.instances.items(.y)[idx] += dy;
            self.dirty = true;
        }
    }

    // ── Wire manipulation ──

    pub fn addWireSeg(self: *Document, start: Point, end: Point, net_name: ?[]const u8) !void {
        const a = self.alloc;
        try self.sch.wires.append(a, .{ .x0 = start[0], .y0 = start[1], .x1 = end[0], .y1 = end[1], .net_name = net_name });
        self.dirty = true;
    }

    pub fn deleteWireAt(self: *Document, idx: usize) void {
        if (idx < self.sch.wires.len) { self.sch.wires.swapRemove(idx); self.dirty = true; }
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// AppState — top-level application state
// ═══════════════════════════════════════════════════════════════════════════

pub const AppState = struct {
    // Hot: read every frame — 8-byte aligned
    gpa: std.heap.GeneralPurposeAllocator(.{}),
    documents: std.ArrayListUnmanaged(Document) = .{},
    gui: GuiState = .{},
    tool: ToolState = .{},
    status_msg: []const u8 = "Ready",

    // Warm: project config + commands — 8-byte aligned
    project_dir: []const u8 = ".",
    config: ProjectConfig = undefined,
    queue: cmd.CommandQueue = .{},
    clipboard: Clipboard = .{},
    highlighted_nets: std.DynamicBitSetUnmanaged = .{},
    log: utility.Logger = undefined,

    // Cold — 8-byte aligned
    tb_index: TbIndex = undefined,
    hierarchy_stack: std.ArrayListUnmanaged(HierEntry) = .{},
    plugin_host: ?PluginHost = null,
    last_netlist: []u8 = &.{},

    // Hot: 4-byte
    canvas_w: f32 = 800.0,
    canvas_h: f32 = 600.0,
    active_idx: u32 = 0,

    // Warm: 4-byte
    cmd_flags: CommandFlags = .{},

    // Cold: 4-byte / 2-byte / 1-byte
    last_netlist_len: usize = 0,
    closed_tabs: ClosedTabs = .{},

    // Hot: 1-byte arrays
    status_buf: [256]u8 = [_]u8{0} ** 256,

    // Hot/Warm: 1-byte
    show_grid: bool = true,

    // Cold: startup plugin download overlay
    startup_dl: StartupDownload = .{},

    // Cold: 1-byte
    plugin_refresh_requested: bool = false,
    open_library_browser: bool = false,
    rescan_library_browser: bool = false,
    open_file_explorer: bool = false,

    // ── Lifecycle ──

    pub fn init(self: *AppState, project_dir: []const u8) void {
        self.* = .{ .gpa = .{}, .project_dir = project_dir };
        self.config = ProjectConfig.init(self.gpa.allocator());
        self.tb_index = TbIndex.init(self.gpa.allocator());
    }

    pub fn deinit(self: *AppState) void {
        const a = self.gpa.allocator();
        for (self.documents.items) |*doc| doc.deinit();
        self.documents.deinit(a);
        self.hierarchy_stack.deinit(a);
        self.gui.cold.plugin_panels_meta.deinit(a);
        self.gui.cold.plugin_panels_state.deinit(a);
        self.gui.cold.plugin_keybinds.deinit(a);
        self.gui.cold.plugin_commands.deinit(a);
        self.gui.cold.marketplace.deinit(a);
        self.clipboard.instances.deinit(a);
        self.clipboard.wires.deinit(a);
        self.highlighted_nets.deinit(a);
        if (self.last_netlist.len > 0) a.free(self.last_netlist);
        self.tb_index.deinit();
        self.config.deinit();
        self.queue.deinit(a);
        _ = self.gpa.deinit();
    }

    pub fn allocator(self: *AppState) std.mem.Allocator {
        return self.gpa.allocator();
    }

    // ── Config / Logger ──

    pub fn loadConfig(self: *AppState) !void {
        self.config = ProjectConfig.parseFromPath(self.allocator(), self.project_dir) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        self.buildTbIndex();
    }

    fn buildTbIndex(self: *AppState) void {
        const a = self.allocator();
        for (self.config.paths.chn_tb) |tb_path| {
            const data = utility.platform.fs.cwd().readFileAlloc(a, tb_path, std.math.maxInt(usize)) catch continue;
            defer a.free(data);
            var sch = core.Schemify.readFile(data, a, null);
            defer sch.deinit(a);
            self.tb_index.indexTb(tb_path, &sch);
        }
    }

    pub fn initLogger(self: *AppState) void { self.log = utility.Logger.init(.info); }

    // ── Document management ──

    pub fn active(self: *AppState) ?*Document {
        if (self.documents.items.len == 0) return null;
        const idx = @min(self.active_idx, @as(u32, @intCast(self.documents.items.len - 1)));
        return &self.documents.items[idx];
    }

    pub fn newFile(self: *AppState, name: []const u8) !void {
        const a = self.allocator();
        const owned_name = try a.dupe(u8, name);
        errdefer a.free(owned_name);
        try self.documents.append(a, .{ .alloc = a, .name = owned_name, .sch = core.Schemify{} });
        self.active_idx = @intCast(self.documents.items.len - 1);
    }

    pub fn openPath(self: *AppState, path: []const u8) !void {
        const a = self.allocator();
        const doc = try Document.open(a, &self.log, path);
        try self.documents.append(a, doc);
        self.active_idx = @intCast(self.documents.items.len - 1);
        const stored = &self.documents.items[self.documents.items.len - 1];
        if (stored.sch.stype == .testbench) {
            if (stored.origin == .chn_file) self.tb_index.indexTb(stored.origin.chn_file, &stored.sch);
        }
    }

    pub fn saveActiveTo(self: *AppState, path: []const u8) !void {
        const doc = self.active() orelse return;
        if (doc.sch.stype == .testbench) {
            if (doc.origin == .chn_file) self.tb_index.deindexTb(doc.origin.chn_file);
        }
        const out = doc.sch.writeFile(self.allocator(), &self.log) orelse return;
        try utility.platform.fs.cwd().writeFile(.{ .sub_path = path, .data = out });
        doc.origin = .{ .chn_file = path };
        doc.dirty = false;
        if (doc.sch.stype == .testbench) self.tb_index.indexTb(path, &doc.sch);
    }

    // ── Status ──

    pub fn setStatus(self: *AppState, msg: []const u8) void { self.status_msg = msg; }

    pub fn setStatusBuf(self: *AppState, msg: []const u8) void {
        const n = @min(msg.len, self.status_buf.len);
        @memcpy(self.status_buf[0..n], msg[0..n]);
        self.status_msg = self.status_buf[0..n];
    }

    pub const setStatusErr = setStatus;

    // ── Selection helpers ──

    pub fn selectAll(self: *AppState) void {
        const doc = self.active() orelse return;
        const a = self.allocator();
        doc.selection.instances.resize(a, doc.sch.instances.len, true) catch return;
        doc.selection.wires.resize(a, doc.sch.wires.len, true) catch return;
        doc.selection.instances.setAll();
        doc.selection.wires.setAll();
    }

    // ── Plugin helpers ──

    pub fn registerPluginPanelEx(self: *AppState, id: []const u8, title: []const u8, vim_cmd: []const u8, layout: PluginPanelLayout, keybind: u8, panel_id: u16) u16 {
        const a = self.allocator();
        self.gui.cold.plugin_panels_meta.append(a, .{ .id = id, .title = title, .vim_cmd = vim_cmd }) catch return 0;
        self.gui.cold.plugin_panels_state.append(a, .{ .layout = layout, .keybind = keybind, .panel_id = panel_id }) catch {
            _ = self.gui.cold.plugin_panels_meta.pop();
            return 0;
        };
        if (keybind > 0) self.gui.cold.key_to_panel[keybind] = @intCast(self.gui.cold.plugin_panels_state.items.len - 1);
        return panel_id;
    }

    pub fn registerPluginCommand(self: *AppState, id: []const u8, display_name: []const u8, description: []const u8) void {
        const a = self.allocator();
        self.gui.cold.plugin_commands.append(a, .{ .id = id, .display_name = display_name, .description = description }) catch {};
    }

};

// ── Global singleton ─────────────────────────────────────────────────────────

pub var app: AppState = undefined;

// ── Tests ────────────────────────────────────────────────────────────────────

test "Viewport zoom clamps" {
    var vp = Viewport{};
    vp.zoomIn();
    try std.testing.expect(vp.zoom > 1.0);
    vp.zoomReset();
    try std.testing.expectEqual(@as(f32, 1.0), vp.zoom);
    vp.zoomOut();
    try std.testing.expect(vp.zoom < 1.0);
    vp.zoom = 50.0;
    vp.zoomIn();
    try std.testing.expectEqual(@as(f32, 50.0), vp.zoom);
    vp.zoom = 0.01;
    vp.zoomOut();
    try std.testing.expectEqual(@as(f32, 0.01), vp.zoom);
}

test "Selection clear and isEmpty" {
    var sel = Selection{};
    try std.testing.expect(sel.isEmpty());
    sel.clear();
    try std.testing.expect(sel.isEmpty());
}

test "Clipboard clear" {
    var cb = Clipboard{};
    cb.clear();
    try std.testing.expectEqual(@as(usize, 0), cb.instances.items.len);
}

test "ClosedTabs ring buffer" {
    var tabs = ClosedTabs{};
    try std.testing.expectEqual(@as(?[]const u8, null), tabs.popLast());
    const a = std.testing.allocator;
    tabs.push(a, "a.chn");
    tabs.push(a, "b.chn");
    try std.testing.expectEqual(@as(u8, 2), tabs.len);
    const last = tabs.popLast().?;
    try std.testing.expectEqualStrings("b.chn", last);
    a.free(last);
    const first = tabs.popLast().?;
    try std.testing.expectEqualStrings("a.chn", first);
    a.free(first);
}

test "Tool label" {
    try std.testing.expectEqualStrings("SELECT", Tool.select.label());
    try std.testing.expectEqualStrings("WIRE", Tool.wire.label());
}

test "CtxMenu defaults" {
    const m = CtxMenu{};
    try std.testing.expect(!m.open);
    try std.testing.expectEqual(@as(i32, -1), m.inst_idx);
}

test "MarketplaceState deinit on fresh" {
    var ms = MarketplaceState{};
    ms.deinit(std.testing.allocator);
    try std.testing.expect(!ms.visible);
}

test "CommandFlags defaults" {
    const flags = CommandFlags{};
    try std.testing.expect(!flags.fullscreen);
    try std.testing.expect(flags.show_all_layers);
    try std.testing.expectEqual(@as(i16, 1), flags.line_width);
}

test "TbIndex normalizeSymbol" {
    try std.testing.expectEqualStrings("inv", TbIndex.normalizeSymbol("sky130_tests/inv.sym"));
    try std.testing.expectEqualStrings("buffer", TbIndex.normalizeSymbol("chn/buffer"));
    try std.testing.expectEqualStrings("nmos4", TbIndex.normalizeSymbol("nmos4"));
}
