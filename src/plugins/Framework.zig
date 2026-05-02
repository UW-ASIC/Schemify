//! Comptime plugin framework -- generates the process function and ABI
//! descriptor from a declarative spec.  Used by plugin AUTHORS (not the host).

const std = @import("std");
const types = @import("types.zig");
const Reader = @import("Reader.zig");
const Writer = @import("Writer.zig");

const PanelLayout = types.PanelLayout;
const Descriptor = types.Descriptor;
const ABI_VERSION = types.ABI_VERSION;

// -- Widget kind (plugin-side only) -------------------------------------------

pub const WidgetKind = enum { slider, button, label, label_fmt, checkbox, separator, progress };

pub const WidgetSpec = union(WidgetKind) {
    slider: struct { label: [:0]const u8, field: [:0]const u8, min: f32, max: f32 },
    button: struct { label: [:0]const u8, handler: *const fn (*anyopaque) void },
    label: struct { text: [:0]const u8 },
    label_fmt: struct { fmt: [:0]const u8, field: [:0]const u8 },
    checkbox: struct { label: [:0]const u8, field: [:0]const u8, handler: ?*const fn (*anyopaque, bool) void = null },
    separator: struct {},
    progress: struct { field: [:0]const u8 },
};

// -- Type-erasure wrappers ----------------------------------------------------

fn wrapHandler(comptime S: type, comptime h: fn (*S) void) *const fn (*anyopaque) void {
    return &struct {
        fn call(p: *anyopaque) void { h(@alignCast(@ptrCast(p))); }
    }.call;
}

fn wrapCheckboxHandler(comptime S: type, comptime h: fn (*S, bool) void) *const fn (*anyopaque, bool) void {
    return &struct {
        fn call(p: *anyopaque, v: bool) void { h(@alignCast(@ptrCast(p)), v); }
    }.call;
}

pub fn wrapWriterHook(comptime S: type, comptime h: fn (*S, *Writer) void) *const fn (*anyopaque, *Writer) void {
    return &struct {
        fn call(p: *anyopaque, w: *Writer) void { h(@alignCast(@ptrCast(p)), w); }
    }.call;
}

pub const wrapDrawFn = wrapWriterHook;
pub const wrapUnloadHook = wrapHandler;

pub fn wrapOnButton(comptime S: type, comptime h: fn (*S, u32, *Writer) void) *const fn (*anyopaque, u32, *Writer) void {
    return &struct {
        fn call(p: *anyopaque, wid: u32, w: *Writer) void { h(@alignCast(@ptrCast(p)), wid, w); }
    }.call;
}

pub fn wrapTickHook(comptime S: type, comptime h: fn (*S, f32) void) *const fn (*anyopaque, f32) void {
    return &struct {
        fn call(p: *anyopaque, dt: f32) void { h(@alignCast(@ptrCast(p)), dt); }
    }.call;
}

pub fn wrapCommandHook(comptime S: type, comptime h: fn (*S, []const u8, []const u8, *Writer) void) *const fn (*anyopaque, []const u8, []const u8, *Writer) void {
    return &struct {
        fn call(p: *anyopaque, tag: []const u8, payload: []const u8, w: *Writer) void {
            h(@alignCast(@ptrCast(p)), tag, payload, w);
        }
    }.call;
}

pub fn wrapHoverHook(comptime S: type, comptime h: fn (*S, HoverInfo, *Writer) void) *const fn (*anyopaque, HoverInfo, *Writer) void {
    return &struct {
        fn call(p: *anyopaque, info: HoverInfo, w: *Writer) void { h(@alignCast(@ptrCast(p)), info, w); }
    }.call;
}

pub fn wrapKeyEventHook(comptime S: type, comptime h: fn (*S, KeyEventInfo, *Writer) void) *const fn (*anyopaque, KeyEventInfo, *Writer) void {
    return &struct {
        fn call(p: *anyopaque, info: KeyEventInfo, w: *Writer) void { h(@alignCast(@ptrCast(p)), info, w); }
    }.call;
}

// -- Widget constructor helpers -----------------------------------------------

pub fn slider(comptime lbl: [:0]const u8, comptime field: [:0]const u8, comptime min: f32, comptime max: f32) WidgetSpec {
    return .{ .slider = .{ .label = lbl, .field = field, .min = min, .max = max } };
}

pub fn button(comptime lbl: [:0]const u8, comptime S: type, comptime handler: fn (*S) void) WidgetSpec {
    return .{ .button = .{ .label = lbl, .handler = wrapHandler(S, handler) } };
}

pub fn label(comptime text: [:0]const u8) WidgetSpec {
    return .{ .label = .{ .text = text } };
}

pub fn label_fmt(comptime fmt: [:0]const u8, comptime field: [:0]const u8) WidgetSpec {
    return .{ .label_fmt = .{ .fmt = fmt, .field = field } };
}

pub fn checkbox(comptime lbl: [:0]const u8, comptime field: [:0]const u8) WidgetSpec {
    return .{ .checkbox = .{ .label = lbl, .field = field } };
}

pub fn checkboxCb(comptime lbl: [:0]const u8, comptime field: [:0]const u8, comptime S: type, comptime handler: fn (*S, bool) void) WidgetSpec {
    return .{ .checkbox = .{ .label = lbl, .field = field, .handler = wrapCheckboxHandler(S, handler) } };
}

pub fn separator() WidgetSpec {
    return .{ .separator = .{} };
}

pub fn progress(comptime field: [:0]const u8) WidgetSpec {
    return .{ .progress = .{ .field = field } };
}

// -- Panel / Plugin descriptors -----------------------------------------------

pub const PanelSpec = struct {
    id: [:0]const u8,
    title: [:0]const u8,
    vim_cmd: [:0]const u8,
    layout: PanelLayout,
    keybind: u8,
    widgets: []const WidgetSpec = &.{},
    draw_fn: ?*const fn (*anyopaque, *Writer) void = null,
    on_load: ?*const fn (*anyopaque, *Writer) void = null,
    on_unload: ?*const fn (*anyopaque) void = null,
    on_button: ?*const fn (*anyopaque, u32, *Writer) void = null,
};

pub const EVENT_HOVER: u8 = 1 << 0;
pub const EVENT_KEYS: u8 = 1 << 1;

pub const HoverInfo = struct {
    world_x: i32,
    world_y: i32,
    element_type: u8,
    element_idx: i32,
    element_name: []const u8,
};

pub const KeyEventInfo = struct {
    key: u8,
    mods: u8,
    action: u8, // 0=down, 1=up, 2=repeat
};

pub const PluginSpec = struct {
    name: [:0]const u8,
    version: [:0]const u8,
    panels: []const PanelSpec,
    on_load: ?*const fn (*anyopaque, *Writer) void = null,
    on_unload: ?*const fn (*anyopaque, *Writer) void = null,
    on_tick: ?*const fn (*anyopaque, f32) void = null,
    on_command: ?*const fn (*anyopaque, []const u8, []const u8, *Writer) void = null,
    on_hover: ?*const fn (*anyopaque, HoverInfo, *Writer) void = null,
    on_key_event: ?*const fn (*anyopaque, KeyEventInfo, *Writer) void = null,
    event_subscription: u8 = 0,
};

// -- define() -----------------------------------------------------------------

pub fn define(comptime State: type, comptime state_ptr: *State, comptime spec: PluginSpec) type {
    return struct {
        const g: *anyopaque = state_ptr;

        pub fn process(in_ptr: [*]const u8, in_len: usize, out_ptr: [*]u8, out_cap: usize) callconv(.c) usize {
            var r = Reader.init(in_ptr[0..in_len]);
            var w = Writer.init(out_ptr[0..out_cap]);

            while (r.next()) |msg| switch (msg) {
                .load => {
                    inline for (spec.panels) |p| {
                        w.registerPanel(.{ .id = p.id, .title = p.title, .vim_cmd = p.vim_cmd, .layout = p.layout, .keybind = p.keybind });
                        if (p.on_load) |h| h(g, &w);
                    }
                    if (spec.event_subscription != 0) w.subscribeEvents(spec.event_subscription);
                    if (spec.on_load) |h| h(g, &w);
                },
                .unload => {
                    if (spec.on_unload) |h| h(g, &w);
                    inline for (spec.panels) |p| if (p.on_unload) |h| h(g);
                },
                .tick => |ev| if (spec.on_tick) |h| h(g, ev.dt),
                .draw_panel => |ev| inline for (spec.panels, 0..) |p, pi| {
                    if (ev.panel_id == pi) {
                        if (p.draw_fn) |df| {
                            df(g, &w);
                        } else {
                            inline for (p.widgets, 0..) |widget, wi| {
                                const wid: u32 = pi * 256 + wi;
                                switch (widget) {
                                    .slider => |s| {
                                        w.label(s.label, wid);
                                        w.slider(@field(state_ptr.*, s.field), s.min, s.max, wid + 128);
                                    },
                                    .button => |b| w.button(b.label, wid),
                                    .label => |l| w.label(l.text, wid),
                                    .label_fmt => |lf| {
                                        var buf: [256]u8 = undefined;
                                        const text = std.fmt.bufPrint(&buf, lf.fmt, .{@field(state_ptr.*, lf.field)}) catch lf.fmt;
                                        w.label(text, wid);
                                    },
                                    .checkbox => |cb| w.checkbox(@field(state_ptr.*, cb.field), cb.label, wid),
                                    .separator => w.separator(wid),
                                    .progress => |pr| w.progress(@field(state_ptr.*, pr.field), wid),
                                }
                            }
                        }
                    }
                },
                .button_clicked => |ev| inline for (spec.panels, 0..) |p, pi| {
                    if (p.on_button) |h| h(g, ev.widget_id, &w);
                    inline for (p.widgets, 0..) |widget, wi| {
                        if (ev.widget_id == pi * 256 + wi) {
                            if (widget == .button) widget.button.handler(g);
                        }
                    }
                },
                .slider_changed => |ev| inline for (spec.panels, 0..) |_, pi| {
                    inline for (spec.panels[pi].widgets, 0..) |widget, wi| {
                        if (ev.widget_id == pi * 256 + wi + 128) {
                            if (widget == .slider) @field(state_ptr.*, widget.slider.field) = ev.val;
                        }
                    }
                },
                .checkbox_changed => |ev| inline for (spec.panels, 0..) |_, pi| {
                    inline for (spec.panels[pi].widgets, 0..) |widget, wi| {
                        if (ev.widget_id == pi * 256 + wi) {
                            if (widget == .checkbox) {
                                const v = ev.val != 0;
                                @field(state_ptr.*, widget.checkbox.field) = v;
                                if (widget.checkbox.handler) |h| h(g, v);
                            }
                        }
                    }
                },
                .command => |ev| if (spec.on_command) |h| h(g, ev.tag, ev.payload, &w),
                .hover => |ev| if (spec.on_hover) |h| h(g, .{
                    .world_x = ev.world_x,
                    .world_y = ev.world_y,
                    .element_type = ev.element_type,
                    .element_idx = ev.element_idx,
                    .element_name = ev.element_name,
                }, &w),
                .key_event => |ev| if (spec.on_key_event) |h| h(g, .{
                    .key = ev.key,
                    .mods = ev.mods,
                    .action = ev.action,
                }, &w),
                else => {},
            };

            return if (w.overflowed) std.math.maxInt(usize) else w.pos;
        }

        const descriptor: Descriptor = .{
            .abi_version = ABI_VERSION,
            .name = spec.name.ptr,
            .version_str = spec.version.ptr,
            .process = &process,
        };

        pub fn export_plugin() void {
            @export(&process, .{ .name = "schemify_process", .linkage = .strong });
            @export(&descriptor, .{ .name = "schemify_plugin", .linkage = .strong });
        }
    };
}
