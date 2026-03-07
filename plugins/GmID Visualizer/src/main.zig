const std = @import("std");
const Plugin = @import("PluginIF");
const panel = @import("panel.zig");
const runner = @import("runner.zig");
const state = @import("state.zig");

const TAG = "GmIDVisualizer";

const panel_def: Plugin.OverlayDef = .{
    .name = "gmid",
    .keybind = 'g',
    .draw_fn = &panel.draw,
};

fn onLoad() callconv(.c) void {
    Plugin.setStatus("GmID Visualizer loading...");
    Plugin.logInfo(TAG, "on_load");

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const project_dir = Plugin.getProjectDir(&dir_buf);

    var plugin_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = std.posix.getenv("HOME") orelse "/tmp";
    const installed_dir = std.fmt.bufPrint(&plugin_dir_buf, "{s}/.config/Schemify/GmIDVisualizer", .{home}) catch project_dir;

    runner.init(installed_dir);
    _ = Plugin.registerOverlay(&panel_def);

    Plugin.setStatus("GmID Visualizer ready");
    Plugin.logInfo(TAG, "overlay panel registered (keybind: g, cmd: :gmid)");
}

fn onUnload() callconv(.c) void {
    Plugin.logInfo(TAG, "on_unload");
    state.g.resetAll();
}

fn onTick(dt: f32) callconv(.c) void {
    _ = dt;
}

export const schemify_plugin: Plugin.Descriptor = .{
    .abi_version = Plugin.ABI_VERSION,
    .name = "GmIDVisualizer",
    .version_str = "0.1.0",
    .set_ctx = Plugin.setCtx,
    .on_load = &onLoad,
    .on_unload = &onUnload,
    .on_tick = &onTick,
};
