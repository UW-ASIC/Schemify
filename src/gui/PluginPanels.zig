//! Plugin panel rendering — sidebars, bottom bar, and overlay windows.
//!
//! Each panel is drawn from its `ParsedWidget` list (populated by the plugin
//! runtime).  Layout is determined by `PluginPanelLayout`.

const std = @import("std");
const dvui = @import("dvui");
const st = @import("state");
const plugin_runtime = @import("runtime");

const AppState = st.AppState;
const PluginPanel = st.PluginPanel;
const PluginPanelLayout = st.PluginPanelLayout;
const Runtime = plugin_runtime.Runtime;

const sidebar_min_width: f32 = 220;
const sidebar_padding: f32 = 8;
const bottom_bar_min_height: f32 = 150;
const bottom_bar_padding: f32 = 8;
const overlay_min_width: f32 = 360;
const overlay_min_height: f32 = 220;
const panel_bg = dvui.Color{ .r = 24, .g = 24, .b = 30, .a = 255 };
const awaiting_plugin_msg = "(awaiting plugin response)";

/// Maximum row nesting depth (begin_row / end_row).
const MAX_ROW_NESTING: usize = 8;

/// Maximum tracked collapsible sections per panel.
const MAX_COLLAPSIBLES: usize = 32;

// ── Public draw entry points ──────────────────────────────────────────────── //

pub fn drawSidebar(app: *AppState, layout: PluginPanelLayout) void {
    const panels = app.gui.plugin_panels.items;
    for (panels) |panel| {
        if (!panel.visible or panel.layout != layout) continue;
        var box = dvui.box(@src(), .{ .dir = .vertical }, .{
            .background = true,
            .color_fill = panel_bg,
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
        drawPanelBody(panel, app);
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
        .color_fill = panel_bg,
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
        drawPanelBody(panel, app);
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
        drawPanelBody(panel.*, app);
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

/// Render all widgets for a single plugin panel.
///
/// Reads the ParsedWidget list from the runtime via the opaque pointer stored
/// in AppState.  Each widget type maps to a dvui call.  Interactive widgets
/// (button, slider, checkbox) dispatch events back through the runtime so the
/// plugin sees them on the next tick.
fn drawPanelBody(panel: PluginPanel, app: *AppState) void {
    // Title (always shown, highlight style).
    dvui.labelNoFmt(@src(), panel.title, .{}, .{ .style = .highlight });

    // Obtain runtime pointer -- graceful null check per UI-SPEC.
    const rt_ptr = app.plugin_runtime_ptr orelse {
        drawAwaitingPlugin(@as(usize, 0xFFFF));
        return;
    };
    const rt: *Runtime = @ptrCast(@alignCast(rt_ptr));

    // Fetch the widget list for this panel.
    const wl = rt.getPanelWidgetList(panel.panel_id);
    const len = wl.len;
    if (len == 0) {
        drawAwaitingPlugin(@as(usize, 0xFFFE));
        return;
    }

    const tags = wl.items(.tag);
    const widget_ids = wl.items(.widget_id);
    const strs = wl.items(.str);
    const vals = wl.items(.val);
    const mins = wl.items(.min);
    const maxs = wl.items(.max);
    const opens = wl.items(.open);

    // Row layout stack (begin_row / end_row nesting).
    var row_boxes: [MAX_ROW_NESTING]*dvui.BoxWidget = undefined;
    var row_depth: usize = 0;

    // Collapsible section state tracking.
    var collapsed: [MAX_COLLAPSIBLES]bool = .{true} ** MAX_COLLAPSIBLES;
    var collapse_idx: usize = 0;
    var skip_depth: usize = 0;

    for (0..len) |i| {
        const tag = tags[i];
        const wid = widget_ids[i];
        const str = strs[i];
        const val = vals[i];
        const mn = mins[i];
        const mx = maxs[i];

        // If inside a collapsed section, only track nesting depth.
        if (skip_depth > 0) {
            if (tag == .collapsible_start) {
                skip_depth += 1;
            } else if (tag == .collapsible_end) {
                skip_depth -= 1;
            }
            continue;
        }

        switch (tag) {
            .label => {
                dvui.labelNoFmt(@src(), str, .{}, .{ .id_extra = i });
            },
            .button => {
                if (dvui.button(@src(), str, .{}, .{ .id_extra = i })) {
                    rt.dispatchButtonClicked(panel.panel_id, wid);
                }
            },
            .separator => {
                _ = dvui.separator(@src(), .{ .id_extra = i });
            },
            .begin_row => {
                if (row_depth < MAX_ROW_NESTING) {
                    row_boxes[row_depth] = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = i });
                    row_depth += 1;
                }
            },
            .end_row => {
                if (row_depth > 0) {
                    row_depth -= 1;
                    row_boxes[row_depth].deinit();
                }
            },
            .slider => {
                // dvui slider works on a 0-1 fraction; convert from plugin's min/max range.
                const range = mx - mn;
                var fraction: f32 = sliderFraction(val, mn, mx);
                if (dvui.slider(@src(), .{ .fraction = &fraction }, .{ .id_extra = i })) {
                    const new_val = mn + fraction * range;
                    rt.dispatchSliderChanged(panel.panel_id, wid, new_val);
                }
            },
            .checkbox => {
                var checked: bool = val != 0;
                if (dvui.checkbox(@src(), &checked, str, .{ .id_extra = i })) {
                    rt.dispatchCheckboxChanged(panel.panel_id, wid, checked);
                }
            },
            .progress => {
                dvui.progress(@src(), .{ .percent = val }, .{ .id_extra = i });
            },
            .collapsible_start => {
                const cidx = collapse_idx;
                collapse_idx += 1;
                // Default to open if the plugin requested it.
                if (opens[i] and cidx < MAX_COLLAPSIBLES) {
                    collapsed[cidx] = false;
                }
                // Render toggle button as a highlight-styled button.
                if (dvui.button(@src(), str, .{}, .{ .id_extra = i, .style = .highlight })) {
                    if (cidx < MAX_COLLAPSIBLES) {
                        collapsed[cidx] = !collapsed[cidx];
                    }
                }
                // If collapsed, skip content until matching collapsible_end.
                if (cidx < MAX_COLLAPSIBLES and collapsed[cidx]) {
                    skip_depth = 1;
                }
            },
            .collapsible_end => {
                // Nothing to do when not skipping.
            },
        }
    }

    // Auto-close any unclosed row boxes.
    while (row_depth > 0) {
        row_depth -= 1;
        row_boxes[row_depth].deinit();
    }
}

fn drawAwaitingPlugin(id_extra: usize) void {
    dvui.labelNoFmt(@src(), awaiting_plugin_msg, .{}, .{ .id_extra = id_extra });
}

fn sliderFraction(val: f32, mn: f32, mx: f32) f32 {
    const range = mx - mn;
    return if (range > 0) std.math.clamp((val - mn) / range, 0, 1) else 0;
}
