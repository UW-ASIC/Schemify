const std = @import("std");
const sdk    = @import("schemify_sdk");
const helper = sdk.build_plugin_helper;

pub fn build(b: *std.Build) void {
    const sdk_dep = b.dependency("schemify_sdk", .{});
    const ctx     = helper.setup(b, sdk_dep);

    if (!ctx.is_web) {
        const lib = helper.addNativePluginLibrary(b, ctx, "Optimizer", "src/main.zig");
        b.installArtifact(lib);
        helper.addNativeAutoInstallRunStep(b, "Optimizer", sdk_dep, "Optimizer");
    }

    // Unit tests for helper modules (no PluginIF dependency)
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/test_all.zig"),
        .target = ctx.target,
        .optimize = ctx.optimize,
    });
    const tests = b.addTest(.{
        .root_module = test_mod,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
