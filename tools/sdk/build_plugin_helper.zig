//! Schemify Plugin SDK — build helper.
//!
//! Import this from your plugin's `build.zig` via the `schemify_sdk` dep:
//!
//!   const sdk    = @import("schemify_sdk");   // imports Schemify's build.zig
//!   const helper = sdk.build_plugin_helper;
//!
//!   pub fn build(b: *std.Build) void {
//!       const sdk_dep = b.dependency("schemify_sdk", .{});
//!       const ctx     = helper.setup(b, sdk_dep);
//!       ...
//!   }
//!
//! All source paths (PluginIF, core, sdk module) are resolved via `sdk_dep`
//! so no hardcoded relative paths to the Schemify repo are needed.
//!
//! `dvui` is pulled from Schemify's own dependency graph via
//! `sdk_dep.builder`, so external plugin repos do NOT need a `dvui` entry
//! in their `build.zig.zon` — only a single `schemify_sdk` entry is required.

const std = @import("std");

pub const Backend = enum { native, web };

pub const PluginContext = struct {
    backend:     Backend,
    is_web:      bool,
    optimize:    std.builtin.OptimizeMode,
    target:      std.Build.ResolvedTarget,
    dvui_mod:    *std.Build.Module,
    utility_mod: *std.Build.Module,
    core_mod:    *std.Build.Module,
    plugin_if:   *std.Build.Module,
    /// Convenience module that re-exports `PluginIF` and `core`.
    /// Added to every plugin artifact as the `"sdk"` named import.
    sdk_mod:     *std.Build.Module,
};

/// Set up a plugin build context.
///
/// `sdk_dep` is `b.dependency("schemify_sdk", .{})`.  All SDK source paths
/// and the `dvui` dependency are resolved through it, so the plugin's own
/// `build.zig.zon` only needs the single `schemify_sdk` entry.
pub fn setup(b: *std.Build, sdk_dep: *std.Build.Dependency) PluginContext {
    const backend  = b.option(Backend, "backend", "native (.so) or web (.wasm)") orelse .native;
    const is_web   = backend == .web;
    const optimize = b.standardOptimizeOption(.{});

    const wasm_query = std.Target.Query{ .cpu_arch = .wasm32, .os_tag = .freestanding };
    const target = if (is_web) b.resolveTargetQuery(wasm_query) else b.standardTargetOptions(.{});

    // Resolve dvui through the SDK's own dependency graph — plugins need not
    // declare dvui themselves.
    const sdk_b    = sdk_dep.builder;
    const dvui_dep = if (is_web)
        sdk_b.dependency("dvui", .{ .target = target, .optimize = optimize, .backend = .web })
    else
        sdk_b.dependency("dvui", .{
            .target   = target,
            .optimize = optimize,
            .backend  = .raylib,
            .linux_display_backend = .X11,
            .freetype  = false,
        });
    const dvui_mod = if (is_web)
        dvui_dep.module("dvui_web_wasm")
    else
        dvui_dep.module("dvui_raylib");

    const utility_mod = b.createModule(.{
        .root_source_file = sdk_dep.path("src/utility/lib.zig"),
        .target   = target,
        .optimize = optimize,
    });
    const core_mod = b.createModule(.{
        .root_source_file = sdk_dep.path("src/core/Schemify.zig"),
        .target   = target,
        .optimize = optimize,
    });
    core_mod.addImport("utility", utility_mod);
    const plugin_if = b.createModule(.{
        .root_source_file = sdk_dep.path("src/PluginIF.zig"),
        .target   = target,
        .optimize = optimize,
    });
    plugin_if.addImport("dvui", dvui_mod);
    plugin_if.addImport("core", core_mod);
    plugin_if.addImport("utility", utility_mod);

    const sdk_mod = b.createModule(.{
        .root_source_file = sdk_dep.path("tools/sdk/root.zig"),
        .target   = target,
        .optimize = optimize,
    });
    sdk_mod.addImport("PluginIF", plugin_if);
    sdk_mod.addImport("core",     core_mod);

    return .{
        .backend     = backend,
        .is_web      = is_web,
        .optimize    = optimize,
        .target      = target,
        .dvui_mod    = dvui_mod,
        .utility_mod = utility_mod,
        .core_mod    = core_mod,
        .plugin_if   = plugin_if,
        .sdk_mod     = sdk_mod,
    };
}

/// Create a native dynamic-library plugin artifact.
///
/// `"PluginIF"`, `"dvui"`, and `"sdk"` are wired in as named imports.
/// Add any plugin-specific system libraries before calling
/// `b.installArtifact(lib)`.
pub fn addNativePluginLibrary(
    b:                *std.Build,
    ctx:              PluginContext,
    name:             []const u8,
    root_source_file: []const u8,
) *std.Build.Step.Compile {
    const lib = b.addLibrary(.{
        .name    = name,
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path(root_source_file),
            .target   = ctx.target,
            .optimize = ctx.optimize,
        }),
    });
    lib.root_module.addImport("PluginIF", ctx.plugin_if);
    lib.root_module.addImport("dvui",     ctx.dvui_mod);
    lib.root_module.addImport("sdk",      ctx.sdk_mod);
    return lib;
}

/// Create a WASM plugin executable and install it under
/// `zig-out/plugins/<name>.wasm`.
pub fn addWasmPlugin(
    b:                *std.Build,
    ctx:              PluginContext,
    name:             []const u8,
    root_source_file: []const u8,
) void {
    const wasm = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(root_source_file),
            .target   = ctx.target,
            .optimize = ctx.optimize,
        }),
    });
    wasm.entry    = .disabled;
    wasm.rdynamic = true;
    wasm.root_module.addImport("PluginIF", ctx.plugin_if);
    wasm.root_module.addImport("dvui",     ctx.dvui_mod);
    wasm.root_module.addImport("sdk",      ctx.sdk_mod);

    const wasm_install = b.addInstallArtifact(wasm, .{
        .dest_dir = .{ .override = .{ .custom = "plugins" } },
    });
    b.getInstallStep().dependOn(&wasm_install.step);
}

/// Install a list of files (relative to the plugin root) into `install_dir`.
pub fn addInstallFiles(
    b:           *std.Build,
    install_dir: std.Build.InstallDir,
    files:       []const []const u8,
) void {
    const install = b.getInstallStep();
    for (files) |rel| {
        install.dependOn(&b.addInstallFileWithDir(b.path(rel), install_dir, rel).step);
    }
}

/// Register a `zig build run` step that:
///   1. Copies `zig-out/lib/*` into `~/.config/Schemify/<plugin_dir_name>/`
///   2. Runs `zig build run` in the Schemify host repo (resolved via `sdk_dep`).
///
/// Primarily for in-repo plugin development.
pub fn addNativeAutoInstallRunStep(
    b:               *std.Build,
    plugin_dir_name: []const u8,
    sdk_dep:         *std.Build.Dependency,
    log_label:       []const u8,
) void {
    const run_step = b.step("run", "Install plugin to ~/.config/Schemify/ and launch Schemify");
    run_step.dependOn(b.getInstallStep());

    const schemify_root = sdk_dep.path(".").getPath(b);
    const install_and_run = b.addSystemCommand(&.{
        "sh", "-c",
        b.fmt(
            "set -e\n" ++
            "PLUGIN_DIR=\"$HOME/.config/Schemify/{s}\"\n" ++
            "mkdir -p \"$PLUGIN_DIR\"\n" ++
            "cp -r zig-out/lib/* \"$PLUGIN_DIR/\" 2>/dev/null || true\n" ++
            "echo \"[{s}] Installed to $PLUGIN_DIR\"\n" ++
            "cd \"{s}\"\n" ++
            "echo \"[{s}] Building Schemify host...\"\n" ++
            "zig build run\n",
            .{ plugin_dir_name, log_label, schemify_root, log_label },
        ),
    });
    install_and_run.step.dependOn(b.getInstallStep());
    run_step.dependOn(&install_and_run.step);
}

/// Register a `zig build run -Dbackend=web` step that:
///   1. Builds the Schemify host in web mode (`zig build -Dbackend=web`).
///   2. Copies `<name>.wasm` into the host's `zig-out/bin/plugins/` directory.
///   3. Patches `plugins.json` so the host discovers the plugin.
///   4. Kills any process on port 8080 and serves the build at http://localhost:8080.
pub fn addWasmAutoServeStep(
    b:         *std.Build,
    sdk_dep:   *std.Build.Dependency,
    name:      []const u8,
    log_label: []const u8,
) void {
    const run_step = b.step("run", "Build WASM, install into host web build, serve at :8080");
    run_step.dependOn(b.getInstallStep());

    const schemify_root = sdk_dep.path(".").getPath(b);
    const install_and_serve = b.addSystemCommand(&.{
        "sh", "-c",
        b.fmt(
            "set -e\n" ++
            "cd \"{s}\"\n" ++
            "echo \"[{s}] Building Schemify host (web)...\"\n" ++
            "zig build -Dbackend=web\n" ++
            "HOST_PLUGINS_DIR=\"zig-out/bin/plugins\"\n" ++
            "WASM_SRC=\"plugins/{s}/zig-out/plugins/{s}.wasm\"\n" ++
            "cp \"$WASM_SRC\" \"$HOST_PLUGINS_DIR/{s}.wasm\" 2>/dev/null || true\n" ++
            "python3 -c \"\n" ++
            "import json, pathlib\n" ++
            "p = pathlib.Path('$HOST_PLUGINS_DIR/plugins.json')\n" ++
            "d = json.loads(p.read_text()) if p.exists() else {{'plugins':[]}}\n" ++
            "entry = '{s}.wasm'\n" ++
            "if entry not in d['plugins']: d['plugins'].append(entry)\n" ++
            "p.write_text(json.dumps(d, indent=2))\n" ++
            "\"\n" ++
            "echo \"[{s}] Serving at http://localhost:8080\"\n" ++
            "fuser -k 8080/tcp 2>/dev/null; sleep 0.3\n" ++
            "python3 -m http.server 8080 --directory zig-out/bin\n",
            .{ schemify_root, log_label, name, name, name, name, log_label },
        ),
    });
    install_and_serve.step.dependOn(b.getInstallStep());
    run_step.dependOn(&install_and_serve.step);
}

/// Link the CPython embedding library (`libpython3.x`) to `lib`.
///
/// Uses `python3-config --includes` and `python3-config --ldflags --embed`
/// to locate the exact versioned library and its Nix-store library path.
/// Falls back to a bare `-lpython3` if `python3-config` is absent.
pub fn linkPythonC(b: *std.Build, lib: *std.Build.Step.Compile) void {
    // Include path
    if (pyIncludePath(b)) |inc| {
        lib.addIncludePath(.{ .cwd_relative = inc });
    }
    // Link flags
    const result = std.process.Child.run(.{
        .allocator = b.allocator,
        .argv      = &.{ "python3-config", "--ldflags", "--embed" },
    }) catch {
        lib.linkSystemLibrary("python3");
        return;
    };
    var it = std.mem.splitScalar(u8, std.mem.trim(u8, result.stdout, " \n\r\t"), ' ');
    while (it.next()) |tok| {
        const t = std.mem.trim(u8, tok, " \t");
        if (t.len == 0) continue;
        if (std.mem.startsWith(u8, t, "-L")) {
            lib.addLibraryPath(.{ .cwd_relative = t[2..] });
        } else if (std.mem.startsWith(u8, t, "-l")) {
            lib.linkSystemLibrary2(t[2..], .{ .use_pkg_config = .no });
        }
    }
}

/// Return the Python3 C include directory, or null if `python3-config` is absent.
fn pyIncludePath(b: *std.Build) ?[]const u8 {
    const result = std.process.Child.run(.{
        .allocator = b.allocator,
        .argv      = &.{ "python3-config", "--includes" },
    }) catch return null;
    var it = std.mem.splitScalar(u8, std.mem.trim(u8, result.stdout, " \n\r\t"), ' ');
    while (it.next()) |tok| {
        if (std.mem.startsWith(u8, tok, "-I")) return b.dupe(tok[2..]);
    }
    return null;
}

/// Create a native C plugin dynamic library (ABI v6, header-only SDK).
///
/// Compiles `c_src` (a path relative to the plugin repo root) against
/// `schemify_plugin.h` (header-only, no shim file required).
/// The include path is resolved through `sdk_dep` so the plugin's own repo
/// does not need any copies of the SDK files.
///
/// Usage:
///   const lib = helper.addCPlugin(b, ctx, sdk_dep, "CHello", "src/main.c");
///   b.installArtifact(lib);
pub fn addCPlugin(
    b:       *std.Build,
    ctx:     PluginContext,
    sdk_dep: *std.Build.Dependency,
    name:    []const u8,
    c_src:   []const u8,
) *std.Build.Step.Compile {
    const lib = b.addLibrary(.{
        .name    = name,
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .target   = ctx.target,
            .optimize = ctx.optimize,
        }),
    });
    // Plugin source
    lib.addCSourceFile(.{
        .file  = b.path(c_src),
        .flags = &.{ "-std=c11", "-fvisibility=default" },
    });
    // Expose schemify_plugin.h (header-only, no shim needed in ABI v6)
    lib.addIncludePath(sdk_dep.path("tools/sdk"));
    lib.linkLibC();
    // Generate compile_flags.txt next to the source file so clangd picks up
    // the include path without a separate hand-written file in the repo.
    writeCompileFlags(b, c_src, sdk_dep, &.{});
    return lib;
}

/// Create a native C++ plugin dynamic library (ABI v6, header-only SDK).
///
/// Same as `addCPlugin` but compiles `cpp_src` as C++17 and links libstdc++.
///
/// Usage:
///   const lib = helper.addCppPlugin(b, ctx, sdk_dep, "CppHello", "src/main.cpp");
///   b.installArtifact(lib);
pub fn addCppPlugin(
    b:       *std.Build,
    ctx:     PluginContext,
    sdk_dep: *std.Build.Dependency,
    name:    []const u8,
    cpp_src: []const u8,
) *std.Build.Step.Compile {
    const lib = b.addLibrary(.{
        .name    = name,
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .target   = ctx.target,
            .optimize = ctx.optimize,
        }),
    });
    // Plugin source (C++)
    lib.addCSourceFile(.{
        .file  = b.path(cpp_src),
        .flags = &.{ "-std=c++17", "-fvisibility=default" },
    });
    // Expose schemify_plugin.h (header-only, no shim needed in ABI v6)
    lib.addIncludePath(sdk_dep.path("tools/sdk"));
    lib.linkLibC();
    lib.linkLibCpp();
    // Generate compile_flags.txt next to the source file for clangd.
    writeCompileFlags(b, cpp_src, sdk_dep, &.{"-std=c++17"});
    return lib;
}

/// Write `compile_flags.txt` alongside `src_file` so clangd resolves the
/// SDK headers without a hand-written file committed to the plugin repo.
/// The file is (re)generated every time `zig build` runs.
fn writeCompileFlags(
    b:           *std.Build,
    src_file:    []const u8,
    sdk_dep:     *std.Build.Dependency,
    extra_flags: []const []const u8,
) void {
    const src_dir = std.fs.path.dirname(src_file) orelse ".";
    const sdk_inc = sdk_dep.path("tools/sdk").getPath(b);

    // Build: printf '%s\n' '-Ipath' > dir/compile_flags.txt
    //     && printf '%s\n' '-extra' >> dir/compile_flags.txt ...
    var cmd = std.ArrayList(u8){};
    std.fmt.format(cmd.writer(b.allocator),
        "printf '%s\\n' '-I{s}' > \"{s}/compile_flags.txt\"",
        .{ sdk_inc, src_dir }) catch unreachable;
    for (extra_flags) |f| {
        std.fmt.format(cmd.writer(b.allocator),
            " && printf '%s\\n' '{s}' >> \"{s}/compile_flags.txt\"",
            .{ f, src_dir }) catch unreachable;
    }

    const gen = b.addSystemCommand(&.{ "sh", "-c", b.dupe(cmd.items) });
    b.getInstallStep().dependOn(&gen.step);
}

/// Compile a C plugin to WASM using Emscripten (`emcc`).
///
/// Output: `zig-out/plugins/<name>.wasm`
/// Exported symbols: `schemify_process`, `schemify_plugin`
pub fn addCWasmPlugin(
    b:       *std.Build,
    sdk_dep: *std.Build.Dependency,
    name:    []const u8,
    c_src:   []const u8,
) void {
    const out_path = b.fmt("zig-out/plugins/{s}.wasm", .{name});
    const sdk_inc  = sdk_dep.path("tools/sdk").getPath(b);
    const emcc = b.addSystemCommand(&.{
        "emcc",
        b.path(c_src).getPath(b),
        b.fmt("-I{s}", .{sdk_inc}),
        "-o", out_path,
        "-std=c11",
        "-O2",
        "--no-entry",
        "-s", "STANDALONE_WASM=1",
        "-s", "EXPORTED_FUNCTIONS=[\"_schemify_process\",\"_schemify_plugin\"]",
        "-s", "ERROR_ON_UNDEFINED_SYMBOLS=0",
    });
    b.getInstallStep().dependOn(&emcc.step);
}

/// Compile a C++ plugin to WASM using Emscripten (`em++`).
///
/// Output: `zig-out/plugins/<name>.wasm`
/// Exported symbols: `schemify_process`, `schemify_plugin`
pub fn addCppWasmPlugin(
    b:       *std.Build,
    sdk_dep: *std.Build.Dependency,
    name:    []const u8,
    cpp_src: []const u8,
) void {
    const out_path = b.fmt("zig-out/plugins/{s}.wasm", .{name});
    const sdk_inc  = sdk_dep.path("tools/sdk").getPath(b);
    const empp = b.addSystemCommand(&.{
        "em++",
        b.path(cpp_src).getPath(b),
        b.fmt("-I{s}", .{sdk_inc}),
        "-o", out_path,
        "-std=c++17",
        "-O2",
        "--no-entry",
        "-s", "STANDALONE_WASM=1",
        "-s", "EXPORTED_FUNCTIONS=[\"_schemify_process\",\"_schemify_plugin\"]",
        "-s", "ERROR_ON_UNDEFINED_SYMBOLS=0",
    });
    b.getInstallStep().dependOn(&empp.step);
}

/// Register a `zig build run-rust` step that invokes `cargo build --release`
/// and copies the resulting shared library into `zig-out/lib/`.
///
/// `cargo_dir`    — path to the Cargo workspace root (contains Cargo.toml).
/// `install_name` — bare name used for the .so, e.g. "my_plugin" produces
///                  `zig-out/lib/libmy_plugin.so`.
pub fn addRustPlugin(
    b:            *std.Build,
    cargo_dir:    []const u8,
    install_name: []const u8,
) void {
    const cargo_build = b.addSystemCommand(&.{
        "cargo", "build", "--release", "--manifest-path",
        b.fmt("{s}/Cargo.toml", .{cargo_dir}),
    });

    // Try libNAME.so (Linux) then NAME.so as fallback.
    const copy = b.addSystemCommand(&.{
        "sh", "-c",
        b.fmt(
            "mkdir -p zig-out/lib && " ++
            "cp \"{s}/target/release/lib{s}.so\" \"zig-out/lib/lib{s}.so\" 2>/dev/null || " ++
            "cp \"{s}/target/release/{s}.so\"    \"zig-out/lib/lib{s}.so\" 2>/dev/null || true",
            .{ cargo_dir, install_name, install_name,
               cargo_dir, install_name, install_name },
        ),
    });
    copy.step.dependOn(&cargo_build.step);
    b.getInstallStep().dependOn(&copy.step);
}

/// Register a `zig build` step that invokes TinyGo to build a native shared library.
///
/// `go_dir`       — directory containing go.mod (relative to plugin root).
/// `install_name` — bare library name, e.g. "go_hello" → `zig-out/lib/libgo_hello.so`.
pub fn addGoPlugin(
    b:            *std.Build,
    go_dir:       []const u8,
    install_name: []const u8,
) void {
    const tinygo_build = b.addSystemCommand(&.{
        "sh", "-c",
        b.fmt(
            "set -e\n" ++
            "mkdir -p zig-out/lib\n" ++
            "cd \"{s}\"\n" ++
            "tinygo build -o \"$(cd .. && pwd)/zig-out/lib/lib{s}.so\" " ++
            "-buildmode=c-shared -target=linux/amd64 .\n",
            .{ go_dir, install_name },
        ),
    });
    b.getInstallStep().dependOn(&tinygo_build.step);
}

/// Deploy a Python plugin to the SchemifyPython scripts directory.
///
/// Copies all files in `py_files` to
///   `~/.config/Schemify/SchemifyPython/scripts/<plugin_dir_name>/`
/// If `requirements` is non-null, runs `pip install -r <requirements>` first.
pub fn addPythonPlugin(
    b:               *std.Build,
    plugin_dir_name: []const u8,
    sdk_dep:         *std.Build.Dependency,
    py_files:        []const []const u8,
    requirements:    ?[]const u8,
    log_label:       []const u8,
) void {
    const run_step = b.step("run", "Deploy Python plugin and launch Schemify");

    // Build the shell script piecewise using b.fmt and string concatenation.
    var script: []const u8 = "set -e\n";
    if (requirements) |req| {
        script = b.fmt("{s}pip install -r \"{s}\" --quiet\n", .{ script, req });
    }
    script = b.fmt(
        "{s}SCRIPTS=\"$HOME/.config/Schemify/SchemifyPython/scripts/{s}\"\n" ++
        "mkdir -p \"$SCRIPTS\"\n",
        .{ script, plugin_dir_name },
    );
    for (py_files) |f| {
        script = b.fmt("{s}cp \"{s}\" \"$SCRIPTS/\"\n", .{ script, f });
    }
    script = b.fmt("{s}echo \"[{s}] Installed to $SCRIPTS\"\n", .{ script, log_label });

    const deploy = b.addSystemCommand(&.{ "sh", "-c", script });
    b.getInstallStep().dependOn(&deploy.step);
    run_step.dependOn(b.getInstallStep());

    const schemify_root = sdk_dep.path(".").getPath(b);
    const run_schemify = b.addSystemCommand(&.{
        "sh", "-c",
        b.fmt("cd \"{s}\" && zig build run\n", .{schemify_root}),
    });
    run_schemify.step.dependOn(b.getInstallStep());
    run_step.dependOn(&run_schemify.step);
}
