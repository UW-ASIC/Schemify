const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // wasm3 C source is a lazy dependency. When not fetched, export a stub module
    // with `is_stub = true`. loader_wasm.zig detects this at comptime and disables
    // all wasm3-dependent code paths.
    const wasm3_dep = b.lazyDependency("wasm3_source", .{}) orelse {
        _ = b.addModule("wasm3", .{
            .root_source_file = b.path("src/wasm3_stub.zig"),
            .target = target,
            .optimize = optimize,
        });
        return;
    };

    // Core wasm3 C source files (excluding WASI, libc, tracer, uvwasi)
    const core_sources = [_][]const u8{
        "source/m3_bind.c",
        "source/m3_code.c",
        "source/m3_compile.c",
        "source/m3_core.c",
        "source/m3_emit.c",
        "source/m3_env.c",
        "source/m3_exec.c",
        "source/m3_function.c",
        "source/m3_info.c",
        "source/m3_module.c",
        "source/m3_optimize.c",
        "source/m3_parse.c",
    };

    // Create a module for the C library (no Zig root source, pure C)
    const lib_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    lib_mod.addIncludePath(wasm3_dep.path("source"));

    for (&core_sources) |src| {
        lib_mod.addCSourceFile(.{
            .file = wasm3_dep.path(src),
            .flags = &.{
                "-std=c99",
                "-Dd_m3HasWASI=0",
                "-DNDEBUG",
                "-fno-sanitize=undefined",
            },
        });
    }

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "wasm3",
        .root_module = lib_mod,
    });
    b.installArtifact(lib);

    // Expose the "wasm3" Zig module with real @cImport bindings
    const wasm3_mod = b.addModule("wasm3", .{
        .root_source_file = b.path("src/wasm3.zig"),
        .target = target,
        .optimize = optimize,
    });
    wasm3_mod.addIncludePath(wasm3_dep.path("source"));
    wasm3_mod.linkLibrary(lib);
}
