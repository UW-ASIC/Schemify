const std = @import("std");
const dvui = @import("dvui");
const st = @import("state");
const AppState = st.AppState;
const tc = @import("theme_config");

pub fn draw(app: *AppState) void {
    const doc = app.active() orelse return;
    var editor = &app.gui.cold.doc_editor;

    // Load documentation from schematic on first view
    if (!editor.loaded) {
        {
            const text = doc.sch.str(doc.sch.documentation);
            if (text.len > 0) editor.setText(text);
        }
        editor.loaded = true;
    }

    var outer = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = 6000,
        .expand = .both,
        .padding = .{ .x = 8, .y = 8, .w = 8, .h = 8 },
    });
    defer outer.deinit();

    switch (editor.layout_mode) {
        .editor_only, .side_by_side => {
            // Editor pane
            var edit_pane = dvui.box(@src(), .{ .dir = .vertical }, .{
                .id_extra = 6010,
                .expand = .both,
                .background = true,
                .padding = .{ .x = 8, .y = 8, .w = 8, .h = 8 },
            });
            defer edit_pane.deinit();

            // Header
            {
                var hdr = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .id_extra = 6011,
                    .expand = .horizontal,
                });
                defer hdr.deinit();

                dvui.labelNoFmt(@src(), "Documentation Editor", .{}, .{ .id_extra = 6012, .gravity_y = 0.5 });
                _ = dvui.spacer(@src(), .{ .expand = .horizontal, .id_extra = 6013 });

                // Layout toggle
                const mode_label: []const u8 = switch (editor.layout_mode) {
                    .editor_only => "Editor",
                    .side_by_side => "Split",
                    .preview_only => "Preview",
                };
                if (dvui.button(@src(), mode_label, .{}, .{
                    .id_extra = 6014,
                    .gravity_y = 0.5,
                    .padding = .{ .x = 6, .y = 2, .w = 6, .h = 2 },
                    .corner_radius = dvui.Rect.all(3),
                })) {
                    editor.layout_mode = @enumFromInt((@intFromEnum(editor.layout_mode) + 1) % 3);
                }
            }

            _ = dvui.separator(@src(), .{ .expand = .horizontal, .id_extra = 6015 });

            // Editor content
            {
                var te = dvui.textEntry(@src(), .{
                    .text = .{ .buffer = &editor.edit_buf },
                    .placeholder = "(empty -- start typing documentation)",
                }, .{ .id_extra = 6020, .expand = .both });
                te.deinit();
            }
        },
        .preview_only => {},
    }

    // Preview pane (for side_by_side and preview_only)
    if (editor.layout_mode == .side_by_side or editor.layout_mode == .preview_only) {
        var preview_pane = dvui.box(@src(), .{ .dir = .vertical }, .{
            .id_extra = 6030,
            .expand = .both,
            .background = true,
            .padding = .{ .x = 8, .y = 8, .w = 8, .h = 8 },
            .margin = .{ .x = 4, .y = 0, .w = 0, .h = 0 },
        });
        defer preview_pane.deinit();

        dvui.labelNoFmt(@src(), "Preview", .{}, .{ .id_extra = 6031 });
        _ = dvui.separator(@src(), .{ .expand = .horizontal, .id_extra = 6032 });

        {
            var scroll = dvui.scrollArea(@src(), .{}, .{
                .id_extra = 6040,
                .expand = .both,
            });
            defer scroll.deinit();

            const text = std.mem.sliceTo(&editor.edit_buf, 0);
            if (text.len > 0) {
                dvui.labelNoFmt(@src(), text, .{}, .{
                    .id_extra = 6041,
                    .expand = .horizontal,
                });
            } else {
                dvui.labelNoFmt(@src(), "(no documentation)", .{}, .{
                    .id_extra = 6042,
                    .color_text = tc.chromeTextSecondary(),
                });
            }
        }
    }
}
