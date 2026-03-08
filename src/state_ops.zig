//! AppState mutation operations — free functions that take *AppState as first arg.
//! Extracted from AppState methods to keep state.zig as a pure data bag.

const std = @import("std");
const state_mod = @import("state.zig");
const AppState = state_mod.AppState;
const FileIO = state_mod.FileIO;
const FileType = state_mod.FileType;
const PluginPanelLayout = state_mod.PluginPanelLayout;
const PanelDrawFn = state_mod.PanelDrawFn;

pub fn setStatus(app: *AppState, msg: []const u8) void {
    app.status_msg = msg;
    app.log.info("STATUS", "{s}", .{msg});
}

pub fn setStatusErr(app: *AppState, msg: []const u8) void {
    app.status_msg = msg;
    app.log.err("STATUS", "{s}", .{msg});
}

pub fn dumpLog(app: *AppState) void {
    const entries = app.log.entries();
    for (entries) |entry| {
        std.debug.print("[{s}] {s}: {s}\n", .{ entry.level.sym(), entry.src, entry.msg });
    }
    const err_count = app.log.countAt(.err);
    std.debug.print("[INF] LOG: entries={d} errors={d}\n", .{ entries.len, err_count });
}

pub fn active(app: *AppState) ?*FileIO {
    if (app.schematics.items.len == 0) return null;
    return app.schematics.items[app.active_idx];
}

pub fn openPath(app: *AppState, path: []const u8) !void {
    const alloc = app.allocator();
    const fio = try alloc.create(FileIO);
    errdefer alloc.destroy(fio);

    const ft = FileType.fromPath(path);
    fio.* = switch (ft) {
        .chn, .chn_tb => try FileIO.initFromChn(alloc, &app.log, path),
        .chn_sym       => try FileIO.initFromChnSym(alloc, &app.log, path),
        .unknown       => {
            setStatusErr(app, "Unsupported file type (only .chn, .chn_tb, .chn_sym)");
            return error.InvalidFormat;
        },
    };

    try app.schematics.append(alloc, fio);
    app.active_idx = app.schematics.items.len - 1;
    app.selection.clear();
    setStatus(app, "Opened file");
}

pub fn newFile(app: *AppState, name: []const u8) !void {
    const alloc = app.allocator();
    const fio = try alloc.create(FileIO);
    errdefer alloc.destroy(fio);
    fio.* = try FileIO.initNew(alloc, &app.log, name, false);
    try app.schematics.append(alloc, fio);
    app.active_idx = app.schematics.items.len - 1;
    app.selection.clear();
    setStatus(app, "New file created");
}

pub fn saveActiveTo(app: *AppState, path: []const u8) !void {
    const fio = active(app) orelse {
        setStatusErr(app, "No active document");
        return error.NoActiveDocument;
    };
    try fio.saveAsChn(path);
    setStatus(app, "Saved file");
}

/// Select every instance and wire in the active schematic.
pub fn selectAll(app: *AppState) void {
    const fio = active(app) orelse return;
    const sch = fio.schematic();
    const alloc = app.allocator();
    app.selection.instances.resize(alloc, sch.instances.items.len, false) catch return;
    app.selection.wires.resize(alloc, sch.wires.items.len, false) catch return;
    app.selection.instances.setRangeValue(.{ .start = 0, .end = sch.instances.items.len }, true);
    app.selection.wires.setRangeValue(.{ .start = 0, .end = sch.wires.items.len }, true);
}

pub fn registerPluginPanel(
    app: *AppState,
    id: []const u8,
    title: []const u8,
    vim_cmd: []const u8,
    layout: PluginPanelLayout,
    keybind: ?u8,
) bool {
    return registerPluginPanelEx(app, id, title, vim_cmd, layout, keybind, null);
}

pub fn registerPluginPanelEx(
    app: *AppState,
    id: []const u8,
    title: []const u8,
    vim_cmd: []const u8,
    layout: PluginPanelLayout,
    keybind: ?u8,
    draw_fn: ?PanelDrawFn,
) bool {
    if (id.len == 0 or title.len == 0 or vim_cmd.len == 0) return false;
    const alloc = app.allocator();

    if (findPluginPanelById(app, id)) |existing| {
        var panel = &app.gui.plugin_panels.items[existing];
        const new_title = alloc.dupe(u8, title) catch return false;
        const new_vim = alloc.dupe(u8, vim_cmd) catch {
            alloc.free(new_title);
            return false;
        };
        alloc.free(panel.title);
        alloc.free(panel.vim_cmd);
        panel.title = new_title;
        panel.vim_cmd = new_vim;
        panel.layout = layout;
        panel.keybind = if (keybind) |k| asciiLower(k) else 0;
        panel.draw_fn = draw_fn;
        rebuildPluginPanelIndexes(app);
        return true;
    }

    const panel_id = alloc.dupe(u8, id) catch return false;
    errdefer alloc.free(panel_id);
    const panel_title = alloc.dupe(u8, title) catch return false;
    errdefer alloc.free(panel_title);
    const panel_vim = alloc.dupe(u8, vim_cmd) catch return false;
    errdefer alloc.free(panel_vim);

    app.gui.plugin_panels.append(alloc, .{
        .id = panel_id,
        .title = panel_title,
        .vim_cmd = panel_vim,
        .layout = layout,
        .keybind = if (keybind) |k| asciiLower(k) else 0,
        .draw_fn = draw_fn,
    }) catch return false;
    rebuildPluginPanelIndexes(app);
    return true;
}

pub fn togglePluginPanelByVim(app: *AppState, vim_cmd: []const u8) bool {
    for (app.gui.plugin_panels.items, 0..) |panel, i| {
        if (std.mem.eql(u8, panel.vim_cmd, vim_cmd)) {
            app.gui.plugin_panels.items[i].visible = !app.gui.plugin_panels.items[i].visible;
            app.status_msg = if (app.gui.plugin_panels.items[i].visible) "Panel opened" else "Panel hidden";
            return true;
        }
    }
    return false;
}

pub fn togglePluginPanelByKey(app: *AppState, key: u8) bool {
    const lowered = asciiLower(key);
    const idx = app.gui.key_to_panel[lowered];
    if (idx >= 0) {
        const i: usize = @intCast(idx);
        app.gui.plugin_panels.items[i].visible = !app.gui.plugin_panels.items[i].visible;
        app.status_msg = if (app.gui.plugin_panels.items[i].visible) "Panel opened" else "Panel hidden";
        return true;
    }
    return false;
}

/// Dynamic registry of plugin panels (name + draw callback link).
pub fn pluginPanels(app: *const AppState) []const state_mod.PluginPanel {
    return app.gui.plugin_panels.items;
}

fn findPluginPanelById(app: *const AppState, id: []const u8) ?usize {
    for (app.gui.plugin_panels.items, 0..) |panel, i| {
        if (std.mem.eql(u8, panel.id, id)) return i;
    }
    return null;
}

pub fn seedDefaultPluginPanels(app: *AppState) void {
    _ = app;
}

fn rebuildPluginPanelIndexes(app: *AppState) void {
    app.gui.key_to_panel = [_]i16{-1} ** 256;

    for (app.gui.plugin_panels.items, 0..) |panel, i| {
        if (panel.keybind != 0) {
            app.gui.key_to_panel[panel.keybind] = @intCast(i);
        }
    }
}

fn asciiLower(ch: u8) u8 {
    if (ch >= 'A' and ch <= 'Z') return ch + 32;
    return ch;
}
