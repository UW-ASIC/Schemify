//! Plugin runtime -- drives the load / tick / unload lifecycle.
//!
//! This is a standalone rewrite that uses HostCallbacks for all app interaction,
//! avoiding direct imports of gui/state/core modules.  The caller (main.zig)
//! wires HostCallbacks to the real AppState at startup.

const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");
const PluginHost = @import("PluginHost.zig");
const Cap = @import("Capability.zig");

const Tag = types.Tag;
const HEADER_SZ = types.HEADER_SZ;
const U16_SZ = types.U16_SZ;
const U32_SZ = types.U32_SZ;
const is_wasm = builtin.cpu.arch == .wasm32 or builtin.cpu.arch == .wasm64;

// -- Event subscription flags -------------------------------------------------

pub const EVENT_HOVER: u8 = 1 << 0;
pub const EVENT_KEYS: u8 = 1 << 1;

// -- HostCallbacks ------------------------------------------------------------

/// Flat callback table the host (main.zig) populates so the plugin runtime can
/// call back into the application without importing gui/state/core.
pub const HostCallbacks = struct {
    ctx: *anyopaque,
    register_panel: *const fn (*anyopaque, []const u8, []const u8, []const u8, u8, u8, u16) u16,
    register_command: *const fn (*anyopaque, []const u8, []const u8, []const u8) void,
    set_status: *const fn (*anyopaque, []const u8) void,
    log_msg: *const fn (*anyopaque, u8, []const u8, []const u8) void,
    push_command: *const fn (*anyopaque, []const u8) bool,
    request_refresh: *const fn (*anyopaque) void,
    read_file: *const fn (*anyopaque, []const u8) ?[]const u8,
    write_file: *const fn (*anyopaque, []const u8, []const u8) bool,
    project_dir: *const fn (*anyopaque) []const u8,
    plugin_data_dir: *const fn (*anyopaque, []const u8) []const u8,
    apply_config: *const fn (*anyopaque, []const u8, []const u8) void,
    query_state: *const fn (*anyopaque, []const u8) ?[]const u8,
    register_keybind: *const fn (*anyopaque, u8, u8, []const u8) void,
    override_keybind: *const fn (*anyopaque, u8, u8, []const u8) void,
    mark_lazy_loading: *const fn (*anyopaque, []const u8) void,
};

// -- PanelState ---------------------------------------------------------------

const PanelState = struct {
    widgets: std.MultiArrayList(types.ParsedWidget) = .{},
    arena: std.heap.ArenaAllocator,

    fn init(backing: std.mem.Allocator) PanelState {
        return .{ .arena = std.heap.ArenaAllocator.init(backing) };
    }
    fn deinit(self: *PanelState, backing: std.mem.Allocator) void {
        self.widgets.deinit(backing);
        self.arena.deinit();
    }
    fn resetForTick(self: *PanelState) void {
        self.widgets.len = 0;
        _ = self.arena.reset(.retain_capacity);
    }
};

// -- LoadedPlugin -------------------------------------------------------------

const FileResponse = struct { path: []u8, data: []u8 };
const StateResponse = struct { key: []u8, val: []u8 };

const LoadedPlugin = struct {
    lib: if (is_wasm) void else std.DynLib,
    desc: *const types.Descriptor,
    buf: []u8 = &.{},
    pending_file_responses: std.ArrayListUnmanaged(FileResponse) = .{},
    pending_state_responses: std.ArrayListUnmanaged(StateResponse) = .{},
    event_mask: u8 = 0,
    capabilities: Cap.Capability = .{},

    fn freePendingFiles(self: *LoadedPlugin, alloc: std.mem.Allocator) void {
        for (self.pending_file_responses.items) |r| {
            alloc.free(r.path);
            if (r.data.len > 0) alloc.free(r.data);
        }
        self.pending_file_responses.clearRetainingCapacity();
    }

    fn freePendingStates(self: *LoadedPlugin, alloc: std.mem.Allocator) void {
        for (self.pending_state_responses.items) |r| {
            alloc.free(r.key);
            alloc.free(r.val);
        }
        self.pending_state_responses.clearRetainingCapacity();
    }
};

// -- Lazy stub ----------------------------------------------------------------

const LazyStub = struct { name: []const u8, so_path: []const u8 };

// -- PanelEvent + EventBuf ----------------------------------------------------

pub const PanelEvent = struct {
    tag: Tag,
    panel_id: u16,
    widget_id: u32,
    val_f32: f32 = 0,
    val_u8: u8 = 0,
    text: []const u8 = &.{},
};

const EventBuf = struct {
    buf: [types.MAX_EVENTS]PanelEvent = undefined,
    len: usize = 0,

    fn append(self: *EventBuf, ev: PanelEvent) void {
        if (self.len < types.MAX_EVENTS) {
            self.buf[self.len] = ev;
            self.len += 1;
        }
    }
    fn slice(self: *const EventBuf) []const PanelEvent {
        return self.buf[0..self.len];
    }
};

// -- Runtime ------------------------------------------------------------------

pub const Runtime = struct {
    plugins: std.ArrayListUnmanaged(LoadedPlugin) = .{},
    panel_states: std.ArrayListUnmanaged(PanelState) = .{},
    lazy_stubs: std.ArrayListUnmanaged(LazyStub) = .{},
    meta_arena: std.heap.ArenaAllocator,
    tooltip_text: [512]u8 = [_]u8{0} ** 512,
    tooltip_len: u16 = 0,
    pending_events: EventBuf = .{},
    callbacks: ?HostCallbacks = null,
    /// Allocator captured at tick()/hover()/keyEvent() entry so that
    /// PluginHost vtable methods (which don't receive an allocator) can
    /// forward to the real implementations.
    tick_alloc: std.mem.Allocator = undefined,

    // -- Lifecycle ------------------------------------------------------------

    pub fn init(backing: std.mem.Allocator) Runtime {
        return .{ .meta_arena = std.heap.ArenaAllocator.init(backing) };
    }

    pub fn deinit(self: *Runtime, alloc: std.mem.Allocator) void {
        if (comptime is_wasm) return;
        for (self.plugins.items) |*p| {
            p.freePendingFiles(alloc);
            p.pending_file_responses.deinit(alloc);
            p.freePendingStates(alloc);
            p.pending_state_responses.deinit(alloc);
            if (p.buf.len > 0) alloc.free(p.buf);
            // Skip dlclose -- see original rationale (CPython teardown, etc.)
        }
        self.plugins.deinit(alloc);
        for (self.panel_states.items) |*ps| ps.deinit(alloc);
        self.panel_states.deinit(alloc);
        self.lazy_stubs.deinit(alloc);
        self.meta_arena.deinit();
        self.* = undefined;
    }

    pub fn setCallbacks(self: *Runtime, cb: HostCallbacks) void {
        self.callbacks = cb;
    }

    // -- Load / unload --------------------------------------------------------

    pub fn loadOne(self: *Runtime, alloc: std.mem.Allocator, so_path: []const u8, caps: Cap.Capability) void {
        if (comptime is_wasm) return;

        var lib = std.DynLib.open(so_path) catch |err| {
            self.logErr(alloc, "dlopen({s}): {}", .{ so_path, err });
            return;
        };

        const desc = lib.lookup(*const types.Descriptor, "schemify_plugin") orelse {
            self.logErr(alloc, "{s}: missing 'schemify_plugin' export", .{so_path});
            lib.close();
            return;
        };

        if (desc.abi_version != types.ABI_VERSION) {
            self.logErr(alloc, "{s}: ABI {d} != {d}", .{ so_path, desc.abi_version, types.ABI_VERSION });
            lib.close();
            return;
        }

        // Build load message with project dir.
        const dir = if (self.callbacks) |cb| cb.project_dir(cb.ctx) else "";
        const dir_len: u16 = types.strLen(dir);
        var load_buf: [HEADER_SZ + U16_SZ + 4096]u8 = undefined;
        load_buf[0] = @intFromEnum(Tag.load);
        std.mem.writeInt(u16, load_buf[1..3], U16_SZ + dir_len, .little);
        std.mem.writeInt(u16, load_buf[3..5], dir_len, .little);
        if (dir_len > 0) @memcpy(load_buf[5 .. 5 + dir_len], dir[0..dir_len]);

        var p: LoadedPlugin = .{ .lib = lib, .desc = desc, .capabilities = caps };

        if (callPluginProcess(&p, load_buf[0 .. HEADER_SZ + U16_SZ + @as(usize, dir_len)], alloc)) |out| {
            defer alloc.free(out);
            self.dispatchOutMsgs(alloc, out, &p);
        } else |_| {}

        self.plugins.append(alloc, p) catch {
            sendUnload(&p, alloc);
            if (p.buf.len > 0) alloc.free(p.buf);
            lib.close();
            return;
        };
    }

    pub fn loadStartup(self: *Runtime, alloc: std.mem.Allocator, names: []const []const u8, paths: []const ?[]const u8, lazys: []const bool, caps: []const Cap.Capability) void {
        if (comptime is_wasm) return;
        for (names, 0..) |name, i| {
            const path = paths[i] orelse continue;
            const cap = if (i < caps.len) caps[i] else Cap.Capability{};
            if (lazys[i]) {
                self.registerLazyStub(alloc, name, path);
            } else {
                self.loadOne(alloc, path, cap);
            }
        }
    }

    fn registerLazyStub(self: *Runtime, alloc: std.mem.Allocator, name: []const u8, so_path: []const u8) void {
        const ma = self.meta_arena.allocator();
        const owned_name = ma.dupe(u8, name) catch return;
        const owned_path = ma.dupe(u8, so_path) catch return;
        self.lazy_stubs.append(alloc, .{ .name = owned_name, .so_path = owned_path }) catch return;
        if (self.callbacks) |cb| cb.mark_lazy_loading(cb.ctx, owned_name);
    }

    fn unloadAll(self: *Runtime, alloc: std.mem.Allocator) void {
        for (self.plugins.items) |*p| {
            sendUnload(p, alloc);
            p.freePendingFiles(alloc);
            p.freePendingStates(alloc);
            if (p.buf.len > 0) alloc.free(p.buf);
            if (!is_wasm) p.lib.close();
        }
        self.plugins.clearRetainingCapacity();
        self.lazy_stubs.clearRetainingCapacity();
        _ = self.meta_arena.reset(.retain_capacity);
    }

    pub fn refresh(self: *Runtime, alloc: std.mem.Allocator, names: []const []const u8, paths: []const ?[]const u8, lazys: []const bool, caps: []const Cap.Capability) void {
        self.unloadAll(alloc);
        self.loadStartup(alloc, names, paths, lazys, caps);
    }

    // -- Tick -----------------------------------------------------------------

    pub fn tick(self: *Runtime, alloc: std.mem.Allocator, dt: f32) void {
        if (comptime is_wasm) return;
        self.tick_alloc = alloc;
        for (self.plugins.items) |*p| self.callProcessWithTick(alloc, p, dt);
        // Free text event data
        for (self.pending_events.slice()) |ev| {
            if (ev.tag == .text_changed and ev.text.len > 0)
                alloc.free(@constCast(ev.text));
        }
        self.pending_events.len = 0;
    }

    pub fn drawPanel(self: *Runtime, alloc: std.mem.Allocator, panel_id: u16) void {
        if (comptime is_wasm) return;
        self.tick_alloc = alloc;
        for (self.plugins.items) |*p| self.callProcessDrawPanel(alloc, p, panel_id);
    }

    // -- PluginHost interface (called from GUI) --------------------------------

    /// Load a lazy plugin by name.  Allocator-explicit variant for direct use.
    pub fn ensureLoadedAlloc(self: *Runtime, alloc: std.mem.Allocator, plugin_name: []const u8) void {
        if (comptime is_wasm) return;
        const idx = for (self.lazy_stubs.items, 0..) |stub, si| {
            if (std.mem.eql(u8, stub.name, plugin_name)) break si;
        } else return;
        const stub = self.lazy_stubs.items[idx];
        self.loadOne(alloc, stub.so_path, .{});
        _ = self.lazy_stubs.swapRemove(idx);
    }

    // -- PluginHost-compatible methods ----------------------------------------
    // These use tick_alloc captured at tick()/hover()/keyEvent() entry so
    // that PluginHost.from(Runtime, self) can bind them without an allocator
    // parameter.

    pub fn ensureLoaded(self: *Runtime, name: []const u8) void {
        self.ensureLoadedAlloc(self.tick_alloc, name);
    }

    pub fn getPanelWidgets(self: *Runtime, panel_id: u16) PluginHost.WidgetSlice {
        if (panel_id >= self.panel_states.items.len) return empty_widgets.slice();
        return self.panel_states.items[panel_id].widgets.slice();
    }

    pub fn buttonClicked(self: *Runtime, panel_id: u16, widget_id: u32) void {
        self.pending_events.append(.{ .tag = .button_clicked, .panel_id = panel_id, .widget_id = widget_id });
    }

    pub fn sliderChanged(self: *Runtime, panel_id: u16, widget_id: u32, val: f32) void {
        self.pending_events.append(.{ .tag = .slider_changed, .panel_id = panel_id, .widget_id = widget_id, .val_f32 = val });
    }

    pub fn checkboxChanged(self: *Runtime, panel_id: u16, widget_id: u32, val: bool) void {
        self.pending_events.append(.{ .tag = .checkbox_changed, .panel_id = panel_id, .widget_id = widget_id, .val_u8 = if (val) 1 else 0 });
    }

    pub fn textChanged(self: *Runtime, panel_id: u16, widget_id: u32, text: []const u8) void {
        const duped = self.tick_alloc.dupe(u8, text) catch return;
        self.pending_events.append(.{ .tag = .text_changed, .panel_id = panel_id, .widget_id = widget_id, .text = duped });
    }

    pub fn hover(self: *Runtime, wx: i32, wy: i32, etype: u8, eidx: i32, ename: []const u8) void {
        self.dispatchHoverAlloc(self.tick_alloc, wx, wy, etype, eidx, ename);
    }

    pub fn keyEvent(self: *Runtime, key: u8, mods: u8, action: u8) bool {
        return self.dispatchKeyEventAlloc(self.tick_alloc, key, mods, action);
    }

    pub fn getTooltip(self: *const Runtime) []const u8 {
        return self.tooltip_text[0..self.tooltip_len];
    }

    // -- Allocator-explicit event dispatch ------------------------------------

    pub fn dispatchHoverAlloc(self: *Runtime, alloc: std.mem.Allocator, wx: i32, wy: i32, etype: u8, eidx: i32, ename: []const u8) void {
        if (comptime is_wasm) return;
        self.tick_alloc = alloc;
        self.tooltip_len = 0;

        const name_len: u16 = types.strLen(ename);
        const payload_sz: u16 = @intCast(U32_SZ * 2 + 1 + U32_SZ + U16_SZ + name_len);
        var buf: [HEADER_SZ + 256]u8 = undefined;
        var pos: usize = 0;
        buf[pos] = @intFromEnum(Tag.hover);
        pos += 1;
        std.mem.writeInt(u16, buf[pos..][0..2], payload_sz, .little);
        pos += 2;
        std.mem.writeInt(i32, buf[pos..][0..4], wx, .little);
        pos += 4;
        std.mem.writeInt(i32, buf[pos..][0..4], wy, .little);
        pos += 4;
        buf[pos] = etype;
        pos += 1;
        std.mem.writeInt(i32, buf[pos..][0..4], eidx, .little);
        pos += 4;
        std.mem.writeInt(u16, buf[pos..][0..2], name_len, .little);
        pos += 2;
        if (name_len > 0) {
            @memcpy(buf[pos..][0..name_len], ename[0..name_len]);
            pos += name_len;
        }

        for (self.plugins.items) |*p| {
            if (p.event_mask & EVENT_HOVER == 0) continue;
            const out = callPluginProcess(p, buf[0..pos], alloc) catch continue;
            defer alloc.free(out);
            self.dispatchOutMsgs(alloc, out, p);
        }
    }

    pub fn dispatchKeyEventAlloc(self: *Runtime, alloc: std.mem.Allocator, key: u8, mods: u8, action: u8) bool {
        if (comptime is_wasm) return false;
        self.tick_alloc = alloc;

        var key_buf: [HEADER_SZ + 3]u8 = undefined;
        key_buf[0] = @intFromEnum(Tag.key_event);
        std.mem.writeInt(u16, key_buf[1..3], 3, .little);
        key_buf[3] = key;
        key_buf[4] = mods;
        key_buf[5] = action;

        for (self.plugins.items) |*p| {
            if (p.event_mask & EVENT_KEYS == 0) continue;
            const out = callPluginProcess(p, &key_buf, alloc) catch continue;
            defer alloc.free(out);

            var consumed = false;
            iterOutMsgs(out, struct {
                fn cb(tag: Tag, _: []const u8, ctx: *bool) void {
                    if (tag == .consume_event) ctx.* = true;
                }
            }.cb, &consumed);

            self.dispatchOutMsgs(alloc, out, p);
            if (consumed) return true;
        }
        return false;
    }

    /// Construct a PluginHost vtable pointing at this Runtime.
    pub fn host(self: *Runtime) PluginHost.PluginHost {
        return PluginHost.from(Runtime, self);
    }

    // -- Internal: tick -------------------------------------------------------

    fn callProcessWithTick(self: *Runtime, alloc: std.mem.Allocator, p: *LoadedPlugin, dt: f32) void {
        const events = self.pending_events.slice();

        // Compute input buffer size.
        var needed: usize = HEADER_SZ + U32_SZ; // tick message
        for (p.pending_file_responses.items) |r|
            needed += HEADER_SZ + U16_SZ + r.path.len + U32_SZ + r.data.len;
        for (p.pending_state_responses.items) |sr|
            needed += HEADER_SZ + U16_SZ + sr.key.len + U16_SZ + sr.val.len;
        for (events) |ev| needed += eventSize(ev);

        const in_slice = alloc.alloc(u8, needed) catch return;
        defer alloc.free(in_slice);

        // Write tick header.
        in_slice[0] = @intFromEnum(Tag.tick);
        std.mem.writeInt(u16, in_slice[1..3], 4, .little);
        std.mem.writeInt(u32, in_slice[3..7], @bitCast(dt), .little);
        var pos: usize = HEADER_SZ + U32_SZ;

        // Flush pending file responses.
        for (p.pending_file_responses.items) |r| {
            const path_len: u16 = @intCast(@min(r.path.len, std.math.maxInt(u16)));
            const data_len: u32 = @intCast(@min(r.data.len, std.math.maxInt(u32)));
            writeHeader(in_slice, &pos, .file_response, @intCast(U16_SZ + path_len + U32_SZ + data_len));
            writeU16(in_slice, &pos, path_len);
            @memcpy(in_slice[pos..][0..path_len], r.path[0..path_len]);
            pos += path_len;
            writeU32(in_slice, &pos, data_len);
            @memcpy(in_slice[pos..][0..data_len], r.data[0..data_len]);
            pos += data_len;
        }
        p.freePendingFiles(alloc);

        // Flush pending state responses.
        for (p.pending_state_responses.items) |sr| {
            const key_len: u16 = @intCast(@min(sr.key.len, std.math.maxInt(u16)));
            const val_len: u16 = @intCast(@min(sr.val.len, std.math.maxInt(u16)));
            writeHeader(in_slice, &pos, .state_response, @intCast(U16_SZ + key_len + U16_SZ + val_len));
            writeU16(in_slice, &pos, key_len);
            @memcpy(in_slice[pos..][0..key_len], sr.key[0..key_len]);
            pos += key_len;
            writeU16(in_slice, &pos, val_len);
            @memcpy(in_slice[pos..][0..val_len], sr.val[0..val_len]);
            pos += val_len;
        }
        p.freePendingStates(alloc);

        // Append GUI events.
        for (events) |ev| writeEvent(in_slice, &pos, ev);

        const out = callPluginProcess(p, in_slice[0..pos], alloc) catch return;
        defer alloc.free(out);
        self.dispatchOutMsgs(alloc, out, p);
    }

    // -- Internal: draw -------------------------------------------------------

    fn callProcessDrawPanel(self: *Runtime, alloc: std.mem.Allocator, p: *LoadedPlugin, panel_id: u16) void {
        const needed = @as(usize, panel_id) + 1;
        if (self.panel_states.items.len < needed) {
            const prev_len = self.panel_states.items.len;
            self.panel_states.resize(alloc, needed) catch return;
            for (self.panel_states.items[prev_len..]) |*s| s.* = PanelState.init(alloc);
        }

        var in_buf: [HEADER_SZ + U16_SZ]u8 = undefined;
        in_buf[0] = @intFromEnum(Tag.draw_panel);
        std.mem.writeInt(u16, in_buf[1..3], U16_SZ, .little);
        std.mem.writeInt(u16, in_buf[3..5], panel_id, .little);

        const ps = &self.panel_states.items[panel_id];
        ps.resetForTick();

        const out = callPluginProcess(p, &in_buf, alloc) catch return;
        defer alloc.free(out);

        const arena_alloc = ps.arena.allocator();
        iterOutMsgs(out, struct {
            fn cb(tag: Tag, payload: []const u8, ctx: struct { a: std.mem.Allocator, ps: *PanelState, backing: std.mem.Allocator }) void {
                if (parseWidget(ctx.a, tag, payload)) |widget|
                    ctx.ps.widgets.append(ctx.backing, widget) catch {};
            }
        }.cb, .{ .a = arena_alloc, .ps = ps, .backing = alloc });
    }

    // -- Internal: output message dispatch ------------------------------------

    fn dispatchOutMsgs(self: *Runtime, alloc: std.mem.Allocator, out: []const u8, p: *LoadedPlugin) void {
        const Ctx = struct {
            rt: *Runtime,
            p: *LoadedPlugin,
            alloc: std.mem.Allocator,
            fn cb(tag: Tag, payload: []const u8, ctx: @This()) void {
                ctx.rt.handleOutMsg(ctx.alloc, ctx.p, tag, payload);
            }
        };
        iterOutMsgs(out, Ctx.cb, Ctx{ .rt = self, .p = p, .alloc = alloc });
    }

    fn handleOutMsg(self: *Runtime, alloc: std.mem.Allocator, p: *LoadedPlugin, tag: Tag, payload: []const u8) void {
        const ma = self.meta_arena.allocator();
        const cb = self.callbacks orelse return;
        switch (tag) {
            .register_panel => {
                var pp: usize = 0;
                const id = ma.dupe(u8, readStr(payload, &pp) orelse return) catch return;
                const title = ma.dupe(u8, readStr(payload, &pp) orelse return) catch return;
                const vim_cmd = ma.dupe(u8, readStr(payload, &pp) orelse return) catch return;
                if (pp + 2 > payload.len) return;
                const layout = payload[pp];
                pp += 1;
                const keybind = payload[pp];
                _ = cb.register_panel(cb.ctx, id, title, vim_cmd, layout, keybind, 0);
            },
            .set_status => {
                var pp: usize = 0;
                cb.set_status(cb.ctx, readStr(payload, &pp) orelse return);
            },
            .log => {
                if (payload.len < 1) return;
                var pp: usize = 1;
                const src = readStr(payload, &pp) orelse return;
                const msg = readStr(payload, &pp) orelse return;
                cb.log_msg(cb.ctx, payload[0], src, msg);
            },
            .register_command => {
                var pp: usize = 0;
                const id = ma.dupe(u8, readStr(payload, &pp) orelse return) catch return;
                const display_name = ma.dupe(u8, readStr(payload, &pp) orelse return) catch return;
                const description = ma.dupe(u8, readStr(payload, &pp) orelse return) catch return;
                cb.register_command(cb.ctx, id, display_name, description);
            },
            .set_config => {
                var pp: usize = 0;
                _ = readStr(payload, &pp) orelse return; // plugin name (unused here)
                const key = readStr(payload, &pp) orelse return;
                const val = readStr(payload, &pp) orelse return;
                cb.apply_config(cb.ctx, key, val);
            },
            .file_read_request => {
                var pp: usize = 0;
                const path = readStr(payload, &pp) orelse return;
                // Capability gate: validate read path.
                const plugin_name = std.mem.span(p.desc.name);
                const data_dir = cb.plugin_data_dir(cb.ctx, plugin_name);
                const proj_dir = cb.project_dir(cb.ctx);
                if (!Cap.validateReadPath(p.capabilities, path, data_dir, proj_dir)) {
                    enqueueFileResponse(p, alloc, path, @constCast(&[_]u8{}), false);
                    return;
                }
                if (cb.read_file(cb.ctx, path)) |data| {
                    // read_file returns host-owned slice; dupe for pending response.
                    const owned = alloc.dupe(u8, data) catch {
                        enqueueFileResponse(p, alloc, path, @constCast(&[_]u8{}), false);
                        return;
                    };
                    enqueueFileResponse(p, alloc, path, @constCast(owned), true);
                } else {
                    enqueueFileResponse(p, alloc, path, @constCast(&[_]u8{}), false);
                }
            },
            .file_write => {
                var pp: usize = 0;
                const path = readStr(payload, &pp) orelse return;
                if (pp + 4 > payload.len) return;
                const count = std.mem.readInt(u32, payload[pp..][0..4], .little);
                pp += 4;
                if (pp + count > payload.len) return;
                // Capability gate: validate write path.
                const plugin_name = std.mem.span(p.desc.name);
                const data_dir = cb.plugin_data_dir(cb.ctx, plugin_name);
                if (!Cap.validateWritePath(p.capabilities, path, data_dir)) return;
                _ = cb.write_file(cb.ctx, path, payload[pp .. pp + count]);
            },
            .request_refresh => cb.request_refresh(cb.ctx),
            .register_keybind => {
                if (payload.len < 2) return;
                var pp: usize = 2;
                const cmd_tag = ma.dupe(u8, readStr(payload, &pp) orelse return) catch return;
                cb.register_keybind(cb.ctx, payload[0], payload[1], cmd_tag);
            },
            .subscribe_events => {
                if (payload.len >= 1) p.event_mask = payload[0];
            },
            .consume_event => {}, // handled inline by keyEvent
            .override_keybind => {
                if (payload.len < 2) return;
                var pp: usize = 2;
                const cmd_tag = ma.dupe(u8, readStr(payload, &pp) orelse return) catch return;
                cb.override_keybind(cb.ctx, payload[0], payload[1], cmd_tag);
            },
            .ui_tooltip => {
                var pp: usize = 0;
                const text = readStr(payload, &pp) orelse return;
                const copy_len = @min(text.len, self.tooltip_text.len);
                @memcpy(self.tooltip_text[0..copy_len], text[0..copy_len]);
                self.tooltip_len = @intCast(copy_len);
            },
            .get_state => {
                var pp: usize = 0;
                const key = readStr(payload, &pp) orelse return;
                const val = cb.query_state(cb.ctx, key) orelse return;
                const key_dup = alloc.dupe(u8, key) catch return;
                const val_dup = alloc.dupe(u8, val) catch {
                    alloc.free(key_dup);
                    return;
                };
                p.pending_state_responses.append(alloc, .{ .key = key_dup, .val = val_dup }) catch {
                    alloc.free(key_dup);
                    alloc.free(val_dup);
                };
            },
            .push_command => {
                var pp: usize = 0;
                const cmd_tag = readStr(payload, &pp) orelse return;
                if (!ALLOWED_CMDS.has(cmd_tag)) return;
                _ = cb.push_command(cb.ctx, cmd_tag);
            },
            // Schematic mutations route through the command queue.
            .place_device, .add_wire, .set_instance_prop => {
                if (!p.capabilities.schematic_mutate) return;
                const cmd_name = switch (tag) {
                    .place_device => "place_device",
                    .add_wire => "add_wire",
                    .set_instance_prop => "set_instance_prop",
                    else => unreachable,
                };
                _ = cb.push_command(cb.ctx, cmd_name);
            },
            else => {},
        }
    }

    // -- Logging helper -------------------------------------------------------

    fn logErr(self: *Runtime, alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) void {
        _ = alloc;
        if (self.callbacks) |cb| {
            var buf: [512]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
            cb.log_msg(cb.ctx, @intFromEnum(types.LogLevel.err), "PLUGIN", msg);
        }
    }
};

// -- Module-level helpers -----------------------------------------------------

var empty_widgets: std.MultiArrayList(types.ParsedWidget) = .{};

fn sendUnload(p: *LoadedPlugin, alloc: std.mem.Allocator) void {
    const unload_msg: [HEADER_SZ]u8 = .{ @intFromEnum(Tag.unload), 0, 0 };
    _ = callPluginProcess(p, &unload_msg, alloc) catch null;
}

fn iterOutMsgs(out: []const u8, comptime cb: anytype, ctx: anytype) void {
    var opos: usize = 0;
    while (opos + HEADER_SZ <= out.len) {
        const tag_byte = out[opos];
        const payload_sz = std.mem.readInt(u16, out[opos + 1 ..][0..2], .little);
        opos += HEADER_SZ;
        if (opos + payload_sz > out.len) break;
        const payload = out[opos .. opos + payload_sz];
        opos += payload_sz;
        const tag = std.meta.intToEnum(Tag, tag_byte) catch continue;
        cb(tag, payload, ctx);
    }
}

fn callPluginProcess(
    p: *LoadedPlugin,
    in: []const u8,
    alloc: std.mem.Allocator,
) error{ OutOfMemory, PluginOutputTooLarge }![]u8 {
    if (p.buf.len < types.INITIAL_OUT_BUF) {
        if (p.buf.len > 0) alloc.free(p.buf);
        p.buf = try alloc.alloc(u8, types.INITIAL_OUT_BUF);
    }

    const n = p.desc.process(in.ptr, in.len, p.buf.ptr, p.buf.len);
    if (n != std.math.maxInt(usize)) return try alloc.dupe(u8, p.buf[0..n]);

    const new_cap = @min(p.buf.len * 2, types.MAX_OUT_BUF);
    if (new_cap == p.buf.len) return error.PluginOutputTooLarge;
    p.buf = try alloc.realloc(p.buf, new_cap);

    const n2 = p.desc.process(in.ptr, in.len, p.buf.ptr, p.buf.len);
    if (n2 == std.math.maxInt(usize)) return error.PluginOutputTooLarge;
    return try alloc.dupe(u8, p.buf[0..n2]);
}

// -- Wire-format helpers ------------------------------------------------------

fn readStr(payload: []const u8, pos: *usize) ?[]const u8 {
    if (pos.* + 2 > payload.len) return null;
    const len = std.mem.readInt(u16, payload[pos.*..][0..2], .little);
    pos.* += 2;
    if (pos.* + len > payload.len) return null;
    const s = payload[pos.* .. pos.* + len];
    pos.* += len;
    return s;
}

inline fn writeHeader(buf: []u8, pos: *usize, tag: Tag, payload_sz: u16) void {
    buf[pos.*] = @intFromEnum(tag);
    std.mem.writeInt(u16, buf[pos.* + 1 ..][0..2], payload_sz, .little);
    pos.* += HEADER_SZ;
}

inline fn writeU16(buf: []u8, pos: *usize, val: u16) void {
    std.mem.writeInt(u16, buf[pos.*..][0..2], val, .little);
    pos.* += 2;
}

inline fn writeU32(buf: []u8, pos: *usize, val: u32) void {
    std.mem.writeInt(u32, buf[pos.*..][0..4], val, .little);
    pos.* += 4;
}

fn eventSize(ev: PanelEvent) usize {
    return switch (ev.tag) {
        .button_clicked => HEADER_SZ + U16_SZ + U32_SZ,
        .slider_changed => HEADER_SZ + U16_SZ + U32_SZ + U32_SZ,
        .checkbox_changed => HEADER_SZ + U16_SZ + U32_SZ + 1,
        .text_changed => HEADER_SZ + U16_SZ + U32_SZ + U16_SZ + ev.text.len,
        else => 0,
    };
}

fn writeEvent(buf: []u8, pos: *usize, ev: PanelEvent) void {
    switch (ev.tag) {
        .button_clicked => {
            writeHeader(buf, pos, .button_clicked, U16_SZ + U32_SZ);
            writeU16(buf, pos, ev.panel_id);
            writeU32(buf, pos, ev.widget_id);
        },
        .slider_changed => {
            writeHeader(buf, pos, .slider_changed, U16_SZ + U32_SZ + U32_SZ);
            writeU16(buf, pos, ev.panel_id);
            writeU32(buf, pos, ev.widget_id);
            writeU32(buf, pos, @bitCast(ev.val_f32));
        },
        .checkbox_changed => {
            writeHeader(buf, pos, .checkbox_changed, U16_SZ + U32_SZ + 1);
            writeU16(buf, pos, ev.panel_id);
            writeU32(buf, pos, ev.widget_id);
            buf[pos.*] = ev.val_u8;
            pos.* += 1;
        },
        .text_changed => {
            const tl: u16 = @intCast(@min(ev.text.len, std.math.maxInt(u16)));
            writeHeader(buf, pos, .text_changed, U16_SZ + U32_SZ + U16_SZ + tl);
            writeU16(buf, pos, ev.panel_id);
            writeU32(buf, pos, ev.widget_id);
            writeU16(buf, pos, tl);
            if (tl > 0) {
                @memcpy(buf[pos.*..][0..tl], ev.text[0..tl]);
                pos.* += tl;
            }
        },
        else => {},
    }
}

fn enqueueFileResponse(p: *LoadedPlugin, alloc: std.mem.Allocator, path: []const u8, data: []u8, owns_data: bool) void {
    const dup_path = alloc.dupe(u8, path) catch {
        if (owns_data and data.len > 0) alloc.free(data);
        return;
    };
    p.pending_file_responses.append(alloc, .{ .path = dup_path, .data = data }) catch {
        alloc.free(dup_path);
        if (owns_data and data.len > 0) alloc.free(data);
    };
}

// -- Widget parsing -----------------------------------------------------------

fn parseTextIdWidget(arena: std.mem.Allocator, payload: []const u8, p: *usize, wtag: types.WidgetTag) ?types.ParsedWidget {
    const text = readStr(payload, p) orelse return null;
    if (p.* + 4 > payload.len) return null;
    const id = std.mem.readInt(u32, payload[p.*..][0..4], .little);
    return .{ .tag = wtag, .widget_id = id, .str = arena.dupe(u8, text) catch return null };
}

fn parseWidget(arena: std.mem.Allocator, tag: Tag, payload: []const u8) ?types.ParsedWidget {
    var p: usize = 0;
    switch (tag) {
        .ui_label => return parseTextIdWidget(arena, payload, &p, .label),
        .ui_button => return parseTextIdWidget(arena, payload, &p, .button),
        .ui_tooltip => return parseTextIdWidget(arena, payload, &p, .tooltip),
        .ui_separator, .ui_begin_row, .ui_end_row, .ui_collapsible_end => {
            if (payload.len < 4) return null;
            const wtag: types.WidgetTag = switch (tag) {
                .ui_separator => .separator,
                .ui_begin_row => .begin_row,
                .ui_end_row => .end_row,
                .ui_collapsible_end => .collapsible_end,
                else => unreachable,
            };
            return .{ .tag = wtag, .widget_id = std.mem.readInt(u32, payload[0..4], .little) };
        },
        .ui_slider => {
            if (payload.len < 16) return null;
            return .{
                .tag = .slider,
                .val = @bitCast(std.mem.readInt(u32, payload[0..4], .little)),
                .min = @bitCast(std.mem.readInt(u32, payload[4..8], .little)),
                .max = @bitCast(std.mem.readInt(u32, payload[8..12], .little)),
                .widget_id = std.mem.readInt(u32, payload[12..16], .little),
            };
        },
        .ui_checkbox => {
            if (payload.len < 1) return null;
            const checked: f32 = if (payload[0] != 0) 1.0 else 0.0;
            p = 1;
            const text = readStr(payload, &p) orelse return null;
            if (p + 4 > payload.len) return null;
            const id = std.mem.readInt(u32, payload[p..][0..4], .little);
            return .{ .tag = .checkbox, .widget_id = id, .val = checked, .str = arena.dupe(u8, text) catch return null };
        },
        .ui_progress => {
            if (payload.len < 8) return null;
            return .{
                .tag = .progress,
                .widget_id = std.mem.readInt(u32, payload[4..8], .little),
                .val = @bitCast(std.mem.readInt(u32, payload[0..4], .little)),
            };
        },
        .ui_collapsible_start => {
            const lbl = readStr(payload, &p) orelse return null;
            if (p + 5 > payload.len) return null;
            const open = payload[p] != 0;
            p += 1;
            const id = std.mem.readInt(u32, payload[p..][0..4], .little);
            return .{ .tag = .collapsible_start, .widget_id = id, .open = open, .str = arena.dupe(u8, lbl) catch return null };
        },
        .ui_text_input => {
            const hint = readStr(payload, &p) orelse return null;
            const text = readStr(payload, &p) orelse return null;
            if (p + 4 > payload.len) return null;
            const id = std.mem.readInt(u32, payload[p..][0..4], .little);
            // Store hint in .str, current text value is discarded (host manages state)
            _ = text;
            return .{ .tag = .text_input, .widget_id = id, .str = arena.dupe(u8, hint) catch return null };
        },
        .ui_text_area => {
            const hint = readStr(payload, &p) orelse return null;
            const text = readStr(payload, &p) orelse return null;
            if (p + 4 > payload.len) return null;
            const id = std.mem.readInt(u32, payload[p..][0..4], .little);
            _ = text;
            return .{ .tag = .text_area, .widget_id = id, .str = arena.dupe(u8, hint) catch return null };
        },
        else => return null,
    }
}

// -- Command whitelist --------------------------------------------------------

const ALLOWED_CMDS = std.StaticStringMap(void).initComptime(.{
    .{ "zoom_in", {} },
    .{ "zoom_out", {} },
    .{ "zoom_fit", {} },
    .{ "zoom_reset", {} },
    .{ "zoom_fit_selected", {} },
    .{ "toggle_colorscheme", {} },
    .{ "toggle_fill_rects", {} },
    .{ "toggle_text_in_symbols", {} },
    .{ "toggle_symbol_details", {} },
    .{ "toggle_crosshair", {} },
    .{ "toggle_show_netlist", {} },
    .{ "toggle_fullscreen", {} },
    .{ "snap_halve", {} },
    .{ "snap_double", {} },
    .{ "select_all", {} },
    .{ "select_none", {} },
    .{ "find_select_dialog", {} },
    .{ "highlight_selected_nets", {} },
    .{ "unhighlight_selected_nets", {} },
    .{ "unhighlight_all", {} },
    .{ "select_attached_nets", {} },
    .{ "clipboard_copy", {} },
    .{ "clipboard_cut", {} },
    .{ "clipboard_paste", {} },
    .{ "copy_selected", {} },
    .{ "move_interactive", {} },
    .{ "escape_mode", {} },
    .{ "align_to_grid", {} },
    .{ "start_wire", {} },
    .{ "start_wire_snap", {} },
    .{ "toggle_orthogonal_routing", {} },
    .{ "start_line", {} },
    .{ "start_rect", {} },
    .{ "start_polygon", {} },
    .{ "place_text", {} },
    .{ "new_tab", {} },
    .{ "close_tab", {} },
    .{ "next_tab", {} },
    .{ "prev_tab", {} },
    .{ "reload_from_disk", {} },
    .{ "descend_schematic", {} },
    .{ "descend_symbol", {} },
    .{ "ascend", {} },
    .{ "edit_in_new_tab", {} },
    .{ "make_symbol_from_schematic", {} },
    .{ "make_schematic_from_symbol", {} },
    .{ "insert_from_library", {} },
    .{ "open_file_explorer", {} },
    .{ "edit_properties", {} },
    .{ "view_properties", {} },
    .{ "netlist_hierarchical", {} },
    .{ "netlist_top_only", {} },
    .{ "toggle_flat_netlist", {} },
    .{ "export_pdf", {} },
    .{ "export_png", {} },
    .{ "export_svg", {} },
    .{ "undo", {} },
    .{ "redo", {} },
    .{ "plugins_refresh", {} },
    .{ "open_waveform_viewer", {} },
    .{ "show_keybinds", {} },
    .{ "delete_selected", {} },
    .{ "duplicate_selected", {} },
    .{ "rotate_cw", {} },
    .{ "rotate_ccw", {} },
    .{ "flip_horizontal", {} },
    .{ "flip_vertical", {} },
    .{ "nudge_left", {} },
    .{ "nudge_right", {} },
    .{ "nudge_up", {} },
    .{ "nudge_down", {} },
    .{ "place_device", {} },
    .{ "add_wire", {} },
    .{ "set_instance_prop", {} },
});
