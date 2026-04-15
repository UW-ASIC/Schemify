//! Types for the installer module.

const std = @import("std");
const builtin = @import("builtin");

pub const Target = enum {
    /// Download the platform-native binary (.so / .dylib / .dll).
    native,
    /// Download the .wasm artifact and update the web manifest.
    web,
};

pub const InstallOptions = struct {
    target: Target = .native,
    /// Only used when target == .web.  Defaults to zig-out/bin/plugins/.
    web_out_dir: []const u8 = "zig-out/bin/plugins",
};

pub const InstallError = error{
    InvalidUrl,
    InvalidGitHubUrl,
    NoPluginAsset,
    OutOfMemory,
    HttpError,
    NoHomeDir,
};