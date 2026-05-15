//! Native plugin loader — dlopen/dlsym resolution for API v1 plugins.
//!
//! Resolves the 11 schemify_* export symbols (1 required, 10 optional)
//! from a shared library (.so). Trust verification is NOT done here;
//! the caller is responsible for checking safety.zig before calling load().
//!
//! On WASM targets this module is a no-op stub.

const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");

const is_wasm = builtin.cpu.arch == .wasm32 or builtin.cpu.arch == .wasm64;

// -- C dynamic linker bindings ------------------------------------------------

const c = if (is_wasm) struct {} else struct {
    const RTLD_LAZY: c_int = 0x1;
    const RTLD_GLOBAL: c_int = 0x100;

    extern "c" fn dlopen(filename: [*:0]const u8, flags: c_int) ?*anyopaque;
    extern "c" fn dlsym(handle: *anyopaque, symbol: [*:0]const u8) ?*anyopaque;
    extern "c" fn dlclose(handle: *anyopaque) c_int;
    extern "c" fn dlerror() ?[*:0]const u8;
};

// -- Errors -------------------------------------------------------------------

pub const LoadError = error{
    DlOpenFailed,
    MissingActivate,
    PathTooLong,
};

// -- NativePlugin -------------------------------------------------------------

pub const NativePlugin = struct {
    handle: *anyopaque,
    exports: types.PluginExports,
    path: []const u8,

    /// Close the library handle.
    pub fn close(self: *NativePlugin) void {
        if (is_wasm) return;
        _ = c.dlclose(self.handle);
        self.* = undefined;
    }
};

// -- Symbol resolution --------------------------------------------------------

fn lookupSymbol(handle: *anyopaque, comptime T: type, name: [*:0]const u8) ?T {
    if (is_wasm) return null;
    const ptr = c.dlsym(handle, name) orelse return null;
    return @ptrCast(@alignCast(ptr));
}

// -- load() -------------------------------------------------------------------

/// Load a native plugin from a .so file.
///
/// Resolves `schemify_activate` (required) and all optional symbols.
/// Returns `LoadError` if dlopen fails or `schemify_activate` is missing.
/// Does NOT verify trust — the caller must do that via safety.zig.
pub fn load(path: []const u8) LoadError!NativePlugin {
    if (is_wasm) return LoadError.DlOpenFailed;

    // Convert to null-terminated path for dlopen.
    const path_z = std.posix.toPosixPath(path) catch return LoadError.PathTooLong;

    const handle = c.dlopen(&path_z, c.RTLD_LAZY | c.RTLD_GLOBAL) orelse {
        if (c.dlerror()) |err_msg| {
            std.log.err("dlopen failed for '{s}': {s}", .{ path, std.mem.span(err_msg) });
        } else {
            std.log.err("dlopen failed for '{s}': unknown error", .{path});
        }
        return LoadError.DlOpenFailed;
    };

    // Required: schemify_activate
    const activate = lookupSymbol(handle, types.ActivateFn, types.export_symbols.activate) orelse {
        _ = c.dlclose(handle);
        return LoadError.MissingActivate;
    };

    return .{
        .handle = handle,
        .path = path,
        .exports = .{
            .activate = activate,
            .deactivate = lookupSymbol(handle, types.DeactivateFn, types.export_symbols.deactivate),
            .render = lookupSymbol(handle, types.RenderFn, types.export_symbols.render),
            .on_html_event = lookupSymbol(handle, types.OnHtmlEventFn, types.export_symbols.on_html_event),
            .on_command = lookupSymbol(handle, types.OnCommandFn, types.export_symbols.on_command),
            .on_schematic_changed = lookupSymbol(handle, types.OnSchematicChangedFn, types.export_symbols.on_schematic_changed),
            .on_selection_changed = lookupSymbol(handle, types.OnSelectionChangedFn, types.export_symbols.on_selection_changed),
            .on_key_event = lookupSymbol(handle, types.OnKeyEventFn, types.export_symbols.on_key_event),
            .on_hover = lookupSymbol(handle, types.OnHoverFn, types.export_symbols.on_hover),
            .provide = lookupSymbol(handle, types.ProvideFn, types.export_symbols.provide),
            .on_message = lookupSymbol(handle, types.OnMessageFn, types.export_symbols.on_message),
        },
    };
}
