const std = @import("std");
const dvui = @import("dvui");
const PluginIF = @import("PluginIF");
const st = @import("../state.zig");
const AppState = st.AppState;
const PluginPanel = st.PluginPanel;
const PluginPanelLayout = st.PluginPanelLayout;

// ── Host-side UiCtx wrappers ──────────────────────────────────────────────── //
//
// The plugin calls these through the UiCtx vtable instead of importing dvui
// directly.  This avoids struct-layout mismatches that arise when the host
// binary and the plugin .so each compile their own static copy of dvui.
//
// `id` values passed by the plugin are used as `id_extra` in dvui widget
// calls.  Because all wrapper functions share the same @src() location the
// id_extra is the ONLY differentiator — the plugin must use unique values.

fn uiLabel(text: [*]const u8, len: usize, id: u32) callconv(.c) void {
    dvui.labelNoFmt(@src(), text[0..len], .{}, .{ .id_extra = id });
}

fn uiButton(text: [*]const u8, len: usize, id: u32) callconv(.c) bool {
    return dvui.button(@src(), text[0..len], .{}, .{ .id_extra = id });
}

fn uiSeparator(id: u32) callconv(.c) void {
    _ = dvui.separator(@src(), .{ .id_extra = id });
}

// Simple stack for paired begin_row / end_row calls within one draw callback.
// Depth 8 is more than enough for any practical plugin panel.
var box_stack: [8]*dvui.BoxWidget = undefined;
var box_stack_top: usize = 0;

fn uiBeginRow(id: u32) callconv(.c) void {
    if (box_stack_top < box_stack.len) {
        box_stack[box_stack_top] = dvui.box(
            @src(),
            .{ .dir = .horizontal },
            .{ .expand = .horizontal, .id_extra = id },
        );
        box_stack_top += 1;
    }
}

fn uiEndRow(id: u32) callconv(.c) void {
    _ = id;
    if (box_stack_top > 0) {
        box_stack_top -= 1;
        box_stack[box_stack_top].deinit();
    }
}

// ── New widget host stubs ─────────────────────────────────────────────────── //
//
// These bridge the new UiCtx fields to dvui.  For now they are no-ops until
// the dvui widget wrappers are wired up.

fn hostTextInput(buf: [*]u8, buf_len: usize, cur_len: *usize, id: u32) callconv(.c) bool {
    if (buf_len == 0) return false;
    const slice = buf[0..buf_len];
    // Zero-terminate at cur_len so dvui sees the current content.
    if (cur_len.* < buf_len) slice[cur_len.*] = 0;
    var te = dvui.textEntry(@src(), .{
        .text = .{ .buffer = slice },
    }, .{ .id_extra = id, .expand = .horizontal });
    defer te.deinit();
    // Recalculate length from the buffer (dvui zero-terminates edits).
    const new_len = std.mem.indexOfScalar(u8, slice, 0) orelse buf_len;
    const changed = new_len != cur_len.*;
    cur_len.* = new_len;
    return changed;
}

fn hostSlider(val: *f32, min: f32, max: f32, id: u32) callconv(.c) bool {
    const range = max - min;
    if (range <= 0) return false;
    // dvui.slider works with a 0–1 fraction.
    var frac: f32 = (val.* - min) / range;
    frac = @max(0, @min(1, frac));
    const changed = dvui.slider(@src(), .{ .fraction = &frac }, .{ .id_extra = id, .expand = .horizontal });
    if (changed) val.* = min + frac * range;
    return changed;
}

fn hostCheckbox(val: *bool, text: [*]const u8, len: usize, id: u32) callconv(.c) bool {
    return dvui.checkbox(@src(), val, text[0..len], .{ .id_extra = id });
}

fn hostProgress(fraction: f32, id: u32) callconv(.c) void {
    dvui.progress(@src(), .{ .percent = @max(0, @min(1, fraction)) }, .{ .id_extra = id, .expand = .horizontal });
}

const g_ui_ctx: PluginIF.UiCtx = .{
    .label      = &uiLabel,
    .button     = &uiButton,
    .separator  = &uiSeparator,
    .begin_row  = &uiBeginRow,
    .end_row    = &uiEndRow,
    .text_input = &hostTextInput,
    .slider     = &hostSlider,
    .checkbox   = &hostCheckbox,
    .progress   = &hostProgress,
};

// ── Layout constants ──────────────────────────────────────────────────────── //

const SIDEBAR_MIN_WIDTH: f32 = 220;
const SIDEBAR_PADDING: f32 = 8;
const BOTTOM_BAR_MIN_HEIGHT: f32 = 150;
const BOTTOM_BAR_PADDING: f32 = 8;
const OVERLAY_MIN_WIDTH: f32 = 360;
const OVERLAY_MIN_HEIGHT: f32 = 220;

// ── Public draw functions ─────────────────────────────────────────────────── //

/// Render toggle buttons for each registered plugin panel in the toolbar.
pub fn drawToolbarButtons(app: *AppState) void {
    if (app.gui.plugin_panels.items.len == 0) return;
    dvui.labelNoFmt(@src(), "Plugins", .{}, .{ .id_extra = 0 });
    for (app.gui.plugin_panels.items, 0..) |panel, i| {
        var label_buf: [64]u8 = undefined;
        const vis = if (panel.visible) "*" else "";
        const label = std.fmt.bufPrint(&label_buf, "{s}{s}", .{ vis, panel.title }) catch panel.title;
        if (dvui.button(@src(), label, .{}, .{ .id_extra = i + 1 })) {
            app.gui.plugin_panels.items[i].visible = !app.gui.plugin_panels.items[i].visible;
        }
    }
}

/// Draw all visible plugin panels with the given sidebar layout (left or right).
pub fn drawSidebar(app: *AppState, layout: PluginPanelLayout) void {
    for (app.gui.plugin_panels.items) |panel| {
        if (!panel.visible or panel.layout != layout) continue;
        var box = dvui.box(@src(), .{ .dir = .vertical }, .{
            .background = true,
            .color_fill = .{ .r = 30, .g = 30, .b = 34, .a = 255 },
            .min_size_content = .{ .w = SIDEBAR_MIN_WIDTH },
            .padding = .{ .x = SIDEBAR_PADDING, .y = SIDEBAR_PADDING, .w = SIDEBAR_PADDING, .h = SIDEBAR_PADDING },
            .expand = .vertical,
        });
        defer box.deinit();
        drawPanelBody(panel);
    }
}

/// Draw all visible plugin panels with layout == .bottom_bar in a horizontal dock.
pub fn drawBottomBar(app: *AppState) void {
    if (!hasVisibleBottomBar(app)) return;

    var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .background = true,
        .color_fill = .{ .r = 30, .g = 30, .b = 34, .a = 255 },
        .min_size_content = .{ .h = BOTTOM_BAR_MIN_HEIGHT },
        .padding = .{ .x = BOTTOM_BAR_PADDING, .y = BOTTOM_BAR_PADDING, .w = BOTTOM_BAR_PADDING, .h = BOTTOM_BAR_PADDING },
        .expand = .horizontal,
    });
    defer bar.deinit();

    for (app.gui.plugin_panels.items) |panel| {
        if (!panel.visible or panel.layout != .bottom_bar) continue;
        var section = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .both,
        });
        defer section.deinit();
        drawPanelBody(panel);
    }
}

/// Returns true if any plugin panel with layout == .bottom_bar is visible.
pub fn hasVisibleBottomBar(app: *AppState) bool {
    for (app.gui.plugin_panels.items) |panel| {
        if (panel.visible and panel.layout == .bottom_bar) return true;
    }
    return false;
}

/// Draw all visible overlay-style plugin panels as floating windows.
pub fn drawOverlays(app: *AppState) void {
    for (app.gui.plugin_panels.items, 0..) |*panel, i| {
        if (!panel.visible or panel.layout != .overlay) continue;

        var fwin = dvui.floatingWindow(@src(), .{
            .open_flag = &panel.visible,
        }, .{
            .id_extra = i,
            .min_size_content = .{ .w = OVERLAY_MIN_WIDTH, .h = OVERLAY_MIN_HEIGHT },
        });
        defer fwin.deinit();

        fwin.dragAreaSet(dvui.windowHeader(panel.title, "", &panel.visible));

        drawPanelBody(panel.*);
    }
}

/// Check if a plain key press toggles a plugin panel. Returns true if handled.
pub fn handlePlainKeyToggle(app: *AppState, key_char: u8) bool {
    if (key_char == 0) return false;
    return app.togglePluginPanelByKey(key_char);
}

/// Try to dispatch a vim command as a plugin panel toggle. Returns true if handled.
pub fn tryHandleVim(app: *AppState, name: []const u8) bool {
    return app.togglePluginPanelByVim(name);
}

fn drawPanelBody(panel: PluginPanel) void {
    box_stack_top = 0; // guard against unbalanced begin_row/end_row
    if (panel.draw_fn) |draw| {
        draw(&g_ui_ctx);
        // Clean up any boxes the plugin left open (shouldn't happen, but safe)
        while (box_stack_top > 0) {
            box_stack_top -= 1;
            box_stack[box_stack_top].deinit();
        }
        return;
    }
    dvui.labelNoFmt(@src(), panel.title, .{}, .{});
    var info_buf: [96]u8 = undefined;
    const info = if (panel.keybind == 0)
        std.fmt.bufPrint(&info_buf, ":{s} | key: -", .{panel.vim_cmd}) catch panel.vim_cmd
    else
        std.fmt.bufPrint(&info_buf, ":{s} | key: {c}", .{ panel.vim_cmd, panel.keybind }) catch panel.vim_cmd;
    dvui.labelNoFmt(@src(), info, .{}, .{});
    dvui.labelNoFmt(@src(), "Plugin-owned UI region", .{}, .{});
}
