const std = @import("std");
const sdk = @import("schemify_sdk");
const helper = sdk.build_plugin_helper;

pub fn build(b: *std.Build) void {
    const sdk_dep = b.dependency("schemify_sdk", .{});
    const ctx = helper.setup(b, sdk_dep);

    // ── Internal modules ────────────────────────────────────────────────────

    const ct_mod = b.createModule(.{
        .root_source_file = b.path("src/convert_types.zig"),
        .target = ctx.target,
        .optimize = ctx.optimize,
    });
    ct_mod.addImport("core", ctx.core_mod);

    const tcl_mod = b.createModule(.{
        .root_source_file = b.path("src/TCL/mod.zig"),
        .target = ctx.target,
        .optimize = ctx.optimize,
    });

    const xschem_mod = b.createModule(.{
        .root_source_file = b.path("src/XSchem/mod.zig"),
        .target = ctx.target,
        .optimize = ctx.optimize,
    });
    xschem_mod.addImport("tcl", tcl_mod);
    xschem_mod.addImport("core", ctx.core_mod);
    xschem_mod.addImport("utility", ctx.utility_mod);
    xschem_mod.addImport("convert_types", ct_mod);

    const virtuoso_mod = b.createModule(.{
        .root_source_file = b.path("src/Virtuoso/mod.zig"),
        .target = ctx.target,
        .optimize = ctx.optimize,
    });
    virtuoso_mod.addImport("convert_types", ct_mod);

    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = ctx.target,
        .optimize = ctx.optimize,
    });
    lib_mod.addImport("xschem", xschem_mod);
    lib_mod.addImport("virtuoso", virtuoso_mod);
    lib_mod.addImport("tcl", tcl_mod);
    lib_mod.addImport("core", ctx.core_mod);
    lib_mod.addImport("convert_types", ct_mod);

    // ── Native plugin (.so) ─────────────────────────────────────────────────

    if (!ctx.is_web) {
        const plugin_lib = helper.addNativePluginLibrary(b, ctx, "XSchemDropIN", "src/main.zig");
        plugin_lib.root_module.addImport("easyimport", lib_mod);
        plugin_lib.root_module.addImport("core", ctx.core_mod);
        b.installArtifact(plugin_lib);
        helper.addNativeAutoInstallRunStep(b, "XSchemDropIN", sdk_dep, "EasyImport");
    }

    // Import requires filesystem access — no WASM plugin.

    // ── Tests ───────────────────────────────────────────────────────────────

    const test_step = b.step("test", "Run all tests");
    {
        const tmod = b.createModule(.{
            .root_source_file = b.path("test/test_all.zig"),
            .target = ctx.target,
            .optimize = ctx.optimize,
        });
        tmod.addImport("xschem", xschem_mod);
        tmod.addImport("tcl", tcl_mod);
        tmod.addImport("virtuoso", virtuoso_mod);
        tmod.addImport("easyimport", lib_mod);
        tmod.addImport("core", ctx.core_mod);
        tmod.addImport("convert_types", ct_mod);

        const t = b.addTest(.{ .root_module = tmod });
        const run = b.addRunArtifact(t);
        run.setCwd(b.path("../.."));
        test_step.dependOn(&run.step);
    }

    // ── Borrow Examples ──────────────────────────────────────────────────

    const borrow_step = b.step("borrow-examples", "Convert xschem examples to schemify format");
    {
        const bmod = b.createModule(.{
            .root_source_file = b.path("tools/BorrowExamples.zig"),
            .target = ctx.target,
            .optimize = ctx.optimize,
        });
        bmod.addImport("xschem", xschem_mod);
        bmod.addImport("core", ctx.core_mod);
        bmod.addImport("easyimport", lib_mod);
        bmod.addImport("convert_types", ct_mod);

        const exe = b.addExecutable(.{
            .name = "borrow-examples",
            .root_module = bmod,
        });
        const run_exe = b.addRunArtifact(exe);
        run_exe.setCwd(b.path("../.."));
        borrow_step.dependOn(&run_exe.step);
    }
}
