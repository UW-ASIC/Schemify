const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Pull core modules from the root Schemify SDK so the plugin can
    // produce core.Schemify objects and call emitSpice().
    const sdk = b.dependency("schemify_sdk", .{ .target = target, .optimize = optimize });
    const utility_mod = sdk.module("utility");
    const core_mod = sdk.module("core");

    // Shared conversion result types (used by all backends and lib.zig)
    const ct_mod = b.addModule("convert_types", .{
        .root_source_file = b.path("src/convert_types.zig"),
        .target = target,
        .optimize = optimize,
    });
    ct_mod.addImport("core", core_mod);

    // Tcl module (tokenizer, expr, evaluator, commands)
    const tcl_mod = b.addModule("tcl", .{
        .root_source_file = b.path("src/TCL/mod.zig"),
        .target = target,
        .optimize = optimize,
    });

    // XSchem module (types, props, reader, xschemrc, converter, backend)
    const xschem_mod = b.addModule("xschem", .{
        .root_source_file = b.path("src/XSchem/mod.zig"),
        .target = target,
        .optimize = optimize,
    });
    xschem_mod.addImport("tcl", tcl_mod);
    xschem_mod.addImport("core", core_mod);
    xschem_mod.addImport("utility", utility_mod);
    xschem_mod.addImport("convert_types", ct_mod);

    // Virtuoso module
    const virtuoso_mod = b.addModule("virtuoso", .{
        .root_source_file = b.path("src/Virtuoso/mod.zig"),
        .target = target,
        .optimize = optimize,
    });
    virtuoso_mod.addImport("convert_types", ct_mod);

    // EasyImport top-level library module
    const lib_mod = b.addModule("easyimport", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_mod.addImport("xschem", xschem_mod);
    lib_mod.addImport("virtuoso", virtuoso_mod);
    lib_mod.addImport("tcl", tcl_mod);
    lib_mod.addImport("core", core_mod);
    lib_mod.addImport("convert_types", ct_mod);

    // Umbrella test
    const test_step = b.step("test", "Run all tests");
    {
        const tmod = b.createModule(.{
            .root_source_file = b.path("test/test_all.zig"),
            .target = target,
            .optimize = optimize,
        });
        tmod.addImport("xschem", xschem_mod);
        tmod.addImport("tcl", tcl_mod);
        tmod.addImport("virtuoso", virtuoso_mod);
        tmod.addImport("easyimport", lib_mod);
        tmod.addImport("core", core_mod);
        tmod.addImport("convert_types", ct_mod);

        const t = b.addTest(.{ .root_module = tmod });
        const run = b.addRunArtifact(t);
        run.setCwd(b.path("../.."));
        test_step.dependOn(&run.step);
    }
}
