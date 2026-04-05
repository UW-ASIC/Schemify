//! Message reader -- decodes a host->plugin binary message batch.

const std = @import("std");
const types = @import("types.zig");

const Tag = types.Tag;
const InMsg = types.InMsg;
const HEADER_SZ = types.HEADER_SZ;

const Reader = @This();

/// Pointer to the input message buffer (zero-copy; valid for call duration).
buf: []const u8,
/// Current read position within `buf`.
pos: usize,

pub fn init(buf: []const u8) Reader {
    return .{ .buf = buf, .pos = 0 };
}

/// Returns the next host->plugin message, or null at end of buffer.
/// Skips unknown / plugin->host tags transparently.
/// Returns null on malformed input (truncated header or payload).
pub fn next(self: *Reader) ?InMsg {
    while (true) {
        if (self.pos + HEADER_SZ > self.buf.len) return null;

        const tag_byte = self.buf[self.pos];
        const payload_sz = std.mem.readInt(u16, self.buf[self.pos + 1 ..][0..2], .little);
        self.pos += HEADER_SZ;

        if (self.pos + payload_sz > self.buf.len) return null;

        const payload = self.buf[self.pos .. self.pos + payload_sz];
        const tag_enum = std.meta.intToEnum(Tag, tag_byte) catch {
            self.pos += payload_sz;
            continue;
        };

        if (!types.host_to_plugin_tag[@intFromEnum(tag_enum)]) {
            self.pos += payload_sz;
            continue;
        }

        const msg = types.parsePayload(tag_enum, payload) orelse return null;
        self.pos += payload_sz;
        return msg;
    }
}
