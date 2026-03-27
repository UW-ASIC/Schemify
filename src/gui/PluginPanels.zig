//! Plugin panel rendering — sidebars, bottom bar, and overlay windows.
//!
//! Each panel is drawn from its `ParsedWidget` list (populated by the plugin
//! runtime).  Layout is determined by `PluginPanelLayout`.

const std = @import("std");
const dvui = @import("dvui");
const st = @import("state");

const AppState = st.AppState;
const PluginPanel = st.PluginPanel;
const PluginPanelLayout = st.PluginPanelLayout;

const sidebar_min_width: f32 = 220;
const sidebar_padding: f32 = 8;
const bottom_bar_min_height: f32 = 150;
const bottom_bar_padding: f32 = 8;
const overlay_min_width: f32 = 360;
const overlay_min_height: f32 = 220;

// ── Public draw entry points ──────────────────────────────────────────────── //

pub fn drawSidebar(app: *AppState, layout: PluginPanelLayout) void {
    const panels = app.gui.plugin_panels.items;
    for (panels) |panel| {
        if (!panel.visible or panel.layout != layout) continue;
        var box = dvui.box(@src(), .{ .dir = .vertical }, .{
            .background = true,
            .color_fill = .{ .r = 24, .g = 24, .b = 30, .a = 255 },
            .min_size_content = .{ .w = sidebar_min_width },
            .padding = .{
                .x = sidebar_padding,
                .y = sidebar_padding,
                .w = sidebar_padding,
                .h = sidebar_padding,
            },
            .expand = .vertical,
        });
        defer box.deinit();
        drawPanelBody(panel);
    }
}

pub fn drawBottomBar(app: *AppState) void {
    const panels = app.gui.plugin_panels.items;

    var has_bottom = false;
    for (panels) |p| {
        if (p.visible and p.layout == .bottom_bar) {
            has_bottom = true;
            break;
        }
    }
    if (!has_bottom) return;

    var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .background = true,
        .color_fill = .{ .r = 24, .g = 24, .b = 30, .a = 255 },
        .min_size_content = .{ .h = bottom_bar_min_height },
        .padding = .{
            .x = bottom_bar_padding,
            .y = bottom_bar_padding,
            .w = bottom_bar_padding,
            .h = bottom_bar_padding,
        },
        .expand = .horizontal,
    });
    defer bar.deinit();

    for (panels) |panel| {
        if (!panel.visible or panel.layout != .bottom_bar) continue;
        var section = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
        defer section.deinit();
        drawPanelBody(panel);
    }
}

pub fn drawOverlays(app: *AppState) void {
    for (app.gui.plugin_panels.items, 0..) |*panel, i| {
        if (!panel.visible or panel.layout != .overlay) continue;

        var fwin = dvui.floatingWindow(@src(), .{
            .open_flag = &panel.visible,
        }, .{
            .id_extra = i,
            .min_size_content = .{ .w = overlay_min_width, .h = overlay_min_height },
        });
        defer fwin.deinit();

        fwin.dragAreaSet(dvui.windowHeader(panel.title, "", &panel.visible));
        drawPanelBody(panel.*);
    }
}

pub fn handlePlainKeyToggle(app: *AppState, key_char: u8) bool {
    if (key_char == 0) return false;
    const panels = app.gui.plugin_panels.items;
    const idx_i8 = app.gui.key_to_panel[key_char];
    if (idx_i8 < 0) return false;
    const idx: usize = @intCast(idx_i8);
    if (idx >= panels.len) return false;
    app.gui.plugin_panels.items[idx].visible = !panels[idx].visible;
    return true;
}

pub fn tryHandleVim(app: *AppState, name: []const u8) bool {
    for (app.gui.plugin_panels.items, 0..) |panel, i| {
        if (std.mem.eql(u8, panel.vim_cmd, name)) {
            app.gui.plugin_panels.items[i].visible = !panel.visible;
            return true;
        }
    }
    return false;
}

// ── Private rendering ─────────────────────────────────────────────────────── //

fn drawPanelBody(panel: PluginPanel) void {
    // TODO: When plugin runtime is wired in, render ParsedWidget lists here.
    // For now, show a placeholder label with the panel title.
    dvui.labelNoFmt(@src(), panel.title, .{}, .{ .style = .highlight });
    dvui.labelNoFmt(@src(), "(plugin panel — connect runtime to render widgets)", .{}, .{ .id_extra = 1 });
}
