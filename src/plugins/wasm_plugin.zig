//! WASM Plugin Helper — import declarations and a Zig-friendly wrapper that
//! mirrors the native Ctx API for plugins targeting the web build.
//!
//! Usage in a WASM plugin entry point (e.g. src/web.zig):
//!
//!   const wasm = @import("wasm_plugin.zig");
//!
//!   export fn on_load() void {
//!       wasm.setStatus("hello from WASM");
//!       _ = wasm.registerPanel("my-panel", "My Panel", "mypanel",
//!                              wasm.LAYOUT_RIGHT_SIDEBAR, 'm');
//!   }
//!   export fn on_unload() void {}
//!   export fn on_tick(dt: f32) void { _ = dt; }
//!
//! ── WASM ABI ─────────────────────────────────────────────────────────────────
//!
//! The host (plugin_host.js) provides these WebAssembly imports under the
//! "host" namespace.  All string arguments are passed as (ptr: i32, len: i32)
//! pairs pointing into the plugin's linear memory.
//!
//!   host.set_status(ptr, len)
//!   host.log(level, tag_ptr, tag_len, msg_ptr, msg_len)
//!   host.register_panel(id_ptr, id_len, title_ptr, title_len,
//!                       vim_ptr, vim_len, layout, keybind) → i32
//!   host.project_dir_len() → i32
//!   host.project_dir_copy(dest_ptr)
//!   host.active_schematic_len() → i32  (-1 if none)
//!   host.active_schematic_copy(dest_ptr)
//!   host.request_refresh()
//!
//! The plugin must export `memory` (the default in Zig WASM builds) so the
//! host can read/write the string buffers.

// ── Host imports ─────────────────────────────────────────────────────────── //

extern "host" fn set_status(ptr: i32, len: i32) void;
extern "host" fn log(level: i32, tag_ptr: i32, tag_len: i32, msg_ptr: i32, msg_len: i32) void;
extern "host" fn register_panel(
    id_ptr:    i32, id_len:    i32,
    title_ptr: i32, title_len: i32,
    vim_ptr:   i32, vim_len:   i32,
    layout:    i32,
    keybind:   i32,
) i32;
extern "host" fn project_dir_len() i32;
extern "host" fn project_dir_copy(dest: i32) void;
extern "host" fn active_schematic_len() i32;
extern "host" fn active_schematic_copy(dest: i32) void;
extern "host" fn request_refresh() void;

// ── Layout constants (mirror PluginIF.Layout) ─────────────────────────────── //

pub const LAYOUT_OVERLAY        = 0;
pub const LAYOUT_LEFT_SIDEBAR   = 1;
pub const LAYOUT_RIGHT_SIDEBAR  = 2;

// ── Log levels ────────────────────────────────────────────────────────────── //

pub const LOG_INFO = 0;
pub const LOG_WARN = 1;
pub const LOG_ERR  = 2;

// ── Safe API wrappers ─────────────────────────────────────────────────────── //

pub fn setStatus(msg: []const u8) void {
    set_status(@intCast(@intFromPtr(msg.ptr)), @intCast(msg.len));
}

pub fn logMsg(level: i32, tag: []const u8, msg: []const u8) void {
    log(
        level,
        @intCast(@intFromPtr(tag.ptr)), @intCast(tag.len),
        @intCast(@intFromPtr(msg.ptr)), @intCast(msg.len),
    );
}

/// Returns true if the panel was registered (or updated) successfully.
pub fn registerPanel(
    id:      []const u8,
    title:   []const u8,
    vim_cmd: []const u8,
    layout:  i32,
    keybind: u8,
) bool {
    return register_panel(
        @intCast(@intFromPtr(id.ptr)),      @intCast(id.len),
        @intCast(@intFromPtr(title.ptr)),   @intCast(title.len),
        @intCast(@intFromPtr(vim_cmd.ptr)), @intCast(vim_cmd.len),
        layout,
        keybind,
    ) != 0;
}

/// Copy the project directory into `buf`.  Returns the actual slice written.
/// If `buf` is too small, the string is truncated.
pub fn getProjectDir(buf: []u8) []const u8 {
    const len = project_dir_len();
    if (len <= 0) return buf[0..0];
    const n = @min(@as(usize, @intCast(len)), buf.len);
    project_dir_copy(@intCast(@intFromPtr(buf.ptr)));
    return buf[0..n];
}

/// Copy the active schematic name into `buf`.  Returns null if none is open.
pub fn getActiveSchematicName(buf: []u8) ?[]const u8 {
    const len = active_schematic_len();
    if (len < 0) return null;
    const n = @min(@as(usize, @intCast(len)), buf.len);
    active_schematic_copy(@intCast(@intFromPtr(buf.ptr)));
    return buf[0..n];
}

pub fn requestRefresh() void {
    request_refresh();
}
