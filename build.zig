const std = @import("std");

// ── Types ─────────────────────────────────────────────────────────────────────

pub const Backend = enum { native, web };

// ── Module graph ──────────────────────────────────────────────────────────────
// Two-pass creation: first create all modules, then wire imports.
// This allows commands ↔ state to share types without ordering issues.
//
// Module layout lives in src/ (bounded contexts with CONTEXT.md each).
const Def = struct { []const u8, []const u8, []const []const u8 };
const module_defs = [_]Def{
    .{ "utility", "src/utility/lib.zig", &.{} },
    .{ "schematic", "src/schematic/lib.zig", &.{ "utility", "dvui" } },
    .{ "simulation", "src/simulation/lib.zig", &.{"schematic"} },
    .{ "plugins", "src/plugins/lib.zig", &.{ "dvui", "utility" } },
    .{ "commands", "src/commands/lib.zig", &.{ "utility", "dvui", "schematic", "simulation" } },
    .{ "state", "src/gui/state.zig", &.{ "dvui", "schematic", "utility", "commands", "plugins", "simulation" } },
    .{ "theme_config", "src/gui/theme.zig", &.{"dvui"} },
    .{ "import", "src/import/lib.zig", &.{ "schematic", "simulation", "utility" } },
    .{ "gui", "src/gui/lib.zig", &.{ "dvui", "state", "commands", "plugins", "theme_config", "schematic", "utility", "import", "simulation", "examples" } },
    .{ "cli", "src/cli.zig", &.{ "schematic", "utility", "state", "dvui", "commands", "import", "simulation" } },
};

const wasm32 = std.Target.Query{ .cpu_arch = .wasm32, .os_tag = .freestanding };

pub fn build(b: *std.Build) void {
    const backend = b.option(Backend, "backend", "native or web (WASM)") orelse .native;
    const is_web = backend == .web;

    const target = if (is_web) b.resolveTargetQuery(wasm32) else b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // dvui — native uses SDL3 backend, web uses wasm backend
    const dvui_dep = if (is_web)
        b.dependency("dvui", .{ .target = target, .optimize = optimize, .backend = .web })
    else
        b.dependency("dvui", .{ .target = target, .optimize = optimize, .backend = .sdl3 });
    const dvui_mod = if (is_web) dvui_dep.module("dvui_web_wasm") else dvui_dep.module("dvui_sdl3");

    const build_opts = b.addOptions();
    build_opts.addOption(Backend, "backend", backend);
    build_opts.addOption(bool, "has_cli", !is_web);

    // ── Examples module (auto-discovered from examples/) ─────────────────────
    const examples_mod = generateExamplesModule(b, target, optimize);

    // Module graph — two-pass: create all modules first, then wire imports.
    var mods = std.StringHashMap(*std.Build.Module).init(b.allocator);
    mods.put("dvui", dvui_mod) catch @panic("OOM");
    mods.put("examples", examples_mod) catch @panic("OOM");
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
    addImports(exe_mod, &mods, &.{ "dvui", "utility", "schematic", "plugins", "commands", "state", "gui", "cli", "theme_config", "import", "simulation" });

    const exe = b.addExecutable(.{ .name = "Schemify", .root_module = exe_mod });
    exe.root_module.strip = optimize != .Debug;
    if (!is_web) exe.use_lld = false;
    if (is_web) exe.entry = .disabled;
    b.installArtifact(exe);

    // Size
    const size_cmd = b.addSystemCommand(&.{ "sh", "-c", "printf 'Executable size: '; du -h \"$1\" | cut -f1", "--" });
    size_cmd.addArtifactArg(exe);
    b.getInstallStep().dependOn(&size_cmd.step);

    // ── Tests ─────────────────────────────────────────────────────────────
    const test_deps = &[_][]const u8{ "import", "simulation", "schematic", "examples" };
    {
        const mod = b.createModule(.{ .root_source_file = b.path("test/test_all.zig"), .target = target, .optimize = optimize });
        addImports(mod, &mods, test_deps);
        const t = b.addTest(.{ .root_module = mod, .test_runner = .{ .path = b.path("test/test_runner.zig"), .mode = .simple } });
        b.step("test", "Run all integration tests").dependOn(&b.addRunArtifact(t).step);
    }
    {
        const mod = b.createModule(.{ .root_source_file = b.path("test/test_pyspice_import.zig"), .target = target, .optimize = optimize });
        addImports(mod, &mods, test_deps);
        const t = b.addTest(.{ .root_module = mod, .test_runner = .{ .path = b.path("test/test_runner.zig"), .mode = .simple } });
        b.step("test_pyspice_import", "PySpice round-trip tests only").dependOn(&b.addRunArtifact(t).step);
    }
    {
        const t = b.addTest(.{ .root_module = mods.get("schematic").? });
        b.step("test_schematic", "Run schematic module unit tests").dependOn(&b.addRunArtifact(t).step);
    }
    {
        const t = b.addTest(.{ .root_module = mods.get("import").? });
        b.step("test_import", "Run import module unit tests").dependOn(&b.addRunArtifact(t).step);
    }

    // ── Native: run steps ──────────────────────────────────────────────
    if (!is_web) {
        const run = b.addRunArtifact(exe);
        run.setCwd(b.path("."));
        run.step.dependOn(b.getInstallStep());
        if (b.args) |args| run.addArgs(args);
        b.step("run", "Run Schemify GUI (-- --cli for CLI)").dependOn(&run.step);
    }

    // ── Web: install assets + run_local dev server ────────────────────────────
    if (is_web) {
        const install = b.getInstallStep();
        install.dependOn(&b.addInstallFileWithDir(dvui_dep.path("src/backends/web.js"), .bin, "web.js").step);
        for ([_][]const u8{ "index.html", "boot.js", "vfs.js", "vfs-worker.js" }) |name| {
            install.dependOn(&b.addInstallFileWithDir(b.path(b.fmt("src/web/{s}", .{name})), .bin, name).step);
        }
        install.dependOn(&b.addInstallFileWithDir(b.path("src/web/schemify_host.js"), .bin, "schemify_host.js").step);

        const kill = b.addSystemCommand(&.{ "sh", "-c", "fuser -k 8080/tcp 2>/dev/null; sleep 0.3; exit 0" });
        kill.step.dependOn(install);
        const serve = b.addSystemCommand(&.{ "python3", "-m", "http.server", "8080", "--directory", b.getInstallPath(.bin, "") });
        serve.step.dependOn(&kill.step);
        b.step("run_local", "Build WASM + serve at http://localhost:8080").dependOn(&serve.step);
    }
}

fn addImports(
    mod: *std.Build.Module,
    mods: *const std.StringHashMap(*std.Build.Module),
    names: []const []const u8,
) void {
    for (names) |n| mod.addImport(n, mods.get(n).?);
}

fn generateExamplesModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    const wf = b.addWriteFiles();
    var src: std.ArrayListUnmanaged(u8) = .{};
    const w = src.writer(b.allocator);
    w.writeAll(
        \\pub const Example = struct { name: []const u8, data: []const u8 };
        \\pub const list: []const Example = &.{
        \\
    ) catch @panic("OOM");

    var dir = std.fs.cwd().openDir("examples", .{ .iterate = true }) catch
        @panic("Cannot open examples/ directory");
    defer dir.close();
    var walker = dir.walk(b.allocator) catch @panic("Failed to walk examples/");
    defer walker.deinit();
    while (walker.next() catch @panic("Failed to iterate examples/")) |entry| {
        if (entry.kind != .file) continue;
        const path = entry.path;
        const is_example = std.mem.endsWith(u8, path, ".chn") or
            std.mem.endsWith(u8, path, ".chn_tb") or
            std.mem.endsWith(u8, path, ".chn_prim") or
            std.mem.endsWith(u8, path, ".py");
        if (!is_example) continue;
        // Skip venv/pycache artifacts
        if (std.mem.indexOf(u8, path, ".venv") != null) continue;
        if (std.mem.indexOf(u8, path, "__pycache__") != null) continue;
        _ = wf.addCopyFile(b.path(b.fmt("examples/{s}", .{path})), path);
        w.print("    .{{ .name = \"{s}\", .data = @embedFile(\"{s}\") }},\n", .{ path, path }) catch @panic("OOM");
    }

    w.writeAll("};\n") catch @panic("OOM");
    const generated = wf.add("examples.zig", src.items);

    return b.addModule("examples", .{ .root_source_file = generated, .target = target, .optimize = optimize });
}
