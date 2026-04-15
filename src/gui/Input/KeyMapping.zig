//! Key → ASCII character mapping and modifier packing.
//!
//! Extracted from Input.zig so the lookup table computation lives here
//! rather than in the input dispatcher.

const dvui = @import("dvui");

// ── Key to char lookup table ─────────────────────────────────────────── //

pub fn keyToChar(code: dvui.enums.Key, shift: bool) u8 {
    const key_int = @intFromEnum(code);
    if (key_int >= key_char_table.len) return 0;
    const entry = key_char_table[key_int];
    if (entry[0] == 0) return 0;
    return if (shift) entry[1] else entry[0];
}

pub fn packMods(ctrl: bool, shift: bool, alt: bool) u8 {
    return (@as(u8, @intFromBool(ctrl)) << 0) |
        (@as(u8, @intFromBool(shift)) << 1) |
        (@as(u8, @intFromBool(alt)) << 2);
}

const key_char_table = blk: {
    const Key = dvui.enums.Key;
    const max_key = max: {
        var m: comptime_int = 0;
        for (@typeInfo(Key).@"enum".fields) |fld| if (fld.value > m) {
            m = fld.value;
        };
        break :max m;
    };
    var table: [max_key + 1][2]u8 = .{.{ 0, 0 }} ** (max_key + 1);

    const mappings = .{
        .{ Key.a, 'a', 'A' },             .{ Key.b, 'b', 'B' },
        .{ Key.c, 'c', 'C' },             .{ Key.d, 'd', 'D' },
        .{ Key.e, 'e', 'E' },             .{ Key.f, 'f', 'F' },
        .{ Key.g, 'g', 'G' },             .{ Key.h, 'h', 'H' },
        .{ Key.i, 'i', 'I' },             .{ Key.j, 'j', 'J' },
        .{ Key.k, 'k', 'K' },             .{ Key.l, 'l', 'L' },
        .{ Key.m, 'm', 'M' },             .{ Key.n, 'n', 'N' },
        .{ Key.o, 'o', 'O' },             .{ Key.p, 'p', 'P' },
        .{ Key.q, 'q', 'Q' },             .{ Key.r, 'r', 'R' },
        .{ Key.s, 's', 'S' },             .{ Key.t, 't', 'T' },
        .{ Key.u, 'u', 'U' },             .{ Key.v, 'v', 'V' },
        .{ Key.w, 'w', 'W' },             .{ Key.x, 'x', 'X' },
        .{ Key.y, 'y', 'Y' },             .{ Key.z, 'z', 'Z' },
        .{ Key.zero, '0', ')' },          .{ Key.one, '1', '!' },
        .{ Key.two, '2', '@' },           .{ Key.three, '3', '#' },
        .{ Key.four, '4', '$' },          .{ Key.five, '5', '%' },
        .{ Key.six, '6', '^' },           .{ Key.seven, '7', '&' },
        .{ Key.eight, '8', '*' },         .{ Key.nine, '9', '(' },
        .{ Key.grave, '`', '~' },         .{ Key.minus, '-', '_' },
        .{ Key.equal, '=', '+' },         .{ Key.left_bracket, '[', '{' },
        .{ Key.right_bracket, ']', '}' }, .{ Key.backslash, '\\', '|' },
        .{ Key.semicolon, ';', ':' },     .{ Key.apostrophe, '\'', '"' },
        .{ Key.comma, ',', '<' },         .{ Key.period, '.', '>' },
        .{ Key.slash, '/', '?' },         .{ Key.space, ' ', ' ' },
    };

    for (mappings) |m| table[@intFromEnum(m[0])] = .{ m[1], m[2] };

    break :blk table;
};