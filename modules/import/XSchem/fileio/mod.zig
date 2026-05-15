// fileio/mod.zig - XSchem file I/O entry points.

const reader = @import("reader.zig");
const writer = @import("writer.zig");

pub const parse = reader.parse;
pub const writeFile = writer.writeFile;
pub const serialize = writer.serialize;
