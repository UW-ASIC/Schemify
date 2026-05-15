//! Minimal host -> plugin message decoder. Zero-copy. Skips unknown/plugin -> host tags.

const std = @import("std");
const types = @import("types.zig");

const Reader = @This();

buf: []const u8,
pos: usize,

pub fn init(buf: []const u8) Reader {
    return .{ .buf = buf, .pos = 0 };
}

/// Returns the next host -> plugin message, or null at end / on malformed input.
pub fn next(self: *Reader) ?types.InMsg {
    while (true) {
        if (self.pos + types.HEADER_SZ > self.buf.len) return null;

        const tag_byte = self.buf[self.pos];
        const payload_sz = std.mem.readInt(u16, self.buf[self.pos + 1 ..][0..2], .little);
        self.pos += types.HEADER_SZ;

        if (self.pos + payload_sz > self.buf.len) return null;

        const payload = self.buf[self.pos .. self.pos + payload_sz];
        self.pos += payload_sz;

        if (!types.host_to_plugin_tag[tag_byte]) continue;

        const tag = std.meta.intToEnum(types.Tag, tag_byte) catch continue;
        if (types.parsePayload(tag, payload)) |msg| return msg;
        return null;
    }
}
