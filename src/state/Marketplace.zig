//! Plugin Marketplace state — registry entries, status, and UI state for
//! the marketplace browser panel. Dominant type: `MarketplaceState`.

const std = @import("std");

/// One entry in the remote plugin registry.
/// All string fields are fixed-size buffers — no heap allocation needed.
pub const MarketplaceEntry = struct {
    id: [48]u8 = [_]u8{0} ** 48,
    name: [64]u8 = [_]u8{0} ** 64,
    author: [48]u8 = [_]u8{0} ** 48,
    version: [24]u8 = [_]u8{0} ** 24,
    desc: [200]u8 = [_]u8{0} ** 200,
    tags: [96]u8 = [_]u8{0} ** 96,
    repo_url: [200]u8 = [_]u8{0} ** 200,
    readme_url: [200]u8 = [_]u8{0} ** 200,
    dl_linux: [200]u8 = [_]u8{0} ** 200,
    installed: bool = false,
};

pub const MktStatus = enum(u8) { idle, fetching, done, failed };

pub const MarketplaceState = struct {
    visible: bool = false,
    entries: std.ArrayListUnmanaged(MarketplaceEntry) = .{},
    registry_status: MktStatus = .idle,
    selected: i16 = -1,
    readme_text: std.ArrayListUnmanaged(u8) = .{},
    readme_status: MktStatus = .idle,
    search_buf: [128]u8 = [_]u8{0} ** 128,
    custom_url_buf: [512]u8 = [_]u8{0} ** 512,
    install_msg: [256]u8 = [_]u8{0} ** 256,
    install_msg_len: u8 = 0,
    install_status: MktStatus = .idle,

    pub fn deinit(self: *MarketplaceState, alloc: std.mem.Allocator) void {
        self.entries.deinit(alloc);
        self.readme_text.deinit(alloc);
        self.* = .{};
    }
};

test "Expose struct size for MarketplaceState" {
    const print = @import("std").debug.print;
    print("MarketplaceState: {d}B\n", .{@sizeOf(MarketplaceState)});
}
