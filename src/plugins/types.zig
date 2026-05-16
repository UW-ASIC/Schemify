const std = @import("std");

pub const PROTOCOL_VERSION: u32 = 1;

pub const PanelLayout = enum(u8) { overlay = 0, left_sidebar = 1, right_sidebar = 2, bottom_bar = 3 };
pub const LogLevel = enum(u8) { info = 0, warn = 1, err = 2 };

pub const PluginState = enum { starting, running, stopped, error_state };

pub const WidgetTag = enum(u8) {
    label,
    button,
    separator,
    begin_row,
    end_row,
    slider,
    checkbox,
    progress,
    collapsible_start,
    collapsible_end,
    tooltip,
    text_input,
    text_area,
};

pub const ParsedWidget = struct {
    str: []const u8 = &.{},
    val: f32 = 0,
    min: f32 = 0,
    max: f32 = 1,
    widget_id: u32 = 0,
    tag: WidgetTag = .label,
    open: bool = false,
};

pub const WidgetSlice = std.MultiArrayList(ParsedWidget).Slice;

pub const PanelDef = struct {
    id: []const u8,
    title: []const u8,
    vim_cmd: []const u8,
    layout: PanelLayout,
    keybind: u8,
};
