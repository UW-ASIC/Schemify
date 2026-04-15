const std = @import("std");
const Allocator = std.mem.Allocator;
const List = std.ArrayListUnmanaged;

const sch = @import("../Schemify.zig");
const Schemify = sch.Schemify;

const h = @import("../helpers.zig");
const utility = @import("utility");
const simd = utility.simd;
const utils = @import("utils.zig");

pub const Writer = struct {
    pub fn writeCHN(a: Allocator, s: *Schemify, logger: ?*utility.Logger) ?[]u8 {
        s.logger = logger;
        var buf: List(u8) = .{};
        buf.ensureTotalCapacity(a, simd.estimateCHNSize(s)) catch {};
        s.emit(.info, "writing {s}: {d} instances, {d} pins", .{
            switch (s.stype) {
                .testbench => "testbench",
                .primitive => "primitive",
                .component => "component",
            },
            s.instances.len,
            s.pins.len,
        });
        writeCHNImpl(buf.writer(a), s, a) catch |e| {
            s.emit(.err, "write failed: {}", .{e});
            buf.deinit(a);
            return null;
        };
        return buf.toOwnedSlice(a) catch |e| {
            s.emit(.err, "write toOwnedSlice failed: {}", .{e});
            buf.deinit(a);
            return null;
        };
    }
};

// =============================================================================
// Internal implementation
// =============================================================================

fn writeCHNImpl(w: anytype, s: *const Schemify, a: Allocator) !void {
    const effective_stype: @TypeOf(s.stype) = if (s.stype == .component and s.pins.len == 0) .testbench else s.stype;

    // -- File header --
    switch (effective_stype) {
        .primitive => try w.writeAll("chn_prim 1\n"),
        .component => try w.writeAll("chn 1\n"),
        .testbench => try w.writeAll("chn_testbench 1\n"),
    }

    // -- SYMBOL section (component and primitive only) --
    if (effective_stype != .testbench) {
        try w.writeByte('\n');
        try w.writeAll("SYMBOL ");
        try w.writeAll(if (s.name.len > 0) s.name else "untitled");
        try w.writeByte('\n');

        // Symbol metadata lines: sym_prop key -> CHN field name
        const sym_meta = [_]struct { key: []const u8, field: []const u8 }{
            .{ .key = "description", .field = "desc" },
            .{ .key = "symbol_type", .field = "type" },
        };
        for (sym_meta) |entry| {
            if (h.findSymProp(s.sym_props.items, entry.key)) |val| {
                try w.writeAll("  ");
                try w.writeAll(entry.field);
                try w.writeAll(": ");
                try w.writeAll(val);
                try w.writeByte('\n');
            }
        }

        try utils.Pins.write(w, s);
        try utils.Params.write(w, s);

        // Spice metadata lines written as-is from sym_props
        const spice_meta_keys = [_][]const u8{ "spice_format", "spice_lib" };
        for (spice_meta_keys) |meta_key| {
            if (h.findSymProp(s.sym_props.items, meta_key)) |val| {
                try w.writeAll("  ");
                try w.writeAll(meta_key);
                try w.writeAll(": ");
                try w.writeAll(val);
                try w.writeByte('\n');
            }
        }

        // drawing
        try utils.Drawing.write(w, s);
    }

    // -- SCHEMATIC section (component and testbench only) --
    if (effective_stype != .primitive) {
        try w.writeByte('\n');
        if (effective_stype == .testbench) {
            try w.writeAll("TESTBENCH ");
            try w.writeAll(if (s.name.len > 0) s.name else "untitled");
            try w.writeByte('\n');
            try utils.Includes.write(w, s);
        } else {
            try w.writeAll("SCHEMATIC\n");
        }

        // instances
        try utils.Instances.write(w, s, a);


        // nets
        try utils.Nets.write(w, s, a);

        try utils.Analyses.write(w, s);
        try utils.Measures.write(w, s);
        try utils.CodeBlock.write(w, s);

        // annotations
        try utils.Annotations.write(w, s);

        // wires
        try utils.Wires.write(w, s);
    }

    // Plugin blocks
    for (s.plugin_blocks.items) |pb| {
        try utils.writePluginBlock(w, pb.name, pb.entries.items);
    }
}
