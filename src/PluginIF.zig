//! Plugin Interface — the public API surface for Schemify plugins.
//!
//! ## Writing a plugin (single source, compiles to .so AND .wasm)
//!
//!   const Plugin = @import("PluginIF");
//!
//!   export const schemify_plugin: Plugin.Descriptor = .{
//!       .abi_version = Plugin.ABI_VERSION,
//!       .name        = "my-plugin",
//!       .version_str = "0.1.0",
//!       .set_ctx     = Plugin.setCtx,   // provided by this module
//!       .on_load     = &onLoad,
//!       .on_unload   = &onUnload,
//!       .on_tick     = null,
//!   };
//!
//!   fn onLoad() callconv(.c) void {
//!       Plugin.setStatus("hello from my-plugin");
//!       Plugin.Vfs.makePath("my-plugin/cache") catch {};
//!   }
//!
//! The Plugin namespace comptime-selects the backend:
//!
//!   Native  — stores the *Ctx passed by the runtime, dispatches through VTable.
//!   WASM    — calls extern "host" imports directly (no Ctx, no vtable).
//!
//! Vfs is always available and abstracts the filesystem for both targets.
//!
//! ## Low-level / first-party access
//!
//!   If you need the raw *AppState (first-party plugins only):
//!     const state: *AppState = @ptrCast(@alignCast(Plugin.rawState()));

const std = @import("std");
const builtin = @import("builtin");

const is_wasm = builtin.cpu.arch == .wasm32 or builtin.cpu.arch == .wasm64;

// ── Vfs re-export ─────────────────────────────────────────────────────────── //

/// Platform-agnostic filesystem — works on native and WASM.
///
///   const data = try Plugin.Vfs.readAlloc(alloc, "config.toml");
///   try Plugin.Vfs.writeAll("output.sch", data);
///   try Plugin.Vfs.makePath("my-plugin/cache");
///
/// Accessed via the `core` module (which owns Vfs.zig) so the type is the
/// same instance whether imported from here or from FileIO.
pub const Vfs = @import("core").Vfs;

// ── ABI versioning ────────────────────────────────────────────────────────── //

/// Bump whenever VTable or Descriptor change layout.
pub const ABI_VERSION: u32 = 5;

/// Symbol the runtime looks up in each .so / each WASM export table.
pub const EXPORT_SYMBOL: [*:0]const u8 = "schemify_plugin";

// ── Panel types ───────────────────────────────────────────────────────────── //

/// Where a plugin panel is rendered in the host UI.
pub const PanelLayout = enum(u8) {
    overlay = 0,
    left_sidebar = 1,
    right_sidebar = 2,
    bottom_bar = 3,
};

/// Backward-compatible alias for PanelLayout.
pub const Layout = PanelLayout;

/// Minimal UI toolkit the host passes to every draw_fn call.
///
/// All fields use C calling convention.  Plugins MUST call dvui widgets only
/// through this struct — never by importing dvui directly.  This avoids the
/// struct-layout mismatch that arises when the host and the plugin each compile
/// their own static copy of dvui.
///
/// `id` values must be unique within a single panel frame.  Using a simple
/// sequential counter (0, 1, 2 …) is sufficient.
pub const UiCtx = extern struct {
    /// Render a text label.
    label: *const fn (text: [*]const u8, len: usize, id: u32) callconv(.c) void,
    /// Render a button; returns true the frame the user clicks it.
    button: *const fn (text: [*]const u8, len: usize, id: u32) callconv(.c) bool,
    /// Render a horizontal separator rule.
    separator: *const fn (id: u32) callconv(.c) void,
    /// Begin a horizontal row layout.  Must be paired with end_row(same_id).
    begin_row: *const fn (id: u32) callconv(.c) void,
    /// End the horizontal row started with begin_row(id).
    end_row: *const fn (id: u32) callconv(.c) void,
    /// Single-line text input. Returns true if content changed.
    text_input: *const fn (buf: [*]u8, buf_len: usize, cur_len: *usize, id: u32) callconv(.c) bool = &stubTextInput,
    /// Horizontal slider. Returns true if value changed.
    slider: *const fn (val: *f32, min: f32, max: f32, id: u32) callconv(.c) bool = &stubSlider,
    /// Checkbox with label. Returns true if value changed.
    checkbox: *const fn (val: *bool, text: [*]const u8, len: usize, id: u32) callconv(.c) bool = &stubCheckbox,
    /// Progress bar (fraction 0.0–1.0). No return value.
    progress: *const fn (fraction: f32, id: u32) callconv(.c) void = &stubProgress,

    // ── v5 additions ─────────────────────────────────────────────────────────
    /// 2D line chart widget. `x_data` and `y_data` are arrays of `count` f32 values.
    /// `title` is a null-terminated string. Returns true if the widget was clicked.
    plot: *const fn (title: [*:0]const u8, x_data: [*]const f32, y_data: [*]const f32, count: u32, id: u32) callconv(.c) bool = &stubPlot,
    /// Render a bitmap image. `pixels` is RGBA8 data of width*height pixels.
    image: *const fn (pixels: [*]const u8, width: u32, height: u32, id: u32) callconv(.c) void = &stubImage,
    /// Begin a collapsible section. Returns true if the section is open (content should be drawn).
    /// Must be paired with `end_collapsible(id)` regardless of return value.
    collapsible_section: *const fn (label: [*:0]const u8, open: *bool, id: u32) callconv(.c) bool = &stubCollapsible,
    /// End a collapsible section started with collapsible_section(id).
    end_collapsible: *const fn (id: u32) callconv(.c) void = &stubEndCollapsible,

    fn stubTextInput(_: [*]u8, _: usize, _: *usize, _: u32) callconv(.c) bool {
        return false;
    }
    fn stubSlider(_: *f32, _: f32, _: f32, _: u32) callconv(.c) bool {
        return false;
    }
    fn stubCheckbox(_: *bool, _: [*]const u8, _: usize, _: u32) callconv(.c) bool {
        return false;
    }
    fn stubProgress(_: f32, _: u32) callconv(.c) void {}
    fn stubPlot(_: [*:0]const u8, _: [*]const f32, _: [*]const f32, _: u32, _: u32) callconv(.c) bool { return false; }
    fn stubImage(_: [*]const u8, _: u32, _: u32, _: u32) callconv(.c) void {}
    fn stubCollapsible(_: [*:0]const u8, _: *bool, _: u32) callconv(.c) bool { return false; }
    fn stubEndCollapsible(_: u32) callconv(.c) void {}
};

/// Plugin-provided draw callback.
/// The host calls this every frame the panel is visible.
/// `ctx` is valid for the duration of the call only.
pub const DrawFn = *const fn (ctx: *const UiCtx) callconv(.c) void;

pub const PanelDef = extern struct {
    id: [*:0]const u8,
    title: [*:0]const u8,
    vim_cmd: [*:0]const u8,
    layout: PanelLayout,
    keybind: u8,
    draw_fn: ?DrawFn,
};

/// Simplified overlay-first panel definition.
/// `id`, `title`, and `vim_cmd` all use the same plugin label.
pub const OverlayDef = extern struct {
    name: [*:0]const u8,
    keybind: u8,
    draw_fn: ?DrawFn,
};

// ── Log level ─────────────────────────────────────────────────────────────── //

pub const LogLevel = enum(u8) { info = 0, warn = 1, err = 2 };

// ── VTable (host-facing) ──────────────────────────────────────────────────── //

/// Implemented by the host, one comptime-constant instance shared with every
/// loaded plugin.  Plugins must never construct or write to a VTable.
pub const VTable = extern struct {
    version: u32,
    set_status: *const fn (state: *anyopaque, msg: [*:0]const u8) callconv(.c) void,
    log: *const fn (state: *anyopaque, level: u8, tag: [*:0]const u8, msg: [*:0]const u8) callconv(.c) void,
    register_panel: *const fn (state: *anyopaque, def: *const PanelDef) callconv(.c) bool,
    host_alloc: *const fn (state: *anyopaque, size: usize, alignment: usize) callconv(.c) ?[*]u8,
    host_realloc: *const fn (state: *anyopaque, ptr: [*]u8, old_size: usize, alignment: usize, new_size: usize) callconv(.c) ?[*]u8,
    host_free: *const fn (state: *anyopaque, ptr: [*]u8, size: usize, alignment: usize) callconv(.c) void,
    project_dir: *const fn (state: *anyopaque) callconv(.c) [*:0]const u8,
    active_schematic_name: *const fn (state: *anyopaque) callconv(.c) ?[*:0]const u8,
    request_refresh: *const fn (state: *anyopaque) callconv(.c) void,

    // ── v4 additions ─────────────────────────────────────────────────────────
    /// Push a plugin command into the host command queue.
    push_command: *const fn (state: *anyopaque, tag: [*]const u8, tag_len: usize, payload: ?[*]const u8, payload_len: usize) callconv(.c) bool = &vtStubPushCommand,
    /// Store a key/value pair in plugin persistent state.
    set_plugin_state: *const fn (state: *anyopaque, key: [*]const u8, key_len: usize, val: [*]const u8, val_len: usize) callconv(.c) bool = &vtStubSetPluginState,
    /// Read a key from plugin persistent state. Returns bytes written or -1.
    get_plugin_state: *const fn (state: *anyopaque, key: [*]const u8, key_len: usize, buf: [*]u8, buf_len: usize) callconv(.c) i32 = &vtStubGetPluginState,
    /// Register a keybind that fires a plugin command tag.
    register_keybind: *const fn (state: *anyopaque, key: u8, mods: u8, cmd_tag: [*]const u8, tag_len: usize) callconv(.c) bool = &vtStubRegisterKeybind,
    /// Get the number of instances in the active schematic.
    get_instance_count: *const fn (state: *anyopaque) callconv(.c) u32 = &vtStubGetCount,
    /// Get the number of wires in the active schematic.
    get_wire_count: *const fn (state: *anyopaque) callconv(.c) u32 = &vtStubGetCount,
    /// Copy instance name at idx into buf. Returns bytes written or -1.
    get_instance_name: *const fn (state: *anyopaque, idx: u32, buf: [*]u8, buf_len: usize) callconv(.c) i32 = &vtStubGetBuf,
    /// Copy instance symbol path at idx into buf. Returns bytes written or -1.
    get_instance_symbol: *const fn (state: *anyopaque, idx: u32, buf: [*]u8, buf_len: usize) callconv(.c) i32 = &vtStubGetBuf,
    /// Copy instance property value for key into buf. Returns bytes written or -1.
    get_instance_prop: *const fn (state: *anyopaque, idx: u32, key: [*]const u8, key_len: usize, buf: [*]u8, buf_len: usize) callconv(.c) i32 = &vtStubGetProp,
    /// Get the number of resolved nets in the active schematic.
    get_net_count: *const fn (state: *anyopaque) callconv(.c) u32 = &vtStubGetCount,
    /// Copy net name at idx into buf. Returns bytes written or -1.
    get_net_name: *const fn (state: *anyopaque, idx: u32, buf: [*]u8, buf_len: usize) callconv(.c) i32 = &vtStubGetBuf,
    /// Returns opaque pointer to the host's global PdkDeviceRegistry.
    /// Cast to `*core.PdkDeviceRegistry` in first-party plugins that import core.
    /// Returns null when unavailable (WASM, or host does not implement).
    get_pdk_registry: *const fn (state: *anyopaque) callconv(.c) ?*anyopaque = &vtStubGetPdkRegistry,

    // ── v5 additions ─────────────────────────────────────────────────────────
    /// Read a TOML-backed per-plugin config value. Returns bytes written or -1.
    get_config: *const fn (state: *anyopaque, plugin_id: [*]const u8, id_len: usize, key: [*]const u8, key_len: usize, buf: [*]u8, buf_len: usize) callconv(.c) i32 = &vtStubGetBuf2,
    /// Write a TOML-backed per-plugin config value. Returns true on success.
    set_config: *const fn (state: *anyopaque, plugin_id: [*]const u8, id_len: usize, key: [*]const u8, key_len: usize, val: [*]const u8, val_len: usize) callconv(.c) bool = &vtStubSetConfig,

    fn vtStubGetPdkRegistry(_: *anyopaque) callconv(.c) ?*anyopaque {
        return null;
    }

    fn vtStubPushCommand(_: *anyopaque, _: [*]const u8, _: usize, _: ?[*]const u8, _: usize) callconv(.c) bool {
        return false;
    }
    fn vtStubSetPluginState(_: *anyopaque, _: [*]const u8, _: usize, _: [*]const u8, _: usize) callconv(.c) bool {
        return false;
    }
    fn vtStubGetPluginState(_: *anyopaque, _: [*]const u8, _: usize, _: [*]u8, _: usize) callconv(.c) i32 {
        return -1;
    }
    fn vtStubRegisterKeybind(_: *anyopaque, _: u8, _: u8, _: [*]const u8, _: usize) callconv(.c) bool {
        return false;
    }
    fn vtStubGetCount(_: *anyopaque) callconv(.c) u32 {
        return 0;
    }
    fn vtStubGetBuf(_: *anyopaque, _: u32, _: [*]u8, _: usize) callconv(.c) i32 {
        return -1;
    }
    fn vtStubGetProp(_: *anyopaque, _: u32, _: [*]const u8, _: usize, _: [*]u8, _: usize) callconv(.c) i32 {
        return -1;
    }
    fn vtStubGetBuf2(_: *anyopaque, _: [*]const u8, _: usize, _: [*]const u8, _: usize, _: [*]u8, _: usize) callconv(.c) i32 { return -1; }
    fn vtStubSetConfig(_: *anyopaque, _: [*]const u8, _: usize, _: [*]const u8, _: usize, _: [*]const u8, _: usize) callconv(.c) bool { return false; }
};

// ── Ctx (host-facing + plugin-facing) ────────────────────────────────────── //

/// Thin safe wrapper around the vtable.  On native targets this is passed
/// by the runtime and stored in _g_ctx for module-level access.
pub const Ctx = extern struct {
    _vtable: *const VTable,
    _state: *anyopaque,

    pub inline fn setStatus(self: *Ctx, msg: [*:0]const u8) void {
        self._vtable.set_status(self._state, msg);
    }
    pub inline fn logMsg(self: *Ctx, level: LogLevel, tag: [*:0]const u8, msg: [*:0]const u8) void {
        self._vtable.log(self._state, @intFromEnum(level), tag, msg);
    }
    pub inline fn registerPanel(self: *Ctx, def: *const PanelDef) bool {
        return self._vtable.register_panel(self._state, def);
    }
    pub inline fn registerOverlay(self: *Ctx, def: *const OverlayDef) bool {
        const panel: PanelDef = .{
            .id = def.name,
            .title = def.name,
            .vim_cmd = def.name,
            .layout = .overlay,
            .keybind = def.keybind,
            .draw_fn = def.draw_fn,
        };
        return self.registerPanel(&panel);
    }
    pub fn hostAllocator(self: *Ctx) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &host_alloc_vtable };
    }
    pub inline fn getProjectDir(self: *Ctx) [*:0]const u8 {
        return self._vtable.project_dir(self._state);
    }
    pub inline fn getActiveSchematicName(self: *Ctx) ?[*:0]const u8 {
        return self._vtable.active_schematic_name(self._state);
    }
    pub inline fn requestRefresh(self: *Ctx) void {
        self._vtable.request_refresh(self._state);
    }
    pub inline fn rawState(self: *Ctx) *anyopaque {
        return self._state;
    }
};

// ── host-allocator bridge ─────────────────────────────────────────────────── //

fn haAlloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
    const c: *Ctx = @ptrCast(@alignCast(ctx));
    return c._vtable.host_alloc(c._state, len, alignment.toByteUnits());
}
fn haResize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
    return false;
}
fn haRemap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, _: usize) ?[*]u8 {
    const c: *Ctx = @ptrCast(@alignCast(ctx));
    return c._vtable.host_realloc(c._state, memory.ptr, memory.len, alignment.toByteUnits(), new_len);
}
fn haFree(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, _: usize) void {
    const c: *Ctx = @ptrCast(@alignCast(ctx));
    c._vtable.host_free(c._state, memory.ptr, memory.len, alignment.toByteUnits());
}
const host_alloc_vtable: std.mem.Allocator.VTable = .{
    .alloc = haAlloc,
    .resize = haResize,
    .remap = haRemap,
    .free = haFree,
};

// ── Module-level plugin API ───────────────────────────────────────────────── //
//
// Plugin authors use Plugin.setStatus(…) rather than ctx.setStatus(…).
// Comptime-selects the backend:
//
//   Native  — the runtime writes the current *Ctx into _g_ctx before each call.
//   WASM    — extern "host" imports are called directly.
//
// This allows a single plugin source file to compile to both .so and .wasm.

/// Stored by the runtime before calling each lifecycle function on native.
/// Plugins must not write this directly; use setCtx (exported from Descriptor).
var _g_ctx: ?*Ctx = null;

/// Called by the runtime via Descriptor.set_ctx before/after lifecycle calls.
///
///   runtime:  desc.set_ctx(&ctx);  desc.on_load();  desc.set_ctx(null);
pub fn setCtx(ctx: ?*Ctx) callconv(.c) void {
    _g_ctx = ctx;
}

// ── WASM extern host imports (ignored on native) ──────────────────────────── //

extern "host" fn set_status(ptr: i32, len: i32) void;
extern "host" fn log_msg(level: i32, tag_ptr: i32, tag_len: i32, msg_ptr: i32, msg_len: i32) void;
extern "host" fn register_panel(id_ptr: i32, id_len: i32, title_ptr: i32, title_len: i32, vim_ptr: i32, vim_len: i32, layout: i32, keybind: i32, draw_fn_idx: i32) i32;
extern "host" fn project_dir_len() i32;
extern "host" fn project_dir_copy(dest: i32, dest_len: i32) void;
extern "host" fn active_schematic_len() i32;
extern "host" fn active_schematic_copy(dest: i32, dest_len: i32) void;
extern "host" fn request_refresh() void;

// v4 WASM host imports
extern "host" fn push_command(tag_ptr: i32, tag_len: i32, payload_ptr: i32, payload_len: i32) i32;
extern "host" fn set_plugin_state(key_ptr: i32, key_len: i32, val_ptr: i32, val_len: i32) i32;
extern "host" fn get_plugin_state(key_ptr: i32, key_len: i32, buf_ptr: i32, buf_len: i32) i32;
extern "host" fn register_keybind(key: i32, mods: i32, tag_ptr: i32, tag_len: i32) i32;
extern "host" fn get_instance_count() i32;
extern "host" fn get_wire_count() i32;
extern "host" fn get_net_count() i32;
extern "host" fn get_instance_name(idx: i32, buf_ptr: i32, buf_len: i32) i32;
extern "host" fn get_instance_symbol(idx: i32, buf_ptr: i32, buf_len: i32) i32;
extern "host" fn get_instance_prop(idx: i32, key_ptr: i32, key_len: i32, buf_ptr: i32, buf_len: i32) i32;
extern "host" fn get_net_name(idx: i32, buf_ptr: i32, buf_len: i32) i32;

fn wasmPtr(s: []const u8) i32 {
    return @intCast(@intFromPtr(s.ptr));
}
fn wasmLen(s: []const u8) i32 {
    return @intCast(s.len);
}
fn wasmPtrMut(s: []u8) i32 {
    return @intCast(@intFromPtr(s.ptr));
}

// ── Public module-level API ───────────────────────────────────────────────── //

/// Set the status bar text displayed in the host UI.
pub fn setStatus(msg: []const u8) void {
    if (comptime is_wasm) {
        set_status(wasmPtr(msg), wasmLen(msg));
        return;
    }
    const c = _g_ctx orelse return;
    var buf: [512:0]u8 = [_:0]u8{0} ** 512;
    const n = @min(msg.len, buf.len - 1);
    @memcpy(buf[0..n], msg[0..n]);
    c.setStatus(&buf);
}

/// Log an informational message with the given tag.
pub fn logInfo(tag: []const u8, msg: []const u8) void {
    logAt(.info, tag, msg);
}

/// Log a warning message with the given tag.
pub fn logWarn(tag: []const u8, msg: []const u8) void {
    logAt(.warn, tag, msg);
}

/// Log an error message with the given tag.
pub fn logErr(tag: []const u8, msg: []const u8) void {
    logAt(.err, tag, msg);
}

/// Log a message at the specified level with the given tag.
pub fn logAt(level: LogLevel, tag: []const u8, msg: []const u8) void {
    if (comptime is_wasm) {
        log_msg(@intFromEnum(level), wasmPtr(tag), wasmLen(tag), wasmPtr(msg), wasmLen(msg));
        return;
    }
    const c = _g_ctx orelse return;
    var tbuf: [64:0]u8 = [_:0]u8{0} ** 64;
    var mbuf: [512:0]u8 = [_:0]u8{0} ** 512;
    @memcpy(tbuf[0..@min(tag.len, 63)], tag[0..@min(tag.len, 63)]);
    @memcpy(mbuf[0..@min(msg.len, 511)], msg[0..@min(msg.len, 511)]);
    c.logMsg(level, &tbuf, &mbuf);
}

/// Register a plugin panel with the host UI.
pub fn registerPanel(def: *const PanelDef) bool {
    if (comptime is_wasm) {
        const id = std.mem.span(def.id);
        const title = std.mem.span(def.title);
        const vim = std.mem.span(def.vim_cmd);
        return register_panel(
            wasmPtr(id),
            wasmLen(id),
            wasmPtr(title),
            wasmLen(title),
            wasmPtr(vim),
            wasmLen(vim),
            @as(i32, @intFromEnum(def.layout)),
            def.keybind,
            0, // draw_fn_idx: JS side looks up by name
        ) >= 0;
    }
    const c = _g_ctx orelse return false;
    return c.registerPanel(def);
}

/// Overlay-only helper API for plugins that do not need sidebars.
pub fn registerOverlay(def: *const OverlayDef) bool {
    const panel: PanelDef = .{
        .id = def.name,
        .title = def.name,
        .vim_cmd = def.name,
        .layout = .overlay,
        .keybind = def.keybind,
        .draw_fn = def.draw_fn,
    };
    return registerPanel(&panel);
}

/// Copy the current project directory into `buf`.  Returns the slice written.
pub fn getProjectDir(buf: []u8) []const u8 {
    if (comptime is_wasm) {
        const sz = project_dir_len();
        const n = @min(@as(usize, @intCast(sz)), buf.len);
        project_dir_copy(@intCast(@intFromPtr(buf.ptr)), @intCast(n));
        return buf[0..n];
    }
    const c = _g_ctx orelse return buf[0..0];
    const s = std.mem.span(c.getProjectDir());
    const n = @min(s.len, buf.len);
    @memcpy(buf[0..n], s[0..n]);
    return buf[0..n];
}

/// Copy the active schematic name into `buf`.  Returns null when none open.
pub fn getActiveSchematicName(buf: []u8) ?[]const u8 {
    if (comptime is_wasm) {
        const sz = active_schematic_len();
        if (sz < 0) return null;
        const n = @min(@as(usize, @intCast(sz)), buf.len);
        active_schematic_copy(@intCast(@intFromPtr(buf.ptr)), @intCast(n));
        return buf[0..n];
    }
    const c = _g_ctx orelse return null;
    const s = c.getActiveSchematicName() orelse return null;
    const slice = std.mem.span(s);
    const n = @min(slice.len, buf.len);
    @memcpy(buf[0..n], slice[0..n]);
    return buf[0..n];
}

/// Request the host to repaint the UI on the next frame.
pub fn requestRefresh() void {
    if (comptime is_wasm) {
        request_refresh();
        return;
    }
    if (_g_ctx) |c| c.requestRefresh();
}

/// Returns the host allocator on native, `std.heap.wasm_allocator` on WASM.
pub fn allocator() std.mem.Allocator {
    if (comptime is_wasm) return std.heap.wasm_allocator;
    if (_g_ctx) |c| return c.hostAllocator();
    return std.heap.page_allocator; // native fallback (only hit outside lifecycle calls)
}

/// Returns an opaque pointer to the host's global PdkDeviceRegistry.
///
/// Cast to `*core.PdkDeviceRegistry` in first-party plugins that import `core`.
/// Returns null on WASM or if the host has not implemented this VTable entry.
pub fn getPdkRegistry() ?*anyopaque {
    if (comptime is_wasm) return null;
    const c = _g_ctx orelse return null;
    return c._vtable.get_pdk_registry(c._state);
}

/// First-party escape hatch: returns *anyopaque pointing at the AppState.
/// Only valid on native, only inside a lifecycle call, only for plugins that
/// share the same source tree as the host.
pub fn rawState() ?*anyopaque {
    if (comptime is_wasm) return null;
    return if (_g_ctx) |c| c.rawState() else null;
}

// ── v4 public API ─────────────────────────────────────────────────────────── //

/// Push a plugin command into the host's command queue.
/// The command is identified by `tag` and may carry an optional `payload`.
pub fn pushCommand(tag: []const u8, payload: ?[]const u8) bool {
    if (comptime is_wasm) {
        const p_ptr: i32 = if (payload) |p| wasmPtr(p) else 0;
        const p_len: i32 = if (payload) |p| wasmLen(p) else 0;
        return push_command(wasmPtr(tag), wasmLen(tag), p_ptr, p_len) != 0;
    }
    const c = _g_ctx orelse return false;
    const p_ptr: ?[*]const u8 = if (payload) |p| p.ptr else null;
    const p_len: usize = if (payload) |p| p.len else 0;
    return c._vtable.push_command(c._state, tag.ptr, tag.len, p_ptr, p_len);
}

/// Store a key/value string in plugin persistent state.
/// Both key and value are copied by the host.
pub fn setState(key: []const u8, value: []const u8) bool {
    if (comptime is_wasm) {
        return set_plugin_state(wasmPtr(key), wasmLen(key), wasmPtr(value), wasmLen(value)) != 0;
    }
    const c = _g_ctx orelse return false;
    return c._vtable.set_plugin_state(c._state, key.ptr, key.len, value.ptr, value.len);
}

/// Read a key from plugin persistent state into buf.
/// Returns null if the key is not found, otherwise the slice of buf written.
pub fn getState(key: []const u8, buf: []u8) ?[]const u8 {
    if (comptime is_wasm) {
        const n = get_plugin_state(wasmPtr(key), wasmLen(key), wasmPtrMut(buf), wasmLen(buf));
        if (n < 0) return null;
        return buf[0..@intCast(n)];
    }
    const c = _g_ctx orelse return null;
    const n = c._vtable.get_plugin_state(c._state, key.ptr, key.len, buf.ptr, buf.len);
    if (n < 0) return null;
    return buf[0..@intCast(n)];
}

/// Register a keybind that fires a plugin command tag when pressed.
/// `mods` is a bitmask: bit 0 = Ctrl, bit 1 = Shift, bit 2 = Alt.
pub fn registerKeybind(key: u8, mods: u8, cmd_tag: []const u8) bool {
    if (comptime is_wasm) {
        return register_keybind(key, mods, wasmPtr(cmd_tag), wasmLen(cmd_tag)) != 0;
    }
    const c = _g_ctx orelse return false;
    return c._vtable.register_keybind(c._state, key, mods, cmd_tag.ptr, cmd_tag.len);
}

/// Get the number of instances in the active schematic.
pub fn getInstanceCount() u32 {
    if (comptime is_wasm) return @intCast(get_instance_count());
    const c = _g_ctx orelse return 0;
    return c._vtable.get_instance_count(c._state);
}

/// Get the number of wires in the active schematic.
pub fn getWireCount() u32 {
    if (comptime is_wasm) return @intCast(get_wire_count());
    const c = _g_ctx orelse return 0;
    return c._vtable.get_wire_count(c._state);
}

/// Get the number of resolved nets in the active schematic.
pub fn getNetCount() u32 {
    if (comptime is_wasm) return @intCast(get_net_count());
    const c = _g_ctx orelse return 0;
    return c._vtable.get_net_count(c._state);
}

/// Copy instance name at idx into buf. Returns null if idx out of range.
pub fn getInstanceName(idx: u32, buf: []u8) ?[]const u8 {
    if (comptime is_wasm) {
        const n = get_instance_name(@intCast(idx), wasmPtrMut(buf), wasmLen(buf));
        if (n < 0) return null;
        return buf[0..@intCast(n)];
    }
    const c = _g_ctx orelse return null;
    const n = c._vtable.get_instance_name(c._state, idx, buf.ptr, buf.len);
    if (n < 0) return null;
    return buf[0..@intCast(n)];
}

/// Copy instance symbol at idx into buf. Returns null if idx out of range.
pub fn getInstanceSymbol(idx: u32, buf: []u8) ?[]const u8 {
    if (comptime is_wasm) {
        const n = get_instance_symbol(@intCast(idx), wasmPtrMut(buf), wasmLen(buf));
        if (n < 0) return null;
        return buf[0..@intCast(n)];
    }
    const c = _g_ctx orelse return null;
    const n = c._vtable.get_instance_symbol(c._state, idx, buf.ptr, buf.len);
    if (n < 0) return null;
    return buf[0..@intCast(n)];
}

/// Copy instance property value for key into buf. Returns null if not found.
pub fn getInstanceProp(idx: u32, key: []const u8, buf: []u8) ?[]const u8 {
    if (comptime is_wasm) {
        const n = get_instance_prop(@intCast(idx), wasmPtr(key), wasmLen(key), wasmPtrMut(buf), wasmLen(buf));
        if (n < 0) return null;
        return buf[0..@intCast(n)];
    }
    const c = _g_ctx orelse return null;
    const n = c._vtable.get_instance_prop(c._state, idx, key.ptr, key.len, buf.ptr, buf.len);
    if (n < 0) return null;
    return buf[0..@intCast(n)];
}

/// Copy net name at idx into buf. Returns null if idx out of range.
pub fn getNetName(idx: u32, buf: []u8) ?[]const u8 {
    if (comptime is_wasm) {
        const n = get_net_name(@intCast(idx), wasmPtrMut(buf), wasmLen(buf));
        if (n < 0) return null;
        return buf[0..@intCast(n)];
    }
    const c = _g_ctx orelse return null;
    const n = c._vtable.get_net_name(c._state, idx, buf.ptr, buf.len);
    if (n < 0) return null;
    return buf[0..@intCast(n)];
}

// ── v5 public API ─────────────────────────────────────────────────────────── //

/// Read a TOML-backed per-plugin config value into buf.
/// Returns null if the key is not found, otherwise the slice of buf written.
pub fn getConfig(plugin_id: []const u8, key: []const u8, buf: []u8) ?[]const u8 {
    if (comptime is_wasm) return null;
    const c = _g_ctx orelse return null;
    const n = c._vtable.get_config(c._state, plugin_id.ptr, plugin_id.len, key.ptr, key.len, buf.ptr, buf.len);
    if (n < 0) return null;
    return buf[0..@intCast(n)];
}

/// Write a TOML-backed per-plugin config value. Returns true on success.
pub fn setConfig(plugin_id: []const u8, key: []const u8, value: []const u8) bool {
    if (comptime is_wasm) return false;
    const c = _g_ctx orelse return false;
    return c._vtable.set_config(c._state, plugin_id.ptr, plugin_id.len, key.ptr, key.len, value.ptr, value.len);
}

// ── CommandDispatch ───────────────────────────────────────────────────────── //

/// Comptime command dispatch table. Plugins declare this instead of a
/// manual switch in `on_command`.
///
/// Usage:
///   const dispatch = PluginIF.CommandDispatch(&.{
///       .{ "my_cmd",   handleMyCmd },
///       .{ "other",    handleOther },
///   });
///   // then in Plugin.on_command:
///   pub fn on_command(tag: [*:0]const u8, payload: ?[*:0]const u8) callconv(.c) void {
///       dispatch.handle(tag, payload);
///   }
pub fn CommandDispatch(comptime entries: []const struct { []const u8, *const fn ([*:0]const u8, ?[*:0]const u8) callconv(.c) void }) type {
    return struct {
        pub fn handle(tag: [*:0]const u8, payload: ?[*:0]const u8) void {
            const tag_slice = std.mem.span(tag);
            inline for (entries) |entry| {
                if (std.mem.eql(u8, entry[0], tag_slice)) {
                    entry[1](tag, payload);
                    return;
                }
            }
        }
    };
}

/// Place a device in the active schematic (via command queue).
/// Returns true if the command was queued successfully.
pub fn placeDevice(sym: []const u8, name: []const u8, x: i32, y: i32) bool {
    var buf: [512]u8 = undefined;
    const payload = std.fmt.bufPrint(&buf, "{s}\x00{s}\x00{d}\x00{d}", .{ sym, name, x, y }) catch return false;
    return pushCommand("place_device", payload);
}

/// Add a wire segment in the active schematic (via command queue).
/// Returns true if the command was queued successfully.
pub fn addWire(x0: i32, y0: i32, x1: i32, y1: i32) bool {
    var buf: [256]u8 = undefined;
    const payload = std.fmt.bufPrint(&buf, "{d}\x00{d}\x00{d}\x00{d}", .{ x0, y0, x1, y1 }) catch return false;
    return pushCommand("add_wire", payload);
}

/// Set a property on an instance (via command queue).
/// Returns true if the command was queued successfully.
pub fn setInstanceProp(idx: u32, key: []const u8, val: []const u8) bool {
    var buf: [512]u8 = undefined;
    const payload = std.fmt.bufPrint(&buf, "{d}\x00{s}\x00{s}", .{ idx, key, val }) catch return false;
    return pushCommand("set_prop", payload);
}

// ── Plugin Descriptor ─────────────────────────────────────────────────────── //

/// Lifecycle functions take no parameters — the runtime calls set_ctx first.
pub const OnLoadFn = *const fn () callconv(.c) void;
pub const OnUnloadFn = *const fn () callconv(.c) void;
pub const OnTickFn = *const fn (dt: f32) callconv(.c) void;
pub const SetCtxFn = *const fn (ctx: ?*Ctx) callconv(.c) void;

/// Every plugin must export a symbol named `schemify_plugin` of this type.
///
///   export const schemify_plugin: Plugin.Descriptor = .{
///       .abi_version = Plugin.ABI_VERSION,
///       .name        = "my-plugin",
///       .version_str = "0.1.0",
///       .set_ctx     = Plugin.setCtx,
///       .on_load     = &onLoad,
///       .on_unload   = &onUnload,
///       .on_tick     = null,
///   };
pub const Descriptor = extern struct {
    /// Must equal ABI_VERSION or the runtime will refuse to load.
    abi_version: u32,
    name: [*:0]const u8,
    version_str: [*:0]const u8,
    /// Runtime calls this before/after each lifecycle function to inject ctx.
    set_ctx: SetCtxFn,
    on_load: OnLoadFn,
    on_unload: OnUnloadFn,
    on_tick: ?OnTickFn,
    /// Called when a plugin_command with matching tag is dispatched.
    on_command: ?*const fn (tag: [*]const u8, tag_len: usize, payload: ?[*]const u8, payload_len: usize) callconv(.c) void = null,
};

/// Backward-compatible alias.
pub const PluginDescriptor = Descriptor;
