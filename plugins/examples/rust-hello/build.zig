const std = @import("std");
const sdk    = @import("schemify_sdk");
const helper = sdk.build_plugin_helper;

pub fn build(b: *std.Build) void {
    const sdk_dep = b.dependency("schemify_sdk", .{});
    helper.addRustPlugin(b, ".", "rust_hello");
    helper.addNativeAutoInstallRunStep(b, "RustHello", sdk_dep, "rust-hello");
}
