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
}
