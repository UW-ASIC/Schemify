/// Shared @cImport for the litehtml C bridge.
/// All modules must import this file rather than doing their own @cImport
/// to avoid Zig treating the types as distinct.
pub const bridge = @cImport({
    @cInclude("c_bridge.h");
});
