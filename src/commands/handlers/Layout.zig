const std = @import("std");
const core = @import("schematic");
const layout = core.layout;
const Devices = core.devices.Devices;
const types = @import("../types.zig");
const Undoable = types.Undoable;

pub fn handleAutoLayout(state: anytype) !void {
    const fio = state.active() orelse return;
    const sch = &fio.sch;
    const n = sch.instances.len;
    if (n == 0) {
        state.setStatus("Nothing to layout");
        return;
    }

    var arena_state = std.heap.ArenaAllocator.init(fio.alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const inst_kinds = sch.instances.items(.kind);
    const prop_starts = sch.instances.items(.prop_start);
    const prop_counts = sch.instances.items(.prop_count);

    // Build LayoutElement and DeviceKind slices from instances
    const elements = try arena.alloc(layout.LayoutElement, n);
    const kinds = try arena.alloc(core.types.DeviceKind, n);

    for (0..n) |i| {
        kinds[i] = inst_kinds[i];

        // Derive prefix from device kind
        const pfx = Devices.prefix_lut[@intFromEnum(inst_kinds[i])];
        const prefix: u8 = if (pfx != 0) std.ascii.toLower(pfx) else 'x';

        // Look up "model" property (resolve StringRef through pool)
        var model: ?[]const u8 = null;
        const ps: usize = prop_starts[i];
        const pc: usize = prop_counts[i];
        for (0..pc) |pi| {
            if (ps + pi < sch.props.items.len) {
                const prop = sch.props.items[ps + pi];
                if (std.mem.eql(u8, sch.str(prop.key), "model")) {
                    model = sch.str(prop.val);
                    break;
                }
            }
        }

        elements[i] = .{
            .prefix = prefix,
            .name = sch.str(sch.instances.items(.name)[i]),
            .nodes = &.{},
            .model = model,
        };
    }

    const placed = try layout.place(arena, elements, kinds);

    // Write back positions
    const xs = sch.instances.items(.x);
    const ys = sch.instances.items(.y);
    for (placed) |dev| {
        if (dev.elem_idx < n) {
            xs[dev.elem_idx] = dev.x;
            ys[dev.elem_idx] = dev.y;
        }
    }

    fio.dirty = true;
    state.setStatus("Auto-layout applied");
}
