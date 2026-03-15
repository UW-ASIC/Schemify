const std = @import("std");
const sdk    = @import("schemify_sdk");
const helper = sdk.build_plugin_helper;

pub fn build(b: *std.Build) void {
    const sdk_dep = b.dependency("schemify_sdk", .{});
    const ctx     = helper.setup(b, sdk_dep);

    if (!ctx.is_web) {
        const lib = helper.addCPlugin(b, ctx, sdk_dep, "CHello", "src/main.c");
        b.installArtifact(lib);
        helper.addNativeAutoInstallRunStep(b, "CHello", sdk_dep, "c-hello");
    }

    if (ctx.is_web) {
        helper.addCWasmPlugin(b, sdk_dep, "CHello", "src/main.c");
        helper.addWasmAutoServeStep(b, sdk_dep, "CHello", "c-hello");
    }
}
