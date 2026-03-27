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
//! |  See src/plugins/WasmPlugin.zig for the WASM-side plugin helper.       |
//! `------------------------------------------------------------------------'

const std = @import("std");
const builtin = @import("builtin");
const pi = @import("PluginIF");
const st = @import("state");
const cmd = @import("commands");
const Vfs = pi.Vfs;
const theme_config = @import("theme_config");

const is_wasm = builtin.cpu.arch == .wasm32 or builtin.cpu.arch == .wasm64;

// -- Constants ----------------------------------------------------------------

const INITIAL_OUT_BUF: usize = 4096;
const MAX_OUT_BUF: usize = 64 * 1024;

// -- PendingFileResponse ------------------------------------------------------

/// A file-response message waiting to be delivered to a plugin on the next tick.
const PendingFileResponse = struct {
    path: []u8,
    data: []u8,
};

// -- EventRing ----------------------------------------------------------------

/// Fixed-capacity stack for pending events; no heap allocation per frame.
/// Replaces std.BoundedArray (removed from std in Zig 0.15).
fn EventRing(comptime T: type, comptime cap: usize) type {
    return struct {
        buf: [cap]T = undefined,
        len: usize = 0,

        pub fn append(self: *@This(), val: T) void {
            if (self.len < cap) {
                self.buf[self.len] = val;
                self.len += 1;
            }
        }

        pub fn slice(self: *const @This()) []const T {
            return self.buf[0..self.len];
        }
    };
}

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

    /// Discard widgets and reclaim arena memory, retaining OS-level capacity
    /// so the next tick rarely allocates.
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
};

// -- Runtime ------------------------------------------------------------------

pub const Runtime = struct {
    const Self = @This();

    // -- Nested public types --------------------------------------------------

    /// Tag for the flat ParsedWidget struct (used by MultiArrayList hot path).
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
    ///
    /// Field order is chosen for natural alignment to avoid padding:
    ///   tag(1) + pad(3) + widget_id(4) = 8 bytes hot
    ///   str(16) + val(4) + min(4) + max(4) + open(1) + pad(3) = 32 bytes cold
    pub const ParsedWidget = struct {
        /// Hot: checked on every frame to dispatch rendering.
        tag: WidgetTag,
        /// Hot: needed for event routing.
        widget_id: u32,
        // Cold: only read when tag matches.
        str: []const u8 = &.{}, // label/button text, checkbox label, collapsible label
        val: f32 = 0, // slider value, progress fraction, checkbox bool (0/1)
        min: f32 = 0, // slider min
        max: f32 = 1, // slider max
        open: bool = false, // collapsible initial state
    };

    /// An input event queued from GUI interaction to be sent on the next tick.
    pub const PanelEvent = struct {
        tag: pi.Tag,
        panel_id: u16,
        widget_id: u32,
        val_f32: f32 = 0,
        val_u8: u8 = 0,
        text: [128]u8 = [_]u8{0} ** 128,
        text_len: u8 = 0,
    };

    // -- Fields ---------------------------------------------------------------

    alloc: std.mem.Allocator,
    app: *st.AppState,
    plugins: std.ArrayListUnmanaged(LoadedPlugin),
    scratch: [256]u8,
    /// Per-panel state: widget list + arena, indexed by panel_id (0-based).
    /// Grown on demand; never shrunk during a session.
    panel_states: std.ArrayListUnmanaged(PanelState),
    /// Fixed-capacity event ring -- no heap allocation per frame.
    /// Events are broadcast to ALL plugins on the next tick, then drained.
    pending_events: EventRing(PanelEvent, 64) = .{},

    // -- Lifecycle ------------------------------------------------------------

    pub fn init(alloc: std.mem.Allocator) Self {
        return .{
            .alloc = alloc,
            .app = undefined,
            .plugins = .{},
            .scratch = [_]u8{0} ** 256,
            .panel_states = .{},
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
        // Each plugin sees the same event snapshot for the frame; drain only after
        // all plugins have processed so none is starved.
        for (self.plugins.items) |*p| self.callProcessWithTick(p, dt);
        self.pending_events.len = 0;

        for (app.gui.plugin_panels.items) |panel| {
            if (!panel.visible) continue;
            for (self.plugins.items) |*p| self.callProcessDrawPanel(p, panel.panel_id);
        }
    }

    /// Returns the MultiArrayList for a panel so callers can use
    /// `list.items(.tag)`, `list.items(.widget_id)`, etc.
    /// The returned pointer is valid until the next tick (arena reset).
    pub fn getPanelWidgetList(self: *Runtime, panel_id: u16) *const std.MultiArrayList(ParsedWidget) {
        if (panel_id >= self.panel_states.items.len) return &empty_widget_list;
        return &self.panel_states.items[panel_id].widgets;
    }

    // -- Dispatch helpers (called by plugin_panels.zig) -----------------------

    pub fn dispatchButtonClicked(self: *Runtime, panel_id: u16, widget_id: u32) void {
        self.pending_events.append(.{
            .tag = .button_clicked,
            .panel_id = panel_id,
            .widget_id = widget_id,
        });
    }

    pub fn dispatchSliderChanged(self: *Runtime, panel_id: u16, widget_id: u32, val: f32) void {
        self.pending_events.append(.{
            .tag = .slider_changed,
            .panel_id = panel_id,
            .widget_id = widget_id,
            .val_f32 = val,
        });
    }

    pub fn dispatchCheckboxChanged(self: *Runtime, panel_id: u16, widget_id: u32, val: bool) void {
        self.pending_events.append(.{
            .tag = .checkbox_changed,
            .panel_id = panel_id,
            .widget_id = widget_id,
            .val_u8 = if (val) 1 else 0,
        });
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
        self.* = undefined;
    }

    // -- Internal -------------------------------------------------------------

    /// Build the tick input batch and call process() for one plugin.
    /// Does NOT drain pending_events -- tick() owns that after all plugins run.
    fn callProcessWithTick(self: *Self, p: *LoadedPlugin, dt: f32) void {
        // Compute needed input buffer size:
        //   tick:          HEADER_SZ(3) + f32(4) = 7 bytes
        //   file_response: HEADER_SZ + U16_SZ + path.len + U32_SZ + data.len
        //   event:         HEADER_SZ + payload (varies per tag)
        var needed: usize = pi.HEADER_SZ + pi.U32_SZ;
        for (p.pending_responses.items) |r| {
            needed += pi.HEADER_SZ + pi.U16_SZ + r.path.len + pi.U32_SZ + r.data.len;
        }
        for (self.pending_events.slice()) |ev| {
            needed += switch (ev.tag) {
                .button_clicked => @as(usize, pi.HEADER_SZ + pi.U16_SZ + pi.U32_SZ),
                .slider_changed => @as(usize, pi.HEADER_SZ + pi.U16_SZ + pi.U32_SZ + pi.U32_SZ),
                .checkbox_changed => @as(usize, pi.HEADER_SZ + pi.U16_SZ + pi.U32_SZ + 1),
                else => @as(usize, 0),
            };
        }

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

        // Append pending file responses and free them.
        for (p.pending_responses.items) |r| {
            const path_len: u16 = @intCast(@min(r.path.len, std.math.maxInt(u16)));
            const data_len: u32 = @intCast(@min(r.data.len, std.math.maxInt(u32)));
            const payload_sz: u16 = @intCast(pi.U16_SZ + path_len + pi.U32_SZ + data_len);
            in_slice[pos] = @intFromEnum(pi.Tag.file_response);
            std.mem.writeInt(u16, in_slice[pos + 1 ..][0..2], payload_sz, .little);
            pos += pi.HEADER_SZ;
            std.mem.writeInt(u16, in_slice[pos..][0..2], path_len, .little);
            pos += pi.U16_SZ;
            @memcpy(in_slice[pos .. pos + path_len], r.path[0..path_len]);
            pos += path_len;
            std.mem.writeInt(u32, in_slice[pos..][0..4], data_len, .little);
            pos += pi.U32_SZ;
            @memcpy(in_slice[pos .. pos + data_len], r.data[0..data_len]);
            pos += data_len;
        }
        freePendingResponses(self.alloc, &p.pending_responses);

        // Append pending GUI events (read-only; caller drains after all plugins).
        for (self.pending_events.slice()) |ev| {
            switch (ev.tag) {
                .button_clicked => {
                    in_slice[pos] = @intFromEnum(pi.Tag.button_clicked);
                    std.mem.writeInt(u16, in_slice[pos + 1 ..][0..2], pi.U16_SZ + pi.U32_SZ, .little);
                    pos += pi.HEADER_SZ;
                    std.mem.writeInt(u16, in_slice[pos..][0..2], ev.panel_id, .little);
                    pos += pi.U16_SZ;
                    std.mem.writeInt(u32, in_slice[pos..][0..4], ev.widget_id, .little);
                    pos += pi.U32_SZ;
                },
                .slider_changed => {
                    in_slice[pos] = @intFromEnum(pi.Tag.slider_changed);
                    std.mem.writeInt(u16, in_slice[pos + 1 ..][0..2], pi.U16_SZ + pi.U32_SZ + pi.U32_SZ, .little);
                    pos += pi.HEADER_SZ;
                    std.mem.writeInt(u16, in_slice[pos..][0..2], ev.panel_id, .little);
                    pos += pi.U16_SZ;
                    std.mem.writeInt(u32, in_slice[pos..][0..4], ev.widget_id, .little);
                    pos += pi.U32_SZ;
                    std.mem.writeInt(u32, in_slice[pos..][0..4], @as(u32, @bitCast(ev.val_f32)), .little);
                    pos += pi.U32_SZ;
                },
                .checkbox_changed => {
                    in_slice[pos] = @intFromEnum(pi.Tag.checkbox_changed);
                    std.mem.writeInt(u16, in_slice[pos + 1 ..][0..2], pi.U16_SZ + pi.U32_SZ + 1, .little);
                    pos += pi.HEADER_SZ;
                    std.mem.writeInt(u16, in_slice[pos..][0..2], ev.panel_id, .little);
                    pos += pi.U16_SZ;
                    std.mem.writeInt(u32, in_slice[pos..][0..4], ev.widget_id, .little);
                    pos += pi.U32_SZ;
                    in_slice[pos] = ev.val_u8;
                    pos += 1;
                },
                else => {},
            }
        }

        const out = callPluginProcess(p, in_slice[0..pos], self.alloc) catch return;
        defer self.alloc.free(out);
        parseOutMsgs(out, self, p);
    }

    fn callProcessDrawPanel(self: *Self, p: *LoadedPlugin, panel_id: u16) void {
        // Grow panel_states if this panel_id has not been seen before.
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

    fn handleOutMsg(self: *Self, p: *LoadedPlugin, tag: pi.Tag, payload: []const u8) void {
        switch (tag) {
            .register_panel => {
                var pp: usize = 0;
                const id = readStr(payload, &pp) orelse return;
                const title = readStr(payload, &pp) orelse return;
                const vim_cmd = readStr(payload, &pp) orelse return;
                if (pp + 2 > payload.len) return;
                const layout_byte = payload[pp];
                pp += 1;
                const keybind = payload[pp];
                const layout: st.PluginPanelLayout = switch (layout_byte) {
                    1 => .left_sidebar,
                    2 => .right_sidebar,
                    3 => .bottom_bar,
                    else => .overlay,
                };
                _ = self.app.registerPluginPanelEx(id, title, vim_cmd, layout, keybind, 0);
            },
            .set_status => {
                var pp: usize = 0;
                const msg = readStr(payload, &pp) orelse return;
                self.app.setStatus(msg);
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
                const id = readStr(payload, &pp) orelse return;
                const display_name = readStr(payload, &pp) orelse return;
                const description = readStr(payload, &pp) orelse return;
                _ = self.app.registerPluginCommand(id, display_name, description);
            },
            .set_config => {
                // payload = str(plugin_id) + str(key) + str(val)
                var pp: usize = 0;
                _ = readStr(payload, &pp) orelse return; // plugin_id (unused here)
                const key = readStr(payload, &pp) orelse return;
                const val = readStr(payload, &pp) orelse return;
                if (std.mem.eql(u8, key, "active_theme")) {
                    theme_config.applyJson(val);
                }
            },
            .file_read_request => {
                var pp: usize = 0;
                const path = readStr(payload, &pp) orelse return;
                // Always queue a response, even empty, so the plugin isn't left waiting.
                const data = Vfs.readAlloc(self.alloc, path) catch {
                    queueFileResponse(self.alloc, p, path, &.{});
                    return;
                };
                const dup_path = self.alloc.dupe(u8, path) catch {
                    self.alloc.free(data);
                    return;
                };
                p.pending_responses.append(self.alloc, .{ .path = dup_path, .data = data }) catch {
                    self.alloc.free(dup_path);
                    self.alloc.free(data);
                };
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
            .request_refresh => {
                // Zero-payload message. Writer.requestRefresh() sends tag + 0-length payload.
                // Set the flag that main.zig checks each frame.
                self.app.plugin_refresh_requested = true;
            },
            .register_keybind => {
                // Payload: u8(key) + u8(mods) + str(cmd_tag)
                if (payload.len < 2) return;
                const key = payload[0];
                const mods = payload[1];
                var pp: usize = 2;
                const cmd_tag = readStr(payload, &pp) orelse return;
                self.app.gui.plugin_keybinds.append(self.alloc, .{
                    .key = key,
                    .mods = mods,
                    .cmd_tag = cmd_tag,
                }) catch {};
            },
            .push_command => {
                // Payload: str(cmd_tag) + str(cmd_payload)
                var pp: usize = 0;
                const cmd_tag = readStr(payload, &pp) orelse return;
                const cmd_payload = readStr(payload, &pp);
                if (!isCommandAllowed(cmd_tag)) {
                    self.app.log.err("PLUGIN", "push_command: blocked '{s}'", .{cmd_tag});
                    return;
                }
                self.app.queue.push(self.alloc, .{
                    .immediate = .{ .plugin_command = .{ .tag = cmd_tag, .payload = cmd_payload } },
                }) catch {};
            },
            else => {},
        }
    }

    fn scanAndLoad(self: *Self) void {
        const home = pi.platform.getEnvVar(self.alloc, "HOME") catch return;
        defer self.alloc.free(home);

        var cfg_buf: [4096]u8 = undefined;
        const cfg_dir = std.fmt.bufPrint(
            &cfg_buf,
            "{s}/.config/Schemify",
            .{home},
        ) catch return;

        const listing = Vfs.listDir(self.alloc, cfg_dir) catch return;
        defer listing.deinit(self.alloc);

        for (listing.entries) |entry_name| {
            var plugin_buf: [4096]u8 = undefined;
            const plugin_dir = std.fmt.bufPrint(
                &plugin_buf,
                "{s}/{s}",
                .{ cfg_dir, entry_name },
            ) catch continue;

            self.loadSoFromDir(plugin_dir);

            var lib_buf: [4096]u8 = undefined;
            const lib_dir = std.fmt.bufPrint(
                &lib_buf,
                "{s}/lib",
                .{plugin_dir},
            ) catch continue;
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
            const so_path = std.fmt.bufPrint(
                &so_buf,
                "{s}/{s}",
                .{ dir_path, file_name },
            ) catch continue;
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
            self.app.log.err("PLUGIN", "{s}: ABI {d} != {d}", .{
                so_path, desc.abi_version, pi.ABI_VERSION,
            });
            lib.close();
            return;
        }

        // Build load message: [tag][u16 payload_sz][u16 dir_len][dir_bytes]
        const dir = self.app.project_dir;
        const dir_len: u16 = @intCast(@min(dir.len, std.math.maxInt(u16)));
        var load_buf: [pi.HEADER_SZ + pi.U16_SZ + 4096]u8 = undefined;
        load_buf[0] = @intFromEnum(pi.Tag.load);
        std.mem.writeInt(u16, load_buf[1..3], pi.U16_SZ + dir_len, .little);
        std.mem.writeInt(u16, load_buf[3..5], dir_len, .little);
        @memcpy(load_buf[5 .. 5 + dir_len], dir[0..dir_len]);
        const load_msg = load_buf[0 .. pi.HEADER_SZ + pi.U16_SZ + @as(usize, dir_len)];

        var p: LoadedPlugin = .{ .lib = lib, .desc = desc, .buf = &.{}, .pending_responses = .{} };

        if (callPluginProcess(&p, load_msg, self.alloc)) |out| {
            defer self.alloc.free(out);
            parseOutMsgs(out, self, &p);
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
            freePendingResponses(self.alloc, &p.pending_responses);
            if (p.buf.len > 0) self.alloc.free(p.buf);
            p.lib.close();
        }
        self.plugins.clearRetainingCapacity();
        self.app.clearPluginCommands();
    }
};

// -- Helpers ------------------------------------------------------------------

/// Returned by getPanelWidgetList when panel_id >= panel_states capacity.
/// Never written to; callers receive *const so the guard is enforced by type.
const empty_widget_list: std.MultiArrayList(Runtime.ParsedWidget) = .{};

// -- Module-level private helpers ---------------------------------------------

/// Iterate output message frames, calling cb(tag, payload, ctx) for each.
/// Skips frames with unknown tags or truncated payloads.
fn iterOutMsgs(
    out: []const u8,
    comptime cb: anytype,
    ctx: anytype,
) void {
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

/// Parse a full output batch and dispatch each message to handleOutMsg.
fn parseOutMsgs(out: []const u8, rt: *Runtime, p: *LoadedPlugin) void {
    iterOutMsgs(out, struct {
        fn cb(tag: pi.Tag, payload: []const u8, ctx: anytype) void {
            ctx.rt.handleOutMsg(ctx.p, tag, payload);
        }
    }.cb, .{ .rt = rt, .p = p });
}

/// Call plugin process() with a single-retry-on-overflow output buffer strategy.
/// Returns the output slice (caller must free with alloc).
/// Reuses / grows plugin.buf so the allocation is amortised across calls.
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

    // Overflow: double once, up to MAX_OUT_BUF.
    const new_cap = @min(p.buf.len * 2, MAX_OUT_BUF);
    if (new_cap == p.buf.len) return error.PluginOutputTooLarge;
    p.buf = try alloc.realloc(p.buf, new_cap);

    const n2 = p.desc.process(in.ptr, in.len, p.buf.ptr, p.buf.len);
    if (n2 == std.math.maxInt(usize)) return error.PluginOutputTooLarge;
    return try alloc.dupe(u8, p.buf[0..n2]);
}

/// Read a [u16 len][N bytes] string from a payload slice; advances *pos.
fn readStr(payload: []const u8, pos: *usize) ?[]const u8 {
    if (pos.* + 2 > payload.len) return null;
    const len = std.mem.readInt(u16, payload[pos.*..][0..2], .little);
    pos.* += 2;
    if (pos.* + len > payload.len) return null;
    const s = payload[pos.* .. pos.* + len];
    pos.* += len;
    return s;
}

/// Free all entries in a PendingFileResponse list and clear it.
fn freePendingResponses(alloc: std.mem.Allocator, list: *std.ArrayListUnmanaged(PendingFileResponse)) void {
    for (list.items) |r| {
        alloc.free(r.path);
        if (r.data.len > 0) alloc.free(r.data);
    }
    list.clearRetainingCapacity();
}

/// Queue a file response (possibly empty on read failure) so the plugin
/// isn't left waiting for a reply that never arrives.
fn queueFileResponse(
    alloc: std.mem.Allocator,
    p: *LoadedPlugin,
    path: []const u8,
    data: []const u8,
) void {
    const dup_path = alloc.dupe(u8, path) catch return;
    p.pending_responses.append(alloc, .{ .path = dup_path, .data = @constCast(data) }) catch {
        alloc.free(dup_path);
    };
}

/// Parse a single UI widget tag+payload into a flat ParsedWidget.
/// Returns null for unrecognised tags or malformed payloads.
fn parseWidget(arena: std.mem.Allocator, tag: pi.Tag, payload: []const u8) ?Runtime.ParsedWidget {
    var p: usize = 0;
    switch (tag) {
        .ui_label => {
            const text = readStr(payload, &p) orelse return null;
            if (p + 4 > payload.len) return null;
            const id = std.mem.readInt(u32, payload[p..][0..4], .little);
            return .{ .tag = .label, .widget_id = id, .str = arena.dupe(u8, text) catch return null };
        },
        .ui_button => {
            const text = readStr(payload, &p) orelse return null;
            if (p + 4 > payload.len) return null;
            const id = std.mem.readInt(u32, payload[p..][0..4], .little);
            return .{ .tag = .button, .widget_id = id, .str = arena.dupe(u8, text) catch return null };
        },
        // Id-only widgets share the same decode path.
        .ui_separator, .ui_begin_row, .ui_end_row, .ui_collapsible_end => {
            if (payload.len < 4) return null;
            const id = std.mem.readInt(u32, payload[0..4], .little);
            const wt: Runtime.WidgetTag = switch (tag) {
                .ui_separator => .separator,
                .ui_begin_row => .begin_row,
                .ui_end_row => .end_row,
                .ui_collapsible_end => .collapsible_end,
                else => unreachable,
            };
            return .{ .tag = wt, .widget_id = id };
        },
        .ui_slider => {
            if (payload.len < 16) return null;
            const val = @as(f32, @bitCast(std.mem.readInt(u32, payload[0..4], .little)));
            const mn = @as(f32, @bitCast(std.mem.readInt(u32, payload[4..8], .little)));
            const mx = @as(f32, @bitCast(std.mem.readInt(u32, payload[8..12], .little)));
            const id = std.mem.readInt(u32, payload[12..16], .little);
            return .{ .tag = .slider, .widget_id = id, .val = val, .min = mn, .max = mx };
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
            const frac = @as(f32, @bitCast(std.mem.readInt(u32, payload[0..4], .little)));
            const id = std.mem.readInt(u32, payload[4..8], .little);
            return .{ .tag = .progress, .widget_id = id, .val = frac };
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

/// Comptime whitelist of command tags that plugins are allowed to push (D-08).
/// View commands are safe (read-only UI state). Selection commands are safe
/// (operate on current state). Plugin management is safe.
const allowed_plugin_commands = [_][]const u8{
    "zoom_in",                "zoom_out",          "zoom_fit",        "zoom_reset",
    "toggle_colorscheme",     "toggle_fill_rects",
    "toggle_text_in_symbols", "toggle_symbol_details",
    "toggle_crosshair",       "toggle_show_netlist",
    "snap_halve",             "snap_double",
    "select_all",             "select_none",
    "plugins_refresh",
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
