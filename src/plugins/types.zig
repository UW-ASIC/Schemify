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

pub const PluginWidgetDef = struct {
    name: [64]u8 = [_]u8{0} ** 64,
    name_len: u8 = 0,
    inherit_role: [16]u8 = [_]u8{0} ** 16,
    inherit_role_len: u8 = 0,

    pub fn nameSlice(self: *const PluginWidgetDef) []const u8 {
        return self.name[0..self.name_len];
    }
    pub fn roleSlice(self: *const PluginWidgetDef) []const u8 {
        return self.inherit_role[0..self.inherit_role_len];
    }
};

pub const PluginExtraProp = struct {
    name: [64]u8 = [_]u8{0} ** 64,
    name_len: u8 = 0,
    prop_type: [16]u8 = [_]u8{0} ** 16,
    prop_type_len: u8 = 0,
    default_val: [32]u8 = [_]u8{0} ** 32,
    default_val_len: u8 = 0,

    pub fn nameSlice(self: *const PluginExtraProp) []const u8 {
        return self.name[0..self.name_len];
    }
};

pub const PluginThemeInfo = struct {
    widgets: FixedList(PluginWidgetDef, 8) = .{},
    extra_props: FixedList(PluginExtraProp, 16) = .{},
};

pub fn FixedList(comptime T: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();
        buffer: [capacity]T = undefined,
        len: usize = 0,

        pub fn append(self: *Self, item: T) void {
            if (self.len >= capacity) return;
            self.buffer[self.len] = item;
            self.len += 1;
        }

        pub fn slice(self: *const Self) []const T {
            return self.buffer[0..self.len];
        }

        pub fn sliceMut(self: *Self) []T {
            return self.buffer[0..self.len];
        }
    };
}
