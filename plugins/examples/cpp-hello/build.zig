const std = @import("std");
const sdk    = @import("schemify_sdk");
const helper = sdk.build_plugin_helper;

pub fn build(b: *std.Build) void {
    const sdk_dep = b.dependency("schemify_sdk", .{});
    const ctx     = helper.setup(b, sdk_dep);

    if (!ctx.is_web) {
        const lib = helper.addCppPlugin(b, ctx, sdk_dep, "CppHello", "src/main.cpp");
        b.installArtifact(lib);
        helper.addNativeAutoInstallRunStep(b, "CppHello", sdk_dep, "cpp-hello");
    }

    if (ctx.is_web) {
        helper.addCppWasmPlugin(b, sdk_dep, "CppHello", "src/main.cpp");
        helper.addWasmAutoServeStep(b, sdk_dep, "CppHello", "cpp-hello");
    }
}
