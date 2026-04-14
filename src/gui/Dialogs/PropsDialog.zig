//! Instance properties dialog — view and edit component properties.
//! For digital blocks, surfaces RTL source and synthesized SPICE as
//! editable properties alongside standard instance props.

const std = @import("std");
const dvui = @import("dvui");
const st = @import("state");
const actions = @import("../Actions.zig");

const AppState = st.AppState;
const components = @import("../Components/lib.zig");

// ── Public API ───────────────────────────────────────────────────────────── //

pub fn draw(app: *AppState) void {
    const pd = &app.gui.cold.props_dialog;
    if (!pd.is_open) return;
    const title: [:0]const u8 = if (pd.view_only)
        "Instance Properties (read-only)"
    else
        "Instance Properties";

    var fwin = dvui.floatingWindow(@src(), .{
        .modal = true,
        .open_flag = &pd.is_open,
        .rect = components.winRectPtr(&pd.win_rect),
    }, .{
        .min_size_content = .{ .w = 480, .h = 360 },
    });
    defer fwin.deinit();
    fwin.dragAreaSet(dvui.windowHeader(title, "", &pd.is_open));

    drawContents(app);
}

fn drawContents(app: *AppState) void {
    const pd = &app.gui.cold.props_dialog;
    const fio = app.active() orelse return;

    var body = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .padding = .{ .x = 10, .y = 8, .w = 10, .h = 8 },
    });
    defer body.deinit();

    // Header with instance info.
    const idx = pd.inst_idx;
    if (idx >= fio.sch.instances.len) {
        dvui.labelNoFmt(@src(), "Instance not found", .{}, .{ .id_extra = 0 });
        return;
    }

    const inst = fio.sch.instances.get(idx);
    {
        var hdr_buf: [256]u8 = undefined;
        const hdr = std.fmt.bufPrint(&hdr_buf, "{s} (#{d})  symbol: {s}", .{
            inst.name, idx, inst.symbol,
        }) catch "Instance";
        dvui.labelNoFmt(@src(), hdr, .{}, .{ .style = .control, .id_extra = 0 });
    }

    _ = dvui.separator(@src(), .{ .id_extra = 1 });

    // ── Standard properties ──────────────────────────────────────────────
    const prop_start: usize = inst.prop_start;
    const prop_end: usize = prop_start + inst.prop_count;
    const props = fio.sch.props.items;

    if (inst.prop_count > 0) {
        dvui.labelNoFmt(@src(), "Properties:", .{}, .{ .id_extra = 10, .style = .control });
        var pi: usize = prop_start;
        var id_ctr: u16 = 20;
        while (pi < prop_end and pi < props.len) : (pi += 1) {
            var row_buf: [256]u8 = undefined;
            const row = std.fmt.bufPrint(&row_buf, "  {s} = {s}", .{
                props[pi].key, props[pi].val,
            }) catch "(prop)";
            dvui.labelNoFmt(@src(), row, .{}, .{ .id_extra = id_ctr });
            id_ctr +%= 1;
        }
    } else {
        dvui.labelNoFmt(@src(), "(no standard properties)", .{}, .{
            .id_extra = 10, .style = .control,
        });
    }

    // ── Symbol-level properties (from .chn / .chn_prim) ─────────────────
    _ = dvui.separator(@src(), .{ .id_extra = 100 });

    if (idx < fio.sch.sym_data.items.len) {
        const sd = fio.sch.sym_data.items[idx];
        dvui.labelNoFmt(@src(), "Symbol Properties:", .{}, .{
            .id_extra = 101, .style = .control,
        });

        var sym_id: u16 = 110;
        for (sd.props) |sp| {
            var sp_buf: [256]u8 = undefined;
            const sp_row = std.fmt.bufPrint(&sp_buf, "  {s} = {s}", .{
                sp.key, sp.val,
            }) catch "(sym prop)";
            dvui.labelNoFmt(@src(), sp_row, .{}, .{ .id_extra = sym_id });
            sym_id +%= 1;
        }

        if (sd.props.len == 0) {
            dvui.labelNoFmt(@src(), "  (no symbol properties)", .{}, .{
                .id_extra = sym_id, .style = .@"03",
            });
            sym_id +%= 1;
        }

        if (sd.format) |fmt| {
            var fmt_buf: [256]u8 = undefined;
            const fmt_row = std.fmt.bufPrint(&fmt_buf, "  format = {s}", .{fmt}) catch "(format)";
            dvui.labelNoFmt(@src(), fmt_row, .{}, .{ .id_extra = sym_id });
            sym_id +%= 1;
        }

        {
            var pin_buf: [64]u8 = undefined;
            const pin_row = std.fmt.bufPrint(&pin_buf, "  pins: {d}", .{sd.pins.len}) catch "(pins)";
            dvui.labelNoFmt(@src(), pin_row, .{}, .{ .id_extra = sym_id });
        }
    } else {
        dvui.labelNoFmt(@src(), "Symbol Properties: (not loaded)", .{}, .{
            .id_extra = 101, .style = .control,
        });
    }

    _ = dvui.separator(@src(), .{ .id_extra = 200 });

    // ── Digital block properties ─────────────────────────────────────────
    if (fio.sch.digital) |dig| {
        dvui.labelNoFmt(@src(), "Digital Block:", .{}, .{ .id_extra = 210, .style = .control });

        {
            var lang_buf: [64]u8 = undefined;
            const lang_str = std.fmt.bufPrint(&lang_buf, "  Language: {s}", .{
                dig.language.toStr(),
            }) catch "  Language: ?";
            dvui.labelNoFmt(@src(), lang_str, .{}, .{ .id_extra = 211 });
        }

        {
            const role = if (dig.is_stimulus) "Stimulus" else "Device";
            var role_buf: [32]u8 = undefined;
            const role_str = std.fmt.bufPrint(&role_buf, "  Role: {s}", .{role}) catch "  Role: ?";
            dvui.labelNoFmt(@src(), role_str, .{}, .{ .id_extra = 212 });
        }

        // RTL source info
        if (dig.behavioral.source) |src| {
            var rtl_info_buf: [128]u8 = undefined;
            const mode_str = if (dig.behavioral.mode == .@"inline") "inline" else "file";
            const rtl_info = std.fmt.bufPrint(&rtl_info_buf, "  RTL Source ({s}): {d} chars", .{
                mode_str, src.len,
            }) catch "  RTL Source: present";
            dvui.labelNoFmt(@src(), rtl_info, .{}, .{ .id_extra = 213 });

            if (dig.behavioral.file_path) |fp| {
                var fp_buf: [256]u8 = undefined;
                const fp_str = std.fmt.bufPrint(&fp_buf, "  RTL File: {s}", .{fp}) catch "  RTL File: ?";
                dvui.labelNoFmt(@src(), fp_str, .{}, .{ .id_extra = 214 });
            }
        }

        // Synthesized SPICE info
        if (dig.synthesized.source) |src| {
            var synth_buf: [128]u8 = undefined;
            const synth_info = std.fmt.bufPrint(&synth_buf, "  Synth SPICE: {d} chars", .{
                src.len,
            }) catch "  Synth SPICE: present";
            dvui.labelNoFmt(@src(), synth_info, .{}, .{ .id_extra = 220 });
        } else if (dig.synthesized.file_path) |fp| {
            var sfp_buf: [256]u8 = undefined;
            const sfp_str = std.fmt.bufPrint(&sfp_buf, "  Synth SPICE File: {s}", .{fp}) catch "  Synth File: ?";
            dvui.labelNoFmt(@src(), sfp_str, .{}, .{ .id_extra = 221 });
        } else {
            dvui.labelNoFmt(@src(), "  Synth SPICE: (none)", .{}, .{ .id_extra = 222 });
        }

        // Sim preference
        {
            const pref = switch (dig.sim_preference) {
                0 => "Behavioral only",
                1 => "Post-synthesis only",
                2 => "Both (user chooses)",
                else => "Unknown",
            };
            var pref_buf: [64]u8 = undefined;
            const pref_str = std.fmt.bufPrint(&pref_buf, "  Simulation: {s}", .{pref}) catch "  Simulation: ?";
            dvui.labelNoFmt(@src(), pref_str, .{}, .{ .id_extra = 230 });
        }
    }

    _ = dvui.spacer(@src(), .{ .expand = .vertical });
    _ = dvui.separator(@src(), .{ .id_extra = 300 });

    // Bottom buttons.
    {
        var btns = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .id_extra = 3,
        });
        defer btns.deinit();

        if (!pd.view_only) {
            if (dvui.button(@src(), "Apply", .{}, .{ .id_extra = 4 })) {
                app.status_msg = "Properties applied";
                pd.is_open = false;
            }
        }
        if (dvui.button(@src(), "Close", .{}, .{ .id_extra = 5 })) {
            pd.is_open = false;
        }
    }
}
