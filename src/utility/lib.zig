//! utility -- public re-export surface for the `utility` package.
//!
//! Import via the `utility` module in build.zig:
//!   const utility = @import("utility");

pub const Logger = @import("Logger.zig").Logger;
pub const Vfs = @import("Vfs.zig").Vfs;
pub const platform = @import("Platform.zig");
pub const simd = @import("Simd.zig");
pub const UnionFind = @import("UnionFind.zig").UnionFind;
pub const RingBuffer = @import("RingBuffer.zig").RingBuffer;

test {
    _ = @import("Logger.zig");
    _ = @import("Vfs.zig");
    _ = @import("Platform.zig");
    _ = @import("Simd.zig");
    _ = @import("UnionFind.zig");
    _ = @import("RingBuffer.zig");
}
