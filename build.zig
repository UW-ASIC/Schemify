const std = @import("std");
const build_dep = @import("tools/build_dep.zig");

/// Plugin SDK build helper — re-exported so external plugin repos can do:
///
///   const sdk    = @import("schemify_sdk");   // imports this build.zig
///   const helper = sdk.build_plugin_helper;
///   const ctx    = helper.setup(b, b.dependency("schemify_sdk", .{}));
pub const build_plugin_helper = @import("tools/sdk/build_plugin_helper.zig");

// ── Types ─────────────────────────────────────────────────────────────────────

pub const Backend = enum { native, web };

/// { name, source-path, dependency-names }
const Def = struct { []const u8, []const u8, []const []const u8 };

// ── Module graph ──────────────────────────────────────────────────────────────
//
// Order matters: each module may only depend on modules listed before it,
// or on "dvui" / the spice modules injected by addSpiceMods().

const module_defs = [_]Def{
    .{ "core", "src/core/FileIO.zig", &.{} },

    .{ "PluginIF", "src/PluginIF.zig", &.{ "core", "dvui" } },
};

// ── Test suites ───────────────────────────────────────────────────────────────
//
// All tests import "core" so types shared with FileIO are identical instances.
// Run individually: zig build test_<name>  |  Run all: zig build test

const test_defs = [_]Def{
    .{ "core", "test/core/test_core.zig", &.{"core"} },
};

// ── WASM target ───────────────────────────────────────────────────────────────

const wasm32 = std.Target.Query{ .cpu_arch = .wasm32, .os_tag = .freestanding };

// ── Web index.html ────────────────────────────────────────────────────────────

const web_index_html =
    \\<!doctype html>
    \\<html lang="en" style="height:100%;">
    \\  <head>
    \\    <meta charset="utf-8"/>
    \\    <meta name="viewport" content="width=device-width,initial-scale=1.0"/>
    \\    <title>N1Schem</title>
    \\  </head>
    \\  <body style="height:100%;margin:0;padding:0;">
    \\    <canvas id="dvui-canvas" tabIndex="1"
    \\      style="display:block;width:100%;height:100%;outline:none;caret-color:transparent;">
    \\    </canvas>
    \\    <script src="./plugin_host.js"></script>
    \\    <script type="module">
    \\      import { dvui } from "./web.js";
    \\      dvui("#dvui-canvas", "n1schem.wasm");
    \\    </script>
    \\  </body>
    \\</html>
;

const web_plugins_manifest_json =
    \\{
    \\  "plugins": []
    \\}
;

const web_plugin_host_js =
    \\// plugin_host.js — Schemify WASM plugin host.
    \\//
    \\// Loaded by index.html before the main Schemify WASM module.
    \\// Reads plugins/plugins.json, instantiates each listed .wasm file,
    \\// and forwards lifecycle calls (on_load / on_unload / on_tick).
    \\//
    \\// Each plugin .wasm must export:
    \\//   on_load()         — called once after instantiation
    \\//   on_unload()       — called on refresh / page unload
    \\//   on_tick(dt: f32)  — called every animation frame (optional)
    \\//   memory            — shared linear memory (for string passing)
    \\//
    \\// And may import from the "host" namespace (all provided below):
    \\//   set_status(ptr, len)
    \\//   log(level, tag_ptr, tag_len, msg_ptr, msg_len)
    \\//   register_panel(id_ptr, id_len, title_ptr, title_len,
    \\//                  vim_ptr, vim_len, layout, keybind) → i32
    \\//   project_dir_len() → i32
    \\//   project_dir_copy(dest_ptr)
    \\//   active_schematic_len() → i32
    \\//   active_schematic_copy(dest_ptr)
    \\//   request_refresh()
    \\
    \\(() => {
    \\  // ── Shared app state (set by dvui/main WASM on init) ──────────────── //
    \\  //
    \\  // schemifyPluginHost.setAppState({ statusFn, registerPanelFn, ... })
    \\  // is called by the main Schemify WASM glue once the app is ready.
    \\
    \\  let _app = {
    \\    statusFn:        (msg) => console.info("[plugin] status:", msg),
    \\    registerPanelFn: (id, title, vim, layout, keybind) => {
    \\      console.debug("[plugin] register_panel", { id, title, vim, layout, keybind });
    \\      return 1;
    \\    },
    \\    projectDir:            ".",
    \\    activeSchematicName:   null,
    \\    requestRefreshFn:      () => {},
    \\  };
    \\
    \\  // ── Utilities ─────────────────────────────────────────────────────── //
    \\
    \\  function readStr(mem, ptr, len) {
    \\    return new TextDecoder().decode(new Uint8Array(mem.buffer, ptr, len));
    \\  }
    \\
    \\  function writeStr(mem, dest, str) {
    \\    const enc = new TextEncoder().encode(str);
    \\    new Uint8Array(mem.buffer, dest, enc.length).set(enc);
    \\  }
    \\
    \\  const LOG_LABELS = ["INFO", "WARN", "ERR"];
    \\  const ENC = new TextEncoder();
    \\
    \\  // ── In-memory VFS ─────────────────────────────────────────────────────── //
    \\  //
    \\  // Simple Map-backed virtual filesystem shared across all plugins.
    \\  // schemifyPluginHost.vfs exposes it so the host page can seed files
    \\  // (e.g. from IndexedDB / OPFS) before boot().
    \\  //
    \\  //   schemifyPluginHost.vfs.write("my-plugin/config.toml", new Uint8Array(...));
    \\  //   const data = schemifyPluginHost.vfs.read("my-plugin/config.toml");
    \\
    \\  const _vfs = {
    \\    _store: new Map(),       // path → Uint8Array
    \\    _dirs:  new Set([""]),   // tracked directory paths
    \\
    \\    read(path) { return this._store.get(path) ?? null; },
    \\
    \\    write(path, data) {
    \\      const bytes = data instanceof Uint8Array ? data : ENC.encode(data);
    \\      this._store.set(path, bytes);
    \\      // ensure parent directories are registered
    \\      let p = path;
    \\      while (p.includes("/")) {
    \\        p = p.substring(0, p.lastIndexOf("/"));
    \\        this._dirs.add(p);
    \\      }
    \\    },
    \\
    \\    mkdir(path) { this._dirs.add(path); },
    \\
    \\    del(path) { this._store.delete(path); },
    \\
    \\    list(dirPath) {
    \\      const prefix = dirPath === "" ? "" : dirPath + "/";
    \\      const entries = [];
    \\      for (const k of this._store.keys()) {
    \\        if (k.startsWith(prefix)) {
    \\          const rest = k.slice(prefix.length);
    \\          if (!rest.includes("/")) entries.push(rest);
    \\        }
    \\      }
    \\      for (const d of this._dirs) {
    \\        if (d !== dirPath && d.startsWith(prefix)) {
    \\          const rest = d.slice(prefix.length);
    \\          if (!rest.includes("/")) entries.push(rest + "/");
    \\        }
    \\      }
    \\      return entries;
    \\    },
    \\  };
    \\
    \\  // ── Host import object (passed to every plugin .wasm) ──────────────── //
    \\
    \\  function makeHost(memRef) {
    \\    const m = () => memRef();
    \\    return {
    \\      // ── Status / logging ────────────────────────────────────────────── //
    \\      set_status(ptr, len) {
    \\        _app.statusFn(readStr(m(), ptr, len));
    \\      },
    \\      log_msg(level, tagPtr, tagLen, msgPtr, msgLen) {
    \\        const lbl = LOG_LABELS[level] ?? "LOG";
    \\        const tag = readStr(m(), tagPtr, tagLen);
    \\        const msg = readStr(m(), msgPtr, msgLen);
    \\        console.info(`[plugin][${lbl}] ${tag}: ${msg}`);
    \\      },
    \\      // ── Panel registration ───────────────────────────────────────────── //
    \\      register_panel(idPtr, idLen, titlePtr, titleLen,
    \\                     vimPtr, vimLen, layout, keybind, _drawFnIdx) {
    \\        const id    = readStr(m(), idPtr, idLen);
    \\        const title = readStr(m(), titlePtr, titleLen);
    \\        const vim   = readStr(m(), vimPtr, vimLen);
    \\        return _app.registerPanelFn(id, title, vim, layout, keybind) ? 1 : 0;
    \\      },
    \\      // ── Schematic info ───────────────────────────────────────────────── //
    \\      project_dir_len() {
    \\        return ENC.encode(_app.projectDir).length;
    \\      },
    \\      project_dir_copy(dest, destLen) {
    \\        const bytes = ENC.encode(_app.projectDir);
    \\        const n = Math.min(bytes.length, destLen);
    \\        new Uint8Array(m().buffer, dest, n).set(bytes.slice(0, n));
    \\      },
    \\      active_schematic_len() {
    \\        if (_app.activeSchematicName == null) return -1;
    \\        return ENC.encode(_app.activeSchematicName).length;
    \\      },
    \\      active_schematic_copy(dest, destLen) {
    \\        if (_app.activeSchematicName == null) return;
    \\        const bytes = ENC.encode(_app.activeSchematicName);
    \\        const n = Math.min(bytes.length, destLen);
    \\        new Uint8Array(m().buffer, dest, n).set(bytes.slice(0, n));
    \\      },
    \\      request_refresh() { _app.requestRefreshFn(); },
    \\      // ── Virtual filesystem (Vfs.zig) ─────────────────────────────────── //
    \\      //
    \\      // Two-step protocol: plugin calls *_len to learn the size, allocates a
    \\      // buffer in WASM linear memory, then calls the matching *_read/*_write.
    \\      vfs_file_len(pathPtr, pathLen) {
    \\        const path = readStr(m(), pathPtr, pathLen);
    \\        const data = _vfs.read(path);
    \\        return data ? data.length : -1;
    \\      },
    \\      vfs_file_read(pathPtr, pathLen, dest, destLen) {
    \\        const path = readStr(m(), pathPtr, pathLen);
    \\        const data = _vfs.read(path);
    \\        if (!data) return -1;
    \\        const n = Math.min(data.length, destLen);
    \\        new Uint8Array(m().buffer, dest, n).set(data.slice(0, n));
    \\        return n;
    \\      },
    \\      vfs_file_write(pathPtr, pathLen, src, srcLen) {
    \\        const path = readStr(m(), pathPtr, pathLen);
    \\        const bytes = new Uint8Array(m().buffer, src, srcLen).slice();
    \\        _vfs.write(path, bytes);
    \\        return 0;
    \\      },
    \\      vfs_file_delete(pathPtr, pathLen) {
    \\        _vfs.del(readStr(m(), pathPtr, pathLen));
    \\        return 0;
    \\      },
    \\      vfs_dir_make(pathPtr, pathLen) {
    \\        _vfs.mkdir(readStr(m(), pathPtr, pathLen));
    \\        return 0;
    \\      },
    \\      vfs_dir_list_len(pathPtr, pathLen) {
    \\        const entries = _vfs.list(readStr(m(), pathPtr, pathLen));
    \\        return entries.reduce((acc, e) => acc + ENC.encode(e).length + 1, 0);
    \\      },
    \\      vfs_dir_list_read(pathPtr, pathLen, dest, destLen) {
    \\        const entries = _vfs.list(readStr(m(), pathPtr, pathLen));
    \\        let pos = dest;
    \\        const view = new Uint8Array(m().buffer);
    \\        for (const e of entries) {
    \\          const bytes = ENC.encode(e);
    \\          if (pos + bytes.length + 1 > dest + destLen) break;
    \\          view.set(bytes, pos);
    \\          view[pos + bytes.length] = 0;
    \\          pos += bytes.length + 1;
    \\        }
    \\        return pos - dest;
    \\      },
    \\    };
    \\  }
    \\
    \\  // ── Plugin lifecycle ──────────────────────────────────────────────── //
    \\
    \\  const state = { modules: [], ready: false };
    \\
    \\  async function loadManifest(path = "plugins/plugins.json") {
    \\    try {
    \\      const res = await fetch(path, { cache: "no-store" });
    \\      if (!res.ok) return [];
    \\      const json = await res.json();
    \\      if (!json || !Array.isArray(json.plugins)) return [];
    \\      return json.plugins
    \\        .filter((x) => typeof x === "string")
    \\        .map((x) => x.startsWith("http") ? x : `plugins/${x}`);
    \\    } catch (_e) { return []; }
    \\  }
    \\
    \\  async function loadWasmPlugin(url) {
    \\    try {
    \\      let mem = null;
    \\      const host = makeHost(() => mem);
    \\      const result = await WebAssembly.instantiateStreaming(
    \\        fetch(url), { host }
    \\      );
    \\      const inst = result.instance;
    \\      mem = inst.exports.memory;
    \\      if (inst.exports.on_load) inst.exports.on_load();
    \\      state.modules.push({ url, inst, mem });
    \\      console.info("[plugin-host] loaded", url);
    \\    } catch (e) {
    \\      console.warn("[plugin-host] failed to load", url, e);
    \\    }
    \\  }
    \\
    \\  async function boot(path = "plugins/plugins.json") {
    \\    const urls = await loadManifest(path);
    \\    for (const url of urls) await loadWasmPlugin(url);
    \\    state.ready = true;
    \\  }
    \\
    \\  // ── Public API ────────────────────────────────────────────────────── //
    \\
    \\  window.schemifyPluginHost = {
    \\    boot,
    \\
    \\    refresh: async (path = "plugins/plugins.json") => {
    \\      for (const m of state.modules)
    \\        if (m.inst.exports.on_unload) m.inst.exports.on_unload();
    \\      state.modules = [];
    \\      state.ready = false;
    \\      await boot(path);
    \\    },
    \\
    \\    tick: (dt) => {
    \\      for (const m of state.modules)
    \\        if (m.inst.exports.on_tick) m.inst.exports.on_tick(dt);
    \\    },
    \\
    \\    /** Called by the main WASM glue to wire up app callbacks. */
    \\    setAppState: (appState) => { Object.assign(_app, appState); },
    \\
    \\    /**
    \\     * In-memory virtual filesystem.  Seed files before boot() so plugins
    \\     * can read them via Plugin.Vfs.readAlloc():
    \\     *
    \\     *   schemifyPluginHost.vfs.write("my-plugin/config.toml", tomlBytes);
    \\     *   schemifyPluginHost.vfs.mkdir("my-plugin/cache");
    \\     *
    \\     * Persist to IndexedDB / OPFS by syncing with this store externally.
    \\     */
    \\    vfs: _vfs,
    \\
    \\    state,
    \\  };
    \\
    \\  void boot();
    \\})();
;

// ── Helpers ───────────────────────────────────────────────────────────────────

fn addImports(
    mod: *std.Build.Module,
    mods: *const std.StringHashMap(*std.Build.Module),
    names: []const []const u8,
) void {
    for (names) |n| mod.addImport(n, mods.get(n).?);
}

/// Create and wire ngspice / xyce / spice modules; insert them into `mods`.
/// Only called for native targets — WASM cannot link libngspice/libxyce.
fn addSpiceMods(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    comptime cfg: build_dep.SpiceConfig,
    mods: *std.StringHashMap(*std.Build.Module),
) void {
    const ngspice = b.createModule(.{ .root_source_file = b.path("deps/ngspice.zig"), .target = target, .optimize = optimize });
    const xyce = b.createModule(.{ .root_source_file = b.path("deps/xyce.zig"), .target = target, .optimize = optimize });
    const spice = b.createModule(.{ .root_source_file = b.path("deps/lib.zig"), .target = target, .optimize = optimize });
    spice.addImport("ngspice", ngspice);
    spice.addImport("xyce", xyce);

    if (cfg.enable_ngspice) {
        const inc = cfg.ngspice_include_path orelse (cfg.ngspice_src ++ "/src/include");
        const lib = cfg.ngspice_lib_path orelse (cfg.ngspice_src ++ "/src/.libs");
        ngspice.addIncludePath(.{ .cwd_relative = inc });
        ngspice.addLibraryPath(.{ .cwd_relative = lib });
        ngspice.linkSystemLibrary("ngspice", .{ .preferred_link_mode = .static });
        ngspice.link_libc = true;
    }

    if (cfg.enable_xyce) {
        const inc = cfg.xyce_dir ++ "/" ++ cfg.xyce_install_subdir ++ "/include";
        const lib = cfg.xyce_dir ++ "/" ++ cfg.xyce_install_subdir ++ "/lib";
        const shim = cfg.xyce_dir ++ "/xyce_c_api.cpp";
        xyce.addCSourceFile(.{
            .file = .{ .cwd_relative = shim },
            .flags = &.{ "-std=c++17", "-fPIC", "-O2", b.fmt("-I{s}", .{inc}) },
        });
        xyce.addIncludePath(.{ .cwd_relative = cfg.xyce_dir });
        xyce.addLibraryPath(.{ .cwd_relative = lib });
        xyce.linkSystemLibrary("xyce", .{ .preferred_link_mode = .static });
        xyce.link_libcpp = true;
        xyce.link_libc = true;
    }

    mods.put("ngspice", ngspice) catch @panic("OOM");
    mods.put("xyce", xyce) catch @panic("OOM");
    mods.put("spice", spice) catch @panic("OOM");
}

/// Add simulator shared-library RPATHs to `exe` so it finds them at runtime.
fn addSpiceRPaths(exe: *std.Build.Step.Compile, comptime cfg: build_dep.SpiceConfig) void {
    if (cfg.enable_ngspice) {
        const lib = cfg.ngspice_lib_path orelse (cfg.ngspice_src ++ "/src/.libs");
        exe.addRPath(.{ .cwd_relative = lib });
    }
    if (cfg.enable_xyce) {
        exe.addRPath(.{ .cwd_relative = cfg.xyce_dir ++ "/" ++ cfg.xyce_install_subdir ++ "/lib" });
    }
}

// ── build() ───────────────────────────────────────────────────────────────────

pub fn build(b: *std.Build) void {
    const backend = b.option(Backend, "backend", "native (raylib) or web (WASM)") orelse .native;
    const is_web = backend == .web;
    const target = if (is_web) b.resolveTargetQuery(wasm32) else b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const spice = build_dep.SpiceConfig{};

    // dvui — native uses raylib, web uses wasm backend
    const dvui_dep = if (is_web)
        b.dependency("dvui", .{ .target = target, .optimize = optimize, .backend = .web })
    else b.dependency("dvui", .{
        .target = target,
        .optimize = optimize,
        .backend = .raylib,
        .linux_display_backend = .X11,
        .freetype = false,
    });
    const dvui_mod = if (is_web) dvui_dep.module("dvui_web_wasm") else dvui_dep.module("dvui_raylib");

    // Build options passed into the executable
    const build_opts = b.addOptions();
    build_opts.addOption(Backend, "backend", backend);
    build_opts.addOption(bool, "has_cli", !is_web);

    // Module graph
    var mods = std.StringHashMap(*std.Build.Module).init(b.allocator);
    mods.put("dvui", dvui_mod) catch @panic("OOM");
    if (!is_web) addSpiceMods(b, target, optimize, spice, &mods);
    for (&module_defs) |def| {
        const mod = b.addModule(def[0], .{ .root_source_file = b.path(def[1]), .target = target, .optimize = optimize });
        addImports(mod, &mods, def[2]);
        mods.put(def[0], mod) catch @panic("OOM");
    }

    // ── Executable ────────────────────────────────────────────────────────────
    const exe_mod = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize });
    exe_mod.addOptions("build_options", build_opts);
    addImports(exe_mod, &mods, &.{ "dvui", "core", "PluginIF" });

    const exe = b.addExecutable(.{ .name = "schemify", .root_module = exe_mod });
    exe.root_module.strip = optimize != .Debug;
    if (!is_web) exe.use_lld = false;
    if (is_web) exe.entry = .disabled;
    if (!is_web) addSpiceRPaths(exe, spice);
    b.installArtifact(exe);

    const size_cmd = b.addSystemCommand(&.{ "sh", "-c", "printf 'Executable size: '; du -h \"$1\" | cut -f1", "--" });
    size_cmd.addArtifactArg(exe);
    b.getInstallStep().dependOn(&size_cmd.step);

    // ── Native: run + test steps ──────────────────────────────────────────────
    if (!is_web) {
        const run = b.addRunArtifact(exe);
        run.setCwd(b.path("."));
        run.step.dependOn(b.getInstallStep());
        if (b.args) |args| run.addArgs(args);
        b.step("run", "Run N1Schem GUI (-- --cli for CLI)").dependOn(&run.step);

        const audit_mod = b.createModule(.{
            .root_source_file = b.path("tools/struct_audit.zig"),
            .target = target,
            .optimize = optimize,
        });
        addImports(audit_mod, &mods, &.{"core"});

        // -Dtest-filter=<name> narrows to a single test (Zig extension code-lens).
        const test_filters = b.option([]const []const u8, "test-filter", "Filter tests by name") orelse &[0][]const u8{};
        const test_step = b.step("test", "Run all tests");
        for (&test_defs) |def| {
            const tmod = b.createModule(.{ .root_source_file = b.path(def[1]), .target = target, .optimize = optimize });
            addImports(tmod, &mods, def[2]);
            const test_exe = b.addTest(.{
                .root_module = tmod,
                .filters = test_filters,
                .test_runner = .{ .path = b.path("test/test_runner.zig"), .mode = .simple },
            });
            const test_run = b.addRunArtifact(test_exe);
            test_run.setCwd(b.path(".")); // file paths in tests resolve from project root
            test_step.dependOn(&test_run.step);
            const step_name = b.fmt("test_{s}", .{def[0]});
            b.step(step_name, b.fmt("Run {s} tests", .{def[0]})).dependOn(&test_run.step);
            if (std.mem.eql(u8, def[0], "core")) {
                b.step("core", "Build and test core module").dependOn(&test_run.step);
            }
        }
    }

    // ── Web: install assets + run_local dev server ────────────────────────────
    if (is_web) {
        const install = b.getInstallStep();
        install.dependOn(&b.addInstallFileWithDir(dvui_dep.path("src/backends/web.js"), .bin, "web.js").step);
        const wf = b.addWriteFiles();
        install.dependOn(&b.addInstallFileWithDir(wf.add("index.html", web_index_html), .bin, "index.html").step);
        install.dependOn(&b.addInstallFileWithDir(wf.add("plugin_host.js", web_plugin_host_js), .bin, "plugin_host.js").step);
        install.dependOn(&b.addInstallFileWithDir(wf.add("plugins/plugins.json", web_plugins_manifest_json), .bin, "plugins/plugins.json").step);

        const kill = b.addSystemCommand(&.{ "sh", "-c", "fuser -k 8080/tcp 2>/dev/null; sleep 0.3; exit 0" });
        kill.step.dependOn(install);
        const serve = b.addSystemCommand(&.{ "python3", "-m", "http.server", "8080", "--directory", b.getInstallPath(.bin, "") });
        serve.step.dependOn(&kill.step);
        b.step("run_local", "Build WASM + serve at http://localhost:8080").dependOn(&serve.step);
    }
}
