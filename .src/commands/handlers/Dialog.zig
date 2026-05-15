//! Dialog command handlers — open various modal dialogs.

const std = @import("std");
const types = @import("../types.zig");
const Immediate = types.Immediate;

pub fn handleDialog(imm: Immediate, state: anytype) void {
    switch (imm) {
        .open_find_dialog => { state.gui.cold.find_dialog.is_open = true; state.setStatus("Find"); },
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
                        const mpd = &state.gui.cold.multi_props_dialog;
                        mpd.populateFrom(fio.sch.instances, fio.sch.instances.len, &fio.selection.instances, fio.sch.props.items);
                        mpd.is_open = true;
                        state.setStatus("Batch edit properties");
                        return;
                    } else if (sel_count == 1) {
                        const pd = &state.gui.cold.props_dialog;
                        const idx = first_idx.?;
                        pd.inst_idx = idx;
                        pd.view_only = false;
                        pd.initialized = false;
                        pd.populateFrom(fio.sch.instances.get(idx), fio.sch.props.items);
                        pd.is_open = true;
                        state.setStatus("Properties");
                        return;
                    }
                }
            }
            // No selection: open empty single-props dialog
            state.gui.cold.props_dialog.is_open = true;
            state.setStatus("Properties");
        },
        .open_spice_code_dialog => { state.gui.cold.spice_code_dialog.is_open = true; state.setStatus("SPICE Code"); },
        .open_marketplace => { state.gui.cold.marketplace.visible = true; state.setStatus("Marketplace"); },
        .open_new_prim_dialog => { state.gui.cold.new_prim_dialog.is_open = true; state.setStatus("New Primitive"); },
        .open_import_project => { state.gui.cold.import_project.is_open = true; state.setStatus("Import Project"); },
        else => {},
    }
}
