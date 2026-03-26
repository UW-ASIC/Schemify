const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // XSchem module (types, props, reader, root)
    const xschem_mod = b.addModule("xschem", .{
        .root_source_file = b.path("src/XSchem/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Tcl module
    const tcl_mod = b.addModule("tcl", .{
        .root_source_file = b.path("src/TCL/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // xschemrc.zig needs to @import("tcl") -- wire TCL into the XSchem module
    xschem_mod.addImport("tcl", tcl_mod);

    const test_step = b.step("test", "Run all tests");

    // Test: reader
    {
        const t = b.addTest(.{
            .root_source_file = b.path("test/test_reader.zig"),
            .target = target,
            .optimize = optimize,
        });
        t.root_module.addImport("xschem", xschem_mod);
        const run = b.addRunArtifact(t);
        test_step.dependOn(&run.step);
    }

    // Test: props
    {
        const t = b.addTest(.{
            .root_source_file = b.path("test/test_props.zig"),
            .target = target,
            .optimize = optimize,
        });
        t.root_module.addImport("xschem", xschem_mod);
        const run = b.addRunArtifact(t);
        test_step.dependOn(&run.step);
    }

    // Test: tcl
    {
        const t = b.addTest(.{
            .root_source_file = b.path("test/test_tcl.zig"),
            .target = target,
            .optimize = optimize,
        });
        t.root_module.addImport("tcl", tcl_mod);
        const run = b.addRunArtifact(t);
        test_step.dependOn(&run.step);
    }

    // Test: xschemrc
    {
        const t = b.addTest(.{
            .root_source_file = b.path("test/test_xschemrc.zig"),
            .target = target,
            .optimize = optimize,
        });
        t.root_module.addImport("xschem", xschem_mod);
        t.root_module.addImport("tcl", tcl_mod);
        const run = b.addRunArtifact(t);
        test_step.dependOn(&run.step);
    }
}
