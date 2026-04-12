const std = @import("std");
const sdk = @import("schemify_sdk");
const helper = sdk.build_plugin_helper;

pub fn build(b: *std.Build) void {
    const sdk_dep = b.dependency("schemify_sdk", .{});
    const ctx = helper.setup(b, sdk_dep);
    const lib = helper.addNativePluginLibrary(b, ctx, "zig-demo", "src/main.zig");
    b.installArtifact(lib);
    helper.addNativeAutoInstallRunStep(b, "zig-demo", sdk_dep, "zig-demo");
}
