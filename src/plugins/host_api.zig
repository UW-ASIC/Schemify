//! Host API bridge for Plugin API v1.
//!
//! Constructs the SchemifyHost function pointer table that gets passed to
//! plugins at activation time. Each C ABI function pointer converts
//! null-terminated C strings to Zig slices and forwards to the active
//! HostContext.
//!
//! State is instance-based via HostContext rather than file-level statics.
//! A thread-local pointer to the active context is set before each plugin
//! call, making this extensible to thread-per-plugin without changes to
//! host function implementations.

const std = @import("std");
const types = @import("types.zig");

// -- HostCallbacks ------------------------------------------------------------

/// Callback table the application (main.zig) populates so host_api can forward
/// plugin requests without importing gui/state/core modules.
pub const HostCallbacks = struct {
    ctx: *anyopaque,

    // Core
    log_msg: *const fn (*anyopaque, []const u8, []const u8) void,
    set_status: *const fn (*anyopaque, []const u8) void,
    push_command: *const fn (*anyopaque, []const u8) bool,
    request_refresh: *const fn (*anyopaque) void,

    // Files
    read_file: *const fn (*anyopaque, []const u8) ?[]const u8,
    write_file: *const fn (*anyopaque, []const u8, []const u8) bool,
    project_dir: *const fn (*anyopaque) []const u8,
    plugin_data_dir: *const fn (*anyopaque, []const u8) []const u8,

    // Registration
    register_panel: *const fn (*anyopaque, []const u8) void,
    unregister_panel: *const fn (*anyopaque, []const u8) void,
    register_command: *const fn (*anyopaque, []const u8) void,
    register_keybind: *const fn (*anyopaque, []const u8) void,
    register_provider: *const fn (*anyopaque, []const u8) void,

    // Config
    set_config: *const fn (*anyopaque, []const u8, []const u8) void,

    // IPC
    publish: *const fn (*anyopaque, []const u8, []const u8) void,
};

// -- Return buffer ------------------------------------------------------------

/// Per-function buffer for returning null-terminated strings to plugins.
const ReturnBuf = struct {
    buf: [4096:0]u8 = [_:0]u8{0} ** 4096,

    fn set(self: *ReturnBuf, s: []const u8) ?[*:0]const u8 {
        if (s.len >= self.buf.len) return null;
        @memcpy(self.buf[0..s.len], s);
        self.buf[s.len] = 0;
        return self.buf[0..s.len :0];
    }
};

// -- HostContext ---------------------------------------------------------------

/// Instance-based state for the host API. Owns callbacks, active plugin name,
/// and per-function return buffers. Set as the thread-local active context
/// before each plugin call.
pub const HostContext = struct {
    callbacks: HostCallbacks,
    plugin_name: []const u8 = "",

    // Per-function return buffers (safe: one context per thread)
    buf_read_file: ReturnBuf = .{},
    buf_project_dir: ReturnBuf = .{},
    buf_plugin_data_dir: ReturnBuf = .{},
};

/// Thread-local pointer to the active context. Set before each plugin call
/// by the plugin system / scheduler. Single-threaded now; extensible to
/// thread-per-plugin later without changing host function implementations.
threadlocal var active_context: ?*HostContext = null;

// Static host/canvas/schematic tables (function pointers are constant;
// they read from the thread-local context).
var host_table: types.SchemifyHost = .{};
var canvas_table: types.SchemifyCanvas = .{};
var schematic_table: types.SchemifySchematic = .{};

// -- Public API ---------------------------------------------------------------

/// Initialize the host API with a new context. Returns a pointer to the
/// context for the caller to store. The context is also set as the active
/// thread-local context.
pub fn init(callbacks: HostCallbacks) void {
    // Store context in file-level storage (single PluginSystem instance)
    static_context = .{ .callbacks = callbacks };
    active_context = &static_context;

    canvas_table = .{
        .clear_layer = canvasClearLayer,
        .line = canvasLine,
        .rect = canvasRect,
        .circle = canvasCircle,
        .text = canvasText,
        .polyline = canvasPolyline,
        .polygon = canvasPolygon,
        .arc = canvasArc,
        .image = canvasImage,
    };

    schematic_table = .{
        .instances = schematicInstances,
        .nets = schematicNets,
        .wires = schematicWires,
        .selection = schematicSelection,
        .instance = schematicInstance,
        .net = schematicNet,
        .config = schematicConfig,
        .set_config = schematicSetConfig,
    };

    host_table = .{
        .log = hostLog,
        .set_status = hostSetStatus,
        .push_command = hostPushCommand,
        .request_refresh = hostRequestRefresh,
        .read_file = hostReadFile,
        .write_file = hostWriteFile,
        .project_dir = hostProjectDir,
        .plugin_data_dir = hostPluginDataDir,
        .register_panel = hostRegisterPanel,
        .unregister_panel = hostUnregisterPanel,
        .register_command = hostRegisterCommand,
        .register_keybind = hostRegisterKeybind,
        .register_provider = hostRegisterProvider,
        .publish = hostPublish,
        .canvas = &canvas_table,
        .schematic = &schematic_table,
    };
}

/// Set the active plugin name before calling into a plugin export.
pub fn setActivePlugin(name: []const u8) void {
    if (active_context) |c| {
        c.plugin_name = name;
    }
}

/// Get the name of the currently-active plugin.
pub fn getActivePlugin() []const u8 {
    return if (active_context) |c| c.plugin_name else "";
}

/// Get a pointer to the SchemifyHost table for passing to plugins.
pub fn getHost() *const types.SchemifyHost {
    return &host_table;
}

/// Set a specific context as active (for future thread-per-plugin).
pub fn setContext(host_ctx: *HostContext) void {
    active_context = host_ctx;
}

/// Clear the active context.
pub fn clearContext() void {
    active_context = null;
}

/// Tear down (clear context and tables).
pub fn deinit() void {
    active_context = null;
    static_context = .{ .callbacks = undefined };
    host_table = .{};
    canvas_table = .{};
    schematic_table = .{};
}

// File-level storage for the single PluginSystem context.
// When thread-per-plugin is needed, each thread gets its own HostContext
// allocated by the scheduler and set via setContext().
var static_context: HostContext = .{ .callbacks = undefined };

// -- Inline context accessor --------------------------------------------------

inline fn ctx() ?*HostContext {
    return active_context;
}

inline fn cb() ?HostCallbacks {
    return if (active_context) |c| c.callbacks else null;
}

// -- Core host function implementations (C ABI) -------------------------------

fn hostLog(level: ?[*:0]const u8, msg: ?[*:0]const u8) callconv(.c) void {
    const c = cb() orelse return;
    const level_str = if (level) |l| std.mem.span(l) else "info";
    const msg_str = if (msg) |m| std.mem.span(m) else "";
    c.log_msg(c.ctx, level_str, msg_str);
}

fn hostSetStatus(text: ?[*:0]const u8) callconv(.c) void {
    const c = cb() orelse return;
    const str = if (text) |t| std.mem.span(t) else "";
    c.set_status(c.ctx, str);
}

fn hostPushCommand(cmd: ?[*:0]const u8) callconv(.c) c_int {
    const c = cb() orelse return 0;
    const str = if (cmd) |s| std.mem.span(s) else return 0;
    return if (c.push_command(c.ctx, str)) 1 else 0;
}

fn hostRequestRefresh() callconv(.c) void {
    const c = cb() orelse return;
    c.request_refresh(c.ctx);
}

fn hostReadFile(path: ?[*:0]const u8) callconv(.c) ?[*:0]const u8 {
    const context = ctx() orelse return null;
    const path_str = if (path) |p| std.mem.span(p) else return null;
    const data = context.callbacks.read_file(context.callbacks.ctx, path_str) orelse return null;
    return context.buf_read_file.set(data);
}

fn hostWriteFile(path: ?[*:0]const u8, data: ?[*:0]const u8) callconv(.c) c_int {
    const c = cb() orelse return 0;
    const path_str = if (path) |p| std.mem.span(p) else return 0;
    const data_str = if (data) |d| std.mem.span(d) else "";
    return if (c.write_file(c.ctx, path_str, data_str)) 1 else 0;
}

fn hostProjectDir() callconv(.c) ?[*:0]const u8 {
    const context = ctx() orelse return null;
    const dir = context.callbacks.project_dir(context.callbacks.ctx);
    return context.buf_project_dir.set(dir);
}

fn hostPluginDataDir() callconv(.c) ?[*:0]const u8 {
    const context = ctx() orelse return null;
    const dir = context.callbacks.plugin_data_dir(context.callbacks.ctx, context.plugin_name);
    return context.buf_plugin_data_dir.set(dir);
}

fn hostRegisterPanel(panel_json: ?[*:0]const u8) callconv(.c) void {
    const c = cb() orelse return;
    const str = if (panel_json) |p| std.mem.span(p) else return;
    c.register_panel(c.ctx, str);
}

fn hostUnregisterPanel(panel_id: ?[*:0]const u8) callconv(.c) void {
    const c = cb() orelse return;
    const str = if (panel_id) |p| std.mem.span(p) else return;
    c.unregister_panel(c.ctx, str);
}

fn hostRegisterCommand(cmd_json: ?[*:0]const u8) callconv(.c) void {
    const c = cb() orelse return;
    const str = if (cmd_json) |s| std.mem.span(s) else return;
    c.register_command(c.ctx, str);
}

fn hostRegisterKeybind(keybind_json: ?[*:0]const u8) callconv(.c) void {
    const c = cb() orelse return;
    const str = if (keybind_json) |k| std.mem.span(k) else return;
    c.register_keybind(c.ctx, str);
}

fn hostRegisterProvider(provider_json: ?[*:0]const u8) callconv(.c) void {
    const c = cb() orelse return;
    const str = if (provider_json) |p| std.mem.span(p) else return;
    c.register_provider(c.ctx, str);
}

fn hostPublish(topic: ?[*:0]const u8, payload: ?[*:0]const u8) callconv(.c) void {
    const c = cb() orelse return;
    const topic_str = if (topic) |t| std.mem.span(t) else return;
    const payload_str = if (payload) |p| std.mem.span(p) else "";
    c.publish(c.ctx, topic_str, payload_str);
}

// -- Canvas command buffer ----------------------------------------------------

pub const CanvasCommand = union(enum) {
    clear: struct { layer: i32 },
    line: struct { x1: f32, y1: f32, x2: f32, y2: f32, color: u32, width: f32 },
    rect: struct { x: f32, y: f32, w: f32, h: f32, color: u32, filled: bool },
    circle: struct { cx: f32, cy: f32, r: f32, color: u32, filled: bool },
    text: struct { x: f32, y: f32, content: [*:0]const u8, color: u32, size: f32 },
    polyline: struct { points: [*]const f32, count: i32, color: u32, width: f32 },
    polygon: struct { points: [*]const f32, count: i32, color: u32, filled: bool },
    arc: struct { cx: f32, cy: f32, r: f32, start: f32, end: f32, color: u32, width: f32 },
    image: struct { x: f32, y: f32, w: f32, h: f32, data_uri: [*:0]const u8 },
};

const max_canvas_commands = 4096;
var canvas_command_buf: [max_canvas_commands]CanvasCommand = undefined;
var canvas_command_len: usize = 0;
var canvas_mutex: std.Thread.Mutex = .{};

pub fn getCanvasCommands() []const CanvasCommand {
    canvas_mutex.lock();
    defer canvas_mutex.unlock();
    return canvas_command_buf[0..canvas_command_len];
}

pub fn clearCanvasCommands() void {
    canvas_mutex.lock();
    defer canvas_mutex.unlock();
    canvas_command_len = 0;
}

fn appendCanvasCommand(cmd: CanvasCommand) void {
    canvas_mutex.lock();
    defer canvas_mutex.unlock();
    if (canvas_command_len < max_canvas_commands) {
        canvas_command_buf[canvas_command_len] = cmd;
        canvas_command_len += 1;
    }
}

fn canvasClearLayer(layer: c_int) callconv(.c) void {
    appendCanvasCommand(.{ .clear = .{ .layer = layer } });
}

fn canvasLine(x1: f32, y1: f32, x2: f32, y2: f32, color: u32, width: f32) callconv(.c) void {
    appendCanvasCommand(.{ .line = .{ .x1 = x1, .y1 = y1, .x2 = x2, .y2 = y2, .color = color, .width = width } });
}

fn canvasRect(x: f32, y: f32, w: f32, h: f32, color: u32, filled: c_int) callconv(.c) void {
    appendCanvasCommand(.{ .rect = .{ .x = x, .y = y, .w = w, .h = h, .color = color, .filled = filled != 0 } });
}

fn canvasCircle(cx_: f32, cy_: f32, r: f32, color: u32, filled: c_int) callconv(.c) void {
    appendCanvasCommand(.{ .circle = .{ .cx = cx_, .cy = cy_, .r = r, .color = color, .filled = filled != 0 } });
}

fn canvasText(x: f32, y: f32, content: ?[*:0]const u8, color: u32, size: f32) callconv(.c) void {
    const ptr = content orelse return;
    appendCanvasCommand(.{ .text = .{ .x = x, .y = y, .content = ptr, .color = color, .size = size } });
}

fn canvasPolyline(points: [*]const f32, count: c_int, color: u32, width: f32) callconv(.c) void {
    appendCanvasCommand(.{ .polyline = .{ .points = points, .count = count, .color = color, .width = width } });
}

fn canvasPolygon(points: [*]const f32, count: c_int, color: u32, filled: c_int) callconv(.c) void {
    appendCanvasCommand(.{ .polygon = .{ .points = points, .count = count, .color = color, .filled = filled != 0 } });
}

fn canvasArc(cx_: f32, cy_: f32, r: f32, start: f32, end: f32, color: u32, width: f32) callconv(.c) void {
    appendCanvasCommand(.{ .arc = .{ .cx = cx_, .cy = cy_, .r = r, .start = start, .end = end, .color = color, .width = width } });
}

fn canvasImage(x: f32, y: f32, w: f32, h: f32, data_uri: ?[*:0]const u8) callconv(.c) void {
    const ptr = data_uri orelse return;
    appendCanvasCommand(.{ .image = .{ .x = x, .y = y, .w = w, .h = h, .data_uri = ptr } });
}

// -- Schematic stubs (Phase 0: return empty JSON) -----------------------------

fn schematicInstances() callconv(.c) ?[*:0]const u8 { return "[]"; }
fn schematicNets() callconv(.c) ?[*:0]const u8 { return "[]"; }
fn schematicWires() callconv(.c) ?[*:0]const u8 { return "[]"; }
fn schematicSelection() callconv(.c) ?[*:0]const u8 { return "[]"; }
fn schematicInstance(_: ?[*:0]const u8) callconv(.c) ?[*:0]const u8 { return "{}"; }
fn schematicNet(_: ?[*:0]const u8) callconv(.c) ?[*:0]const u8 { return "{}"; }
fn schematicConfig(_: ?[*:0]const u8) callconv(.c) ?[*:0]const u8 { return "{}"; }

fn schematicSetConfig(key: ?[*:0]const u8, value: ?[*:0]const u8) callconv(.c) void {
    const c = cb() orelse return;
    const key_str = if (key) |k| std.mem.span(k) else return;
    const val_str = if (value) |v| std.mem.span(v) else "";
    c.set_config(c.ctx, key_str, val_str);
}

// -- Tests --------------------------------------------------------------------

test "init populates host table" {
    const T = struct {
        fn logMsg(_: *anyopaque, _: []const u8, _: []const u8) void {}
        fn setStatus(_: *anyopaque, _: []const u8) void {}
        fn pushCommand(_: *anyopaque, _: []const u8) bool { return false; }
        fn requestRefresh(_: *anyopaque) void {}
        fn readFile(_: *anyopaque, _: []const u8) ?[]const u8 { return null; }
        fn writeFile(_: *anyopaque, _: []const u8, _: []const u8) bool { return false; }
        fn projectDir(_: *anyopaque) []const u8 { return "/tmp"; }
        fn pluginDataDir(_: *anyopaque, _: []const u8) []const u8 { return "/tmp/data"; }
        fn registerPanel(_: *anyopaque, _: []const u8) void {}
        fn unregisterPanel(_: *anyopaque, _: []const u8) void {}
        fn registerCommand(_: *anyopaque, _: []const u8) void {}
        fn registerKeybind(_: *anyopaque, _: []const u8) void {}
        fn registerProvider(_: *anyopaque, _: []const u8) void {}
        fn setConfigCb(_: *anyopaque, _: []const u8, _: []const u8) void {}
        fn publish(_: *anyopaque, _: []const u8, _: []const u8) void {}
    };

    var dummy: u8 = 0;
    init(.{
        .ctx = @ptrCast(&dummy),
        .log_msg = T.logMsg,
        .set_status = T.setStatus,
        .push_command = T.pushCommand,
        .request_refresh = T.requestRefresh,
        .read_file = T.readFile,
        .write_file = T.writeFile,
        .project_dir = T.projectDir,
        .plugin_data_dir = T.pluginDataDir,
        .register_panel = T.registerPanel,
        .unregister_panel = T.unregisterPanel,
        .register_command = T.registerCommand,
        .register_keybind = T.registerKeybind,
        .register_provider = T.registerProvider,
        .set_config = T.setConfigCb,
        .publish = T.publish,
    });
    defer deinit();

    const host = getHost();
    try std.testing.expect(host.log != null);
    try std.testing.expect(host.set_status != null);
    try std.testing.expect(host.push_command != null);
    try std.testing.expect(host.request_refresh != null);
    try std.testing.expect(host.read_file != null);
    try std.testing.expect(host.write_file != null);
    try std.testing.expect(host.project_dir != null);
    try std.testing.expect(host.plugin_data_dir != null);
    try std.testing.expect(host.register_panel != null);
    try std.testing.expect(host.unregister_panel != null);
    try std.testing.expect(host.register_command != null);
    try std.testing.expect(host.register_keybind != null);
    try std.testing.expect(host.register_provider != null);
    try std.testing.expect(host.publish != null);
    try std.testing.expect(host.canvas != null);
    try std.testing.expect(host.schematic != null);

    // Context should be active
    try std.testing.expect(active_context != null);
}

test "host functions are callable with no context" {
    deinit();

    hostLog("info", "test");
    hostSetStatus("ok");
    try std.testing.expect(hostPushCommand("zoom_in") == 0);
    hostRequestRefresh();
    try std.testing.expect(hostReadFile("/foo") == null);
    try std.testing.expect(hostWriteFile("/foo", "bar") == 0);
    try std.testing.expect(hostProjectDir() == null);
    try std.testing.expect(hostPluginDataDir() == null);
    hostRegisterPanel("{}");
    hostUnregisterPanel("test");
    hostRegisterCommand("{}");
    hostRegisterKeybind("{}");
    hostRegisterProvider("{}");
    hostPublish("topic", "payload");
}

test "schematic stubs return valid JSON" {
    try std.testing.expectEqualStrings("[]", std.mem.span(schematicInstances().?));
    try std.testing.expectEqualStrings("[]", std.mem.span(schematicNets().?));
    try std.testing.expectEqualStrings("[]", std.mem.span(schematicWires().?));
    try std.testing.expectEqualStrings("[]", std.mem.span(schematicSelection().?));
    try std.testing.expectEqualStrings("{}", std.mem.span(schematicInstance("foo").?));
    try std.testing.expectEqualStrings("{}", std.mem.span(schematicNet("bar").?));
    try std.testing.expectEqualStrings("{}", std.mem.span(schematicConfig("key").?));
}

test "ReturnBuf set and overflow" {
    var rb: ReturnBuf = .{};

    const result = rb.set("hello");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("hello", std.mem.span(result.?));

    const result2 = rb.set("world");
    try std.testing.expect(result2 != null);
    try std.testing.expectEqualStrings("world", std.mem.span(result2.?));

    const result3 = rb.set("");
    try std.testing.expect(result3 != null);
    try std.testing.expectEqualStrings("", std.mem.span(result3.?));

    const big = [_]u8{'x'} ** 4096;
    try std.testing.expect(rb.set(&big) == null);
}

test "setActivePlugin updates context" {
    const T = struct {
        fn logMsg(_: *anyopaque, _: []const u8, _: []const u8) void {}
        fn setStatus(_: *anyopaque, _: []const u8) void {}
        fn pushCommand(_: *anyopaque, _: []const u8) bool { return false; }
        fn requestRefresh(_: *anyopaque) void {}
        fn readFile(_: *anyopaque, _: []const u8) ?[]const u8 { return null; }
        fn writeFile(_: *anyopaque, _: []const u8, _: []const u8) bool { return false; }
        fn projectDir(_: *anyopaque) []const u8 { return "/tmp"; }
        fn pluginDataDir(_: *anyopaque, _: []const u8) []const u8 { return "/tmp/data"; }
        fn registerPanel(_: *anyopaque, _: []const u8) void {}
        fn unregisterPanel(_: *anyopaque, _: []const u8) void {}
        fn registerCommand(_: *anyopaque, _: []const u8) void {}
        fn registerKeybind(_: *anyopaque, _: []const u8) void {}
        fn registerProvider(_: *anyopaque, _: []const u8) void {}
        fn setConfigCb(_: *anyopaque, _: []const u8, _: []const u8) void {}
        fn publish(_: *anyopaque, _: []const u8, _: []const u8) void {}
    };

    var dummy: u8 = 0;
    init(.{
        .ctx = @ptrCast(&dummy),
        .log_msg = T.logMsg,
        .set_status = T.setStatus,
        .push_command = T.pushCommand,
        .request_refresh = T.requestRefresh,
        .read_file = T.readFile,
        .write_file = T.writeFile,
        .project_dir = T.projectDir,
        .plugin_data_dir = T.pluginDataDir,
        .register_panel = T.registerPanel,
        .unregister_panel = T.unregisterPanel,
        .register_command = T.registerCommand,
        .register_keybind = T.registerKeybind,
        .register_provider = T.registerProvider,
        .set_config = T.setConfigCb,
        .publish = T.publish,
    });
    defer deinit();

    setActivePlugin("TestPlugin");
    try std.testing.expectEqualStrings("TestPlugin", getActivePlugin());
}
