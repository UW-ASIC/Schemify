const std    = @import("std");
const sdk    = @import("schemify_sdk");
const helper = sdk.build_plugin_helper;

pub fn build(b: *std.Build) void {
    const sdk_dep = b.dependency("schemify_sdk", .{});
    const ctx     = helper.setup(b, sdk_dep);

    if (!ctx.is_web) {
        const lib = helper.addNativePluginLibrary(b, ctx, "EasyPDKLoader", "src/main.zig");
        lib.root_module.addImport("core", ctx.core_mod);
        b.installArtifact(lib);
        helper.addNativeAutoInstallRunStep(b, "EasyPDKLoader", sdk_dep, "EasyPDKLoader");

        addTests(b, ctx);
    }

    // PDK scanning requires filesystem access — no WASM plugin.
}

fn addTests(b: *std.Build, ctx: anytype) void {
    // volare.zig is the module under test; it needs "core" for XSchem conversion.
    const volare_mod = b.createModule(.{
        .root_source_file = b.path("src/volare.zig"),
        .target           = ctx.target,
        .optimize         = ctx.optimize,
    });
    volare_mod.addImport("core", ctx.core_mod);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("tests/test_volare_pdks.zig"),
        .target           = ctx.target,
        .optimize         = ctx.optimize,
    });
    test_mod.addImport("volare", volare_mod);

    const tests    = b.addTest(.{ .root_module = test_mod });
    const run_test = b.addRunArtifact(tests);
    run_test.setCwd(b.path("."));

    const test_step = b.step("test", "Run EasyPDKLoader tests");
    test_step.dependOn(&run_test.step);
}
