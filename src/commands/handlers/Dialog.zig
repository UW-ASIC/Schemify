const std = @import("std");
const types = @import("../types.zig");
const Immediate = types.Immediate;

pub fn handleDialog(imm: Immediate, state: anytype) void {
    switch (imm) {
        .open_find_dialog => { state.gui.cold.dialogs.find.is_open = true; state.setStatus("Find"); },
        .open_props_dialog, .edit_properties => {
            // Count selected instances to decide single vs multi-props dialog.
            if (state.active()) |fio| {
                if (fio.selection.instances.bit_length > 0) {
                    var it = fio.selection.instances.iterator(.{});
                    var sel_count: usize = 0;
                    var first_idx: ?usize = null;
                    while (it.next()) |idx| {
                        if (idx < fio.sch.instances.len) {
                            if (first_idx == null) first_idx = idx;
                            sel_count += 1;
                        }
                    }
                    if (sel_count > 1) {
                        const mpd = &state.gui.cold.dialogs.multi_props;
                        mpd.populateFrom(fio.sch.instances, fio.sch.instances.len, &fio.selection.instances, fio.sch.props.items, &fio.sch.strings);
                        mpd.is_open = true;
                        state.setStatus("Batch edit properties");
                        return;
                    } else if (sel_count == 1) {
                        const pd = &state.gui.cold.dialogs.props;
                        const idx = first_idx.?;
                        pd.inst_idx = idx;
                        pd.view_only = false;
                        pd.initialized = false;
                        pd.populateFrom(fio.sch.instances.get(idx), fio.sch.props.items, &fio.sch.strings);
                        pd.is_open = true;
                        state.setStatus("Properties");
                        return;
                    }
                }
            }
            // No selection: open empty single-props dialog
            state.gui.cold.dialogs.props.is_open = true;
            state.setStatus("Properties");
        },
        .open_spice_code_dialog => { state.gui.cold.dialogs.spice_code.is_open = true; state.setStatus("SPICE Code"); },
        .open_marketplace => { state.gui.cold.marketplace.visible = true; state.setStatus("Marketplace"); },
        .open_new_prim_dialog => { state.gui.cold.dialogs.new_prim.is_open = true; state.setStatus("New Primitive"); },
        .open_import_project => { state.gui.cold.dialogs.import_project.is_open = true; state.setStatus("Import Project"); },
        else => {},
    }
}
