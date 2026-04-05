//! Comptime plugin framework -- generates widget IDs, draw_panel dispatch,
//! event routing, and the full schemify_process body from a declarative spec.

const std = @import("std");
const types = @import("types.zig");
const Reader = @import("Reader.zig");
const Writer = @import("Writer.zig");

const PanelLayout = types.PanelLayout;
const Descriptor = types.Descriptor;
const ABI_VERSION = types.ABI_VERSION;

const Framework = @This();

// -- Widget descriptor --------------------------------------------------------

pub const WidgetKind = enum { slider, button, label, label_fmt, checkbox, separator, progress };

/// Comptime widget specification. All string fields are comptime constants.
pub const WidgetSpec = union(WidgetKind) {
    slider: struct {
        label: [:0]const u8,
        field: [:0]const u8,
        min: f32,
        max: f32,
    },
    button: struct {
        label: [:0]const u8,
        handler: *const fn (*anyopaque) void,
    },
    label: struct { text: [:0]const u8 },
    label_fmt: struct {
        fmt: [:0]const u8,
        field: [:0]const u8,
    },
    checkbox: struct {
        label: [:0]const u8,
        field: [:0]const u8,
        handler: ?*const fn (*anyopaque, bool) void = null,
    },
    separator: struct {},
    progress: struct { field: [:0]const u8 },
};

// -- Type-erasure wrappers ----------------------------------------------------

fn wrapHandler(comptime S: type, comptime h: fn (*S) void) *const fn (*anyopaque) void {
    return &struct {
        fn call(p: *anyopaque) void {
            h(@alignCast(@ptrCast(p)));
        }
    }.call;
}

fn wrapCheckboxHandler(comptime S: type, comptime h: fn (*S, bool) void) *const fn (*anyopaque, bool) void {
    return &struct {
        fn call(p: *anyopaque, v: bool) void {
            h(@alignCast(@ptrCast(p)), v);
        }
    }.call;
}

pub fn wrapWriterHook(comptime S: type, comptime h: fn (*S, *Writer) void) *const fn (*anyopaque, *Writer) void {
    return &struct {
        fn call(p: *anyopaque, w: *Writer) void {
            h(@alignCast(@ptrCast(p)), w);
        }
    }.call;
}

pub const wrapDrawFn = wrapWriterHook;

pub fn wrapUnloadHook(comptime S: type, comptime h: fn (*S) void) *const fn (*anyopaque) void {
    return wrapHandler(S, h);
}

pub fn wrapOnButton(comptime S: type, comptime h: fn (*S, u32, *Writer) void) *const fn (*anyopaque, u32, *Writer) void {
    return &struct {
        fn call(p: *anyopaque, wid: u32, w: *Writer) void {
            h(@alignCast(@ptrCast(p)), wid, w);
        }
    }.call;
}

pub fn wrapTickHook(comptime S: type, comptime h: fn (*S, f32) void) *const fn (*anyopaque, f32) void {
    return &struct {
        fn call(p: *anyopaque, dt: f32) void {
            h(@alignCast(@ptrCast(p)), dt);
        }
    }.call;
}

pub fn wrapCommandHook(comptime S: type, comptime h: fn (*S, []const u8, []const u8, *Writer) void) *const fn (*anyopaque, []const u8, []const u8, *Writer) void {
    return &struct {
        fn call(p: *anyopaque, tag: []const u8, payload: []const u8, w: *Writer) void {
            h(@alignCast(@ptrCast(p)), tag, payload, w);
        }
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
    return .{ .checkbox = .{ .label = lbl, .field = field, .handler = null } };
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

// -- Panel descriptor ---------------------------------------------------------

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

pub fn panel(
    comptime id: [:0]const u8,
    comptime title: [:0]const u8,
    comptime vim_cmd: [:0]const u8,
    comptime layout: PanelLayout,
    comptime keybind: u8,
    comptime widgets: []const WidgetSpec,
) PanelSpec {
    return .{ .id = id, .title = title, .vim_cmd = vim_cmd, .layout = layout, .keybind = keybind, .widgets = widgets };
}

// -- Plugin descriptor --------------------------------------------------------

pub const PluginSpec = struct {
    name: [:0]const u8,
    version: [:0]const u8,
    panels: []const PanelSpec,
    on_load: ?*const fn (*anyopaque, *Writer) void = null,
    on_unload: ?*const fn (*anyopaque, *Writer) void = null,
    on_tick: ?*const fn (*anyopaque, f32) void = null,
    on_command: ?*const fn (*anyopaque, []const u8, []const u8, *Writer) void = null,
};

// -- define() -- generates the process fn and export_plugin -------------------

pub fn define(comptime State: type, comptime state_ptr: *State, comptime spec: PluginSpec) type {
    return struct {
        const g_state_ptr: *anyopaque = state_ptr;

        pub fn process(
            in_ptr: [*]const u8,
            in_len: usize,
            out_ptr: [*]u8,
            out_cap: usize,
        ) callconv(.c) usize {
            var r = Reader.init(in_ptr[0..in_len]);
            var w = Writer.init(out_ptr[0..out_cap]);

            while (r.next()) |msg| switch (msg) {
                .load => {
                    inline for (spec.panels) |p| {
                        w.registerPanel(.{
                            .id = p.id,
                            .title = p.title,
                            .vim_cmd = p.vim_cmd,
                            .layout = p.layout,
                            .keybind = p.keybind,
                        });
                        if (p.on_load) |h| h(g_state_ptr, &w);
                    }
                    if (spec.on_load) |h| h(g_state_ptr, &w);
                },

                .unload => {
                    if (spec.on_unload) |h| h(g_state_ptr, &w);
                    inline for (spec.panels) |p| {
                        if (p.on_unload) |h| h(g_state_ptr);
                    }
                },

                .tick => |ev| {
                    if (spec.on_tick) |h| h(g_state_ptr, ev.dt);
                },

                .draw_panel => |ev| {
                    inline for (spec.panels, 0..) |p, pi| {
                        if (ev.panel_id == pi) {
                            if (p.draw_fn) |df| {
                                df(g_state_ptr, &w);
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
                    }
                },

                .button_clicked => |ev| {
                    inline for (spec.panels, 0..) |p, pi| {
                        if (p.on_button) |h| h(g_state_ptr, ev.widget_id, &w);
                        inline for (p.widgets, 0..) |widget, wi| {
                            if (ev.widget_id == pi * 256 + wi) {
                                switch (widget) {
                                    .button => |b| b.handler(g_state_ptr),
                                    else => {},
                                }
                            }
                        }
                    }
                },

                .slider_changed => |ev| {
                    inline for (spec.panels, 0..) |p, pi| {
                        inline for (p.widgets, 0..) |widget, wi| {
                            if (ev.widget_id == pi * 256 + wi + 128) {
                                switch (widget) {
                                    .slider => |s| @field(state_ptr.*, s.field) = ev.val,
                                    else => {},
                                }
                            }
                        }
                    }
                },

                .checkbox_changed => |ev| {
                    inline for (spec.panels, 0..) |p, pi| {
                        inline for (p.widgets, 0..) |widget, wi| {
                            if (ev.widget_id == pi * 256 + wi) {
                                switch (widget) {
                                    .checkbox => |cb| {
                                        const v = ev.val != 0;
                                        @field(state_ptr.*, cb.field) = v;
                                        if (cb.handler) |h| h(g_state_ptr, v);
                                    },
                                    else => {},
                                }
                            }
                        }
                    }
                },

                .command => |ev| {
                    if (spec.on_command) |h| h(g_state_ptr, ev.tag, ev.payload, &w);
                },

                else => {},
            };

            return if (w.overflow()) std.math.maxInt(usize) else w.pos;
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
