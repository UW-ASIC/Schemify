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
    .{ "commands", "src/commands/lib.zig", &.{ "state", "core", "utility", "dvui" } },
    .{ "state", "src/gui/state/lib.zig", &.{ "utility", "commands", "PluginIF", "core" } },
    .{ "installer", "src/plugins/installer/lib.zig", &.{"utility"} },

    .{ "theme_config", "src/gui/Theme.zig", &.{"dvui"} },
    .{ "runtime", "src/plugins/Runtime.zig", &.{ "PluginIF", "state", "theme_config", "commands", "utility", "installer", "core" } },
    .{ "cli", "src/cli.zig", &.{ "core", "installer", "utility", "state" } },
};

// ── Test suites ───────────────────────────────────────────────────────────────
// All tests import "core" so types shared with FileIO are identical instances.
// Run individually: zig build test_<name>  |  Run all: zig build test
const test_defs = [_]Def{
    .{ "core", "test/core/test_core.zig", &.{"core"} },
    .{ "utility", "src/utility/lib.zig", &.{} },
    .{ "marketplace", "test/marketplace/test_marketplace.zig", &.{"utility"} },
};

// ── web-specific ───────────────────────────────────────────────────────────────
const wasm32 = std.Target.Query{ .cpu_arch = .wasm32, .os_tag = .freestanding };

// ── build() ───────────────────────────────────────────────────────────────────

pub fn build(b: *std.Build) void {
    const backend = b.option(Backend, "backend", "native (raylib) or web (WASM)") orelse .native;
    const is_web = backend == .web;
    const target = if (is_web) b.resolveTargetQuery(wasm32) else b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // TODO: restore when addSpice* functions are ported
    // const spice = build_dep.SpiceConfig{};

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
    // TODO: restore when addSpiceMods is ported
    // if (!is_web) addSpiceMods(b, target, optimize, spice, &mods);
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
    // TODO: restore when addSpiceRPaths is ported
    // if (!is_web) addSpiceRPaths(exe, spice);
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
