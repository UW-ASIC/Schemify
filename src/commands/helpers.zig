//! Shared helpers used by multiple command handler files.
//! Centralises selection-index predicates and point comparison so each
//! handler module need not duplicate them.

const st = @import("state");
const std = @import("std");
pub const Point = st.Point;

/// Returns true when instance `i` is in the current selection bitset.
pub inline fn selInst(state: anytype, i: usize) bool {
    return i < state.selection.instances.bit_length and state.selection.instances.isSet(i);
}

/// Returns true when wire `i` is in the current selection bitset.
pub inline fn selWire(state: anytype, i: usize) bool {
    return i < state.selection.wires.bit_length and state.selection.wires.isSet(i);
}

/// Integer point equality.
pub inline fn ptEq(a: Point, b: Point) bool {
    return a[0] == b[0] and a[1] == b[1];
}

/// Ensures `bits` can store `idx`, then sets that bit.
pub inline fn setBit(bits: anytype, alloc: std.mem.Allocator, idx: usize) !void {
    if (idx >= bits.bit_length) try bits.resize(alloc, idx + 1, false);
    bits.set(idx);
}
