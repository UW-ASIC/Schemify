//! GUI shell — toolbar, tabbar, renderer, command bar, dialogs, overlays.
//!
//! Frame layout order:
//!   toolbar -> tabbar -> { left_sidebar | { renderer / bottom_bar } | right_sidebar }
//!   -> command_bar -> overlays -> file_explorer -> library_browser
//!   -> context_menu -> keybinds_dlg -> find_dlg -> props_dlg -> marketplace

const dvui = @import("dvui");
const st = @import("state");

const AppState = st.AppState;

// ── Sub-module imports ──────────────────────────────────────────────────── //

const actions = @import("Actions.zig");
const input = @import("Input.zig");
const canvas = @import("Canvas/lib.zig");
const interaction = @import("Canvas/Interaction.zig");
const CanvasEvent = @import("Canvas/types.zig").CanvasEvent;

// Bars
const toolbar = @import("Bars/ToolBar.zig");
const tabbar = @import("Bars/TabBar.zig");
const command_bar = @import("Bars/CommandBar.zig");

// Panels & browsers
const plugin_panels = @import("PluginPanels.zig");
const marketplace = @import("Panels/Marketplace.zig");
const file_explorer = @import("Panels/FileExplorer.zig");
const library_browser = @import("Panels/LibraryBrowser.zig");

// Dialogs
const context_menu = @import("Panels/ContextMenu.zig");
const keybinds_dlg = @import("Dialogs/KeybindsDialog.zig");
const find_dlg = @import("Dialogs/FindDialog.zig");
const props_dlg = @import("Dialogs/PropsDialog.zig");
const digital_block_dlg = @import("Dialogs/DigitalBlockDialog.zig");
const missing_symbols_panel = @import("Dialogs/MissingSymbolsPanel.zig");
const spice_code_dlg = @import("Dialogs/SpiceCodeDialog.zig");
const multi_props_dlg = @import("Dialogs/MultiPropsDialog.zig");

// ── Public API ─────────────────────────────────────────────────────────── //

/// Render a single GUI frame: input handling, layout, and all sub-panels.
pub fn frame(app: *AppState) !void {
    input.handleInput(app);

    var outer = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
    defer outer.deinit();

    toolbar.draw(app);
    tabbar.draw(app);
    {
        var middle = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both });
        defer middle.deinit();
        plugin_panels.drawSidebar(app, .left_sidebar);
        {
            var col = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
            defer col.deinit();
            const canvas_ev = canvas.draw(app);
            handleCanvasEvent(app, canvas_ev);
            plugin_panels.drawBottomBar(app);
        }
        plugin_panels.drawSidebar(app, .right_sidebar);
    }
    command_bar.draw(app);
    plugin_panels.drawOverlays(app);
    file_explorer.draw(app);
    library_browser.draw(app);
    context_menu.draw(app);

    // Sync keybinds dialog open state from gui flag.
    app.gui.cold.keybinds_dialog.open = app.gui.cold.keybinds_dialog.open or app.gui.cold.keybinds_open;
    app.gui.cold.keybinds_open = false;
    keybinds_dlg.draw(app);

    find_dlg.draw(app);
    props_dlg.draw(app);
    multi_props_dlg.draw(app);
    digital_block_dlg.draw(app);
    spice_code_dlg.draw(app);
    marketplace.draw(app);
    missing_symbols_panel.draw(app);
}

// ── Canvas event dispatch ─────────────────────────────────────────────────── //

fn handleCanvasEvent(app: *AppState, ev: CanvasEvent) void {
    switch (ev) {
        .none => {},
        .click => |pt| {
            switch (app.tool.active) {
                .wire => {
                    if (app.tool.wire_start) |ws| {
                        // Second click: place the wire segment.
                        actions.enqueue(app, .{ .undoable = .{ .add_wire = .{
                            .start = ws,
                            .end = pt,
                        } } }, "Wire placed");
                        // Chain: next wire starts from this endpoint.
                        app.tool.wire_start = pt;
                    } else {
                        // First click: set the starting point.
                        app.tool.wire_start = pt;
                        app.status_msg = "Wire start set — click to place endpoint";
                    }
                },
                .select => {
                    const doc = app.active() orelse return;
                    if (interaction.hitTestInstance(&doc.sch, pt)) |idx| {
                        const already_selected = doc.selection.instances.bit_length > idx and
                            doc.selection.instances.isSet(idx);
                        if (!already_selected) {
                            doc.selection.clear();
                            const a = app.allocator();
                            doc.selection.instances.resize(a, doc.sch.instances.len, false) catch return;
                            doc.selection.instances.set(idx);
                            app.status_msg = "Selected instance";
                        }
                    } else {
                        doc.selection.clear();
                        app.status_msg = "Ready";
                    }
                },
                else => {},
            }
        },
        .double_click => |_| {
            actions.enqueue(app, .{ .immediate = .edit_properties }, "Edit properties");
        },
        .right_click => |rc| {
            app.gui.cold.ctx_menu.pixel_x = rc.pixel[0];
            app.gui.cold.ctx_menu.pixel_y = rc.pixel[1];
            app.gui.cold.ctx_menu.inst_idx = rc.inst_idx;
            app.gui.cold.ctx_menu.wire_idx = rc.wire_idx;
            app.gui.cold.ctx_menu.open = true;
            // Auto-select the right-clicked instance so Properties command finds it.
            if (rc.inst_idx >= 0) {
                const doc = app.active() orelse return;
                const a = app.allocator();
                doc.selection.ensureCapacity(a, doc.sch.instances.len, doc.sch.wires.len, false) catch return;
                doc.selection.clear();
                doc.selection.instances.set(@intCast(rc.inst_idx));
            }
        },
        .rubber_band_complete => |rb| {
            const doc = app.active() orelse return;
            const a = app.allocator();
            doc.selection.ensureCapacity(a, doc.sch.instances.len, doc.sch.wires.len, false) catch return;
            doc.selection.clear();

            const xs = doc.sch.instances.items(.x);
            const ys = doc.sch.instances.items(.y);
            var count: usize = 0;
            for (0..doc.sch.instances.len) |i| {
                if (xs[i] >= rb.min[0] and xs[i] <= rb.max[0] and
                    ys[i] >= rb.min[1] and ys[i] <= rb.max[1])
                {
                    doc.selection.instances.set(i);
                    count += 1;
                }
            }

            const x0s = doc.sch.wires.items(.x0);
            const y0s = doc.sch.wires.items(.y0);
            const x1s = doc.sch.wires.items(.x1);
            const y1s = doc.sch.wires.items(.y1);
            for (0..doc.sch.wires.len) |i| {
                const wx0 = @min(x0s[i], x1s[i]);
                const wy0 = @min(y0s[i], y1s[i]);
                const wx1 = @max(x0s[i], x1s[i]);
                const wy1 = @max(y0s[i], y1s[i]);
                if (wx0 >= rb.min[0] and wx1 <= rb.max[0] and
                    wy0 >= rb.min[1] and wy1 <= rb.max[1])
                {
                    doc.selection.wires.set(i);
                }
            }

            if (count > 0) {
                app.status_msg = "Selected instances";
            } else {
                app.status_msg = "Ready";
            }
        },
    }
}

