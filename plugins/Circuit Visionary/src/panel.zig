//! CircuitVision dvui overlay panel.
//!
//! draw() is the PanelDef.draw_fn callback — called every frame when the
//! overlay is visible.  All UI is rendered through the host-provided UiCtx
//! so no dvui symbols are needed in this file — no struct-layout hazards.

const std    = @import("std");
const Plugin = @import("PluginIF");
const state  = @import("state.zig");
const bridge = @import("python_bridge.zig");

const UiCtx = Plugin.UiCtx;
const STYLES = [_]state.Style{ .auto, .handdrawn, .textbook, .datasheet };

pub fn draw(ctx: *const UiCtx) callconv(.c) void {
    const s = &state.g;

    // ── Title ─────────────────────────────────────────────────────────────── //

    ctx.label("CircuitVision", 13, 0);
    ctx.separator(1);

    // ── Image path display ────────────────────────────────────────────────── //

    ctx.begin_row(2);
    ctx.label("Image:", 6, 3);
    const path = s.imagePath();
    if (path.len > 0) {
        ctx.label(path.ptr, @intCast(path.len), 4);
    } else {
        ctx.label("(no image selected)", 19, 4);
    }
    ctx.end_row(2);

    // ── Style selector ────────────────────────────────────────────────────── //

    ctx.begin_row(10);
    ctx.label("Style:", 6, 11);
    if (ctx.button("auto",      4, 12)) s.selected_style = .auto;
    if (ctx.button("handdrawn", 9, 13)) s.selected_style = .handdrawn;
    if (ctx.button("textbook",  8, 14)) s.selected_style = .textbook;
    if (ctx.button("datasheet", 9, 15)) s.selected_style = .datasheet;
    ctx.end_row(10);

    ctx.separator(20);

    // ── Run / status ──────────────────────────────────────────────────────── //

    switch (s.status) {
        .idle => {
            if (s.image_path_len > 0) {
                if (ctx.button("Run Pipeline", 12, 30)) {
                    bridge.runPipeline();
                }
            } else {
                ctx.label("Set image path to enable pipeline", 32, 31);
            }
        },
        .running => {
            ctx.label("Running pipeline...", 19, 40);
        },
        .done => {
            drawResults(ctx, s);

            ctx.begin_row(50);
            if (ctx.button("Accept",   6, 51)) s.reset();
            if (ctx.button("Run Again",9, 52)) s.reset();
            if (ctx.button("Cancel",   6, 53)) s.reset();
            ctx.end_row(50);
        },
        .err => {
            ctx.label("Error:", 6, 60);
            const msg = s.errorMsg();
            ctx.label(msg.ptr, @intCast(msg.len), 61);
            if (ctx.button("Dismiss", 7, 62)) s.reset();
        },
    }
}

fn drawResults(ctx: *const UiCtx, s: *const state.State) void {
    ctx.separator(100);
    ctx.label("Results", 7, 101);

    // Component / net counts
    ctx.begin_row(110);
    var comp_buf: [64]u8 = undefined;
    const comp_label = std.fmt.bufPrint(&comp_buf, "Components: {d}", .{s.n_components}) catch "Components: ?";
    ctx.label(comp_label.ptr, @intCast(comp_label.len), 111);

    var net_buf: [64]u8 = undefined;
    const net_label = std.fmt.bufPrint(&net_buf, "Nets: {d}", .{s.n_nets}) catch "Nets: ?";
    ctx.label(net_label.ptr, @intCast(net_label.len), 112);
    ctx.end_row(110);

    // Confidence + detected style
    ctx.begin_row(120);
    var conf_buf: [64]u8 = undefined;
    const conf_label = std.fmt.bufPrint(&conf_buf, "Confidence: {d:.2}", .{s.overall_confidence}) catch "Confidence: ?";
    ctx.label(conf_label.ptr, @intCast(conf_label.len), 121);

    if (s.detected_style_len > 0) {
        var style_buf: [64]u8 = undefined;
        const style_label = std.fmt.bufPrint(&style_buf, "Style: {s}", .{s.detectedStyle()}) catch "Style: ?";
        ctx.label(style_label.ptr, @intCast(style_label.len), 122);
    }
    ctx.end_row(120);

    // Warnings count
    if (s.warning_count > 0) {
        ctx.separator(130);
        var warn_buf: [64]u8 = undefined;
        const warn_header = std.fmt.bufPrint(&warn_buf, "Warnings ({d})", .{s.warning_count}) catch "Warnings";
        ctx.label(warn_header.ptr, @intCast(warn_header.len), 131);
    }
}
