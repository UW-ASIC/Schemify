const std = @import("std");
const dvui = @import("dvui");
const utility = @import("utility");
const st = @import("state");
const AppState = st.AppState;
const keybinds = @import("Input/keybinds.zig");
const actions = @import("actions.zig");
const command = @import("commands");
const theme_config = @import("theme_config");
const core = @import("schematic");

// ── Generic dialog shell ─────────────────────────────────────────────────────

fn dialog(
    comptime title: [:0]const u8,
    open: *bool,
    win_rect: *st.WinRect,
    modal: bool,
    min_w: f32,
    min_h: f32,
    comptime drawContent: fn (*AppState) void,
    app: *AppState,
) void {
    if (!open.*) return;
    const bg = theme_config.chromeToolbarBg();
    var fwin = dvui.floatingWindow(@src(), .{
        .modal = modal,
        .open_flag = open,
        .rect = winRectPtr(win_rect),
    }, .{
        .min_size_content = .{ .w = min_w, .h = min_h },
        .background = true,
        .color_fill = .{ .r = bg.r, .g = bg.g, .b = bg.b, .a = 220 },
        .color_border = .{ .r = bg.r +| 30, .g = bg.g +| 30, .b = bg.b +| 30, .a = 255 },
    });
    defer fwin.deinit();
    fwin.dragAreaSet(dvui.windowHeader(title, "", open));
    drawContent(app);
}

inline fn winRectPtr(wr: *st.WinRect) *dvui.Rect {
    return @ptrCast(wr);
}

// ── Draw all dialogs (called once per frame) ─────────────────────────────────

pub fn drawAll(app: *AppState) void {
    drawPropsDialog(app);
    drawMultiPropsDialog(app);
    drawFindDialog(app);
    drawKeybindsDialog(app);
    drawSpiceCodeDialog(app);
    drawNewPrimDialog(app);
    drawMissingSymbols(app);
    drawImportDialog(app);
}

// ══════════════════════════════════════════════════════════════════════════════
//  PROPS DIALOG
// ══════════════════════════════════════════════════════════════════════════════

fn drawPropsDialog(app: *AppState) void {
    const pd = &app.gui.cold.dialogs.props;
    // Position in bottom-left of window
    const win = dvui.windowRect();
    const w: f32 = 520;
    const h: f32 = 440;
    pd.win_rect.x = 10;
    pd.win_rect.y = win.h - h - 10;
    pd.win_rect.w = w;
    pd.win_rect.h = h;
    dialog("Instance Properties", &pd.is_open, &pd.win_rect, false, w, h, drawPropsContent, app);
}

fn drawPropsContent(app: *AppState) void {
    const pd = &app.gui.cold.dialogs.props;
    const fio = app.active() orelse return;
    const accent = theme_config.chromeAccent();
    const muted = theme_config.chromeTextSecondary();

    var body = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .padding = .{ .x = 12, .y = 10, .w = 12, .h = 10 } });
    defer body.deinit();

    if (pd.inst_idx >= fio.sch.instances.len) {
        dvui.labelNoFmt(@src(), "Instance not found", .{}, .{ .id_extra = 0 });
        return;
    }

    const inst = fio.sch.instances.get(pd.inst_idx);

    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .id_extra = 2 });

    // ── Identity section ──
    dvui.labelNoFmt(@src(), "Identity", .{}, .{ .id_extra = 0, .style = .highlight, .color_text = accent });
    _ = dvui.separator(@src(), .{ .id_extra = 1 });
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = 10 });
        defer row.deinit();
        dvui.labelNoFmt(@src(), "Name", .{}, .{ .min_size_content = .{ .w = 100 }, .gravity_y = 0.5, .id_extra = 11 });
        var te = dvui.textEntry(@src(), .{
            .text = .{ .buffer = pd.name_buf[0..st.PropsDialogState.NAME_BUF_LEN] },
        }, .{ .id_extra = 12, .expand = .horizontal });
        te.deinit();
    }
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = 13 });
        defer row.deinit();
        dvui.labelNoFmt(@src(), "Symbol", .{}, .{ .min_size_content = .{ .w = 100 }, .gravity_y = 0.5, .id_extra = 14, .color_text = muted });
        dvui.labelNoFmt(@src(), fio.sch.str(inst.symbol), .{}, .{ .gravity_y = 0.5, .id_extra = 15, .color_text = muted });
    }
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = 16 });
        defer row.deinit();
        dvui.labelNoFmt(@src(), "Kind", .{}, .{ .min_size_content = .{ .w = 100 }, .gravity_y = 0.5, .id_extra = 17, .color_text = muted });
        dvui.labelNoFmt(@src(), @tagName(inst.kind), .{}, .{ .gravity_y = 0.5, .id_extra = 18, .color_text = muted });
    }

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .h = 6 }, .id_extra = 19 });

    // ── Position section ──
    dvui.labelNoFmt(@src(), "Position", .{}, .{ .id_extra = 20, .style = .highlight, .color_text = accent });
    _ = dvui.separator(@src(), .{ .id_extra = 21 });
    {
        var pb: [64]u8 = undefined;
        dvui.labelNoFmt(@src(), std.fmt.bufPrint(&pb, "x={d}  y={d}  rot={d}  flip={s}", .{
            inst.x, inst.y, inst.flags.rot, if (inst.flags.flip) "yes" else "no",
        }) catch "(pos)", .{}, .{ .id_extra = 22, .color_text = muted });
    }

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .h = 6 }, .id_extra = 29 });

    // ── Parameters section ──
    dvui.labelNoFmt(@src(), "Parameters", .{}, .{ .id_extra = 30, .style = .highlight, .color_text = accent });
    _ = dvui.separator(@src(), .{ .id_extra = 31 });

    const props = fio.sch.props.items;
    const start: usize = inst.prop_start;
    const count = @min(@as(usize, inst.prop_count), st.PropsDialogState.MAX_PROPS);

    if (count > 0) {
        for (0..count) |i| {
            const pi = start + i;
            if (pi >= props.len) break;
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = 100 + i });
            defer row.deinit();
            dvui.labelNoFmt(@src(), fio.sch.str(props[pi].key), .{}, .{ .min_size_content = .{ .w = 100 }, .gravity_y = 0.5, .id_extra = 200 + i });
            var te = dvui.textEntry(@src(), .{
                .text = .{ .buffer = &pd.prop_val_bufs[i] },
            }, .{ .id_extra = 300 + i, .expand = .horizontal });
            te.deinit();
        }
    } else {
        dvui.labelNoFmt(@src(), "(no parameters)", .{}, .{ .id_extra = 32, .color_text = muted });
    }

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .h = 6 }, .id_extra = 499 });

    // ── Symbol Info section ──
    if (pd.inst_idx < fio.sch.sym_data.items.len) {
        const sd = fio.sch.sym_data.items[pd.inst_idx];
        dvui.labelNoFmt(@src(), "Symbol Info", .{}, .{ .id_extra = 510, .style = .highlight, .color_text = accent });
        _ = dvui.separator(@src(), .{ .id_extra = 511 });
        {
            const fmt = fio.sch.str(sd.format);
            if (fmt.len > 0) {
                var fb: [256]u8 = undefined;
                dvui.labelNoFmt(@src(), std.fmt.bufPrint(&fb, "format: {s}", .{fmt}) catch "(format)", .{}, .{ .id_extra = 512, .color_text = muted });
            }
        }
        {
            var pb2: [64]u8 = undefined;
            dvui.labelNoFmt(@src(), std.fmt.bufPrint(&pb2, "pins: {d}", .{sd.pins.len}) catch "(pins)", .{}, .{ .id_extra = 513, .color_text = muted });
        }
        for (sd.props, 0..) |sp, si| {
            var sb: [256]u8 = undefined;
            dvui.labelNoFmt(@src(), std.fmt.bufPrint(&sb, "{s} = {s}", .{ fio.sch.str(sp.key), fio.sch.str(sp.val) }) catch "(sym prop)", .{}, .{ .id_extra = 520 + si, .color_text = muted });
        }
    }

    scroll.deinit();

    _ = dvui.separator(@src(), .{ .id_extra = 700 });

    // ── Bottom buttons ──
    {
        var btns = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = 3 });
        defer btns.deinit();

        if (dvui.button(@src(), "Apply", .{}, .{ .id_extra = 4, .style = .highlight })) {
            applyPropsChanges(app);
        }
        _ = dvui.spacer(@src(), .{ .expand = .horizontal, .id_extra = 6 });
        if (dvui.button(@src(), "Close", .{}, .{ .id_extra = 5 })) pd.is_open = false;
    }
}

fn applyPropsChanges(app: *AppState) void {
    const pd = &app.gui.cold.dialogs.props;
    const fio = app.active() orelse return;
    if (pd.inst_idx >= fio.sch.instances.len) return;

    const inst = fio.sch.instances.get(pd.inst_idx);

    // Apply name change
    const new_name = sliceToNull(&pd.name_buf);
    if (!std.mem.eql(u8, new_name, fio.sch.str(inst.name))) {
        actions.enqueue(app, .{ .undoable = .{ .rename_instance = .{
            .idx = @intCast(pd.inst_idx),
            .new_name = new_name,
        } } }, "Renamed");
    }

    // Apply property changes
    const props = fio.sch.props.items;
    const start: usize = inst.prop_start;
    const count = @min(@as(usize, inst.prop_count), st.PropsDialogState.MAX_PROPS);
    for (0..count) |i| {
        const pi = start + i;
        if (pi >= props.len) break;
        const new_val = sliceToNull(&pd.prop_val_bufs[i]);
        if (!std.mem.eql(u8, new_val, fio.sch.str(props[pi].val))) {
            actions.enqueue(app, .{ .undoable = .{ .set_instance_prop = .{
                .idx = @intCast(pd.inst_idx),
                .key = fio.sch.str(props[pi].key),
                .val = new_val,
            } } }, "Property set");
        }
    }

    app.status_msg = "Properties applied";
    pd.is_open = false;
}

/// Return a slice up to the first null byte.
fn sliceToNull(buf: []const u8) []const u8 {
    return if (std.mem.indexOfScalar(u8, buf, 0)) |end| buf[0..end] else buf;
}

// ══════════════════════════════════════════════════════════════════════════════
//  MULTI PROPS DIALOG
// ══════════════════════════════════════════════════════════════════════════════

fn drawMultiPropsDialog(app: *AppState) void {
    const mpd = &app.gui.cold.dialogs.multi_props;
    dialog("Batch Edit Properties", &mpd.is_open, &mpd.win_rect, true, 520, 360, drawMultiPropsContent, app);
}

fn drawMultiPropsContent(app: *AppState) void {
    const mpd = &app.gui.cold.dialogs.multi_props;
    const fio = app.active() orelse return;

    var body = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .padding = .{ .x = 10, .y = 8, .w = 10, .h = 8 } });
    defer body.deinit();

    if (fio.selection.instances.bit_length == 0) { dvui.labelNoFmt(@src(), "No instances selected", .{}, .{ .id_extra = 0 }); return; }

    // Header: count of selected instances
    var sel_count: usize = 0;
    { var it = fio.selection.instances.iterator(.{}); while (it.next()) |_| sel_count += 1; }
    { var hb: [64]u8 = undefined; dvui.labelNoFmt(@src(), std.fmt.bufPrint(&hb, "{d} instances selected", .{sel_count}) catch "Selected", .{}, .{ .id_extra = 1, .style = .control }); }
    _ = dvui.separator(@src(), .{ .id_extra = 2 });

    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .id_extra = 3 });

    // List selected instance names (read-only summary)
    {
        var it2 = fio.selection.instances.iterator(.{});
        var id: u16 = 10;
        while (it2.next()) |idx| {
            if (idx >= fio.sch.instances.len) continue;
            const inst = fio.sch.instances.get(idx);
            var nb: [128]u8 = undefined;
            dvui.labelNoFmt(@src(), std.fmt.bufPrint(&nb, "  {s} ({s})", .{ fio.sch.str(inst.name), fio.sch.str(inst.symbol) }) catch "(instance)", .{}, .{ .id_extra = id });
            id +%= 1;
            if (id > 100) { dvui.labelNoFmt(@src(), "  ... (more)", .{}, .{ .id_extra = id }); break; }
        }
    }

    _ = dvui.separator(@src(), .{ .id_extra = 200 });

    // Editable common properties
    if (mpd.common_count == 0) {
        dvui.labelNoFmt(@src(), "(no common properties across selected instances)", .{}, .{ .id_extra = 201, .style = .control });
    } else {
        dvui.labelNoFmt(@src(), "Common Properties (edit to apply to all):", .{}, .{ .id_extra = 202, .style = .control });
        for (0..mpd.common_count) |i| {
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = 300 + i });
            defer row.deinit();

            const key = sliceToNull(&mpd.key_bufs[i]);

            // Show "(mixed)" indicator for non-uniform values
            if (!mpd.was_uniform[i]) {
                var lbl_buf: [80]u8 = undefined;
                dvui.labelNoFmt(@src(), std.fmt.bufPrint(&lbl_buf, "{s} (mixed)", .{key}) catch key, .{}, .{ .min_size_content = .{ .w = 130 }, .gravity_y = 0.5, .id_extra = 400 + i });
            } else {
                dvui.labelNoFmt(@src(), key, .{}, .{ .min_size_content = .{ .w = 130 }, .gravity_y = 0.5, .id_extra = 400 + i });
            }

            var te = dvui.textEntry(@src(), .{
                .text = .{ .buffer = &mpd.val_bufs[i] },
            }, .{ .id_extra = 500 + i, .expand = .horizontal });
            te.deinit();
        }
    }

    scroll.deinit();

    _ = dvui.separator(@src(), .{ .id_extra = 700 });

    // Bottom buttons
    var btns = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = 901 });
    defer btns.deinit();

    if (mpd.common_count > 0) {
        if (dvui.button(@src(), "Apply to All", .{}, .{ .id_extra = 903 })) {
            applyMultiPropsChanges(app);
        }
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8 }, .id_extra = 904 });
    }
    if (dvui.button(@src(), "Close", .{}, .{ .id_extra = 902 })) mpd.is_open = false;
}

fn applyMultiPropsChanges(app: *AppState) void {
    const mpd = &app.gui.cold.dialogs.multi_props;
    const fio = app.active() orelse return;

    var applied: usize = 0;

    for (0..mpd.common_count) |i| {
        const new_val = sliceToNull(&mpd.val_bufs[i]);
        const key = sliceToNull(&mpd.key_bufs[i]);

        // Skip empty values on properties that were mixed (user hasn't typed anything)
        if (!mpd.was_uniform[i] and new_val.len == 0) continue;

        // Skip if value unchanged from original (uniform case)
        if (mpd.was_uniform[i]) {
            const orig_val = sliceToNull(&mpd.orig_vals[i]);
            if (std.mem.eql(u8, new_val, orig_val)) continue;
        }

        // Apply to every selected instance that has this property
        var it = fio.selection.instances.iterator(.{});
        while (it.next()) |idx| {
            if (idx >= fio.sch.instances.len) continue;
            const inst = fio.sch.instances.get(idx);
            const start: usize = inst.prop_start;
            const count: usize = @min(@as(usize, inst.prop_count), fio.sch.props.items.len -| start);

            // Verify this instance actually has this key before applying
            for (0..count) |pi| {
                const prop = fio.sch.props.items[start + pi];
                if (std.mem.eql(u8, fio.sch.str(prop.key), key)) {
                    if (!std.mem.eql(u8, fio.sch.str(prop.val), new_val)) {
                        actions.enqueue(app, .{ .undoable = .{ .set_instance_prop = .{
                            .idx = @intCast(idx),
                            .key = key,
                            .val = new_val,
                        } } }, "Batch property set");
                        applied += 1;
                    }
                    break;
                }
            }
        }
    }

    if (applied > 0) {
        var msg_buf: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "Applied {d} property change(s)", .{applied}) catch "Properties applied";
        app.setStatusBuf(msg);
    } else {
        app.status_msg = "No changes to apply";
    }
    mpd.is_open = false;
}

// ══════════════════════════════════════════════════════════════════════════════
//  FIND DIALOG
// ══════════════════════════════════════════════════════════════════════════════

fn drawFindDialog(app: *AppState) void {
    const fd = &app.gui.cold.dialogs.find;
    dialog("Find / Select", &fd.is_open, &fd.win_rect, false, 320, 200, drawFindContent, app);
}

fn drawFindContent(app: *AppState) void {
    const fd = &app.gui.cold.dialogs.find;

    var body = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .padding = .{ .x = 10, .y = 8, .w = 10, .h = 8 } });
    defer body.deinit();

    // ── Query row: label + text entry + Search button ──
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = 0 });
        defer row.deinit();
        dvui.labelNoFmt(@src(), "Search:", .{}, .{ .min_size_content = .{ .w = 55 }, .gravity_y = 0.5, .id_extra = 1 });
        var te = dvui.textEntry(@src(), .{
            .text = .{ .buffer = &fd.query_buf },
            .placeholder = "instance name...",
        }, .{ .id_extra = 2, .expand = .horizontal });
        if (te.text_changed) {
            fd.query_len = std.mem.indexOfScalar(u8, &fd.query_buf, 0) orelse fd.query_buf.len;
            fd.result_count = countMatches(app);
        }
        if (te.enter_pressed) {
            fd.query_len = std.mem.indexOfScalar(u8, &fd.query_buf, 0) orelse fd.query_buf.len;
            fd.result_count = countMatches(app);
        }
        te.deinit();
        if (dvui.button(@src(), "Search", .{}, .{ .id_extra = 3, .gravity_y = 0.5 })) {
            fd.query_len = std.mem.indexOfScalar(u8, &fd.query_buf, 0) orelse fd.query_buf.len;
            fd.result_count = countMatches(app);
        }
    }

    _ = dvui.separator(@src(), .{ .id_extra = 4 });

    // ── Result count ──
    {
        var cb: [64]u8 = undefined;
        dvui.labelNoFmt(@src(), std.fmt.bufPrint(&cb, "{d} match(es)", .{fd.result_count}) catch "?", .{}, .{ .id_extra = 5, .style = .control });
    }

    _ = dvui.spacer(@src(), .{ .expand = .vertical, .id_extra = 6 });
    _ = dvui.separator(@src(), .{ .id_extra = 7 });

    // ── Bottom buttons ──
    {
        var btns = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = 8 });
        defer btns.deinit();
        if (dvui.button(@src(), "Select All Matches", .{}, .{ .id_extra = 9 })) {
            selectAllMatches(app);
            fd.is_open = false;
        }
        if (dvui.button(@src(), "Close", .{}, .{ .id_extra = 10 })) fd.is_open = false;
    }
}

fn countMatches(app: *AppState) usize {
    const fd = &app.gui.cold.dialogs.find;
    const query = fd.query_buf[0..fd.query_len];
    if (query.len == 0) return 0;
    const doc = app.active() orelse return 0;
    const name_refs = doc.sch.instances.items(.name);
    var count: usize = 0;
    for (0..doc.sch.instances.len) |i| {
        if (containsInsensitive(doc.sch.str(name_refs[i]), query)) count += 1;
    }
    return count;
}

fn selectAllMatches(app: *AppState) void {
    const fd = &app.gui.cold.dialogs.find;
    const query = fd.query_buf[0..fd.query_len];
    if (query.len == 0) {
        app.status_msg = "No search query";
        return;
    }

    const doc = app.active() orelse {
        app.status_msg = "No active document";
        return;
    };
    const a = app.allocator();
    doc.selection.ensureCapacity(a, doc.sch.instances.len, doc.sch.wires.len, false) catch return;
    doc.selection.clear();

    var count: usize = 0;
    const name_refs = doc.sch.instances.items(.name);
    for (0..doc.sch.instances.len) |i| {
        if (containsInsensitive(doc.sch.str(name_refs[i]), query)) {
            doc.selection.instances.set(i);
            count += 1;
        }
    }

    fd.result_count = count;
    if (count > 0) {
        app.status_msg = "Matched instances selected";
    } else {
        app.status_msg = "No matches found";
    }
}

fn containsInsensitive(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    const end = haystack.len - needle.len + 1;
    for (0..end) |i| {
        var match = true;
        for (0..needle.len) |j| {
            if (toLowerA(haystack[i + j]) != toLowerA(needle[j])) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

fn toLowerA(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

// ══════════════════════════════════════════════════════════════════════════════
//  KEYBINDS DIALOG
// ══════════════════════════════════════════════════════════════════════════════

fn drawKeybindsDialog(app: *AppState) void {
    const kd = &app.gui.cold.dialogs.keybinds;
    // Sync from keybinds_open flag
    kd.is_open = kd.is_open or app.gui.cold.dialogs.keybinds_open;
    app.gui.cold.dialogs.keybinds_open = false;
    dialog("Keyboard Shortcuts", &kd.is_open, &kd.win_rect, false, 500, 400, drawKeybindsContent, app);
}

fn drawKeybindsContent(app: *AppState) void {
    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
    defer scroll.deinit();

    for (keybinds.static_keybinds, 0..) |kb, i| {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = i });
        defer row.deinit();

        var buf: [32]u8 = undefined;
        const cs: []const u8 = if (kb.ctrl) "Ctrl+" else "";
        const ss: []const u8 = if (kb.shift) "Shift+" else "";
        const as: []const u8 = if (kb.alt) "Alt+" else "";
        dvui.labelNoFmt(@src(), std.fmt.bufPrint(&buf, "{s}{s}{s}{s}", .{ cs, ss, as, @tagName(kb.key) }) catch "?", .{}, .{ .min_size_content = .{ .w = 150 }, .id_extra = i });
        const astr: []const u8 = switch (kb.action) {
            .queue => |q| q.msg,
            .gui => |gg| @tagName(gg),
        };
        dvui.labelNoFmt(@src(), astr, .{}, .{ .expand = .horizontal, .id_extra = i + 1000 });
    }
    if (dvui.button(@src(), "Close [Esc]", .{}, .{})) app.gui.cold.dialogs.keybinds.is_open = false;
}

// ══════════════════════════════════════════════════════════════════════════════
//  SPICE CODE DIALOG
// ══════════════════════════════════════════════════════════════════════════════

fn drawSpiceCodeDialog(app: *AppState) void {
    const sd = &app.gui.cold.dialogs.spice_code;
    dialog("SPICE Netlist", &sd.is_open, &sd.win_rect, true, 640, 440, drawSpiceContent, app);
}

fn drawSpiceContent(app: *AppState) void {
    var body = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .padding = .{ .x = 8, .y = 6, .w = 8, .h = 6 } });
    defer body.deinit();
    const netlist = app.last_netlist[0..app.last_netlist_len];
    if (netlist.len == 0) {
        dvui.labelNoFmt(@src(), "No netlist generated yet.", .{}, .{ .id_extra = 0, .style = .control, .gravity_x = 0.5, .gravity_y = 0.5 });
        return;
    }
    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .id_extra = 1 });
    defer scroll.deinit();
    var ln: usize = 0;
    var rest = netlist;
    while (rest.len > 0) {
        const nl = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
        dvui.labelNoFmt(@src(), rest[0..nl], .{}, .{ .id_extra = ln, .font = .theme(.mono) });
        rest = if (nl < rest.len) rest[nl + 1 ..] else &.{};
        ln += 1;
    }
}

// ══════════════════════════════════════════════════════════════════════════════
//  NEW PRIMITIVE DIALOG
// ══════════════════════════════════════════════════════════════════════════════

fn drawNewPrimDialog(app: *AppState) void {
    const npd = &app.gui.cold.dialogs.new_prim;
    dialog("New Primitive", &npd.is_open, &npd.win_rect, true, 540, 440, drawNewPrimContent, app);
}

fn drawNewPrimContent(app: *AppState) void {
    const npd = &app.gui.cold.dialogs.new_prim;

    var body = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .padding = .{ .x = 10, .y = 8, .w = 10, .h = 8 } });
    defer body.deinit();

    dvui.labelNoFmt(@src(), "Create a new .chn_prim primitive file.", .{}, .{ .id_extra = 0, .style = .control });
    _ = dvui.separator(@src(), .{ .id_extra = 1 });

    // ── Name ──
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = 10 });
        defer row.deinit();
        dvui.labelNoFmt(@src(), "Name", .{}, .{ .min_size_content = .{ .w = 80 }, .gravity_y = 0.5, .id_extra = 11 });
        var te = dvui.textEntry(@src(), .{
            .text = .{ .buffer = &npd.name_buf },
            .placeholder = "my_device",
        }, .{ .id_extra = 12, .expand = .horizontal });
        te.deinit();
    }

    _ = dvui.separator(@src(), .{ .id_extra = 19 });

    // ── Primitive type selector ──
    dvui.labelNoFmt(@src(), "Type:", .{}, .{ .id_extra = 20, .style = .control });
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = 21 });
        defer row.deinit();

        const Pt = st.NewPrimDialogState.PrimType;
        inline for (.{ .{ Pt.spice, "SPICE" }, .{ Pt.behavioral, "Behavioral" }, .{ Pt.digital, "Digital" } }, 0..) |entry, bi| {
            if (dvui.button(@src(), entry[1], .{}, .{
                .id_extra = 30 + bi,
                .style = if (npd.prim_type == entry[0]) .highlight else .control,
                .margin = .{ .x = 0, .y = 0, .w = 4, .h = 0 },
            })) {
                npd.prim_type = entry[0];
            }
        }
    }

    _ = dvui.separator(@src(), .{ .id_extra = 39 });

    // ── Pins (comma-separated) ──
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = 40 });
        defer row.deinit();
        dvui.labelNoFmt(@src(), "Pins", .{}, .{ .min_size_content = .{ .w = 80 }, .gravity_y = 0.5, .id_extra = 41 });
        var te = dvui.textEntry(@src(), .{
            .text = .{ .buffer = &npd.pins_buf },
            .placeholder = "in,out,vdd,gnd",
        }, .{ .id_extra = 42, .expand = .horizontal });
        te.deinit();
    }

    _ = dvui.separator(@src(), .{ .id_extra = 49 });

    // ── Description of what will be created ──
    {
        const prim_type_desc: []const u8 = switch (npd.prim_type) {
            .spice => "SPICE subcircuit (.SUBCKT) with a template netlist body.",
            .behavioral => "Behavioral source (B-element) with an expression template.",
            .digital => "Digital HDL wrapper with a Verilog/VHDL stub.",
        };
        dvui.labelNoFmt(@src(), prim_type_desc, .{}, .{ .id_extra = 50, .style = .control });
    }

    _ = dvui.spacer(@src(), .{ .expand = .vertical, .id_extra = 59 });

    // Status
    if (npd.status_msg.len > 0) {
        dvui.labelNoFmt(@src(), npd.status_msg, .{}, .{ .id_extra = 60, .style = .err });
    }

    _ = dvui.separator(@src(), .{ .id_extra = 69 });

    // ── Bottom buttons ──
    var btns = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = 70 });
    defer btns.deinit();

    if (dvui.button(@src(), "Create", .{}, .{ .id_extra = 71 })) {
        createPrimitiveFile(app);
    }
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8 }, .id_extra = 72 });
    if (dvui.button(@src(), "Close", .{}, .{ .id_extra = 73 })) npd.is_open = false;
}

fn createPrimitiveFile(app: *AppState) void {
    const npd = &app.gui.cold.dialogs.new_prim;
    const name = sliceToNull(&npd.name_buf);
    if (name.len == 0) {
        npd.status_msg = "Name cannot be empty";
        return;
    }

    const pins_raw = sliceToNull(&npd.pins_buf);

    // Parse comma-separated pins into formatted pin lines
    var pin_lines_buf: [512]u8 = undefined;
    var pin_pos_buf: [512]u8 = undefined;
    var pin_list_buf: [256]u8 = undefined;
    var pl_len: usize = 0;
    var pp_len: usize = 0;
    var plist_len: usize = 0;
    var pin_count: usize = 0;
    const default_pins = "in,out";
    const pins_src = if (pins_raw.len > 0) pins_raw else default_pins;

    var pin_it = std.mem.splitScalar(u8, pins_src, ',');
    while (pin_it.next()) |raw_pin| {
        const pin = std.mem.trim(u8, raw_pin, " \t");
        if (pin.len == 0) continue;
        const y: i32 = @as(i32, @intCast(pin_count)) * 10 - 10;
        const x: i32 = if (pin_count % 2 == 0) -30 else 30;
        const dir: []const u8 = if (pin_count == 0) "i" else if (pin_count == 1) "o" else "io";
        const pl = std.fmt.bufPrint(pin_lines_buf[pl_len..], "    {s}  {s}\n", .{ pin, dir }) catch break;
        pl_len += pl.len;
        const pp = std.fmt.bufPrint(pin_pos_buf[pp_len..], "      {s}: ({d},{d})\n", .{ pin, x, y }) catch break;
        pp_len += pp.len;
        if (plist_len > 0) {
            if (plist_len < pin_list_buf.len) { pin_list_buf[plist_len] = ' '; plist_len += 1; }
        }
        const pn = std.fmt.bufPrint(pin_list_buf[plist_len..], "{s}", .{pin}) catch break;
        plist_len += pn.len;
        pin_count += 1;
    }
    if (pin_count == 0) { npd.status_msg = "At least one pin required"; return; }

    const pin_lines = pin_lines_buf[0..pl_len];
    const pin_positions = pin_pos_buf[0..pp_len];

    // Build the .chn_prim content
    var content_buf: [2048]u8 = undefined;
    const content = switch (npd.prim_type) {
        .spice => std.fmt.bufPrint(&content_buf,
            \\chn_prim 1.0
            \\
            \\SYMBOL {s}
            \\  desc: SPICE subcircuit
            \\  pins [{d}]:
            \\{s}  params [2]:
            \\    lib_file =
            \\    cell_name = {s}
            \\  block_type: lib
            \\  spice_prefix: X
            \\  spice_format: "@name @pins"
            \\  drawing:
            \\    rect: (-30,-30) (30,30)
            \\    text: (0,0) "SPICE"
            \\    pin_positions:
            \\{s}
        , .{ name, pin_count, pin_lines, name, pin_positions }),
        .behavioral => std.fmt.bufPrint(&content_buf,
            \\chn_prim 1.0
            \\
            \\SYMBOL {s}
            \\  desc: Behavioral source
            \\  pins [{d}]:
            \\{s}  params [2]:
            \\    expr = 0
            \\    bkind = V
            \\  spice_prefix: B
            \\  spice_format: "@name @pins @bkind={{@expr}}"
            \\  drawing:
            \\    rect: (-12,-15) (12,15)
            \\    text: (0,0) "B"
            \\    text: (18,0) "@name"
            \\    pin_positions:
            \\{s}
        , .{ name, pin_count, pin_lines, pin_positions }),
        .digital => std.fmt.bufPrint(&content_buf,
            \\chn_prim 1.0
            \\
            \\SYMBOL {s}
            \\  desc: Digital RTL block
            \\  pins [{d}]:
            \\{s}  params [3]:
            \\    source_file =
            \\    top_module = {s}
            \\    language = verilog
            \\  block_type: digital
            \\  spice_prefix: X
            \\  spice_format: "@name @pins"
            \\  drawing:
            \\    rect: (-40,-30) (40,30)
            \\    text: (0,0) "DIGITAL"
            \\    pin_positions:
            \\{s}
        , .{ name, pin_count, pin_lines, name, pin_positions }),
    } catch {
        npd.status_msg = "Content too long";
        return;
    };

    // Write the file
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}.chn_prim", .{name}) catch {
        npd.status_msg = "Name too long";
        return;
    };

    utility.platform.fs.cwd().writeFile(.{ .sub_path = path, .data = content }) catch {
        npd.status_msg = "Failed to write file";
        return;
    };

    app.status_msg = "Primitive created";
    npd.status_msg = "";
    npd.is_open = false;
}

// ══════════════════════════════════════════════════════════════════════════════
//  MISSING SYMBOLS PANEL
// ══════════════════════════════════════════════════════════════════════════════

var ms_open: bool = true;
var ms_last_count: usize = 0;

fn drawMissingSymbols(app: *AppState) void {
    const doc = app.active() orelse return;
    const count = doc.missing_symbols.count();
    if (count != ms_last_count) { ms_last_count = count; ms_open = (count > 0); }
    if (count == 0 or !ms_open) return;

    const ms_bg = theme_config.chromeToolbarBg();
    var fwin = dvui.floatingWindow(@src(), .{ .modal = false, .open_flag = &ms_open }, .{
        .min_size_content = .{ .w = 320, .h = 180 }, .max_size_content = .{ .w = 520, .h = 420 },
        .background = true,
        .color_fill = .{ .r = ms_bg.r, .g = ms_bg.g, .b = ms_bg.b, .a = 220 },
        .color_border = .{ .r = ms_bg.r +| 30, .g = ms_bg.g +| 30, .b = ms_bg.b +| 30, .a = 255 },
    });
    defer fwin.deinit();
    var tb: [64]u8 = undefined;
    fwin.dragAreaSet(dvui.windowHeader(std.fmt.bufPrintZ(&tb, "Missing Symbols ({d})", .{count}) catch "Missing Symbols", "", &ms_open));

    { var hdr = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .padding = .all(6) }); defer hdr.deinit();
      dvui.labelNoFmt(@src(), "These instance symbols could not be found on disk:", .{}, .{ .style = .err }); }

    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
    defer scroll.deinit();
    for (doc.missing_symbols.keys(), 0..) |name, i| {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .padding = .all(2), .id_extra = i });
        defer row.deinit();
        dvui.labelNoFmt(@src(), "\xe2\x80\xa2", .{}, .{ .id_extra = i });
        dvui.labelNoFmt(@src(), name, .{}, .{ .expand = .horizontal, .id_extra = i + 100_000 });
    }
}

// ======================================================================
//  SETTINGS DIALOG
// ======================================================================

// ── Import Dialog ────────────────────────────────────────────────────────────

const external = @import("import");

fn drawImportDialog(app: *AppState) void {
    const imp = &app.gui.cold.dialogs.import_project;
    dialog("Import External Project", &imp.is_open, &imp.win_rect, true, 520, 320, drawImportContent, app);
}

fn detectFormat(path: []const u8) st.ImportDialogState.Format {
    const ext = std.fs.path.extension(path);
    if (ext.len == 0) return .unknown;
    if (std.mem.eql(u8, ext, ".sch")) return .xschem;
    if (std.mem.eql(u8, ext, ".spice")) return .spice;
    if (std.mem.eql(u8, ext, ".sp")) return .spice;
    if (std.mem.eql(u8, ext, ".cir")) return .spice;
    if (std.mem.eql(u8, ext, ".net")) return .spice;
    if (std.mem.eql(u8, ext, ".oa")) return .virtuoso;
    if (std.mem.eql(u8, ext, ".cellview")) return .virtuoso;
    return .unknown;
}

fn drawImportContent(app: *AppState) void {
    const imp = &app.gui.cold.dialogs.import_project;

    var body = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .padding = .{ .x = 12, .y = 10, .w = 12, .h = 10 } });
    defer body.deinit();

    // File path text entry
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = 700 });
        defer row.deinit();
        dvui.labelNoFmt(@src(), "File:", .{}, .{ .min_size_content = .{ .w = 60 }, .gravity_y = 0.5, .id_extra = 701 });
        var te = dvui.textEntry(@src(), .{
            .text = .{ .buffer = &imp.path_buf },
            .placeholder = "/path/to/schematic.sch",
        }, .{ .id_extra = 702, .expand = .horizontal });
        const entered = te.getText();
        imp.path_len = entered.len;
        const detected = detectFormat(entered);
        if (detected != .unknown) imp.format = detected;
        te.deinit();
        if (dvui.button(@src(), "Browse...", .{}, .{ .id_extra = 703, .gravity_y = 0.5 })) {
            app.open_file_explorer = true;
        }
    }

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .h = 6 }, .id_extra = 705 });

    // Format selector buttons
    {
        dvui.labelNoFmt(@src(), "Format:", .{}, .{ .id_extra = 709 });
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .h = 4 }, .id_extra = 710 });
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = 711 });
        defer row.deinit();

        const accent = theme_config.chromeAccent();
        const sel_fill = dvui.Color{ .r = accent.r / 3, .g = accent.g / 3, .b = accent.b / 2, .a = 200 };

        if (dvui.button(@src(), "XSchem", .{}, .{
            .id_extra = 712,
            .color_fill = if (imp.format == .xschem) sel_fill else null,
        })) imp.format = .xschem;

        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 6 }, .id_extra = 713 });

        if (dvui.button(@src(), "SPICE", .{}, .{
            .id_extra = 714,
            .color_fill = if (imp.format == .spice) sel_fill else null,
        })) imp.format = .spice;

        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 6 }, .id_extra = 715 });

        if (dvui.button(@src(), "Virtuoso", .{}, .{
            .id_extra = 716,
            .color_fill = if (imp.format == .virtuoso) sel_fill else null,
        })) imp.format = .virtuoso;
    }

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .h = 6 }, .id_extra = 718 });
    _ = dvui.separator(@src(), .{ .id_extra = 719 });
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .h = 4 }, .id_extra = 720 });

    // Description of what will happen
    {
        const desc: []const u8 = switch (imp.format) {
            .xschem => "XSchem (.sch) \u{2014} convert XSchem schematic to Schemify format.",
            .spice => "SPICE (.spice/.sp/.cir/.net) \u{2014} import netlist and generate schematic.",
            .virtuoso => "Virtuoso (.oa/.cellview) \u{2014} convert Cadence OA cell to Schemify format.",
            .unknown => "Select a format or enter a file path to auto-detect.",
        };
        dvui.labelNoFmt(@src(), desc, .{}, .{ .id_extra = 721, .style = .control });
    }

    _ = dvui.spacer(@src(), .{ .expand = .vertical, .id_extra = 729 });

    // Status message
    if (imp.status_msg.len > 0) {
        dvui.labelNoFmt(@src(), imp.status_msg, .{}, .{ .id_extra = 730, .style = .control });
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .h = 4 }, .id_extra = 731 });
    }

    _ = dvui.separator(@src(), .{ .id_extra = 739 });
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .h = 4 }, .id_extra = 740 });

    // Import + Cancel buttons
    {
        var btns = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = 741 });
        defer btns.deinit();

        if (dvui.button(@src(), "Import", .{}, .{ .id_extra = 742 })) {
            runImport(app);
        }
        _ = dvui.spacer(@src(), .{ .expand = .horizontal, .id_extra = 743 });
        if (dvui.button(@src(), "Cancel", .{}, .{ .id_extra = 744 })) imp.is_open = false;
    }
}

fn runImport(app: *AppState) void {
    const imp = &app.gui.cold.dialogs.import_project;
    const path = imp.getPath();
    if (path.len == 0) {
        imp.status_msg = "No file path specified";
        return;
    }

    const a = app.allocator();

    // Determine project directory from file path
    const dir = std.fs.path.dirname(path) orelse ".";

    const source: external.ImportSource = switch (imp.format) {
        .xschem => .{ .xschem = .{ .project_dir = dir } },
        .spice => .{ .spice = .{ .project_dir = dir } },
        .virtuoso => .{ .virtuoso = .{ .project_dir = dir } },
        .unknown => {
            imp.status_msg = "Unknown format — cannot import";
            return;
        },
    };

    var results = external.importProject(a, source) catch |err| {
        imp.status_msg = switch (err) {
            error.NoCdsLib => "No cds.lib found in project directory",
            error.NoSpiceFiles => "No SPICE netlist files found",
            else => "Conversion failed",
        };
        return;
    };
    _ = &results;

    if (results.results.len == 0) {
        imp.status_msg = "No schematics found in file";
        return;
    }

    // Open the first result as a new document
    const first = results.results[0];
    const doc_name = if (first.name.len > 0) first.name else "imported";

    var name_buf: [256]u8 = undefined;
    const full_name = std.fmt.bufPrint(&name_buf, "{s}.chn", .{doc_name}) catch "imported.chn";
    app.newFile(full_name) catch {
        imp.status_msg = "Failed to create document";
        return;
    };

    // Copy the converted schematic data into the new document
    if (app.active()) |doc| {
        doc.sch.deinit(a);
        doc.sch = first.schemify;
    }

    imp.is_open = false;
    var status_buf: [128]u8 = undefined;
    const fmt_name: []const u8 = switch (imp.format) {
        .xschem => "XSchem",
        .spice => "SPICE",
        .virtuoso => "Virtuoso",
        .unknown => "unknown",
    };
    app.setStatusBuf(std.fmt.bufPrint(&status_buf, "Imported {d} schematic(s) from {s}", .{ results.results.len, fmt_name }) catch "Import complete");
}

