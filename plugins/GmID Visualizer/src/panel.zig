const std    = @import("std");
const Plugin = @import("PluginIF");
const runner = @import("runner.zig");
const state  = @import("state.zig");

const UiCtx = Plugin.UiCtx;

pub fn draw(ctx: *const UiCtx) callconv(.c) void {
    const s = &state.g;

    ctx.label("Gm/Id Visualizer", 17, 0);
    ctx.separator(1);

    drawModelSelector(ctx, s);
    drawValidationStatus(ctx, s);
    ctx.separator(20);
    drawRunControls(ctx, s);
    ctx.separator(30);
    drawOutputs(ctx, s);
}

fn drawModelSelector(ctx: *const UiCtx, s: *state.State) void {
    ctx.begin_row(2);
    const selected = modelLabel(s);
    if (ctx.button(selected.ptr, @intCast(selected.len), 3)) {
        s.dropdown_open = !s.dropdown_open;
    }
    if (ctx.button("Browse...", 9, 4)) {
        if (runner.pickModelFile()) |owned_path| {
            defer std.heap.page_allocator.free(owned_path);
            const kind = runner.validateModelFile(owned_path);
            if (kind == .unknown) {
                s.setError("Selected file is not recognized as MOSFET or BJT model");
            } else {
                s.clearError();
                s.setSelectedModel(owned_path, kind);
                s.addRecentModel(owned_path);
                s.setStatus("Model selected and validated");
                s.status = .idle;
                s.dropdown_open = false;
            }
        } else {
            s.setStatus("Browse cancelled");
        }
    }
    ctx.end_row(2);

    if (s.dropdown_open and s.recent_count > 0) {
        ctx.label("Previously selected models", 26, 5);
        for (0..@as(usize, s.recent_count)) |idx| {
            const path = s.recent_models[idx][0..s.recent_model_lens[idx]];
            if (ctx.button(path.ptr, @intCast(path.len), @intCast(100 + idx))) {
                const kind = runner.validateModelFile(path);
                s.setSelectedModel(path, kind);
                s.dropdown_open = false;
                if (kind == .unknown) {
                    s.setError("Saved model no longer matches MOSFET/BJT format");
                } else {
                    s.clearError();
                    s.setStatus("Model selected from history");
                    s.status = .idle;
                }
            }
        }
    }
}

fn drawValidationStatus(ctx: *const UiCtx, s: *state.State) void {
    const path = s.selectedPath();
    if (path.len == 0) {
        ctx.label("No model selected", 17, 10);
        return;
    }
    var kind_buf: [80]u8 = undefined;
    const kind_text = std.fmt.bufPrint(
        &kind_buf, "Validated as {s}", .{s.selected_model_kind.label()},
    ) catch "Validated";
    ctx.label(kind_text.ptr, @intCast(kind_text.len), 11);
    ctx.label(path.ptr, @intCast(path.len), 12);
}

fn drawRunControls(ctx: *const UiCtx, s: *state.State) void {
    if (ctx.button("Run", 3, 21)) {
        runner.runSweep();
    }
    switch (s.status) {
        .idle => {
            const st = s.statusText();
            if (st.len > 0) {
                ctx.label(st.ptr, @intCast(st.len), 22);
            } else {
                ctx.label("Select model, then run sweep", 27, 23);
            }
        },
        .running => ctx.label("Simulation running...", 21, 24),
        .done => {
            const st = s.statusText();
            ctx.label(st.ptr, @intCast(st.len), 25);
        },
        .err => {
            ctx.label("Error:", 6, 26);
            const et = s.errorText();
            ctx.label(et.ptr, @intCast(et.len), 27);
        },
    }
}

fn drawOutputs(ctx: *const UiCtx, s: *state.State) void {
    ctx.label("Generated SVG Graphs", 20, 31);
    if (s.plot_count == 0) {
        ctx.label("(none yet)", 10, 32);
        return;
    }
    for (0..@as(usize, s.plot_count)) |idx| {
        const p = s.plots[idx][0..s.plot_lens[idx]];
        ctx.begin_row(@intCast(40 + idx));
        ctx.label(p.ptr, @intCast(p.len), @intCast(200 + idx));
        if (ctx.button("Open", 4, @intCast(300 + idx))) {
            runner.openSvg(p);
        }
        ctx.end_row(@intCast(40 + idx));
    }
}

fn modelLabel(s: *state.State) []const u8 {
    const selected = s.selectedPath();
    if (selected.len == 0) return "Model";
    const basename = std.fs.path.basename(selected);
    if (basename.len == 0) return "Model";
    return basename;
}
