//! File I/O submodule — CHN format parser/serializer and project config.

pub const Reader = @import("Reader.zig");
pub const Writer = @import("Writer.zig");
pub const Toml = @import("Toml.zig");

comptime {
    _ = Reader;
    _ = Writer;
    _ = Toml;
}
