//! Plugin runtime — drives the load / tick / unload lifecycle.
//!
//! ┌─ Native (Linux/macOS/Windows) ─────────────────────────────────────────┐
//! │  Scans ~/.config/Schemify/<name>/                                       │
//! │    <name>.so  |  lib<name>.so       ← top-level (direct install)       │
//! │    lib/<name>.so | lib/lib<name>.so ← zig-build default prefix         │
//! │  Calls dlopen() → looks up `schemify_plugin` → ABI-checks → lifecycle  │
//! └────────────────────────────────────────────────────────────────────────┘
//!
//! ┌─ Web (wasm32) ──────────────────────────────────────────────────────────┐
//! │  WASM plugins are loaded entirely by plugin_host.js in the browser.    │
//! │  The Zig runtime is a no-op stub on this target.                       │
//! │  See src/plugins/wasm_plugin.zig for the WASM-side plugin helper.      │
//! └────────────────────────────────────────────────────────────────────────┘

const std     = @import("std");
const builtin = @import("builtin");
const pi      = @import("PluginIF");
const st      = @import("../state.zig");
const core    = @import("core");

const is_wasm = builtin.cpu.arch == .wasm32 or builtin.cpu.arch == .wasm64;

// ── VTable implementations (native only) ─────────────────────────────────── //

const vtable_instance: pi.VTable = if (is_wasm) undefined else blk: {
    break :blk .{
        .version               = pi.ABI_VERSION,
        .set_status            = &vtSetStatus,
        .log                   = &vtLog,
        .register_panel        = &vtRegisterPanel,
        .host_alloc            = &vtHostAlloc,
        .host_realloc          = &vtHostRealloc,
        .host_free             = &vtHostFree,
        .project_dir           = &vtProjectDir,
        .active_schematic_name = &vtActiveSchematicName,
        .request_refresh       = &vtRequestRefresh,
        .get_pdk_registry      = &vtGetPdkRegistry,
    };
};

fn rt(state: *anyopaque) *Runtime {
    return @ptrCast(@alignCast(state));
}

fn vtSetStatus(state: *anyopaque, msg: [*:0]const u8) callconv(.c) void {
    rt(state).app.setStatus(std.mem.span(msg));
}

fn vtLog(state: *anyopaque, level: u8, tag: [*:0]const u8, msg: [*:0]const u8) callconv(.c) void {
    const r  = rt(state);
    const lv = std.math.clamp(level, 0, 2);
    const t  = std.mem.span(tag);
    const m  = std.mem.span(msg);
    switch (@as(pi.LogLevel, @enumFromInt(lv))) {
        .info => r.app.log.info(t, "{s}", .{m}),
        .warn => r.app.log.warn(t, "{s}", .{m}),
        .err  => r.app.log.err( t, "{s}", .{m}),
    }
}

fn vtRegisterPanel(state: *anyopaque, def: *const pi.PanelDef) callconv(.c) bool {
    const r = rt(state);
    const layout: st.PluginPanelLayout = switch (def.layout) {
        .overlay       => .overlay,
        .left_sidebar  => .left_sidebar,
        .right_sidebar => .right_sidebar,
        .bottom_bar    => .bottom_bar,
    };
    const draw: ?st.PanelDrawFn = if (def.draw_fn) |f| @ptrCast(f) else null;
    return r.app.registerPluginPanelEx(
        std.mem.span(def.id),
        std.mem.span(def.title),
        std.mem.span(def.vim_cmd),
        layout,
        if (def.keybind != 0) def.keybind else null,
        draw,
    );
}

fn safeAlignment(bytes: usize) std.mem.Alignment {
    if (bytes == 0 or !std.math.isPowerOfTwo(bytes)) return .@"8";
    return std.mem.Alignment.fromByteUnits(bytes);
}

fn vtHostAlloc(state: *anyopaque, size: usize, alignment: usize) callconv(.c) ?[*]u8 {
    if (size == 0) return null;
    return rt(state).app.allocator().rawAlloc(size, safeAlignment(alignment), @returnAddress());
}

fn vtHostRealloc(state: *anyopaque, ptr: [*]u8, old_size: usize, alignment: usize, new_size: usize) callconv(.c) ?[*]u8 {
    const a  = rt(state).app.allocator();
    const al = safeAlignment(alignment);
    if (new_size == 0) { a.rawFree(ptr[0..old_size], al, @returnAddress()); return null; }
    if (old_size == 0) return a.rawAlloc(new_size, al, @returnAddress());
    return a.rawRemap(ptr[0..old_size], al, new_size, @returnAddress());
}

fn vtHostFree(state: *anyopaque, ptr: [*]u8, size: usize, alignment: usize) callconv(.c) void {
    rt(state).app.allocator().rawFree(ptr[0..size], safeAlignment(alignment), @returnAddress());
}

fn vtProjectDir(state: *anyopaque) callconv(.c) [*:0]const u8 {
    return @as([*:0]const u8, @ptrCast(rt(state).app.project_dir.ptr));
}

fn vtActiveSchematicName(state: *anyopaque) callconv(.c) ?[*:0]const u8 {
    const r    = rt(state);
    const fio  = r.app.active() orelse return null;
    const name = fio.comp.name;
    const n    = @min(name.len, r.scratch.len - 1);
    @memcpy(r.scratch[0..n], name[0..n]);
    r.scratch[n] = 0;
    return @as([*:0]const u8, @ptrCast(&r.scratch));
}

fn vtRequestRefresh(state: *anyopaque) callconv(.c) void {
    rt(state).app.plugin_refresh_requested = true;
}

fn vtGetPdkRegistry(_: *anyopaque) callconv(.c) ?*anyopaque {
    return @ptrCast(core.pdk_registry);
}

// ── LoadedPlugin ──────────────────────────────────────────────────────────── //

const LoadedPlugin = struct {
    lib:  std.DynLib,
    desc: *const pi.PluginDescriptor,
    ctx:  pi.Ctx,
};

// ── Runtime ───────────────────────────────────────────────────────────────── //

pub const Runtime = struct {
    alloc:   std.mem.Allocator,
    app:     *st.AppState,
    plugins: std.ArrayListUnmanaged(LoadedPlugin),
    scratch: [256]u8,

    pub fn init(alloc: std.mem.Allocator) Runtime {
        return .{
            .alloc   = alloc,
            .app     = undefined,
            .plugins = .{},
            .scratch = [_]u8{0} ** 256,
        };
    }

    pub fn loadStartup(self: *Runtime, app: *st.AppState) void {
        if (is_wasm) return; // browser loads WASM plugins via plugin_host.js
        self.app = app;
        self.scanAndLoad();
    }

    pub fn tick(self: *Runtime, app: *st.AppState, dt: f32) void {
        if (is_wasm) return;
        self.app = app;
        for (self.plugins.items) |*p| {
            if (p.desc.on_tick) |f| {
                p.desc.set_ctx(&p.ctx);
                f(dt);
                p.desc.set_ctx(null);
            }
        }
    }

    pub fn refresh(self: *Runtime, app: *st.AppState) void {
        if (is_wasm) return;
        self.app = app;
        self.unloadAll();
        self.scanAndLoad();
    }

    pub fn deinit(self: *Runtime, app: *st.AppState) void {
        if (is_wasm) return;
        self.app = app;
        self.unloadAll();
        self.plugins.deinit(self.alloc);
    }

    // ── Internal ──────────────────────────────────────────────────────────── //

    fn makeCtx(self: *Runtime) pi.Ctx {
        return .{ ._vtable = &vtable_instance, ._state = @ptrCast(self) };
    }

    /// Scan ~/.config/Schemify/<name>/ for .so files.
    /// Checks both the top level and the lib/ subdirectory so that both
    /// direct-drop installs and `zig build -p ~/.config/Schemify/<name>` work.
    fn scanAndLoad(self: *Runtime) void {
        const home = std.posix.getenv("HOME") orelse return;

        var cfg_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cfg_dir = std.fmt.bufPrint(
            &cfg_buf, "{s}/.config/Schemify", .{home},
        ) catch return;

        var root = std.fs.openDirAbsolute(cfg_dir, .{ .iterate = true }) catch return;
        defer root.close();

        var it = root.iterate();
        while (it.next() catch null) |entry| {
            if (entry.kind != .directory) continue;

            var plugin_buf: [std.fs.max_path_bytes]u8 = undefined;
            const plugin_dir = std.fmt.bufPrint(
                &plugin_buf, "{s}/{s}", .{ cfg_dir, entry.name },
            ) catch continue;

            // Check <plugin-dir>/ and <plugin-dir>/lib/ (zig build default)
            self.loadSoFromDir(plugin_dir);
            var lib_buf: [std.fs.max_path_bytes]u8 = undefined;
            const lib_dir = std.fmt.bufPrint(
                &lib_buf, "{s}/lib", .{plugin_dir},
            ) catch continue;
            self.loadSoFromDir(lib_dir);
        }
    }

    fn loadSoFromDir(self: *Runtime, dir_path: []const u8) void {
        var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return;
        defer dir.close();

        var it = dir.iterate();
        while (it.next() catch null) |file| {
            if (file.kind != .file and file.kind != .sym_link) continue;
            if (!std.mem.endsWith(u8, file.name, ".so")) continue;

            var so_buf: [std.fs.max_path_bytes]u8 = undefined;
            const so_path = std.fmt.bufPrint(
                &so_buf, "{s}/{s}", .{ dir_path, file.name },
            ) catch continue;
            self.loadOne(so_path);
        }
    }

    fn loadOne(self: *Runtime, so_path: []const u8) void {
        var lib = std.DynLib.open(so_path) catch |err| {
            self.app.log.err("PLUGIN", "dlopen({s}): {}", .{ so_path, err });
            return;
        };

        const desc = lib.lookup(*const pi.PluginDescriptor, "schemify_plugin") orelse {
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

        var ctx = self.makeCtx();
        desc.set_ctx(&ctx);
        desc.on_load();
        desc.set_ctx(null);

        self.plugins.append(self.alloc, .{ .lib = lib, .desc = desc, .ctx = ctx }) catch |err| {
            self.app.log.err("PLUGIN", "OOM {s}: {}", .{ so_path, err });
            desc.set_ctx(&ctx);
            desc.on_unload();
            desc.set_ctx(null);
            lib.close();
            return;
        };

        self.app.log.info("PLUGIN", "loaded {s} v{s}", .{
            std.mem.span(desc.name), std.mem.span(desc.version_str),
        });
    }

    fn unloadAll(self: *Runtime) void {
        for (self.plugins.items) |*p| {
            p.desc.set_ctx(&p.ctx);
            p.desc.on_unload();
            p.desc.set_ctx(null);
            // Log before close() — desc.name points into the .so's memory which
            // dlclose() unmaps.  Reading it after would be a use-after-free.
            self.app.log.info("PLUGIN", "unloaded {s}", .{std.mem.span(p.desc.name)});
            p.lib.close();
        }
        self.plugins.clearRetainingCapacity();
    }
};
