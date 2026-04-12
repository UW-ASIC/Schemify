const std = @import("std");
const sdk = @import("schemify_sdk");
const helper = sdk.build_plugin_helper;

pub fn build(b: *std.Build) void {
    const sdk_dep = b.dependency("schemify_sdk", .{});
    _ = sdk_dep; // Rust build uses cargo directly; sdk_dep unused here
    // `addRustPlugin` calls `cargo build --release` and copies the .so to zig-out/lib/.
    helper.addRustPlugin(b, ".", "rust_demo");
    helper.addNativeAutoInstallRunStep(b, "rust-demo", b.dependency("schemify_sdk", .{}), "rust-demo");
}
