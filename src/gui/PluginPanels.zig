const std = @import("std");
const dvui = @import("dvui");
const st = @import("state");
const plugin_runtime = @import("runtime");

const AppState          = st.AppState;
const PluginPanel       = st.PluginPanel;
const PluginPanelLayout = st.PluginPanelLayout;
const Runtime           = plugin_runtime.Runtime;
const ParsedWidget      = Runtime.ParsedWidget;

const sidebar_min_width:     f32 = 220;
const sidebar_padding:       f32 = 8;
const bottom_bar_min_height: f32 = 150;
const bottom_bar_padding:    f32 = 8;
const overlay_min_width:     f32 = 360;
const overlay_min_height:    f32 = 220;

// ── Comptime render dispatch table ───────────────────────────────────────── //
//
// Indexed by WidgetTag ordinal — zero branch mispredictions, no switch chains.

const WidgetTag = Runtime.WidgetTag;

/// Fn signature shared by every entry in the render table.
const RenderFn = *const fn (ParsedWidget, *Runtime, u16, usize) void;

fn renderNoop(_: ParsedWidget, _: *Runtime, _: u16, _: usize) void {}

fn renderLabel(w: ParsedWidget, _: *Runtime, _: u16, i: usize) void {
    dvui.labelNoFmt(@src(), w.str, .{}, .{ .id_extra = i });
}

fn renderButton(w: ParsedWidget, rt: *Runtime, panel_id: u16, i: usize) void {
    if (dvui.button(@src(), w.str, .{}, .{ .id_extra = i }))
        rt.dispatchButtonClicked(panel_id, w.widget_id);
}

fn renderSeparator(_: ParsedWidget, _: *Runtime, _: u16, i: usize) void {
    _ = dvui.separator(@src(), .{ .id_extra = i });
}

fn renderBeginRow(_: ParsedWidget, _: *Runtime, _: u16, i: usize) void {
    _ = dvui.separator(@src(), .{ .id_extra = i + 10000 });
}

fn renderEndRow(_: ParsedWidget, _: *Runtime, _: u16, _: usize) void {}

fn renderSlider(w: ParsedWidget, rt: *Runtime, panel_id: u16, i: usize) void {
    const range = if (w.max != w.min) w.max - w.min else 1.0;
    var frac: f32 = std.math.clamp((w.val - w.min) / range, 0.0, 1.0);
    if (dvui.slider(@src(), .{ .fraction = &frac }, .{ .id_extra = i, .expand = .horizontal }))
        rt.dispatchSliderChanged(panel_id, w.widget_id, w.min + frac * range);
}

fn renderCheckbox(w: ParsedWidget, rt: *Runtime, panel_id: u16, i: usize) void {
    var checked = w.val != 0;
    if (dvui.checkbox(@src(), &checked, w.str, .{ .id_extra = i }))
        rt.dispatchCheckboxChanged(panel_id, w.widget_id, checked);
}

fn renderProgress(w: ParsedWidget, _: *Runtime, _: u16, i: usize) void {
    dvui.progress(@src(), .{ .percent = w.val }, .{ .id_extra = i, .expand = .horizontal });
}

fn renderCollapsibleStart(w: ParsedWidget, _: *Runtime, _: u16, i: usize) void {
    _ = dvui.expander(@src(), w.str,
        .{ .default_expanded = w.open }, .{ .id_extra = i });
}

fn renderCollapsibleEnd(_: ParsedWidget, _: *Runtime, _: u16, _: usize) void {}

/// Comptime-built render table indexed by WidgetTag ordinal.
const render_table: [@typeInfo(WidgetTag).@"enum".fields.len]RenderFn = blk: {
    const fields = @typeInfo(WidgetTag).@"enum".fields;
    var tbl: [fields.len]RenderFn = undefined;
    for (fields) |f| {
        tbl[f.value] = switch (@field(WidgetTag, f.name)) {
            .label             => renderLabel,
            .button            => renderButton,
            .separator         => renderSeparator,
            .begin_row         => renderBeginRow,
            .end_row           => renderEndRow,
            .slider            => renderSlider,
            .checkbox          => renderCheckbox,
            .progress          => renderProgress,
            .collapsible_start => renderCollapsibleStart,
            .collapsible_end   => renderCollapsibleEnd,
        };
    }
    break :blk tbl;
};

// ── Public draw entry points ──────────────────────────────────────────────── //

pub fn drawToolbarButtons(app: *AppState, rt: *Runtime) void {
    _ = rt;
    const panels = app.gui.plugin_panels.items;
    if (panels.len == 0) return;
    dvui.labelNoFmt(@src(), "Plugins", .{}, .{ .id_extra = 0 });
    for (panels, 0..) |panel, i| {
        var label_buf: [64]u8 = undefined;
        const vis   = if (panel.visible) "*" else "";
        const label = std.fmt.bufPrint(&label_buf, "{s}{s}", .{ vis, panel.title }) catch panel.title;
        if (dvui.button(@src(), label, .{}, .{ .id_extra = i + 1 })) {
            app.gui.plugin_panels.items[i].visible = !app.gui.plugin_panels.items[i].visible;
        }
    }
}

pub fn drawSidebar(app: *AppState, rt: *Runtime, layout: PluginPanelLayout) void {
    const panels = app.gui.plugin_panels.items;
    for (panels) |panel| {
        if (!panel.visible or panel.layout != layout) continue;
        var box = dvui.box(@src(), .{ .dir = .vertical }, .{
            .background       = true,
            .color_fill       = .{ .r = 24, .g = 24, .b = 30, .a = 255 },
            .min_size_content = .{ .w = sidebar_min_width },
            .padding          = .{ .x = sidebar_padding, .y = sidebar_padding,
                                   .w = sidebar_padding, .h = sidebar_padding },
            .expand           = .vertical,
        });
        defer box.deinit();
        drawPanelBody(rt, panel);
    }
}

pub fn drawBottomBar(app: *AppState, rt: *Runtime) void {
    const panels = app.gui.plugin_panels.items;

    // Single pass: bail early if no bottom-bar panel is visible, otherwise
    // render all of them inside the shared container.
    var has_bottom = false;
    for (panels) |p| {
        if (p.visible and p.layout == .bottom_bar) { has_bottom = true; break; }
    }
    if (!has_bottom) return;

    var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .background       = true,
        .color_fill       = .{ .r = 24, .g = 24, .b = 30, .a = 255 },
        .min_size_content = .{ .h = bottom_bar_min_height },
        .padding          = .{ .x = bottom_bar_padding, .y = bottom_bar_padding,
                               .w = bottom_bar_padding, .h = bottom_bar_padding },
        .expand           = .horizontal,
    });
    defer bar.deinit();

    for (panels) |panel| {
        if (!panel.visible or panel.layout != .bottom_bar) continue;
        var section = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
        defer section.deinit();
        drawPanelBody(rt, panel);
    }
}

pub fn hasVisibleBottomBar(app: *AppState) bool {
    for (app.gui.plugin_panels.items) |panel| {
        if (panel.visible and panel.layout == .bottom_bar) return true;
    }
    return false;
}

pub fn drawOverlays(app: *AppState, rt: *Runtime) void {
    for (app.gui.plugin_panels.items, 0..) |*panel, i| {
        if (!panel.visible or panel.layout != .overlay) continue;

        var fwin = dvui.floatingWindow(@src(), .{
            .open_flag = &panel.visible,
        }, .{
            .id_extra         = i,
            .min_size_content = .{ .w = overlay_min_width, .h = overlay_min_height },
        });
        defer fwin.deinit();

        fwin.dragAreaSet(dvui.windowHeader(panel.title, "", &panel.visible));
        drawPanelBody(rt, panel.*);
    }
}

pub fn handlePlainKeyToggle(app: *AppState, key_char: u8) bool {
    if (key_char == 0) return false;
    return app.togglePluginPanelByKey(key_char);
}

pub fn tryHandleVim(app: *AppState, name: []const u8) bool {
    return app.togglePluginPanelByVim(name);
}

// ── Private rendering ─────────────────────────────────────────────────────── //

fn drawPanelBody(rt: *Runtime, panel: PluginPanel) void {
    const widgets = rt.getPanelWidgetList(panel.panel_id);
    if (widgets.len == 0) {
        dvui.labelNoFmt(@src(), panel.title, .{}, .{});
        return;
    }
    for (0..widgets.len) |i| {
        const widget = widgets.get(i);
        render_table[@intFromEnum(widget.tag)](widget, rt, panel.panel_id, i);
    }
}

test "Expose struct size for plugin_panels" {
    const print = @import("std").debug.print;
    print("PanelState: {d}B\n", .{@sizeOf(PluginPanel)});
}
