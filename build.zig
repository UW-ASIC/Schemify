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

// ── Module graph ──────────────────────────────────────────────────────────────
// Two-pass creation: first create all modules, then wire imports.
// This allows commands ↔ state to share types without ordering issues.
const Def = struct { []const u8, []const u8, []const []const u8 };
const module_defs = [_]Def{
    .{ "utility", "src/utility/lib.zig", &.{} },
    .{ "core", "src/core/Schemify.zig", &.{"utility"} },
    .{ "PluginIF", "src/PluginIF.zig", &.{ "core", "utility", "dvui" } },
    .{ "commands", "src/commands/command.zig", &.{ "state", "core", "utility", "dvui" } },
    .{ "state", "src/state.zig", &.{ "utility", "commands", "PluginIF", "core" } },
    .{ "installer", "src/plugins/installer.zig", &.{"utility"} },

    .{ "theme_config", "src/gui/Theme.zig", &.{"dvui"} },
    .{ "runtime", "src/plugins/runtime.zig", &.{ "PluginIF", "state", "theme_config" } },
    .{ "cli", "src/cli.zig", &.{ "core", "installer", "utility", "state" } },
};

// ── Test suites ───────────────────────────────────────────────────────────────
// All tests import "core" so types shared with FileIO are identical instances.
// Run individually: zig build test_<name>  |  Run all: zig build test
const test_defs = [_]Def{
    .{ "core", "test/core/test_core.zig", &.{"core"} },
};

// ── web-specific ───────────────────────────────────────────────────────────────
const wasm32 = std.Target.Query{ .cpu_arch = .wasm32, .os_tag = .freestanding };

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
    else
        b.dependency("dvui", .{ .target = target, .optimize = optimize, .backend = .raylib, .linux_display_backend = .X11, .freetype = false });
    const dvui_mod = if (is_web) dvui_dep.module("dvui_web_wasm") else dvui_dep.module("dvui_raylib");

    // Executable-level build options.
    const build_opts = b.addOptions();
    build_opts.addOption(Backend, "backend", backend);
    build_opts.addOption(bool, "has_cli", !is_web);

    // Module graph — two-pass: create all modules first, then wire imports.
    var mods = std.StringHashMap(*std.Build.Module).init(b.allocator);
    mods.put("dvui", dvui_mod) catch @panic("OOM");
    if (!is_web) addSpiceMods(b, target, optimize, spice, &mods);
    for (&module_defs) |def| {
        const mod = b.addModule(def[0], .{ .root_source_file = b.path(def[1]), .target = target, .optimize = optimize });
        mods.put(def[0], mod) catch @panic("OOM");
    }
    for (&module_defs) |def| {
        addImports(mods.get(def[0]).?, &mods, def[2]);
    }

    // ── Executable ────────────────────────────────────────────────────────────
    const exe_mod = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize });
    exe_mod.addOptions("build_options", build_opts);
    addImports(exe_mod, &mods, &.{ "dvui", "utility", "core", "PluginIF", "commands", "state", "cli", "runtime", "theme_config" });

    const exe = b.addExecutable(.{ .name = "schemify", .root_module = exe_mod });
    exe.root_module.strip = optimize != .Debug;
    if (!is_web) exe.use_lld = false;
    if (is_web) exe.entry = .disabled;
    if (!is_web) addSpiceRPaths(exe, spice);
    b.installArtifact(exe);

    // ── Lint: ban direct std.fs / std.posix usage outside utility/ and cli/ ──
    const lint = b.addSystemCommand(&.{ "sh", "-c",
        \\files=$(find src -name '*.zig' \
        \\  ! -path 'src/utility/*' \
        \\  ! -path 'src/cli/*' \
        \\  ! -path 'src/cli.zig')
        \\if [ -z "$files" ]; then exit 0; fi
        \\hits=$(echo "$files" | xargs grep -n \
        \\  -e 'std\.fs\.open' \
        \\  -e 'std\.fs\.create' \
        \\  -e 'std\.fs\.delete' \
        \\  -e 'std\.fs\.access' \
        \\  -e 'std\.fs\.make' \
        \\  -e 'std\.fs\.cwd()' \
        \\  -e 'std\.posix\.getenv' \
        \\  || true)
        \\if [ -n "$hits" ]; then
        \\  printf '\n\033[1;31mBanned API usage detected.\033[0m Use Vfs / platform instead:\n%s\n' "$hits" >&2
        \\  exit 1
        \\fi
    });
    exe.step.dependOn(&lint.step);

    // Size
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

        const test_step = b.step("test", "Run all tests");
        for (&test_defs) |def| {
            const tmod = b.createModule(.{ .root_source_file = b.path(def[1]), .target = target, .optimize = .ReleaseFast });
            addImports(tmod, &mods, def[2]);
            const test_exe = b.addTest(.{
                .root_module = tmod,
                .test_runner = .{ .path = b.path("test/test_runner.zig"), .mode = .simple },
            });
            const test_run = b.addRunArtifact(test_exe);
            test_run.setCwd(b.path(".")); // file paths in tests resolve from project root
            test_step.dependOn(&test_run.step);
            const step_name = b.fmt("test_{s}", .{def[0]});
            b.step(step_name, b.fmt("Run {s} tests", .{def[0]})).dependOn(&test_run.step);
            // Hyphenated alias (e.g. test-xschem) for developer convenience
            const step_name_hyphen = b.fmt("test-{s}", .{def[0]});
            b.step(step_name_hyphen, b.fmt("Run {s} tests (alias)", .{def[0]})).dependOn(&test_run.step);
            if (std.mem.eql(u8, def[0], "core")) {
                b.step("core", "Build and test core module").dependOn(&test_run.step);
            }
        }

        // ── get_size: print @sizeOf for every struct in src/ ─────────────
        const size_step = b.step("get_size", "Print @sizeOf for every struct in src/");
        {
            var smods = std.StringHashMap(*std.Build.Module).init(b.allocator);
            smods.put("dvui", dvui_mod) catch @panic("OOM");
            addSpiceMods(b, target, optimize, build_dep.SpiceConfig{ .enable_ngspice = false, .enable_xyce = false }, &smods);
            for (&module_defs) |def| {
                const sm = b.createModule(.{ .root_source_file = b.path(def[1]), .target = target, .optimize = optimize });
                smods.put(def[0], sm) catch @panic("OOM");
            }
            for (&module_defs) |def| {
                addImports(smods.get(def[0]).?, &smods, def[2]);
            }

            var size_outputs: std.ArrayList(std.Build.LazyPath) = .{};

            var src_dir = std.fs.cwd().openDir("src", .{ .iterate = true }) catch @panic("cannot open src/");
            defer src_dir.close();
            var walker = src_dir.walk(b.allocator) catch @panic("OOM");
            defer walker.deinit();
            while (walker.next() catch null) |entry| {
                if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
                // Only compile files that actually contain a size test.
                const contents = src_dir.readFileAlloc(b.allocator, entry.path, 1 << 20) catch continue;
                if (std.mem.indexOf(u8, contents, "Expose struct size") == null) continue;
                const rel = b.fmt("src/{s}", .{entry.path});
                const m = b.createModule(.{ .root_source_file = b.path(rel), .target = target, .optimize = optimize });
                // Wire all stub modules — files only import what they use.
                var it = smods.iterator();
                while (it.next()) |kv| m.addImport(kv.key_ptr.*, kv.value_ptr.*);
                m.addOptions("build_options", build_opts);
                const t = b.addTest(.{
                    .root_module = m,
                    .filters = &[_][]const u8{"Expose struct size"},
                    .test_runner = .{ .path = b.path("test/size_runner.zig"), .mode = .simple },
                });
                const size_run = b.addRunArtifact(t);
                size_run.setEnvironmentVariable("SIZE_SOURCE_FILE", rel);
                size_outputs.append(b.allocator, size_run.captureStdOut()) catch @panic("OOM");
            }

            // Collect all per-file totals, sort highest → lowest, print.
            const sort_cmd = b.addSystemCommand(&.{ "sh", "-c", "sort -rn \"$@\" | cut -f2-", "--" });
            for (size_outputs.items) |lp| sort_cmd.addFileArg(lp);
            size_step.dependOn(&sort_cmd.step);
        }
    }

    // ── Web: install assets + run_local dev server ────────────────────────────
    if (is_web) {
        const install = b.getInstallStep();

        // dvui's web.js runtime
        install.dependOn(&b.addInstallFileWithDir(dvui_dep.path("src/backends/web.js"), .bin, "web.js").step);

        // Schemify web shell: index.html, boot.js, vfs.js, vfs-worker.js
        for ([_][]const u8{ "index.html", "boot.js", "vfs.js", "vfs-worker.js" }) |name| {
            install.dependOn(&b.addInstallFileWithDir(b.path(b.fmt("web/{s}", .{name})), .bin, name).step);
        }

        // Schemify host imports (VFS + platform)
        install.dependOn(&b.addInstallFileWithDir(b.path("src/web/schemify_host.js"), .bin, "schemify_host.js").step);

        // Bundled data files so first-run can pre-populate the OPFS VFS.
        install.dependOn(&b.addInstallFileWithDir(b.path("Config.toml"), .bin, "Config.toml").step);
        {
            var examples_dir = std.fs.cwd().openDir("examples", .{ .iterate = true }) catch @panic("cannot open examples/");
            defer examples_dir.close();
            var it = examples_dir.iterate();
            while (it.next() catch null) |entry| {
                if (entry.kind != .file) continue;
                if (std.mem.endsWith(u8, entry.name, ".chn") or
                    std.mem.endsWith(u8, entry.name, ".chn_tb") or
                    std.mem.endsWith(u8, entry.name, ".chn_prim"))
                {
                    const dest = b.fmt("examples/{s}", .{entry.name});
                    const src = b.fmt("examples/{s}", .{entry.name});
                    install.dependOn(&b.addInstallFileWithDir(b.path(src), .bin, dest).step);
                }
            }
        }

        const kill = b.addSystemCommand(&.{ "sh", "-c", "fuser -k 8080/tcp 2>/dev/null; sleep 0.3; exit 0" });
        kill.step.dependOn(install);
        const serve = b.addSystemCommand(&.{ "python3", "-m", "http.server", "8080", "--directory", b.getInstallPath(.bin, "") });
        serve.step.dependOn(&kill.step);
        b.step("run_local", "Build WASM + serve at http://localhost:8080").dependOn(&serve.step);
    }
}

// ── Helpers ───────────────────────────────────────────────────────────────

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
