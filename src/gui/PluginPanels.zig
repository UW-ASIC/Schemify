//! Plugin panel rendering -- sidebars, bottom bar, and overlay windows.
//!
//! Each panel is drawn from its ParsedWidget list (populated by the plugin
//! runtime via Runtime). Layout is determined by PluginPanelLayout.

const std = @import("std");
const dvui = @import("dvui");
const st = @import("state");
const plugins = @import("plugins");

const AppState = st.AppState;
const PluginPanelMeta = st.PluginPanelMeta;
const PluginPanelState = st.PluginPanelState;
const PluginPanelLayout = st.PluginPanelLayout;

const tc = @import("theme_config");

const sidebar_min_width: f32 = 220;
const sidebar_padding: f32 = 8;
const bottom_bar_min_height: f32 = 150;
const bottom_bar_padding: f32 = 8;
const overlay_min_width: f32 = 360;
const overlay_min_height: f32 = 220;
const awaiting_msg = "(awaiting plugin response)";

const MAX_ROW_NESTING: usize = 8;
const MAX_COLLAPSIBLES: usize = 32;

// -- Public draw entry points -------------------------------------------------

pub fn drawSidebar(app: *AppState, layout: PluginPanelLayout) void {
    const metas = app.gui.cold.plugin_panels_meta.items;
    const states = app.gui.cold.plugin_panels_state.items;
    for (states, 0..) |state, i| {
        if (!state.visible or state.layout != layout) continue;
        var box = dvui.box(@src(), .{ .dir = .vertical }, .{
            .id_extra = i,
            .background = true,
            .color_fill = tc.getSidebarBg(),
            .min_size_content = .{ .w = sidebar_min_width },
            .padding = .{ .x = sidebar_padding, .y = sidebar_padding, .w = sidebar_padding, .h = sidebar_padding },
            .expand = .vertical,
        });
        defer box.deinit();
        drawPanelBody(metas[i], state, app, i, false);
    }
}

pub fn drawBottomBar(app: *AppState) void {
    const states = app.gui.cold.plugin_panels_state.items;
    var has_bottom = false;
    for (states) |s| if (s.visible and s.layout == .bottom_bar) {
        has_bottom = true;
        break;
    };
    if (!has_bottom) return;

    var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .background = true,
        .color_fill = tc.getBottomBarBg(),
        .min_size_content = .{ .h = bottom_bar_min_height },
        .padding = .{ .x = bottom_bar_padding, .y = bottom_bar_padding, .w = bottom_bar_padding, .h = bottom_bar_padding },
        .expand = .horizontal,
    });
    defer bar.deinit();

    const metas = app.gui.cold.plugin_panels_meta.items;
    for (states, 0..) |state, i| {
        if (!state.visible or state.layout != .bottom_bar) continue;
        var section = dvui.box(@src(), .{ .dir = .vertical }, .{ .id_extra = i, .expand = .both });
        defer section.deinit();
        drawPanelBody(metas[i], state, app, i, false);
    }
}

pub fn drawOverlays(app: *AppState) void {
    const metas = app.gui.cold.plugin_panels_meta.items;
    for (app.gui.cold.plugin_panels_state.items, 0..) |*state, i| {
        if (!state.visible or state.layout != .overlay) continue;
        var fwin = dvui.floatingWindow(@src(), .{ .open_flag = &state.visible }, .{
            .id_extra = i,
            .min_size_content = .{ .w = overlay_min_width, .h = overlay_min_height },
        });
        defer fwin.deinit();
        fwin.dragAreaSet(dvui.windowHeader(metas[i].title, "", &state.visible));
        drawPanelBody(metas[i], state.*, app, i, true);
    }
}

pub fn handlePlainKeyToggle(app: *AppState, key_char: u8) bool {
    if (key_char == 0) return false;
    const idx_i8 = app.gui.cold.key_to_panel[key_char];
    if (idx_i8 < 0) return false;
    const idx: usize = @intCast(idx_i8);
    if (idx >= app.gui.cold.plugin_panels_state.items.len) return false;
    app.gui.cold.plugin_panels_state.items[idx].visible = !app.gui.cold.plugin_panels_state.items[idx].visible;
    return true;
}

pub fn tryHandleVim(app: *AppState, name: []const u8) bool {
    const metas = app.gui.cold.plugin_panels_meta.items;
    for (app.gui.cold.plugin_panels_state.items, 0..) |state, i| {
        if (std.mem.eql(u8, metas[i].vim_cmd, name)) {
            app.gui.cold.plugin_panels_state.items[i].visible = !state.visible;
            return true;
        }
    }
    return false;
}

// -- Private rendering --------------------------------------------------------

const CollapsibleTracker = struct {
    collapsed: [MAX_COLLAPSIBLES]bool = .{true} ** MAX_COLLAPSIBLES,
    idx: usize = 0,
    skip_depth: usize = 0,

    fn shouldSkip(self: *CollapsibleTracker, tag: anytype) bool {
        if (self.skip_depth > 0) {
            if (tag == .collapsible_start) self.skip_depth += 1
            else if (tag == .collapsible_end) self.skip_depth -= 1;
            return true;
        }
        return false;
    }

    fn startSection(self: *CollapsibleTracker, str: []const u8, is_open: bool, id_extra: usize) bool {
        const cidx = self.idx;
        self.idx += 1;
        if (is_open and cidx < MAX_COLLAPSIBLES) self.collapsed[cidx] = false;
        if (dvui.button(@src(), str, .{}, .{ .id_extra = id_extra, .style = .highlight })) {
            if (cidx < MAX_COLLAPSIBLES) self.collapsed[cidx] = !self.collapsed[cidx];
        }
        if (cidx < MAX_COLLAPSIBLES and self.collapsed[cidx]) {
            self.skip_depth = 1;
            return false;
        }
        return true;
    }
};

const RowStack = struct {
    boxes: [MAX_ROW_NESTING]*dvui.BoxWidget = undefined,
    depth: usize = 0,

    fn push(self: *RowStack, id_extra: usize) void {
        if (self.depth < MAX_ROW_NESTING) {
            self.boxes[self.depth] = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = id_extra });
            self.depth += 1;
        }
    }

    fn pop(self: *RowStack) void {
        if (self.depth > 0) {
            self.depth -= 1;
            self.boxes[self.depth].deinit();
        }
    }

    fn closeAll(self: *RowStack) void {
        while (self.depth > 0) self.pop();
    }
};

fn drawPanelBody(meta: PluginPanelMeta, state: PluginPanelState, app: *AppState, panel_idx: usize, is_overlay: bool) void {
    const id_base = panel_idx *| 0x10000;

    switch (state.load_state) {
        .lazy_pending => {
            // TODO: lazy-load plugin via spawnPlugin
            dvui.labelNoFmt(@src(), "Loading...", .{}, .{ .id_extra = id_base });
            return;
        },
        .loading => {
            dvui.labelNoFmt(@src(), "Loading...", .{}, .{ .id_extra = id_base });
            return;
        },
        .failed => {
            dvui.labelNoFmt(@src(), "Plugin failed to load.", .{}, .{ .id_extra = id_base });
            return;
        },
        .loaded => {},
    }

    if (!is_overlay) dvui.labelNoFmt(@src(), meta.title, .{}, .{ .id_extra = id_base, .style = .highlight });

    const host = app.plugin_runtime orelse {
        dvui.labelNoFmt(@src(), awaiting_msg, .{}, .{ .id_extra = id_base | 0xFFFF });
        return;
    };

    // Send draw_panel to the plugin so it emits current widgets.
    host.drawPanel(app.gpa.allocator(), state.panel_id);

    const wl = host.getPanelWidgets(state.panel_id);
    const len = wl.len;
    if (len == 0) {
        dvui.labelNoFmt(@src(), awaiting_msg, .{}, .{ .id_extra = id_base | 0xFFFE });
        return;
    }

    const tags = wl.items(.tag);
    const widget_ids = wl.items(.widget_id);
    const strs = wl.items(.str);
    const vals = wl.items(.val);
    const mins = wl.items(.min);
    const maxs = wl.items(.max);
    const opens = wl.items(.open);

    var rows: RowStack = .{};
    var collapsibles: CollapsibleTracker = .{};

    for (0..len) |i| {
        const tag = tags[i];
        const wid = id_base + i;

        if (collapsibles.shouldSkip(tag)) continue;

        switch (tag) {
            .label => dvui.labelNoFmt(@src(), strs[i], .{}, .{ .id_extra = wid }),
            .button => {
                if (dvui.button(@src(), strs[i], .{}, .{ .id_extra = wid }))
                    host.buttonClicked(state.panel_id, widget_ids[i]);
            },
            .separator => _ = dvui.separator(@src(), .{ .id_extra = wid }),
            .begin_row => rows.push(wid),
            .end_row => rows.pop(),
            .slider => {
                const range = maxs[i] - mins[i];
                var fraction: f32 = if (range > 0) std.math.clamp((vals[i] - mins[i]) / range, 0, 1) else 0;
                if (dvui.slider(@src(), .{ .fraction = &fraction }, .{ .id_extra = wid }))
                    host.sliderChanged(state.panel_id, widget_ids[i], mins[i] + fraction * range);
            },
            .checkbox => {
                var checked: bool = vals[i] != 0;
                if (dvui.checkbox(@src(), &checked, strs[i], .{ .id_extra = wid }))
                    host.checkboxChanged(state.panel_id, widget_ids[i], checked);
            },
            .progress => dvui.progress(@src(), .{ .percent = vals[i] }, .{ .id_extra = wid }),
            .collapsible_start => _ = collapsibles.startSection(strs[i], opens[i], wid),
            .text_input => {
                var te = dvui.textEntry(@src(), .{
                    .text = .{ .internal = .{ .limit = 4096 } },
                    .placeholder = strs[i],
                }, .{ .id_extra = wid, .expand = .horizontal });
                if (te.enter_pressed) {
                    const txt = te.getText();
                    host.textChanged(state.panel_id, widget_ids[i], txt);
                }
                te.deinit();
            },
            .text_area => {
                var te = dvui.textEntry(@src(), .{
                    .multiline = true,
                    .break_lines = true,
                    .text = .{ .internal = .{ .limit = 32768 } },
                    .placeholder = strs[i],
                }, .{ .id_extra = wid, .expand = .both, .min_size_content = .{ .h = 200 } });
                if (te.text_changed) {
                    const txt = te.getText();
                    host.textChanged(state.panel_id, widget_ids[i], txt);
                }
                te.deinit();
            },
            .collapsible_end, .tooltip => {},
        }
    }

    rows.closeAll();
}
