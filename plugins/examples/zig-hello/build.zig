const std = @import("std");
const sdk    = @import("schemify_sdk");
const helper = sdk.build_plugin_helper;

pub fn build(b: *std.Build) void {
    const sdk_dep = b.dependency("schemify_sdk", .{});
    const ctx     = helper.setup(b, sdk_dep);
    if (!ctx.is_web) {
        const lib = helper.addNativePluginLibrary(b, ctx, "ZigHello", "src/main.zig");
        b.installArtifact(lib);
        helper.addNativeAutoInstallRunStep(b, "ZigHello", sdk_dep, "zig-hello");
    }
    if (ctx.is_web) {
        helper.addWasmPlugin(b, ctx, "ZigHello", "src/main.zig");
        helper.addWasmAutoServeStep(b, sdk_dep, "ZigHello", "zig-hello");
    }
}
