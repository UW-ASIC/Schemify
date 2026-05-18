const std = @import("std");
const core = @import("schematic");
const simulation = @import("simulation");
const toml = core.fileio.Toml;
const cmd = @import("commands");
const utility = @import("utility");

pub const DiscoveredDevice = simulation.optimizer.DiscoveredDevice;
pub const DiscoveredMeasurement = simulation.optimizer.DiscoveredMeasurement;

pub const SettingsDialogTab = enum { theme, keybinds };

pub const SettingsDialogState = struct {
    is_open: bool = false,
    active_tab: SettingsDialogTab = .theme,
    selected_preset: i16 = -1,
    json_edit_buf: [4096]u8 = [_]u8{0} ** 4096,
    json_edit_len: usize = 0,
    status_msg: [128]u8 = [_]u8{0} ** 128,
    status_len: u8 = 0,
    dirty: bool = false,
    editing_theme_json: bool = false,
};
const plugin_mod = @import("plugins");

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
    lines: std.DynamicBitSetUnmanaged = .{},
    rects: std.DynamicBitSetUnmanaged = .{},
    circles: std.DynamicBitSetUnmanaged = .{},
    arcs: std.DynamicBitSetUnmanaged = .{},
    texts: std.DynamicBitSetUnmanaged = .{},

    fn hasAny(bits: *const std.DynamicBitSetUnmanaged) bool {
        if (bits.bit_length == 0) return false;
        var it = bits.iterator(.{});
        return it.next() != null;
    }

    fn clearBits(bits: *std.DynamicBitSetUnmanaged) void {
        if (bits.bit_length > 0) bits.unsetAll();
    }

    pub fn clear(self: *Selection) void {
        clearBits(&self.instances);
        clearBits(&self.wires);
        clearBits(&self.lines);
        clearBits(&self.rects);
        clearBits(&self.circles);
        clearBits(&self.arcs);
        clearBits(&self.texts);
    }

    pub fn isEmpty(self: *const Selection) bool {
        return !hasAny(&self.instances) and !hasAny(&self.wires) and
            !hasAny(&self.lines) and !hasAny(&self.rects) and
            !hasAny(&self.circles) and !hasAny(&self.arcs) and !hasAny(&self.texts);
    }

    pub fn deinit(self: *Selection, a: std.mem.Allocator) void {
        self.instances.deinit(a);
        self.wires.deinit(a);
        self.lines.deinit(a);
        self.rects.deinit(a);
        self.circles.deinit(a);
        self.arcs.deinit(a);
        self.texts.deinit(a);
    }

    fn ensureBits(bits: *std.DynamicBitSetUnmanaged, a: std.mem.Allocator, len: usize, fill: bool) !void {
        if (len > bits.bit_length) try bits.resize(a, len, fill);
    }

    pub fn ensureCapacity(self: *Selection, a: std.mem.Allocator, inst_len: usize, wire_len: usize, fill: bool) !void {
        try ensureBits(&self.instances, a, inst_len, fill);
        try ensureBits(&self.wires, a, wire_len, fill);
    }

    pub fn ensureShapeCapacity(self: *Selection, a: std.mem.Allocator, sch: anytype, fill: bool) !void {
        try ensureBits(&self.lines, a, sch.lines.len, fill);
        try ensureBits(&self.rects, a, sch.rects.len, fill);
        try ensureBits(&self.circles, a, sch.circles.len, fill);
        try ensureBits(&self.arcs, a, sch.arcs.len, fill);
        try ensureBits(&self.texts, a, sch.texts.len, fill);
    }

    pub fn isInstSelected(self: *const Selection, i: usize) bool {
        return i < self.instances.bit_length and self.instances.isSet(i);
    }

    pub fn isWireSelected(self: *const Selection, i: usize) bool {
        return i < self.wires.bit_length and self.wires.isSet(i);
    }

    pub fn isBitSet(bits: *const std.DynamicBitSetUnmanaged, i: usize) bool {
        return i < bits.bit_length and bits.isSet(i);
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
    dark_mode: bool = true,
    fill_rects: bool = false,
    text_in_symbols: bool = false,
    symbol_details: bool = false,
    show_all_layers: bool = true,
    show_netlist: bool = true,
    crosshair: bool = false,
    wire_routing: bool = false,
    orthogonal_routing: bool = false,
    flat_netlist: bool = false,
    _pad: u5 = 0,
    line_width: i16 = 1,
};

pub const Placement = struct {
    kind_name: [32]u8 = [_]u8{0} ** 32,
    kind_len: u8 = 0,
    rot: u2 = 0,
    flip: bool = false,

    pub fn fromName(name: []const u8) Placement {
        var p = Placement{};
        const n = @min(name.len, p.kind_name.len);
        @memcpy(p.kind_name[0..n], name[0..n]);
        p.kind_len = @intCast(n);
        return p;
    }

    pub fn kindSlice(self: *const Placement) []const u8 {
        return self.kind_name[0..self.kind_len];
    }
};

// ── Drawing tool in-progress state ───────────────────────────────────────────

pub const ArcStep = enum(u2) { center, radius_start, sweep };

pub const DrawState = struct {
    /// First point for line/rect/circle, center for arc.
    first_point: ?[2]i32 = null,
    /// Arc: after placing center, stores radius+start angle point.
    arc_second: ?[2]i32 = null,
    /// Arc placement step (3-click sequence).
    arc_step: ArcStep = .center,
    /// Polygon vertices accumulated so far.
    polygon_points: [64][2]i32 = undefined,
    polygon_len: u8 = 0,
    /// Text tool: position where text will be placed.
    text_pos: ?[2]i32 = null,
    /// Text input buffer (inline, no allocation).
    text_buf: [128]u8 = [_]u8{0} ** 128,
    text_len: u8 = 0,
    /// Whether text input is actively capturing keystrokes.
    text_input_active: bool = false,

    pub fn reset(self: *DrawState) void {
        self.first_point = null;
        self.arc_second = null;
        self.arc_step = .center;
        self.polygon_len = 0;
        self.text_pos = null;
        self.text_len = 0;
        self.text_input_active = false;
    }
};

pub const ToolState = struct {
    wire_start: ?[2]i32 = null,
    placement: ?Placement = null,
    draw: DrawState = .{},
    snap_size: f32 = 10.0,
    active: Tool = .select,
    snap_to_grid: bool = true,
    bus_mode: bool = false,

    pub fn resetMode(self: *ToolState) void {
        self.wire_start = null;
        self.placement = null;
        self.draw.reset();
        self.active = .select;
    }
};

// ── Window / Dialog state ────────────────────────────────────────────────────

pub const WinRect = struct { x: f32 = 0, y: f32 = 0, w: f32 = 0, h: f32 = 0 };
pub const PanMode = enum { off, grab };

pub const TbOverlayCache = struct {
    hovered_idx: i32 = -1,
    cached_for_idx: i32 = -1,
    last_mouse_x: f32 = 0,
    last_mouse_y: f32 = 0,

    cached_wires: ?CachedWires = null,
    cache_arena: ?std.heap.ArenaAllocator = null,

    ghost: ?GhostOverlay = null,
    ghost_arena: ?std.heap.ArenaAllocator = null,

    pub const CachedWires = struct {
        x0: []i32,
        y0: []i32,
        x1: []i32,
        y1: []i32,
        count: usize,
    };

    pub const GhostOverlay = struct {
        generation: u32 = 0,
        sim_generation: u32 = 0,
        wire_x0: []i32,
        wire_y0: []i32,
        wire_x1: []i32,
        wire_y1: []i32,
        wire_count: usize,
        inst_x: []i32,
        inst_y: []i32,
        inst_kind: []u8,
        inst_count: usize,
    };
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

pub const FileSortOrder = enum(u8) {
    name_asc,
    name_desc,
    ext_asc,
    dirs_first,
};

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
    sort_order: FileSortOrder = .name_asc,
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

    pub fn populateFrom(self: *PropsDialogState, inst: core.types.Instance, props: []const core.types.Property, pool: *const core.string_pool.StringPool) void {
        // Instance name
        const name = pool.get(inst.name);
        const nlen = @min(name.len, NAME_BUF_LEN - 1);
        @memcpy(self.name_buf[0..nlen], name[0..nlen]);
        self.name_buf[nlen] = 0;
        self.name_len = nlen;
        // Properties
        const start: usize = inst.prop_start;
        const count = @min(@as(usize, inst.prop_count), MAX_PROPS);
        self.prop_count = count;
        for (0..count) |i| {
            const pi = start + i;
            if (pi >= props.len) break;
            const val = pool.get(props[pi].val);
            const vlen = @min(val.len, VAL_BUF_LEN - 1);
            @memcpy(self.prop_val_bufs[i][0..vlen], val[0..vlen]);
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

pub const OptimizerWindowState = struct {
    win_rect: WinRect = .{ .x = 80, .y = 60, .w = 700, .h = 550 },
    is_open: bool = false,
    active_tab: Tab = .setup,

    // Setup tab
    device_entries: [32]DeviceEntry = [_]DeviceEntry{.{}} ** 32,
    n_devices: u8 = 0,
    spec_entries: [32]SpecEntry = [_]SpecEntry{.{}} ** 32,
    n_specs: u8 = 0,
    match_entries: [16]MatchEntry = [_]MatchEntry{.{}} ** 16,
    n_matches: u8 = 0,

    // Config
    max_generations_buf: [8]u8 = [_]u8{0} ** 8,
    timeout_buf: [8]u8 = [_]u8{0} ** 8,
    stop_on_feasible: bool = false,

    // Run tab
    status: Status = .idle,
    generation: u32 = 0,
    max_generations: u32 = 100,
    feasible_count: u32 = 0,
    pop_size: u32 = 0,
    best_summary: [256]u8 = [_]u8{0} ** 256,
    best_summary_len: u8 = 0,
    log_buf: [4096]u8 = [_]u8{0} ** 4096,
    log_len: u16 = 0,

    // Results tab
    result_individuals: [200]ResultRow = [_]ResultRow{.{}} ** 200,
    n_results: u16 = 0,
    selected_result: i16 = -1,
    apply_checks: [32]bool = [_]bool{false} ** 32,

    // Sweep tab
    sweep_device_idx: u8 = 0,
    sweep_analytical: bool = true,
    sweep_data: [256]SweepPoint = [_]SweepPoint{.{}} ** 256,
    n_sweep_points: u16 = 0,

    // Discovery (populated once on window open)
    discovered_devices: [32]DiscoveredDevice = [_]DiscoveredDevice{.{}} ** 32,
    n_discovered_devices: u8 = 0,
    discovered_measurements: [64]DiscoveredMeasurement = [_]DiscoveredMeasurement{.{}} ** 64,
    n_discovered_measurements: u8 = 0,
    discovery_done: bool = false,

    // Thread
    cancelled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread_handle: ?std.Thread = null,

    pub const Tab = enum { setup, run, results, sweep };
    pub const Status = enum { idle, running, completed, failed };
};

pub const DeviceEntry = struct {
    enabled: bool = true,
    instance_buf: [63]u8 = [_]u8{0} ** 63,
    instance_len: u8 = 0,
    device_type: u8 = 0, // 0=mosfet, 1=bjt, 2=resistor
    bound_min_buf: [16]u8 = [_]u8{0} ** 16,
    bound_max_buf: [16]u8 = [_]u8{0} ** 16,
    match_group: u8 = 0,
};

pub const SpecEntry = struct {
    name_buf: [63]u8 = [_]u8{0} ** 63,
    name_len: u8 = 0,
    kind: u8 = 0,
    target_buf: [16]u8 = [_]u8{0} ** 16,
    weight_buf: [8]u8 = [_]u8{0} ** 8,
};

pub const MatchEntry = struct {
    group_id: u8 = 0,
    device_indices: [8]u8 = [_]u8{0} ** 8,
    n_devices: u8 = 0,
    primary_idx: u8 = 0,
};

pub const ResultRow = struct {
    objectives: [8]f64 = [_]f64{0} ** 8,
    n_objectives: u8 = 0,
    rank: u16 = 0,
    feasible: bool = false,
};

pub const SweepPoint = struct {
    x: f64 = 0,
    gain: f64 = 0,
    ft: f64 = 0,
    w: f64 = 0,
    power: f64 = 0,
};

// ── GUI / Plugin types ───────────────────────────────────────────────────────

pub const GuiViewMode = enum { schematic, symbol, doc };
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
    /// Set by any dvui text entry widget that has focus — suppresses single-key
    /// schematic shortcuts so typed characters reach the widget.
    text_entry_focused: bool = false,
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
        pool: *const core.string_pool.StringPool,
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
                const key_str = pool.get(prop.key);
                const val_str = pool.get(prop.val);
                // Find or insert key
                var ki: usize = 0;
                while (ki < key_count) : (ki += 1) {
                    if (std.mem.eql(u8, keys[ki], key_str)) break;
                }
                if (ki == key_count) {
                    if (key_count >= MAX_COMMON_PROPS) continue;
                    keys[key_count] = key_str;
                    first_vals[key_count] = val_str;
                    all_have[key_count] = 1;
                    key_count += 1;
                } else {
                    all_have[ki] += 1;
                    if (!std.mem.eql(u8, first_vals[ki], val_str)) {
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


pub const DocEditorState = struct {
    edit_buf: [64 * 1024]u8 = [_]u8{0} ** (64 * 1024),
    edit_len: u32 = 0,
    cursor_pos: u32 = 0,
    scroll_y: f32 = 0,
    mode: enum(u1) { edit = 0, preview = 1 } = .edit,
    pending_sync: bool = false,
    loaded: bool = false,

    pub fn editSlice(self: *const DocEditorState) []const u8 {
        return self.edit_buf[0..self.edit_len];
    }

    pub fn getText(self: *const DocEditorState) []const u8 {
        return std.mem.sliceTo(&self.edit_buf, 0);
    }

    pub fn wordCount(self: *const DocEditorState) u32 {
        const text = self.getText();
        if (text.len == 0) return 0;
        var count: u32 = 0;
        var in_word = false;
        for (text) |c| {
            if (c == ' ' or c == '\n' or c == '\t' or c == '\r') {
                in_word = false;
            } else {
                if (!in_word) count += 1;
                in_word = true;
            }
        }
        return count;
    }

    pub fn setText(self: *DocEditorState, text: []const u8) void {
        const n: u32 = @intCast(@min(text.len, self.edit_buf.len - 1));
        @memcpy(self.edit_buf[0..n], text[0..n]);
        self.edit_buf[n] = 0;
        self.edit_len = n;
    }
};

pub const Dialogs = struct {
    find: FindDialogState = .{},
    props: PropsDialogState = .{},
    multi_props: MultiPropsDialogState = .{},
    keybinds: DialogState = .{ .win_rect = .{ .x = 100, .y = 80, .w = 520, .h = 420 } },
    keybinds_open: bool = false,
    spice_code: SpiceCodeDialogState = .{},
    new_prim: NewPrimDialogState = .{},
    marketplace_win: DialogState = .{ .win_rect = .{ .x = 80, .y = 50, .w = 820, .h = 560 } },
    settings: SettingsDialogState = .{},
    import_project: ImportDialogState = .{},
};

pub const PluginUI = struct {
    panels_meta: std.ArrayListUnmanaged(PluginPanelMeta) = .{},
    panels_state: std.ArrayListUnmanaged(PluginPanelState) = .{},
    keybinds: std.ArrayListUnmanaged(PluginKeybind) = .{},
    commands: std.ArrayListUnmanaged(PluginCommand) = .{},
    key_to_panel: [256]i8 = [_]i8{-1} ** 256,

    pub fn deinit(self: *PluginUI, a: std.mem.Allocator) void {
        self.panels_meta.deinit(a);
        self.panels_state.deinit(a);
        self.keybinds.deinit(a);
        self.commands.deinit(a);
    }
};

pub const GuiStateCold = struct {
    dialogs: Dialogs = .{},
    plugins: PluginUI = .{},
    marketplace: MarketplaceState = .{},
    file_explorer: FileExplorerState = .{},
    library_browser: LibraryBrowserState = .{},
    optimizer_windows: [4]OptimizerWindowState = [_]OptimizerWindowState{.{}} ** 4,
    n_optimizer_windows: u8 = 0,
    ctx_menu: CtxMenu = .{},
    command_buf: [128]u8 = [_]u8{0} ** 128,
    doc_editor: DocEditorState = .{},
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
        const symbol_refs = sch.instances.items(.symbol);
        for (symbol_refs) |sym_ref| {
            const sym = sch.str(sym_ref);
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
    origin: Origin = .unsaved,
    view: Viewport = .{},
    selection: Selection = .{},
    undo_history: cmd.handlers.History = .{},
    redo_history: cmd.handlers.History = .{},
    missing_symbols: std.StringArrayHashMapUnmanaged(void) = .{},
    conn: core.connectivity.Connectivity = .{},
    sim_results: ?simulation.results.SimResult = null,
    sim_generation: u32 = 0,
    // 1-byte
    dirty: bool = true,

    // ── Lifecycle ──

    pub fn open(a: std.mem.Allocator, logger: ?*utility.Logger, path: []const u8) !Document {
        _ = logger;
        const data = try utility.platform.fs.cwd().readFileAlloc(a, path, std.math.maxInt(usize));
        defer a.free(data);
        const s = core.fileio.Reader.readCHN(data, a);
        const owned_name = try a.dupe(u8, path);
        errdefer a.free(owned_name);
        const owned_origin = std.fs.cwd().realpathAlloc(a, path) catch try a.dupe(u8, path);
        return .{
            .alloc = a, .name = owned_name, .sch = s,
            .origin = .{ .chn_file = owned_origin }, .dirty = false,
        };
    }

    pub fn openEmbedded(a: std.mem.Allocator, logger: ?*utility.Logger, name: []const u8, data: []const u8) !Document {
        _ = logger;
        const s = core.fileio.Reader.readCHN(data, a);
        const owned_name = try a.dupe(u8, name);
        return .{
            .alloc = a, .name = owned_name, .sch = s,
            .origin = .unsaved, .dirty = false,
        };
    }

    pub fn deinit(self: *Document) void {
        self.undo_history.clear();
        self.redo_history.clear();
        self.clearSubcktCache();
        self.selection.deinit(self.alloc);
        self.conn.deinit(self.alloc);
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
        return simulation.Netlist.emitSpice(&self.sch, self.alloc, null);
    }

    // ── Save ──

    pub fn saveAsChn(self: *Document, path: []const u8) !void {
        const out = core.fileio.Writer.writeCHN(self.alloc, &self.sch) orelse return error.WriteFailed;
        defer self.alloc.free(out);
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
    // NOTE: placeSymbol logic moved to commands/handlers/Edit.zig (place_device handler).
    // All placement goes through the command queue to ensure undo/redo consistency.

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
        try self.addWireSegBus(start, end, net_name, false);
    }

    pub fn addWireSegBus(self: *Document, start: Point, end: Point, net_name: ?[]const u8, is_bus: bool) !void {
        const a = self.alloc;
        const net_ref = if (net_name) |nn| (if (nn.len > 0) try self.sch.strings.add(a, nn) else core.string_pool.StringRef.empty) else core.string_pool.StringRef.empty;
        try self.sch.wires.append(a, .{ .x0 = start[0], .y0 = start[1], .x1 = end[0], .y1 = end[1], .net_name = net_ref, .bus = is_bus });
        self.dirty = true;
    }

    pub fn deleteWireAt(self: *Document, idx: usize) void {
        if (idx < self.sch.wires.len) { self.sch.wires.swapRemove(idx); self.dirty = true; }
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// BackendAvailability — cached probe results for SPICE backends
// ═══════════════════════════════════════════════════════════════════════════

pub const BackendAvailability = struct {
    ngspice: bool = false,
    xyce: bool = false,
    ltspice: bool = false,
    spectre: bool = false,
    vacask: bool = false,
    probed: bool = false,

    pub fn isAvailable(self: BackendAvailability, b: simulation.SpiceIF.Backend) bool {
        return switch (b) {
            .ngspice => self.ngspice,
            .xyce => self.xyce,
            .ltspice => self.ltspice,
            .spectre => self.spectre,
            .vacask => self.vacask,
        };
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
    project_dir: []const u8 = "",
    config: ProjectConfig = undefined,
    queue: cmd.CommandQueue = .{},
    clipboard: Clipboard = .{},
    highlighted_nets: std.DynamicBitSetUnmanaged = .{},
    log: utility.Logger = undefined,

    // Cold — 8-byte aligned
    pdk: core.devices.Devices.Pdk = .{},
    tb_index: TbIndex = undefined,
    hierarchy_stack: std.ArrayListUnmanaged(HierEntry) = .{},
    plugin_runtime: ?*plugin_mod.Runtime = null,
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

    // Cold: simulation backend selector + availability cache
    sim_backend: simulation.SpiceIF.Backend = .ngspice,
    backend_avail: BackendAvailability = .{},

    // Cold: startup plugin download overlay
    startup_dl: StartupDownload = .{},

    // Cold: 1-byte
    quit_requested: bool = false,
    plugin_refresh_requested: bool = false,
    settings_reload_requested: bool = false,
    settings_save_requested: bool = false,
    open_library_browser: bool = false,
    rescan_library_browser: bool = false,
    open_file_explorer: bool = false,

    // ── Lifecycle ──

    pub fn init(self: *AppState, project_dir: []const u8) void {
        self.* = .{ .gpa = .{} };
        const a = self.gpa.allocator();
        self.project_dir = a.dupe(u8, project_dir) catch project_dir;
        self.config = ProjectConfig.init(a);
        self.tb_index = TbIndex.init(a);
    }

    pub fn deinit(self: *AppState) void {
        const a = self.gpa.allocator();
        for (self.documents.items) |*doc| doc.deinit();
        self.documents.deinit(a);
        self.hierarchy_stack.deinit(a);
        self.gui.cold.plugins.panels_meta.deinit(a);
        self.gui.cold.plugins.panels_state.deinit(a);
        self.gui.cold.plugins.keybinds.deinit(a);
        self.gui.cold.plugins.commands.deinit(a);
        self.gui.cold.marketplace.deinit(a);
        self.clipboard.instances.deinit(a);
        self.clipboard.wires.deinit(a);
        self.highlighted_nets.deinit(a);
        if (self.last_netlist.len > 0) a.free(self.last_netlist);
        self.pdk.deinit(a);
        self.tb_index.deinit();
        self.config.deinit();
        self.queue.deinit(a);
        if (self.project_dir.len > 0) a.free(self.project_dir);
        _ = self.gpa.deinit();
    }

    pub fn allocator(self: *AppState) std.mem.Allocator {
        return self.gpa.allocator();
    }

    // ── Config / Logger ──

    pub fn loadConfig(self: *AppState) !void {
        self.config.deinit();
        self.config = ProjectConfig.parseFromPath(self.allocator(), self.project_dir) catch |err| switch (err) {
            error.FileNotFound => {
                self.config = ProjectConfig.init(self.allocator());
                return;
            },
            else => {
                self.config = ProjectConfig.init(self.allocator());
                return err;
            },
        };
        self.buildTbIndex();
        if (self.config.pdk) |pdk_name| {
            if (pdk_name.len > 0) self.loadPdkDir(pdk_name);
        }
    }

    pub fn loadPdkDir(self: *AppState, pdk_name: []const u8) void {
        const a = self.allocator();
        const home = utility.platform.homeDir() orelse return;
        var path_buf: [512]u8 = undefined;
        const dir_path = std.fmt.bufPrint(&path_buf, "{s}/.cache/schemify/pdk/{s}", .{ home, pdk_name }) catch return;

        var dir = utility.platform.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
        defer dir.close();

        self.pdk.name = a.dupe(u8, pdk_name) catch return;

        var iter = dir.iterate();
        while (iter.next() catch null) |entry| {
            if (!std.mem.endsWith(u8, entry.name, ".chn_prim")) continue;
            const data = dir.readFileAlloc(a, entry.name, 4 << 20) catch continue;
            defer a.free(data);

            var sch = core.fileio.Reader.readCHN(data, a);
            defer sch.deinit(a);

            const cell_name = std.fs.path.stem(entry.name);
            const owned_name = a.dupe(u8, cell_name) catch continue;

            // Extract pin order from the parsed schematic's pins
            const pin_slice = sch.pins.slice();
            const pin_names = pin_slice.items(.name);
            var pin_order: []const []const u8 = &.{};
            if (pin_names.len > 0) {
                const po = a.alloc([]const u8, pin_names.len) catch continue;
                for (pin_names, 0..) |ref, i| {
                    po[i] = a.dupe(u8, sch.str(ref)) catch "";
                }
                pin_order = po;
            }

            // Detect device kind from sym_props "type" field
            var kind = core.types.DeviceKind.subckt;
            for (sch.sym_props.items) |prop| {
                if (std.mem.eql(u8, sch.str(prop.key), "type")) {
                    const val = sch.str(prop.val);
                    kind = inferKindFromType(val);
                    break;
                }
            }

            // Build file path for the PDK entry
            const file_path = a.dupe(u8, dir_path) catch continue;

            self.pdk.addPrimitive(a, .{
                .cell_name = owned_name,
                .file = file_path,
                .library = pdk_name,
                .kind = kind,
                .prefix = core.devices.Devices.prefix_lut[@intFromEnum(kind)],
                .pin_order = pin_order,
                .model_name = owned_name,
                .default_params = &.{},
                .lib_includes = &.{},
            }) catch {
                a.free(owned_name);
                a.free(file_path);
                for (pin_order) |p| if (p.len > 0) a.free(p);
                if (pin_order.len > 0) a.free(pin_order);
                continue;
            };
        }
    }

    fn buildTbIndex(self: *AppState) void {
        const a = self.allocator();
        for (self.config.paths.chn_tb) |tb_path| {
            const data = utility.platform.fs.cwd().readFileAlloc(a, tb_path, std.math.maxInt(usize)) catch continue;
            defer a.free(data);
            var sch = core.fileio.Reader.readCHN(data, a);
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
        try self.documents.append(a, .{ .alloc = a, .name = owned_name, .sch = core.Schemify{}, .dirty = false });
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

    pub fn openEmbedded(self: *AppState, name: []const u8, data: []const u8) !void {
        const a = self.allocator();
        const doc = try Document.openEmbedded(a, &self.log, name, data);
        try self.documents.append(a, doc);
        self.active_idx = @intCast(self.documents.items.len - 1);
    }

    /// Load a project Config.toml from the given directory if it differs from the
    /// currently loaded project. Triggers PDK loading and plugin spawning.
    pub fn loadProjectFromDir(self: *AppState, dir: []const u8) void {
        if (std.mem.eql(u8, dir, self.project_dir)) return;

        const a = self.allocator();
        if (self.project_dir.len > 0) a.free(self.project_dir);
        self.project_dir = a.dupe(u8, dir) catch return;
        self.pdk.deinit(a);
        self.pdk = .{};
        self.config.deinit();
        self.config = ProjectConfig.parseFromPath(a, dir) catch {
            self.config = ProjectConfig.init(a);
            return;
        };
        self.buildTbIndex();
        if (self.config.pdk) |pdk_name| {
            if (pdk_name.len > 0) self.loadPdkDir(pdk_name);
        }
        self.plugin_refresh_requested = true;
    }

    pub fn saveActiveTo(self: *AppState, path: []const u8) !void {
        const doc = self.active() orelse return;
        if (doc.sch.stype == .testbench) {
            if (doc.origin == .chn_file) self.tb_index.deindexTb(doc.origin.chn_file);
        }
        const out = core.fileio.Writer.writeCHN(self.allocator(), &doc.sch) orelse return error.Unexpected;
        defer self.allocator().free(out);
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
        doc.selection.ensureShapeCapacity(a, &doc.sch, false) catch return;
        if (doc.sch.lines.len > 0) doc.selection.lines.setAll();
        if (doc.sch.rects.len > 0) doc.selection.rects.setAll();
        if (doc.sch.circles.len > 0) doc.selection.circles.setAll();
        if (doc.sch.arcs.len > 0) doc.selection.arcs.setAll();
        if (doc.sch.texts.len > 0) doc.selection.texts.setAll();
    }

    // ── Plugin helpers ──

    pub fn registerPluginPanelEx(self: *AppState, id: []const u8, title: []const u8, vim_cmd: []const u8, layout: PluginPanelLayout, keybind: u8, panel_id: u16) u16 {
        const a = self.allocator();
        self.gui.cold.plugins.panels_meta.append(a, .{ .id = id, .title = title, .vim_cmd = vim_cmd }) catch return 0;
        self.gui.cold.plugins.panels_state.append(a, .{ .layout = layout, .keybind = keybind, .panel_id = panel_id }) catch {
            _ = self.gui.cold.plugins.panels_meta.pop();
            return 0;
        };
        if (keybind > 0) self.gui.cold.plugins.key_to_panel[keybind] = @intCast(self.gui.cold.plugins.panels_state.items.len - 1);
        return panel_id;
    }

    pub fn registerPluginCommand(self: *AppState, id: []const u8, display_name: []const u8, description: []const u8) void {
        const a = self.allocator();
        self.gui.cold.plugins.commands.append(a, .{ .id = id, .display_name = display_name, .description = description }) catch {};
    }

};

fn inferKindFromType(type_str: []const u8) core.types.DeviceKind {
    if (std.mem.eql(u8, type_str, "nmos") or std.mem.eql(u8, type_str, "nmos4")) return .nmos4;
    if (std.mem.eql(u8, type_str, "pmos") or std.mem.eql(u8, type_str, "pmos4")) return .pmos4;
    if (std.mem.eql(u8, type_str, "npn") or std.mem.eql(u8, type_str, "vertical_npn")) return .npn;
    if (std.mem.eql(u8, type_str, "pnp") or std.mem.eql(u8, type_str, "vertical_pnp")) return .pnp;
    if (std.mem.eql(u8, type_str, "resistor") or std.mem.startsWith(u8, type_str, "poly_resistor") or std.mem.endsWith(u8, type_str, "resistor")) return .resistor;
    if (std.mem.eql(u8, type_str, "capacitor") or std.mem.startsWith(u8, type_str, "cap")) return .capacitor;
    if (std.mem.eql(u8, type_str, "diode")) return .diode;
    if (std.mem.eql(u8, type_str, "inductor")) return .inductor;
    return .subckt;
}

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
