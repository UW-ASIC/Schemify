const std = @import("std");
const dvui = @import("dvui");
const st = @import("state");
const AppState = st.AppState;
const tc = @import("theme_config");

pub fn draw(app: *AppState) void {
    if (!app.gui.cold.chat_panel.visible) return;

    var panel = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = 7000,
        .background = true,
        .color_fill = tc.getSidebarBg(),
        .min_size_content = .{ .w = 300 },
        .padding = .{ .x = 8, .y = 8, .w = 8, .h = 8 },
        .expand = .vertical,
    });
    defer panel.deinit();

    // Header
    {
        var hdr = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = 7001,
            .expand = .horizontal,
            .padding = .{ .x = 0, .y = 0, .w = 0, .h = 4 },
        });
        defer hdr.deinit();

        dvui.labelNoFmt(@src(), "AI Chat", .{}, .{ .id_extra = 7002, .gravity_y = 0.5 });
        _ = dvui.spacer(@src(), .{ .expand = .horizontal, .id_extra = 7003 });

        // Provider selector
        const providers = [_][]const u8{ "Claude", "ChatGPT", "Ollama" };
        _ = dvui.dropdown(
            @src(),
            &providers,
            .{ .choice = &app.gui.cold.chat_panel.provider_idx },
            .{},
            .{ .id_extra = 7004, .gravity_y = 0.5 },
        );

        if (dvui.button(@src(), "X", .{}, .{
            .id_extra = 7005,
            .gravity_y = 0.5,
            .padding = .{ .x = 4, .y = 2, .w = 4, .h = 2 },
            .corner_radius = dvui.Rect.all(3),
        })) {
            app.gui.cold.chat_panel.visible = false;
        }
    }

    _ = dvui.separator(@src(), .{ .expand = .horizontal, .id_extra = 7010 });

    // Message area (scrollable)
    {
        var scroll = dvui.scrollArea(@src(), .{}, .{
            .id_extra = 7020,
            .expand = .both,
        });
        defer scroll.deinit();

        const chat = &app.gui.cold.chat_panel;
        for (0..chat.n_messages) |i| {
            const msg = chat.messages[i];
            const content = chat.getContent(msg);
            if (content.len == 0) continue;

            const role_label: []const u8 = switch (msg.role) {
                .user => "You",
                .assistant => "AI",
                .tool => "Tool",
                .system => "System",
            };

            var msg_box = dvui.box(@src(), .{ .dir = .vertical }, .{
                .id_extra = 7100 + i,
                .expand = .horizontal,
                .padding = .{ .x = 4, .y = 4, .w = 4, .h = 4 },
                .margin = .{ .x = 0, .y = 2, .w = 0, .h = 2 },
                .background = true,
                .corner_radius = dvui.Rect.all(4),
            });
            defer msg_box.deinit();

            dvui.labelNoFmt(@src(), role_label, .{}, .{
                .id_extra = 7200 + i,
                .color_text = tc.chromeAccent(),
            });
            dvui.labelNoFmt(@src(), content, .{}, .{
                .id_extra = 7300 + i,
                .expand = .horizontal,
            });
        }

        // Streaming indicator
        if (chat.streaming.load(.acquire)) {
            dvui.labelNoFmt(@src(), "Thinking...", .{}, .{
                .id_extra = 7050,
                .color_text = tc.chromeTextSecondary(),
            });
        }
    }

    _ = dvui.separator(@src(), .{ .expand = .horizontal, .id_extra = 7030 });

    // Input area
    {
        var input_row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = 7040,
            .expand = .horizontal,
            .padding = .{ .x = 0, .y = 4, .w = 0, .h = 0 },
        });
        defer input_row.deinit();

        const chat = &app.gui.cold.chat_panel;
        var te = dvui.textEntry(@src(), .{
            .text = .{ .buffer = &chat.input_buf },
            .placeholder = "Type a message...",
        }, .{ .id_extra = 7041, .expand = .horizontal, .gravity_y = 0.5 });
        const submitted = te.enter_pressed;
        te.deinit();

        const send = submitted or dvui.button(@src(), "Send", .{}, .{
            .id_extra = 7042,
            .gravity_y = 0.5,
            .padding = .{ .x = 8, .y = 4, .w = 8, .h = 4 },
            .corner_radius = dvui.Rect.all(3),
            .style = .highlight,
        });

        if (send) {
            const input_text = std.mem.sliceTo(&chat.input_buf, 0);
            if (input_text.len > 0) {
                chat.addMessage(.user, input_text);
                @memset(&chat.input_buf, 0);
                app.status_msg = "Message sent";
            }
        }
    }
}
