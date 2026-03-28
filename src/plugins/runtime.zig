//! Plugin runtime -- drives the load / tick / unload lifecycle.
//!
//! .-- Native (Linux/macOS/Windows) ----------------------------------------.
//! |  Scans ~/.config/Schemify/<name>/                                       |
//! |    <name>.so  |  lib<name>.so       <- top-level (direct install)       |
//! |    lib/<name>.so | lib/lib<name>.so <- zig-build default prefix         |
//! |  Calls dlopen() -> looks up `schemify_plugin` -> ABI-checks -> lifecycle|
//! `------------------------------------------------------------------------'
//!
//! .-- Web (wasm32) ---------------------------------------------------------.
//! |  WASM plugins are loaded entirely by plugin_host.js in the browser.    |
//! |  The Zig runtime is a no-op stub on this target.                       |
//! |  WASM-side plugin API is provided by the web host runtime imports.      |
//! `------------------------------------------------------------------------'

const std = @import("std");
const builtin = @import("builtin");
const pi = @import("PluginIF");
const st = @import("state");
const Vfs = pi.Vfs;
const theme_config = @import("theme_config");

const is_wasm = builtin.cpu.arch == .wasm32 or builtin.cpu.arch == .wasm64;

// -- Constants ----------------------------------------------------------------

const INITIAL_OUT_BUF: usize = 4096;
const MAX_OUT_BUF: usize = 64 * 1024;
const MAX_EVENTS: usize = 64;

// -- PanelState ---------------------------------------------------------------

/// Per-panel widget list + arena that is reset each draw tick.
const PanelState = struct {
    widgets: std.MultiArrayList(Runtime.ParsedWidget) = .{},
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

const LoadedPlugin = struct {
    lib: std.DynLib,
    desc: *const pi.Descriptor,
    /// I/O buffer reused across calls; may grow up to MAX_OUT_BUF.
    buf: []u8,
    /// File responses queued from file_read_request; flushed into the next tick input.
    pending_responses: std.ArrayListUnmanaged(PendingFileResponse),

    const PendingFileResponse = struct {
        path: []u8,
        data: []u8,
    };

    fn freePendingResponses(self: *LoadedPlugin, alloc: std.mem.Allocator) void {
        for (self.pending_responses.items) |r| {
            alloc.free(r.path);
            if (r.data.len > 0) alloc.free(r.data);
        }
        self.pending_responses.clearRetainingCapacity();
    }
};

// -- Runtime ------------------------------------------------------------------

pub const Runtime = struct {
    const Self = @This();

    // -- Nested public types --------------------------------------------------

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
    };

    /// Flat widget record -- all variants share the same struct so MultiArrayList
    /// can separate hot fields (tag, widget_id) from cold string/float data.
    pub const ParsedWidget = struct {
        tag: WidgetTag,
        widget_id: u32,
        str: []const u8 = &.{},
        val: f32 = 0,
        min: f32 = 0,
        max: f32 = 1,
        open: bool = false,
    };

    /// An input event queued from GUI interaction to be sent on the next tick.
    pub const PanelEvent = struct {
        tag: pi.Tag,
        panel_id: u16,
        widget_id: u32,
        val_f32: f32 = 0,
        val_u8: u8 = 0,
    };

    // -- Fields ---------------------------------------------------------------

    alloc: std.mem.Allocator,
    app: *st.AppState,
    plugins: std.ArrayListUnmanaged(LoadedPlugin),
    scratch: [256]u8,
    panel_states: std.ArrayListUnmanaged(PanelState),
    /// Arena for plugin metadata strings (panel ids/titles, command names, etc.).
    /// Reset on plugin refresh; freed on deinit.
    meta_arena: std.heap.ArenaAllocator,
    /// Fixed-capacity event buffer -- no heap allocation per frame.
    pending_events: struct {
        buf: [MAX_EVENTS]PanelEvent = undefined,
        len: usize = 0,

        fn append(self: *@This(), ev: PanelEvent) void {
            if (self.len < MAX_EVENTS) {
                self.buf[self.len] = ev;
                self.len += 1;
            }
        }

        fn slice(self: *const @This()) []const PanelEvent {
            return self.buf[0..self.len];
        }
    } = .{},

    // -- Lifecycle ------------------------------------------------------------

    pub fn init(alloc: std.mem.Allocator) Self {
        return .{
            .alloc = alloc,
            .app = undefined,
            .plugins = .{},
            .scratch = [_]u8{0} ** 256,
            .panel_states = .{},
            .meta_arena = std.heap.ArenaAllocator.init(alloc),
        };
    }

    pub fn loadStartup(self: *Self, app: *st.AppState) void {
        if (comptime is_wasm) return;
        self.app = app;
        self.scanAndLoad();
    }

    pub fn tick(self: *Self, app: *st.AppState, dt: f32) void {
        if (comptime is_wasm) return;
        self.app = app;
        for (self.plugins.items) |*p| self.callProcessWithTick(p, dt);
        self.pending_events.len = 0;

        for (app.gui.plugin_panels.items) |panel| {
            if (!panel.visible) continue;
            for (self.plugins.items) |*p| self.callProcessDrawPanel(p, panel.panel_id);
        }
    }

    pub fn getPanelWidgetList(self: *Runtime, panel_id: u16) *const std.MultiArrayList(ParsedWidget) {
        if (panel_id >= self.panel_states.items.len) return &empty_widget_list;
        return &self.panel_states.items[panel_id].widgets;
    }

    // -- Dispatch helpers (called by plugin_panels.zig) -----------------------

    pub fn dispatchButtonClicked(self: *Runtime, panel_id: u16, widget_id: u32) void {
        self.pending_events.append(.{ .tag = .button_clicked, .panel_id = panel_id, .widget_id = widget_id });
    }

    pub fn dispatchSliderChanged(self: *Runtime, panel_id: u16, widget_id: u32, val: f32) void {
        self.pending_events.append(.{ .tag = .slider_changed, .panel_id = panel_id, .widget_id = widget_id, .val_f32 = val });
    }

    pub fn dispatchCheckboxChanged(self: *Runtime, panel_id: u16, widget_id: u32, val: bool) void {
        self.pending_events.append(.{ .tag = .checkbox_changed, .panel_id = panel_id, .widget_id = widget_id, .val_u8 = if (val) 1 else 0 });
    }

    pub fn refresh(self: *Self, app: *st.AppState) void {
        if (comptime is_wasm) return;
        self.app = app;
        self.unloadAll();
        self.scanAndLoad();
    }

    pub fn deinit(self: *Self, app: *st.AppState) void {
        if (comptime is_wasm) return;
        self.app = app;
        self.unloadAll();
        self.plugins.deinit(self.alloc);
        for (self.panel_states.items) |*ps| ps.deinit(self.alloc);
        self.panel_states.deinit(self.alloc);
        self.meta_arena.deinit();
        self.* = undefined;
    }

    // -- Internal: tick -------------------------------------------------------

    fn callProcessWithTick(self: *Self, p: *LoadedPlugin, dt: f32) void {
        const events = self.pending_events.slice();

        // Compute input buffer size.
        var needed: usize = pi.HEADER_SZ + pi.U32_SZ; // tick message
        for (p.pending_responses.items) |r|
            needed += pi.HEADER_SZ + pi.U16_SZ + r.path.len + pi.U32_SZ + r.data.len;
        for (events) |ev|
            needed += eventSize(ev);

        var heap_in: ?[]u8 = null;
        defer if (heap_in) |h| self.alloc.free(h);

        const in_slice: []u8 = if (needed <= self.scratch.len)
            self.scratch[0..needed]
        else blk: {
            heap_in = self.alloc.alloc(u8, needed) catch return;
            break :blk heap_in.?;
        };

        // Write tick header + dt.
        in_slice[0] = @intFromEnum(pi.Tag.tick);
        std.mem.writeInt(u16, in_slice[1..3], 4, .little);
        std.mem.writeInt(u32, in_slice[3..7], @as(u32, @bitCast(dt)), .little);
        var pos: usize = pi.HEADER_SZ + pi.U32_SZ;

        // Append pending file responses.
        for (p.pending_responses.items) |r| {
            const path_len: u16 = @intCast(@min(r.path.len, std.math.maxInt(u16)));
            const data_len: u32 = @intCast(@min(r.data.len, std.math.maxInt(u32)));
            writeHeader(in_slice, &pos, .file_response, @intCast(pi.U16_SZ + path_len + pi.U32_SZ + data_len));
            writeU16(in_slice, &pos, path_len);
            @memcpy(in_slice[pos .. pos + path_len], r.path[0..path_len]);
            pos += path_len;
            writeU32(in_slice, &pos, data_len);
            @memcpy(in_slice[pos .. pos + data_len], r.data[0..data_len]);
            pos += data_len;
        }
        p.freePendingResponses(self.alloc);

        // Append pending GUI events.
        for (events) |ev| writeEvent(in_slice, &pos, ev);

        const out = callPluginProcess(p, in_slice[0..pos], self.alloc) catch return;
        defer self.alloc.free(out);
        self.dispatchOutMsgs(out, p);
    }

    // -- Internal: draw -------------------------------------------------------

    fn callProcessDrawPanel(self: *Self, p: *LoadedPlugin, panel_id: u16) void {
        const needed = @as(usize, panel_id) + 1;
        if (self.panel_states.items.len < needed) {
            const prev_len = self.panel_states.items.len;
            self.panel_states.resize(self.alloc, needed) catch return;
            for (self.panel_states.items[prev_len..]) |*s| s.* = PanelState.init(self.alloc);
        }

        var in_buf: [pi.HEADER_SZ + pi.U16_SZ]u8 = undefined;
        in_buf[0] = @intFromEnum(pi.Tag.draw_panel);
        std.mem.writeInt(u16, in_buf[1..3], pi.U16_SZ, .little);
        std.mem.writeInt(u16, in_buf[3..5], panel_id, .little);

        const ps = &self.panel_states.items[panel_id];
        ps.resetForTick();

        const out = callPluginProcess(p, &in_buf, self.alloc) catch return;
        defer self.alloc.free(out);

        const arena_alloc = ps.arena.allocator();
        iterOutMsgs(out, struct {
            fn cb(tag: pi.Tag, payload: []const u8, ctx: anytype) void {
                if (parseWidget(ctx.arena, tag, payload)) |widget|
                    ctx.ps.widgets.append(ctx.backing, widget) catch {};
            }
        }.cb, .{ .arena = arena_alloc, .ps = ps, .backing = self.alloc });
    }

    // -- Internal: output message dispatch ------------------------------------

    fn dispatchOutMsgs(self: *Self, out: []const u8, p: *LoadedPlugin) void {
        iterOutMsgs(out, struct {
            fn cb(tag: pi.Tag, payload: []const u8, ctx: anytype) void {
                ctx.rt.handleOutMsg(ctx.p, tag, payload);
            }
        }.cb, .{ .rt = self, .p = p });
    }

    fn handleOutMsg(self: *Self, p: *LoadedPlugin, tag: pi.Tag, payload: []const u8) void {
        const ma = self.meta_arena.allocator();
        switch (tag) {
            .register_panel => {
                var pp: usize = 0;
                const id = ma.dupe(u8, readStr(payload, &pp) orelse return) catch return;
                const title = ma.dupe(u8, readStr(payload, &pp) orelse return) catch return;
                const vim_cmd = ma.dupe(u8, readStr(payload, &pp) orelse return) catch return;
                if (pp + 2 > payload.len) return;
                const layout: st.PluginPanelLayout = switch (payload[pp]) {
                    1 => .left_sidebar,
                    2 => .right_sidebar,
                    3 => .bottom_bar,
                    else => .overlay,
                };
                pp += 1;
                _ = self.app.registerPluginPanelEx(id, title, vim_cmd, layout, payload[pp], 0);
            },
            .set_status => {
                var pp: usize = 0;
                const raw = readStr(payload, &pp) orelse return;
                self.app.setStatusBuf(raw);
            },
            .log => {
                if (payload.len < 1) return;
                var pp: usize = 1;
                const src = readStr(payload, &pp) orelse return;
                const msg = readStr(payload, &pp) orelse return;
                self.app.log.info("PLUGIN", "[{s}] {s}", .{ src, msg });
            },
            .register_command => {
                var pp: usize = 0;
                const id = ma.dupe(u8, readStr(payload, &pp) orelse return) catch return;
                const display_name = ma.dupe(u8, readStr(payload, &pp) orelse return) catch return;
                const description = ma.dupe(u8, readStr(payload, &pp) orelse return) catch return;
                _ = self.app.registerPluginCommand(id, display_name, description);
            },
            .set_config => {
                var pp: usize = 0;
                _ = readStr(payload, &pp) orelse return;
                const key = readStr(payload, &pp) orelse return;
                const val = readStr(payload, &pp) orelse return;
                if (std.mem.eql(u8, key, "active_theme")) theme_config.applyJson(val);
            },
            .file_read_request => {
                var pp: usize = 0;
                const path = readStr(payload, &pp) orelse return;
                const data = Vfs.readAlloc(self.alloc, path) catch {
                    // Queue empty response so the plugin isn't left waiting.
                    enqueueFileResponse(p, self.alloc, path, @constCast(&[_]u8{}), false);
                    return;
                };
                enqueueFileResponse(p, self.alloc, path, data, true);
            },
            .file_write => {
                var pp: usize = 0;
                const path = readStr(payload, &pp) orelse return;
                if (pp + 4 > payload.len) return;
                const count = std.mem.readInt(u32, payload[pp..][0..4], .little);
                pp += 4;
                if (pp + count > payload.len) return;
                Vfs.writeAll(path, payload[pp .. pp + count]) catch |err| {
                    self.app.log.err("PLUGIN", "file_write({s}): {}", .{ path, err });
                };
            },
            .request_refresh => self.app.plugin_refresh_requested = true,
            .register_keybind => {
                if (payload.len < 2) return;
                var pp: usize = 2;
                const cmd_tag = ma.dupe(u8, readStr(payload, &pp) orelse return) catch return;
                self.app.gui.plugin_keybinds.append(self.alloc, .{
                    .key = payload[0],
                    .mods = payload[1],
                    .cmd_tag = cmd_tag,
                }) catch {};
            },
            .push_command => {
                var pp: usize = 0;
                const cmd_tag = readStr(payload, &pp) orelse return;
                const cmd_payload = readStr(payload, &pp);
                if (!isCommandAllowed(cmd_tag)) {
                    self.app.log.err("PLUGIN", "push_command: blocked '{s}'", .{cmd_tag});
                    return;
                }
                const tag_dup = ma.dupe(u8, cmd_tag) catch return;
                const payload_dup: ?[]const u8 = if (cmd_payload) |cp| ma.dupe(u8, cp) catch return else null;
                self.app.queue.push(self.alloc, .{
                    .immediate = .{ .plugin_command = .{ .tag = tag_dup, .payload = payload_dup } },
                }) catch {};
            },
            else => {},
        }
    }

    // -- Internal: scan & load ------------------------------------------------

    fn scanAndLoad(self: *Self) void {
        const home = pi.platform.getEnvVar(self.alloc, "HOME") catch return;
        defer self.alloc.free(home);

        var cfg_buf: [4096]u8 = undefined;
        const cfg_dir = std.fmt.bufPrint(&cfg_buf, "{s}/.config/Schemify", .{home}) catch return;

        const listing = Vfs.listDir(self.alloc, cfg_dir) catch return;
        defer listing.deinit(self.alloc);

        for (listing.entries) |entry_name| {
            var plugin_buf: [4096]u8 = undefined;
            const plugin_dir = std.fmt.bufPrint(&plugin_buf, "{s}/{s}", .{ cfg_dir, entry_name }) catch continue;
            self.loadSoFromDir(plugin_dir);

            var lib_buf: [4096]u8 = undefined;
            const lib_dir = std.fmt.bufPrint(&lib_buf, "{s}/lib", .{plugin_dir}) catch continue;
            self.loadSoFromDir(lib_dir);
        }
    }

    fn loadSoFromDir(self: *Self, dir_path: []const u8) void {
        if (comptime is_wasm) return;
        const listing = Vfs.listDir(self.alloc, dir_path) catch return;
        defer listing.deinit(self.alloc);

        for (listing.entries) |file_name| {
            if (!std.mem.endsWith(u8, file_name, ".so")) continue;
            var so_buf: [4096]u8 = undefined;
            const so_path = std.fmt.bufPrint(&so_buf, "{s}/{s}", .{ dir_path, file_name }) catch continue;
            self.loadOne(so_path);
        }
    }

    fn loadOne(self: *Self, so_path: []const u8) void {
        var lib = std.DynLib.open(so_path) catch |err| {
            self.app.log.err("PLUGIN", "dlopen({s}): {}", .{ so_path, err });
            return;
        };

        const desc = lib.lookup(*const pi.Descriptor, "schemify_plugin") orelse {
            self.app.log.err("PLUGIN", "{s}: missing 'schemify_plugin' export", .{so_path});
            lib.close();
            return;
        };

        if (desc.abi_version != pi.ABI_VERSION) {
            self.app.log.err("PLUGIN", "{s}: ABI {d} != {d}", .{ so_path, desc.abi_version, pi.ABI_VERSION });
            lib.close();
            return;
        }

        // Build load message.
        const dir = self.app.project_dir;
        const dir_len: u16 = @intCast(@min(dir.len, std.math.maxInt(u16)));
        var load_buf: [pi.HEADER_SZ + pi.U16_SZ + 4096]u8 = undefined;
        load_buf[0] = @intFromEnum(pi.Tag.load);
        std.mem.writeInt(u16, load_buf[1..3], pi.U16_SZ + dir_len, .little);
        std.mem.writeInt(u16, load_buf[3..5], dir_len, .little);
        @memcpy(load_buf[5 .. 5 + dir_len], dir[0..dir_len]);

        var p: LoadedPlugin = .{ .lib = lib, .desc = desc, .buf = &.{}, .pending_responses = .{} };

        if (callPluginProcess(&p, load_buf[0 .. pi.HEADER_SZ + pi.U16_SZ + @as(usize, dir_len)], self.alloc)) |out| {
            defer self.alloc.free(out);
            self.dispatchOutMsgs(out, &p);
        } else |_| {}

        self.plugins.append(self.alloc, p) catch |err| {
            self.app.log.err("PLUGIN", "OOM {s}: {}", .{ so_path, err });
            const unload_msg: [pi.HEADER_SZ]u8 = .{ @intFromEnum(pi.Tag.unload), 0, 0 };
            _ = callPluginProcess(&p, &unload_msg, self.alloc) catch null;
            if (p.buf.len > 0) self.alloc.free(p.buf);
            lib.close();
            return;
        };

        self.app.log.info("PLUGIN", "loaded {s} v{s}", .{
            std.mem.span(desc.name), std.mem.span(desc.version_str),
        });
    }

    fn unloadAll(self: *Self) void {
        const unload_msg: [pi.HEADER_SZ]u8 = .{ @intFromEnum(pi.Tag.unload), 0, 0 };
        for (self.plugins.items) |*p| {
            _ = callPluginProcess(p, &unload_msg, self.alloc) catch null;
            self.app.log.info("PLUGIN", "unloaded {s}", .{std.mem.span(p.desc.name)});
            p.freePendingResponses(self.alloc);
            if (p.buf.len > 0) self.alloc.free(p.buf);
            p.lib.close();
        }
        self.plugins.clearRetainingCapacity();
        self.app.clearPluginCommands();
        // Reset the metadata arena — all duped panel/command strings are invalidated
        // along with the panel/command lists cleared above.
        _ = self.meta_arena.reset(.retain_capacity);
    }
};

// -- Module-level private helpers ---------------------------------------------

const empty_widget_list: std.MultiArrayList(Runtime.ParsedWidget) = .{};

/// Iterate output message frames, calling cb(tag, payload, ctx) for each.
fn iterOutMsgs(out: []const u8, comptime cb: anytype, ctx: anytype) void {
    var opos: usize = 0;
    while (opos + pi.HEADER_SZ <= out.len) {
        const tag_byte = out[opos];
        const payload_sz = std.mem.readInt(u16, out[opos + 1 ..][0..2], .little);
        opos += pi.HEADER_SZ;
        if (opos + payload_sz > out.len) break;
        const payload = out[opos .. opos + payload_sz];
        opos += payload_sz;
        const tag = std.meta.intToEnum(pi.Tag, tag_byte) catch continue;
        cb(tag, payload, ctx);
    }
}

/// Call process() with retry-on-overflow. Caller owns returned slice.
fn callPluginProcess(
    p: *LoadedPlugin,
    in: []const u8,
    alloc: std.mem.Allocator,
) error{ OutOfMemory, PluginOutputTooLarge }![]u8 {
    if (p.buf.len < INITIAL_OUT_BUF) {
        if (p.buf.len > 0) alloc.free(p.buf);
        p.buf = try alloc.alloc(u8, INITIAL_OUT_BUF);
    }

    const n = p.desc.process(in.ptr, in.len, p.buf.ptr, p.buf.len);
    if (n != std.math.maxInt(usize)) return try alloc.dupe(u8, p.buf[0..n]);

    const new_cap = @min(p.buf.len * 2, MAX_OUT_BUF);
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

/// Write [tag][u16 payload_sz] header into buf at *pos; advances pos.
inline fn writeHeader(buf: []u8, pos: *usize, tag: pi.Tag, payload_sz: u16) void {
    buf[pos.*] = @intFromEnum(tag);
    std.mem.writeInt(u16, buf[pos.* + 1 ..][0..2], payload_sz, .little);
    pos.* += pi.HEADER_SZ;
}

inline fn writeU16(buf: []u8, pos: *usize, val: u16) void {
    std.mem.writeInt(u16, buf[pos.*..][0..2], val, .little);
    pos.* += 2;
}

inline fn writeU32(buf: []u8, pos: *usize, val: u32) void {
    std.mem.writeInt(u32, buf[pos.*..][0..4], val, .little);
    pos.* += 4;
}

/// Byte size of a serialised PanelEvent.
fn eventSize(ev: Runtime.PanelEvent) usize {
    return switch (ev.tag) {
        .button_clicked => pi.HEADER_SZ + pi.U16_SZ + pi.U32_SZ,
        .slider_changed => pi.HEADER_SZ + pi.U16_SZ + pi.U32_SZ + pi.U32_SZ,
        .checkbox_changed => pi.HEADER_SZ + pi.U16_SZ + pi.U32_SZ + 1,
        else => 0,
    };
}

/// Serialise one PanelEvent into buf at *pos.
fn writeEvent(buf: []u8, pos: *usize, ev: Runtime.PanelEvent) void {
    switch (ev.tag) {
        .button_clicked => {
            writeHeader(buf, pos, .button_clicked, pi.U16_SZ + pi.U32_SZ);
            writeU16(buf, pos, ev.panel_id);
            writeU32(buf, pos, ev.widget_id);
        },
        .slider_changed => {
            writeHeader(buf, pos, .slider_changed, pi.U16_SZ + pi.U32_SZ + pi.U32_SZ);
            writeU16(buf, pos, ev.panel_id);
            writeU32(buf, pos, ev.widget_id);
            writeU32(buf, pos, @bitCast(ev.val_f32));
        },
        .checkbox_changed => {
            writeHeader(buf, pos, .checkbox_changed, pi.U16_SZ + pi.U32_SZ + 1);
            writeU16(buf, pos, ev.panel_id);
            writeU32(buf, pos, ev.widget_id);
            buf[pos.*] = ev.val_u8;
            pos.* += 1;
        },
        else => {},
    }
}

fn enqueueFileResponse(
    p: *LoadedPlugin,
    alloc: std.mem.Allocator,
    path: []const u8,
    data: []u8,
    owns_data: bool,
) void {
    const dup_path = alloc.dupe(u8, path) catch {
        if (owns_data and data.len > 0) alloc.free(data);
        return;
    };

    p.pending_responses.append(alloc, .{ .path = dup_path, .data = data }) catch {
        alloc.free(dup_path);
        if (owns_data and data.len > 0) alloc.free(data);
    };
}

// -- Widget parsing -----------------------------------------------------------

fn parseTextIdWidget(
    arena: std.mem.Allocator,
    payload: []const u8,
    p: *usize,
    widget_tag: Runtime.WidgetTag,
) ?Runtime.ParsedWidget {
    const text = readStr(payload, p) orelse return null;
    if (p.* + 4 > payload.len) return null;
    const id = std.mem.readInt(u32, payload[p.*..][0..4], .little);
    return .{ .tag = widget_tag, .widget_id = id, .str = arena.dupe(u8, text) catch return null };
}

fn parseIdOnlyWidget(payload: []const u8, widget_tag: Runtime.WidgetTag) ?Runtime.ParsedWidget {
    if (payload.len < 4) return null;
    return .{ .tag = widget_tag, .widget_id = std.mem.readInt(u32, payload[0..4], .little) };
}

fn parseWidget(arena: std.mem.Allocator, tag: pi.Tag, payload: []const u8) ?Runtime.ParsedWidget {
    var p: usize = 0;
    switch (tag) {
        // str + u32 id
        .ui_label => return parseTextIdWidget(arena, payload, &p, .label),
        .ui_button => return parseTextIdWidget(arena, payload, &p, .button),
        // u32 id only
        .ui_separator => return parseIdOnlyWidget(payload, .separator),
        .ui_begin_row => return parseIdOnlyWidget(payload, .begin_row),
        .ui_end_row => return parseIdOnlyWidget(payload, .end_row),
        .ui_collapsible_end => return parseIdOnlyWidget(payload, .collapsible_end),
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
        else => return null,
    }
}

// -- Command whitelist --------------------------------------------------------

const allowed_plugin_commands = [_][]const u8{
    "zoom_in",            "zoom_out",            "zoom_fit",               "zoom_reset",
    "toggle_colorscheme", "toggle_fill_rects",   "toggle_text_in_symbols", "toggle_symbol_details",
    "toggle_crosshair",   "toggle_show_netlist", "snap_halve",             "snap_double",
    "select_all",         "select_none",         "plugins_refresh",
};

fn isCommandAllowed(cmd_tag: []const u8) bool {
    inline for (allowed_plugin_commands) |c| {
        if (std.mem.eql(u8, cmd_tag, c)) return true;
    }
    return false;
}

// -- Size test ----------------------------------------------------------------

test "Expose struct size for Runtime" {
    const print = @import("std").debug.print;
    print("Runtime: {d}B\n", .{@sizeOf(Runtime)});
}
