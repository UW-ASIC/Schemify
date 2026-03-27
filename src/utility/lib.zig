//! utility -- public re-export surface for the `utility` package.
//!
//! Import via the `utility` module in build.zig:
//!   const utility = @import("utility");

pub const Logger = @import("Logger.zig").Logger;
pub const Vfs = @import("Vfs.zig").Vfs;
pub const platform = @import("Platform.zig");
pub const simd = @import("Simd.zig");
pub const UnionFind = @import("UnionFind.zig").UnionFind;

// Phase 1: Foundation data structures
pub const Handle = @import("SlotMap.zig").Handle;
pub const SlotMap = @import("SlotMap.zig").SlotMap;
pub const SecondaryMap = @import("SlotMap.zig").SecondaryMap;
pub const SparseSet = @import("SparseSet.zig").SparseSet;
pub const RingBuffer = @import("RingBuffer.zig").RingBuffer;
pub const Pool = @import("Pool.zig").Pool;
pub const SmallVec = @import("SmallVec.zig").SmallVec;
pub const PerfectHash = @import("PerfectHash.zig").PerfectHash;
pub const ChdHash = @import("PerfectHash.zig").ChdHash;

test {
    _ = @import("SlotMap.zig");
    _ = @import("SparseSet.zig");
    _ = @import("RingBuffer.zig");
    _ = @import("Pool.zig");
    _ = @import("SmallVec.zig");
    _ = @import("PerfectHash.zig");
}
