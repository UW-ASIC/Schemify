const std = @import("std");
const sdk = @import("schemify_sdk");
const helper = sdk.build_plugin_helper;

pub fn build(b: *std.Build) void {
    const sdk_dep = b.dependency("schemify_sdk", .{});
    const ctx = helper.setup(b, sdk_dep);
    const lib = helper.addCPlugin(b, ctx, sdk_dep, "c-demo", "src/plugin.c");
    b.installArtifact(lib);
    helper.addNativeAutoInstallRunStep(b, "c-demo", sdk_dep, "c-demo");
}
