const std = @import("std");
const sdk = @import("schemify_sdk");
const helper = sdk.build_plugin_helper;

pub fn build(b: *std.Build) void {
    // `addGoPlugin` invokes tinygo build -buildmode=c-shared and copies
    // the resulting .so to zig-out/lib/.
    helper.addGoPlugin(b, "src", "go_demo");
    const sdk_dep = b.dependency("schemify_sdk", .{});
    helper.addNativeAutoInstallRunStep(b, "go-demo", sdk_dep, "go-demo");
}
