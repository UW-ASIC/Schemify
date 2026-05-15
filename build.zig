const std = @import("std");

// ── Types ─────────────────────────────────────────────────────────────────────

pub const Backend = enum { native, web };

// ── Module graph ──────────────────────────────────────────────────────────────
// Two-pass creation: first create all modules, then wire imports.
// This allows commands ↔ state to share types without ordering issues.
//
// Module layout lives in modules/ (bounded contexts with CONTEXT.md each).
const Def = struct { []const u8, []const u8, []const []const u8 };
const module_defs = [_]Def{
    .{ "utility", "modules/utility/lib.zig", &.{} },
    .{ "settings", "modules/settings/lib.zig", &.{} },
    .{ "schematic", "modules/schematic/lib.zig", &.{ "utility", "dvui", "simulation" } },
    .{ "simulation", "modules/simulation/lib.zig", &.{"schematic"} },
    .{ "plugins", "modules/plugins/lib.zig", &.{ "dvui", "utility" } },
    .{ "commands", "modules/commands/lib.zig", &.{ "utility", "dvui", "schematic", "simulation" } },
    .{ "state", "modules/gui/state.zig", &.{ "dvui", "schematic", "utility", "commands", "plugins", "settings", "simulation" } },
    .{ "theme_config", "modules/gui/theme.zig", &.{"dvui"} },
    .{ "import", "modules/import/lib.zig", &.{"schematic"} },
    .{ "agent", "modules/agent/lib.zig", &.{ "schematic", "simulation" } },
    .{ "gui", "modules/gui/lib.zig", &.{ "dvui", "state", "commands", "plugins", "theme_config", "schematic", "utility", "import", "settings", "simulation" } },
    .{ "cli", "modules/cli.zig", &.{ "schematic", "utility", "state", "dvui", "commands" } },
};

// ── Test suites ───────────────────────────────────────────────────────────────
// Run individually: zig build test_<name>  |  Run all: zig build test
const test_defs = [_]Def{
    .{ "utility", "modules/utility/lib.zig", &.{} },
    .{ "optimizer", "modules/simulation/optimizer/lib.zig", &.{} },
    .{ "agent", "modules/schematic/lib.zig", &.{ "utility", "dvui" } },
    .{ "marketplace", "test/marketplace/test_marketplace.zig", &.{"utility"} },
    .{ "spice", "modules/import/lib.zig", &.{"schematic"} },
};

// ── web-specific ───────────────────────────────────────────────────────────────
const wasm32 = std.Target.Query{ .cpu_arch = .wasm32, .os_tag = .freestanding };

// ── build() ───────────────────────────────────────────────────────────────────

pub fn build(b: *std.Build) void {
    const backend = b.option(Backend, "backend", "native (raylib) or web (WASM)") orelse .native;
    const is_web = backend == .web;
    const target = if (is_web) b.resolveTargetQuery(wasm32) else b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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
    for (&module_defs) |def| {
        const mod = b.addModule(def[0], .{ .root_source_file = b.path(def[1]), .target = target, .optimize = optimize });
        mods.put(def[0], mod) catch @panic("OOM");
    }
    for (&module_defs) |def| {
        addImports(mods.get(def[0]).?, &mods, def[2]);
    }

    // ── Executable ────────────────────────────────────────────────────────────
    const exe_mod = b.createModule(.{ .root_source_file = b.path("modules/main.zig"), .target = target, .optimize = optimize });
    exe_mod.addOptions("build_options", build_opts);
    addImports(exe_mod, &mods, &.{ "dvui", "utility", "schematic", "plugins", "commands", "state", "gui", "cli", "theme_config", "import", "settings", "simulation", "agent" });

    const exe = b.addExecutable(.{ .name = "schemify", .root_module = exe_mod });
    exe.root_module.strip = optimize != .Debug;
    if (!is_web) exe.use_lld = false;
    if (is_web) exe.entry = .disabled;
    b.installArtifact(exe);

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
        b.step("run", "Run Schemify GUI (-- --cli for CLI)").dependOn(&run.step);

        const test_step = b.step("test", "Run all tests");
        for (&test_defs) |def| {
            const tmod = b.createModule(.{ .root_source_file = b.path(def[1]), .target = target, .optimize = .ReleaseFast });
            addImports(tmod, &mods, def[2]);
            const test_exe = b.addTest(.{
                .root_module = tmod,
                .test_runner = .{ .path = b.path("test/test_runner.zig"), .mode = .simple },
            });
            const test_run = b.addRunArtifact(test_exe);
            test_run.setCwd(b.path("."));
            test_step.dependOn(&test_run.step);
            const step_name = b.fmt("test_{s}", .{def[0]});
            b.step(step_name, b.fmt("Run {s} tests", .{def[0]})).dependOn(&test_run.step);
            const step_name_hyphen = b.fmt("test-{s}", .{def[0]});
            b.step(step_name_hyphen, b.fmt("Run {s} tests (alias)", .{def[0]})).dependOn(&test_run.step);
        }
    }

    // ── Web: install assets + run_local dev server ────────────────────────────
    if (is_web) {
        const install = b.getInstallStep();
        install.dependOn(&b.addInstallFileWithDir(dvui_dep.path("src/backends/web.js"), .bin, "web.js").step);
        for ([_][]const u8{ "index.html", "boot.js", "vfs.js", "vfs-worker.js" }) |name| {
            install.dependOn(&b.addInstallFileWithDir(b.path(b.fmt("web/{s}", .{name})), .bin, name).step);
        }
        install.dependOn(&b.addInstallFileWithDir(b.path("src/web/schemify_host.js"), .bin, "schemify_host.js").step);

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
