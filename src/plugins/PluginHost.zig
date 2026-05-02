const std = @import("std");
const types = @import("types.zig");

pub const WidgetSlice = std.MultiArrayList(types.ParsedWidget).Slice;

inline fn castPtr(comptime T: type, p: *anyopaque) *T {
    return @ptrCast(@alignCast(p));
}

pub const PluginHost = struct {
    ctx: *anyopaque,
    ensureLoaded: *const fn (*anyopaque, []const u8) void,
    getPanelWidgets: *const fn (*anyopaque, u16) WidgetSlice,
    buttonClicked: *const fn (*anyopaque, u16, u32) void,
    sliderChanged: *const fn (*anyopaque, u16, u32, f32) void,
    checkboxChanged: *const fn (*anyopaque, u16, u32, bool) void,
    textChanged: *const fn (*anyopaque, u16, u32, []const u8) void,
    hover: *const fn (*anyopaque, i32, i32, u8, i32, []const u8) void,
    getTooltip: *const fn (*anyopaque) []const u8,
    keyEvent: *const fn (*anyopaque, u8, u8, u8) bool,

    pub inline fn dispatchButton(self: PluginHost, panel: u16, widget: u32) void {
        self.buttonClicked(self.ctx, panel, widget);
    }
    pub inline fn dispatchSlider(self: PluginHost, panel: u16, widget: u32, val: f32) void {
        self.sliderChanged(self.ctx, panel, widget, val);
    }
    pub inline fn dispatchCheckbox(self: PluginHost, panel: u16, widget: u32, val: bool) void {
        self.checkboxChanged(self.ctx, panel, widget, val);
    }
    pub inline fn dispatchText(self: PluginHost, panel: u16, widget: u32, text: []const u8) void {
        self.textChanged(self.ctx, panel, widget, text);
    }
    pub inline fn dispatchHover(self: PluginHost, wx: i32, wy: i32, etype: u8, eidx: i32, ename: []const u8) void {
        self.hover(self.ctx, wx, wy, etype, eidx, ename);
    }
    pub inline fn dispatchKeyEvent(self: PluginHost, key: u8, mods: u8, action: u8) bool {
        return self.keyEvent(self.ctx, key, mods, action);
    }
    pub inline fn tooltipText(self: PluginHost) []const u8 {
        return self.getTooltip(self.ctx);
    }
    pub inline fn widgets(self: PluginHost, panel_id: u16) WidgetSlice {
        return self.getPanelWidgets(self.ctx, panel_id);
    }
    pub inline fn loadPlugin(self: PluginHost, name: []const u8) void {
        self.ensureLoaded(self.ctx, name);
    }
};

pub fn from(comptime T: type, ptr: *T) PluginHost {
    const S = struct {
        fn ensureLoaded(c: *anyopaque, n: []const u8) void { castPtr(T, c).ensureLoaded(n); }
        fn getPanelWidgets(c: *anyopaque, p: u16) WidgetSlice { return castPtr(T, c).getPanelWidgets(p); }
        fn buttonClicked(c: *anyopaque, p: u16, w: u32) void { castPtr(T, c).buttonClicked(p, w); }
        fn sliderChanged(c: *anyopaque, p: u16, w: u32, v: f32) void { castPtr(T, c).sliderChanged(p, w, v); }
        fn checkboxChanged(c: *anyopaque, p: u16, w: u32, v: bool) void { castPtr(T, c).checkboxChanged(p, w, v); }
        fn textChanged(c: *anyopaque, p: u16, w: u32, t: []const u8) void { castPtr(T, c).textChanged(p, w, t); }
        fn hover(c: *anyopaque, wx: i32, wy: i32, et: u8, ei: i32, en: []const u8) void { castPtr(T, c).hover(wx, wy, et, ei, en); }
        fn getTooltip(c: *anyopaque) []const u8 { return castPtr(T, c).getTooltip(); }
        fn keyEvent(c: *anyopaque, k: u8, m: u8, a: u8) bool { return castPtr(T, c).keyEvent(k, m, a); }
    };
    return .{
        .ctx = ptr,
        .ensureLoaded = &S.ensureLoaded,
        .getPanelWidgets = &S.getPanelWidgets,
        .buttonClicked = &S.buttonClicked,
        .sliderChanged = &S.sliderChanged,
        .checkboxChanged = &S.checkboxChanged,
        .textChanged = &S.textChanged,
        .hover = &S.hover,
        .getTooltip = &S.getTooltip,
        .keyEvent = &S.keyEvent,
    };
}
