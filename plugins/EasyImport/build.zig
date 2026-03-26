const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // XSchem module (types, props, reader, xschemrc, root)
    const xschem_mod = b.addModule("xschem", .{
        .root_source_file = b.path("src/XSchem/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Tcl module (tokenizer, expr, evaluator, commands, root)
    const tcl_mod = b.addModule("tcl", .{
        .root_source_file = b.path("src/TCL/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // xschemrc.zig needs @import("tcl") -- wire TCL into the XSchem module
    xschem_mod.addImport("tcl", tcl_mod);

    // Umbrella test: test_all.zig imports all test modules
    const test_step = b.step("test", "Run all tests");
    {
        const t = b.addTest(.{
            .root_source_file = b.path("test/test_all.zig"),
            .target = target,
            .optimize = optimize,
        });
        t.root_module.addImport("xschem", xschem_mod);
        t.root_module.addImport("tcl", tcl_mod);
        const run = b.addRunArtifact(t);
        test_step.dependOn(&run.step);
    }
}
