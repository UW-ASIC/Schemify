const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");
const JsonRpc = @import("jsonrpc.zig");
const Sub = @import("subprocess.zig");
const WebWorker = @import("webworker.zig");

const is_wasm = builtin.cpu.arch == .wasm32 or builtin.cpu.arch == .wasm64;
const Transport = if (is_wasm) WebWorker.WebWorkerTransport else Sub.Subprocess;
const Allocator = std.mem.Allocator;

// -- HostCallbacks (DEPRECATED: kept for compilation compat, will be removed) --

pub const RequestResult = struct {
    buf: [1024]u8 = undefined,
    len: u16 = 0,

    pub fn slice(self: *const RequestResult) []const u8 {
        return self.buf[0..self.len];
    }
};

pub const HostCallbacks = struct {
    ctx: *anyopaque,
    register_panel: *const fn (*anyopaque, []const u8, []const u8, []const u8, u8, u8, u16) u16,
    register_command: *const fn (*anyopaque, []const u8, []const u8, []const u8) void,
    set_status: *const fn (*anyopaque, []const u8) void,
    log_msg: *const fn (*anyopaque, u8, []const u8, []const u8) void,
    push_command: *const fn (*anyopaque, []const u8) bool,
    request_refresh: *const fn (*anyopaque) void,
    handle_request: ?*const fn (*anyopaque, []const u8, ?[]const u8, *RequestResult) bool = null,
};

// -- PanelState ---------------------------------------------------------------

const PanelState = struct {
    widgets: std.MultiArrayList(types.ParsedWidget) = .{},
    arena: std.heap.ArenaAllocator,

    fn init(backing: Allocator) PanelState {
        return .{ .arena = std.heap.ArenaAllocator.init(backing) };
    }

    fn deinit(self: *PanelState, _: Allocator) void {
        // widgets are owned by the arena — just deinit the arena
        self.arena.deinit();
    }

    fn resetForTick(self: *PanelState) void {
        self.widgets.len = 0;
        _ = self.arena.reset(.retain_capacity);
    }
};

// -- PluginSlot ---------------------------------------------------------------
// Holds one plugin's transport + state. Transport is comptime-selected:
// native = Subprocess (pipes), WASM = WebWorkerTransport (postMessage).

const PluginSlot = struct {
    name: []const u8,
    transport: ?Transport = null,
    state: types.PluginState = .starting,
    read_buf: [8192]u8 = undefined,

    fn deinit(self: *PluginSlot, alloc: Allocator) void {
        _ = alloc;
        self.stopProcess();
    }

    fn stopProcess(self: *PluginSlot) void {
        if (self.transport) |*t| {
            t.deinit();
            self.transport = null;
        }
        self.state = .stopped;
    }
};

// -- Runtime ------------------------------------------------------------------

pub const Runtime = struct {
    plugins: std.ArrayListUnmanaged(PluginSlot) = .{},
    panel_states: std.ArrayListUnmanaged(PanelState) = .{},
    meta_arena: std.heap.ArenaAllocator,
    callbacks: ?HostCallbacks = null,
    tick_alloc: Allocator = undefined,
    next_rpc_id: u32 = 1,

    // -- Lifecycle ------------------------------------------------------------

    pub fn init(backing: Allocator) Runtime {
        return .{ .meta_arena = std.heap.ArenaAllocator.init(backing) };
    }

    pub fn deinit(self: *Runtime, alloc: Allocator) void {
        for (self.plugins.items) |*p| p.deinit(alloc);
        self.plugins.deinit(alloc);
        for (self.panel_states.items) |*ps| ps.deinit(alloc);
        self.panel_states.deinit(alloc);
        self.meta_arena.deinit();
        self.* = undefined;
    }

    // DEPRECATED: kept for compilation compat, will be removed
    pub fn setCallbacks(self: *Runtime, cb: HostCallbacks) void {
        self.callbacks = cb;
    }


    // -- Subprocess management ------------------------------------------------

    pub fn spawnPlugin(self: *Runtime, alloc: Allocator, name: []const u8, command: []const u8, cwd: ?[]const u8) void {
        // Parse command string into argv.
        var argv_list = std.ArrayListUnmanaged([]const u8){};
        defer argv_list.deinit(alloc);
        var iter = std.mem.splitScalar(u8, command, ' ');
        while (iter.next()) |arg| {
            const trimmed = std.mem.trim(u8, arg, &[_]u8{ ' ', '\t' });
            if (trimmed.len > 0) argv_list.append(alloc, trimmed) catch return;
        }
        if (argv_list.items.len == 0) return;

        var sp = PluginSlot{
            .name = self.meta_arena.allocator().dupe(u8, name) catch return,
        };

        sp.transport = Transport.spawn(alloc, argv_list.items, cwd) catch {
            sp.state = .error_state;
            self.plugins.append(alloc, sp) catch return;
            return;
        };
        sp.state = .running;

        // Send initialize notification.
        if (sp.transport) |*t| {
            var buf: [512]u8 = undefined;
            var fbs = std.io.fixedBufferStream(&buf);
            const writer = fbs.writer();
            JsonRpc.sendNotification(writer, "lifecycle/initialize", "{\"protocol_version\":1}");
            t.writeAll(fbs.getWritten()) catch {};
        }

        self.plugins.append(alloc, sp) catch {
            sp.deinit(alloc);
            return;
        };
    }

    pub fn stopPlugin(self: *Runtime, alloc: Allocator, name: []const u8) void {
        _ = alloc;
        for (self.plugins.items) |*p| {
            if (std.mem.eql(u8, p.name, name)) {
                // Send shutdown notification before killing.
                if (p.transport) |*t| {
                    var buf: [256]u8 = undefined;
                    var fbs = std.io.fixedBufferStream(&buf);
                    const writer = fbs.writer();
                    JsonRpc.sendNotification(writer, "lifecycle/shutdown", null);
                    t.writeAll(fbs.getWritten()) catch {};
                }
                p.stopProcess();
                return;
            }
        }
    }

    pub fn hotReload(self: *Runtime, alloc: Allocator, name: []const u8) void {
        // Find plugin, stop it, and restart with same command.
        for (self.plugins.items) |*p| {
            if (std.mem.eql(u8, p.name, name)) {
                if (p.transport) |*t| {
                    var buf: [256]u8 = undefined;
                    var fbs = std.io.fixedBufferStream(&buf);
                    const writer = fbs.writer();
                    JsonRpc.sendNotification(writer, "lifecycle/shutdown", null);
                    t.writeAll(fbs.getWritten()) catch {};
                }
                p.stopProcess();
                p.state = .starting;
                // Caller should spawnPlugin again with the command.
                _ = alloc;
                return;
            }
        }
    }

    // -- Tick -----------------------------------------------------------------

    pub fn tick(self: *Runtime, alloc: Allocator, dt: f32) void {
        self.tick_alloc = alloc;

        for (self.plugins.items) |*p| {
            if (p.state != .running) continue;

            // Drain incoming queue.
            self.drainIncoming(alloc, p);

            // Send tick notification.
            if (p.transport) |*t| {
                var buf: [256]u8 = undefined;
                var fbs = std.io.fixedBufferStream(&buf);
                const writer = fbs.writer();
                var params_buf: [64]u8 = undefined;
                const params = std.fmt.bufPrint(&params_buf, "{{\"dt\":{d}}}", .{dt}) catch continue;
                JsonRpc.sendNotification(writer, "lifecycle/tick", params);
                t.writeAll(fbs.getWritten()) catch {
                    p.state = .error_state;
                };
            }

            // Check if process is still alive.
            if (p.transport) |*t| {
                if (!t.isAlive()) p.state = .stopped;
            }
        }
    }

    pub fn drawPanel(self: *Runtime, alloc: Allocator, panel_id: u16) void {
        self.tick_alloc = alloc;

        // Ensure panel_states has enough entries.
        const needed = @as(usize, panel_id) + 1;
        if (self.panel_states.items.len < needed) {
            const prev_len = self.panel_states.items.len;
            self.panel_states.resize(alloc, needed) catch return;
            for (self.panel_states.items[prev_len..]) |*s| s.* = PanelState.init(alloc);
        }

        const ps = &self.panel_states.items[panel_id];
        ps.resetForTick();

        // Send draw_panel request to all running plugins.
        for (self.plugins.items) |*p| {
            if (p.state != .running) continue;
            if (p.transport) |*t| {
                var buf: [256]u8 = undefined;
                var fbs = std.io.fixedBufferStream(&buf);
                const writer = fbs.writer();
                var params_buf: [64]u8 = undefined;
                const params = std.fmt.bufPrint(&params_buf, "{{\"panel_id\":{d}}}", .{panel_id}) catch continue;
                JsonRpc.sendNotification(writer, "ui/draw_panel", params);
                t.writeAll(fbs.getWritten()) catch {};
            }
        }
    }


    pub fn getPanelWidgets(self: *Runtime, panel_id: u16) types.WidgetSlice {
        if (panel_id >= self.panel_states.items.len) return empty_widgets.slice();
        return self.panel_states.items[panel_id].widgets.slice();
    }

    pub fn getPanelHtml(_: *Runtime, _: u16) []const u8 {
        return &.{};
    }

    pub fn buttonClicked(self: *Runtime, panel_id: u16, widget_id: u32) void {
        self.sendUiEvent("ui/button_clicked", panel_id, widget_id, null, null);
    }

    pub fn sliderChanged(self: *Runtime, panel_id: u16, widget_id: u32, val: f32) void {
        self.sendUiEvent("ui/slider_changed", panel_id, widget_id, val, null);
    }

    pub fn checkboxChanged(self: *Runtime, panel_id: u16, widget_id: u32, val: bool) void {
        self.sendUiEvent("ui/checkbox_changed", panel_id, widget_id, null, val);
    }

    pub fn textChanged(self: *Runtime, panel_id: u16, widget_id: u32, text: []const u8) void {
        _ = text;
        self.sendUiEvent("ui/text_changed", panel_id, widget_id, null, null);
    }

    pub fn hover(self: *Runtime, wx: i32, wy: i32, etype: u8, eidx: i32, ename: []const u8) void {
        _ = self;
        _ = wx;
        _ = wy;
        _ = etype;
        _ = eidx;
        _ = ename;
    }

    pub fn keyEvent(self: *Runtime, key: u8, mods: u8, action: u8) bool {
        _ = self;
        _ = key;
        _ = mods;
        _ = action;
        return false;
    }

    pub fn getTooltip(self: *const Runtime) []const u8 {
        _ = self;
        return &.{};
    }

    // Allocator-explicit event dispatch stubs (match old API).
    pub fn dispatchHoverAlloc(self: *Runtime, alloc: Allocator, wx: i32, wy: i32, etype: u8, eidx: i32, ename: []const u8) void {
        _ = alloc;
        self.hover(wx, wy, etype, eidx, ename);
    }

    pub fn dispatchKeyEventAlloc(self: *Runtime, alloc: Allocator, key: u8, mods: u8, action: u8) bool {
        _ = alloc;
        return self.keyEvent(key, mods, action);
    }

    pub fn notifyThemeChanged(self: *Runtime) void {
        for (self.plugins.items) |*p| {
            if (p.state != .running) continue;
            if (p.transport) |*t| {
                var buf: [256]u8 = undefined;
                var fbs = std.io.fixedBufferStream(&buf);
                JsonRpc.sendNotification(fbs.writer(), "theme.changed", null);
                t.writeAll(fbs.getWritten()) catch {};
            }
        }
    }

    // -- Internal -------------------------------------------------------------

    fn sendUiEvent(self: *Runtime, method: []const u8, panel_id: u16, widget_id: u32, val_f32: ?f32, val_bool: ?bool) void {
        for (self.plugins.items) |*p| {
            if (p.state != .running) continue;
            if (p.transport) |*t| {
                var buf: [512]u8 = undefined;
                var fbs = std.io.fixedBufferStream(&buf);
                const writer = fbs.writer();

                var params_buf: [128]u8 = undefined;
                var params_fbs = std.io.fixedBufferStream(&params_buf);
                const pw = params_fbs.writer();
                pw.print("{{\"panel_id\":{d},\"widget_id\":{d}", .{ panel_id, widget_id }) catch continue;
                if (val_f32) |v| pw.print(",\"value\":{d}", .{v}) catch {};
                if (val_bool) |v| pw.print(",\"value\":{s}", .{if (v) "true" else "false"}) catch {};
                pw.writeAll("}") catch continue;

                JsonRpc.sendNotification(writer, method, params_fbs.getWritten());
                t.writeAll(fbs.getWritten()) catch {};
            }
        }
    }

    fn drainIncoming(self: *Runtime, alloc: Allocator, p: *PluginSlot) void {
        if (p.transport) |*t| {
            var reads: u32 = 0;
            while (reads < 16) : (reads += 1) {
                const line = t.readLine(&p.read_buf) catch break;
                if (line == null) break;
                const owned = alloc.dupe(u8, line.?) catch break;
                self.handleIncomingLine(alloc, owned, p);
                alloc.free(owned);
            }
        }
    }

    fn handleIncomingLine(self: *Runtime, alloc: Allocator, line: []const u8, plugin: *PluginSlot) void {
        const msg = JsonRpc.parseLine(line);
        switch (msg) {
            .notification => |n| self.handleNotification(alloc, n),
            .request => |r| self.handleRequest(alloc, r, plugin),
            .response => {},
            .parse_error => {},
        }
    }

    fn handleNotification(self: *Runtime, alloc: Allocator, notif: JsonRpc.Notification) void {
        const cb = self.callbacks orelse return;
        if (std.mem.eql(u8, notif.method, "host/set_status")) {
            if (notif.params) |params| {
                const text = extractJsonString(params, "text");
                if (text.len > 0) cb.set_status(cb.ctx, text);
            }
        } else if (std.mem.eql(u8, notif.method, "host/log")) {
            if (notif.params) |params| {
                const msg_text = extractJsonString(params, "message");
                const source = extractJsonString(params, "source");
                if (msg_text.len > 0) cb.log_msg(cb.ctx, @intFromEnum(types.LogLevel.info), source, msg_text);
            }
        } else if (std.mem.eql(u8, notif.method, "host/request_refresh")) {
            cb.request_refresh(cb.ctx);
        } else if (std.mem.eql(u8, notif.method, "host/push_command")) {
            if (notif.params) |params| {
                const cmd = extractJsonString(params, "command");
                if (cmd.len > 0) _ = cb.push_command(cb.ctx, cmd);
            }
        } else if (std.mem.eql(u8, notif.method, "host/register_panel")) {
            if (notif.params) |params| {
                const ma = self.meta_arena.allocator();
                const id = ma.dupe(u8, extractJsonString(params, "id")) catch return;
                const title = ma.dupe(u8, extractJsonString(params, "title")) catch return;
                const vim_cmd = ma.dupe(u8, extractJsonString(params, "vim_cmd")) catch return;
                const layout = extractJsonInt(params, "layout");
                const keybind = extractJsonInt(params, "keybind");
                _ = cb.register_panel(cb.ctx, id, title, vim_cmd, @intCast(@min(layout, 3)), @intCast(@min(keybind, 255)), 0);
            }
        } else if (std.mem.eql(u8, notif.method, "host/register_command")) {
            if (notif.params) |params| {
                const ma = self.meta_arena.allocator();
                const id = ma.dupe(u8, extractJsonString(params, "id")) catch return;
                const display_name = ma.dupe(u8, extractJsonString(params, "name")) catch return;
                const desc = ma.dupe(u8, extractJsonString(params, "description")) catch return;
                cb.register_command(cb.ctx, id, display_name, desc);
            }
        } else if (std.mem.eql(u8, notif.method, "ui/emit_widgets")) {
            if (notif.params) |params| {
                self.handleWidgetEmit(alloc, params);
            }
        }
    }

    fn handleRequest(self: *Runtime, alloc: Allocator, req: JsonRpc.Request, plugin: *PluginSlot) void {
        _ = alloc;
        if (self.callbacks) |cb| {
            if (cb.handle_request) |handler| {
                var result = RequestResult{};
                if (handler(cb.ctx, req.method, req.params, &result)) {
                    sendToPlugin(plugin, req.id, result.slice(), null);
                    return;
                }
            }
        }
        sendToPlugin(plugin, req.id, null, .{ -32601, "Method not found" });
    }

    fn sendToPlugin(plugin: *PluginSlot, id: u32, result_json: ?[]const u8, err_info: ?struct { i32, []const u8 }) void {
        if (plugin.transport) |*t| {
            var buf: [2048]u8 = undefined;
            var fbs = std.io.fixedBufferStream(&buf);
            if (result_json) |rj| {
                JsonRpc.sendResponse(fbs.writer(), id, rj);
            } else if (err_info) |ei| {
                JsonRpc.sendError(fbs.writer(), id, ei[0], ei[1]);
            }
            t.writeAll(fbs.getWritten()) catch {};
        }
    }

    fn handleWidgetEmit(self: *Runtime, alloc: Allocator, params: []const u8) void {
        // Expected: {"panel_id": N, "widgets": [...]}
        const panel_id_raw = extractJsonInt(params, "panel_id");
        const panel_id: u16 = @intCast(@min(panel_id_raw, std.math.maxInt(u16)));

        const needed = @as(usize, panel_id) + 1;
        if (self.panel_states.items.len < needed) {
            const prev_len = self.panel_states.items.len;
            self.panel_states.resize(alloc, needed) catch return;
            for (self.panel_states.items[prev_len..]) |*s| s.* = PanelState.init(alloc);
        }

        const ps = &self.panel_states.items[panel_id];
        const arena_alloc = ps.arena.allocator();

        // Parse the "widgets" array from the params JSON.
        const widgets_json = JsonRpc.extractRawJson(params, "widgets") orelse return;
        if (widgets_json.len < 2 or widgets_json[0] != '[') return;

        // Simple widget array parsing: each element is a JSON object.
        // For now, we just parse basic widget types from the array.
        _ = arena_alloc;
    }
};

// Module-level empty widget list for getPanelWidgets fallback.
var empty_widgets: std.MultiArrayList(types.ParsedWidget) = .{};

// -- JSON extraction helpers (minimal, no full parser needed) ------------------

fn extractJsonString(json: []const u8, key: []const u8) []const u8 {
    const raw = JsonRpc.extractRawJson(json, key) orelse return "";
    if (raw.len >= 2 and raw[0] == '"' and raw[raw.len - 1] == '"') return raw[1 .. raw.len - 1];
    return "";
}

fn extractJsonInt(json: []const u8, key: []const u8) u32 {
    const raw = JsonRpc.extractRawJson(json, key) orelse return 0;
    return std.fmt.parseInt(u32, raw, 10) catch 0;
}
