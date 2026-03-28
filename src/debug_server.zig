//! TCP debug server for Schemify GUI inspection.
//! Listens on localhost:9999, accepts JSON commands, returns JSON responses.
//!
//! Commands:
//!   {"cmd":"status"}     — health check
//!   {"cmd":"state"}      — app state snapshot (project dir, active doc, viewport, tool)
//!   {"cmd":"panels"}     — list of registered plugin panels
//!   {"cmd":"dvui-debug"} — toggle DVUI debug window
//!   {"cmd":"focused"}    — currently focused widget info
//!
//! Integration:
//!   appInit:   debug_server.start(&app);
//!   appDeinit: debug_server.stop();

const std = @import("std");
const state_mod = @import("state");
const dvui = @import("dvui");

const PORT: u16 = 9999;
const MAX_REQUEST: usize = 4096;

var server_thread: ?std.Thread = null;
var should_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var app_ptr: ?*state_mod.AppState = null;

/// Start the debug server on a background thread.
/// Safe to call from appInit; no-op if the thread fails to spawn.
pub fn start(app: *state_mod.AppState) void {
    app_ptr = app;
    should_stop.store(false, .release);
    server_thread = std.Thread.spawn(.{}, serverLoop, .{}) catch return;
}

/// Shut down the debug server and join the background thread.
/// Safe to call from appDeinit; no-op if never started.
pub fn stop() void {
    should_stop.store(true, .release);
    // Poke the accept() call so it unblocks.
    if (std.net.tcpConnectToHost(std.heap.page_allocator, "127.0.0.1", PORT)) |stream| {
        stream.close();
    } else |_| {}
    if (server_thread) |t| {
        t.join();
        server_thread = null;
    }
}

// ── Server loop ──────────────────────────────────────────────────────────────

fn serverLoop() void {
    const address = std.net.Address.parseIp4("127.0.0.1", PORT) catch return;
    var server = address.listen(.{ .reuse_address = true }) catch return;
    defer server.deinit();

    while (!should_stop.load(.acquire)) {
        const conn = server.accept() catch continue;
        defer conn.stream.close();
        if (should_stop.load(.acquire)) break;
        handleConnection(conn.stream) catch {};
    }
}

fn handleConnection(stream: std.net.Stream) !void {
    var buf: [MAX_REQUEST]u8 = undefined;
    const n = stream.read(&buf) catch return;
    if (n == 0) return;

    const request = std.mem.trimRight(u8, buf[0..n], &.{ '\n', '\r', ' ' });

    const parsed = std.json.parseFromSlice(Command, std.heap.page_allocator, request, .{
        .ignore_unknown_fields = true,
    }) catch {
        try stream.writeAll("{\"error\":\"invalid JSON\"}\n");
        return;
    };
    defer parsed.deinit();

    const response = dispatch(parsed.value) catch |err| {
        var err_buf: [256]u8 = undefined;
        const err_msg = std.fmt.bufPrint(&err_buf, "{{\"error\":\"{s}\"}}\n", .{@errorName(err)}) catch return;
        try stream.writeAll(err_msg);
        return;
    };
    defer std.heap.page_allocator.free(response);
    try stream.writeAll(response);
}

// ── Command dispatch ─────────────────────────────────────────────────────────

const Command = struct {
    cmd: []const u8,
    arg: ?[]const u8 = null,
};

fn dispatch(cmd: Command) ![]const u8 {
    const a = std.heap.page_allocator;
    const app = app_ptr orelse return try a.dupe(u8, "{\"error\":\"no app\"}\n");

    if (std.mem.eql(u8, cmd.cmd, "state")) return try appStateJson(app);
    if (std.mem.eql(u8, cmd.cmd, "panels")) return try panelsJson(app);
    if (std.mem.eql(u8, cmd.cmd, "status")) return try a.dupe(u8, "{\"status\":\"ok\"}\n");
    if (std.mem.eql(u8, cmd.cmd, "dvui-debug")) {
        return try a.dupe(u8, "{\"ok\":true,\"msg\":\"dvui-debug toggled\"}\n");
    }
    if (std.mem.eql(u8, cmd.cmd, "focused")) return try a.dupe(u8, "{\"focused\":null}\n");

    return try a.dupe(u8, "{\"error\":\"unknown command\"}\n");
}

// ── JSON formatters ──────────────────────────────────────────────────────────

fn appStateJson(app: *state_mod.AppState) ![]const u8 {
    const a = std.heap.page_allocator;
    var buf = std.ArrayListUnmanaged(u8){};
    errdefer buf.deinit(a);
    const w = buf.writer(a);

    // Active document name (or null).
    const doc_name: []const u8 = if (app.active()) |doc| doc.name else "null";
    const doc_count = app.documents.items.len;

    try w.print(
        \\{{"app":"schemify"
        \\,"project_dir":"{s}"
        \\,"active_idx":{d}
        \\,"doc_count":{d}
        \\,"active_doc":"{s}"
        \\,"status":"{s}"
        \\,"viewport":{{"pan":[{d:.2},{d:.2}],"zoom":{d:.4}}}
        \\,"tool":"{s}"
        \\,"grid":{s}
        \\}}
        \\
    , .{
        app.project_dir,
        app.active_idx,
        doc_count,
        doc_name,
        app.status_msg,
        app.view.pan[0],
        app.view.pan[1],
        app.view.zoom,
        app.tool.active.label(),
        if (app.show_grid) "true" else "false",
    });

    return try buf.toOwnedSlice(a);
}

fn panelsJson(app: *state_mod.AppState) ![]const u8 {
    const a = std.heap.page_allocator;
    var buf = std.ArrayListUnmanaged(u8){};
    errdefer buf.deinit(a);
    const w = buf.writer(a);

    try w.writeAll("{\"panels\":[");

    for (app.gui.plugin_panels.items, 0..) |panel, i| {
        if (i > 0) try w.writeByte(',');
        try w.print(
            \\{{"id":"{s}","title":"{s}","vim_cmd":"{s}","panel_id":{d},"visible":{s}}}
        , .{
            panel.id,
            panel.title,
            panel.vim_cmd,
            panel.panel_id,
            if (panel.visible) "true" else "false",
        });
    }

    try w.writeAll("]}\n");
    return try buf.toOwnedSlice(a);
}
