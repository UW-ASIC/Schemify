//! CircuitVision — native Zig plugin with embedded libpython and dvui overlay.
//!
//! Combines the Schemify plugin ABI with:
//!   - dvui overlay panel for the GUI (panel.zig)
//!   - Embedded CPython for running the AI pipeline (python_bridge.zig)
//!   - Shared state for panel ↔ bridge communication (state.zig)
//!
//! Build:
//!   zig build -p ~/.config/Schemify/CircuitVision
//!
//! The plugin registers an overlay panel toggled with :circuitvision or 'i'.
//! The panel lets users select an image, choose a style, run the pipeline,
//! and review results — all without leaving the editor.

const std = @import("std");
const Plugin = @import("PluginIF");
const panel = @import("panel.zig");
const bridge = @import("python_bridge.zig");
const state = @import("state.zig");

const TAG = "CircuitVision";

// ── Panel definition ──────────────────────────────────────────────────────── //

const panel_def: Plugin.OverlayDef = .{
    .name = "circuitvision",
    .keybind = 'i',
    .draw_fn = &panel.draw,
};

// ── Lifecycle ─────────────────────────────────────────────────────────────── //

fn onLoad() callconv(.c) void {
    Plugin.setStatus("CircuitVision loading...");
    Plugin.logInfo(TAG, "on_load");

    // Determine the directory where this .so lives — Python sources are
    // installed alongside it.
    var dir_buf: [512]u8 = undefined;
    const project_dir = Plugin.getProjectDir(&dir_buf);

    // Try the plugin's own install directory first.  When installed via
    // `zig build -p ~/.config/Schemify/CircuitVision`, the .so and Python
    // sources are under that prefix.
    // For in-tree development, fall back to the plugin source dir.
    var so_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = std.posix.getenv("HOME") orelse "/tmp";
    const so_dir = std.fmt.bufPrint(&so_dir_buf, "{s}/.config/Schemify/CircuitVision", .{home}) catch project_dir;

    const py_ok = bridge.init(so_dir);
    if (!py_ok) {
        Plugin.logWarn(TAG, "Python init failed — pipeline unavailable");
    }

    _ = Plugin.registerOverlay(&panel_def);
    Plugin.setStatus("CircuitVision ready");
    Plugin.logInfo(TAG, "overlay panel registered (keybind: i, cmd: :circuitvision)");
}

fn onUnload() callconv(.c) void {
    Plugin.logInfo(TAG, "on_unload");
    state.g.reset();
    bridge.deinit();
}

fn onTick(dt: f32) callconv(.c) void {
    _ = dt;
    // Pipeline runs synchronously in runPipeline() for now.
    // Future: poll a background thread here.
}

// ── Plugin descriptor ─────────────────────────────────────────────────────── //

export const schemify_plugin: Plugin.Descriptor = .{
    .abi_version = Plugin.ABI_VERSION,
    .name = "CircuitVision",
    .version_str = "0.1.0",
    .set_ctx = Plugin.setCtx,
    .on_load = &onLoad,
    .on_unload = &onUnload,
    .on_tick = &onTick,
};
