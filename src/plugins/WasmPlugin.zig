//! WASM Plugin Helper — import declarations and a Zig-friendly wrapper that
//! mirrors the native Ctx API for plugins targeting the web build.
//!
//! Usage in a WASM plugin entry point (e.g. src/web.zig):
//!
//!   const wasm = @import("WasmPlugin.zig");
//!
//!   export fn on_load() void {
//!       wasm.Host.setStatus("hello from WASM");
//!       _ = wasm.Host.registerPanel("my-panel", "My Panel", "mypanel",
//!                                   .right_sidebar, 'm');
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

const builtin = @import("builtin");

comptime {
    if (builtin.cpu.arch != .wasm32 and builtin.cpu.arch != .wasm64 and !builtin.is_test) {
        @compileError("WasmPlugin.zig requires a WASM target (wasm32 or wasm64)");
    }
}

// ── Host imports ─────────────────────────────────────────────────────────── //

extern "host" fn set_status(ptr: i32, len: i32) void;
extern "host" fn log(level: i32, tag_ptr: i32, tag_len: i32, msg_ptr: i32, msg_len: i32) void;
extern "host" fn register_panel(
    id_ptr: i32,
    id_len: i32,
    title_ptr: i32,
    title_len: i32,
    vim_ptr: i32,
    vim_len: i32,
    layout: i32,
    keybind: i32,
) i32;
extern "host" fn project_dir_len() i32;
extern "host" fn project_dir_copy(dest: i32) void;
extern "host" fn active_schematic_len() i32;
extern "host" fn active_schematic_copy(dest: i32) void;
extern "host" fn request_refresh() void;

// ── Layout constants (mirror PluginIF.Layout) ─────────────────────────────── //

pub const Layout = enum(i32) {
    overlay = 0,
    left_sidebar = 1,
    right_sidebar = 2,
};

// ── Log levels ────────────────────────────────────────────────────────────── //

pub const LogLevel = enum(i32) {
    info = 0,
    warn = 1,
    err = 2,
};

// ── Host ──────────────────────────────────────────────────────────────────── //

/// Zero-size namespace struct wrapping all host imports with safe Zig slices.
/// Never instantiated — all members are pub and called as `Host.method(...)`.
pub const Host = struct {
    pub fn setStatus(msg: []const u8) void {
        set_status(wasmPtr(msg.ptr), wasmLen(msg.len));
    }

    pub fn logMsg(level: LogLevel, tag: []const u8, msg: []const u8) void {
        log(
            @intFromEnum(level),
            wasmPtr(tag.ptr), wasmLen(tag.len),
            wasmPtr(msg.ptr), wasmLen(msg.len),
        );
    }

    /// Returns true if the panel was registered (or updated) successfully.
    pub fn registerPanel(
        id: []const u8,
        title: []const u8,
        vim_cmd: []const u8,
        layout: Layout,
        keybind: u8,
    ) bool {
        return register_panel(
            wasmPtr(id.ptr), wasmLen(id.len),
            wasmPtr(title.ptr), wasmLen(title.len),
            wasmPtr(vim_cmd.ptr), wasmLen(vim_cmd.len),
            @intFromEnum(layout),
            keybind,
        ) != 0;
    }

    /// Copy the project directory into `buf`.  Returns the actual slice written.
    /// If `buf` is too small, the string is truncated.
    pub fn getProjectDir(buf: []u8) []const u8 {
        const len = project_dir_len();
        if (len <= 0) return buf[0..0];
        const n: usize = @min(@as(usize, @intCast(len)), buf.len);
        project_dir_copy(wasmPtr(buf.ptr));
        return buf[0..n];
    }

    /// Copy the active schematic name into `buf`.  Returns null if none is open.
    pub fn getActiveSchematicName(buf: []u8) ?[]const u8 {
        const len = active_schematic_len();
        if (len < 0) return null;
        const n: usize = @min(@as(usize, @intCast(len)), buf.len);
        active_schematic_copy(wasmPtr(buf.ptr));
        return buf[0..n];
    }

    pub fn requestRefresh() void {
        request_refresh();
    }
};

// ── Private helpers ───────────────────────────────────────────────────────── //

/// Zig pointers are usize; WASM imports expect i32 linear-memory addresses.
inline fn wasmPtr(ptr: anytype) i32 {
    return @intCast(@intFromPtr(ptr));
}

/// Zig lengths are usize; WASM imports expect i32.
inline fn wasmLen(len: usize) i32 {
    return @intCast(len);
}

// ── Size test ─────────────────────────────────────────────────────────────── //

test "Expose struct size for Host" {
    const print = @import("std").debug.print;
    print("Host: {d}B\n", .{@sizeOf(Host)});
}
