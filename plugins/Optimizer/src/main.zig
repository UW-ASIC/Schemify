//! Optimizer — Schemify plugin for Bayesian circuit optimization (ABI v6).
//!
//! Uses the Framework comptime layer — no manual widget IDs or switch boilerplate.

const std = @import("std");
const P = @import("PluginIF");
const F = P.Framework;

// ── Plugin state ──────────────────────────────────────────────────────────── //

const OptStatus = enum { idle, running, done, err };

const State = struct {
    status: OptStatus = .idle,
    iteration: usize = 0,
    msg_buf: [256]u8 = [_]u8{0} ** 256,
    msg_len: usize = 0,

    fn setMsg(s: *State, msg: []const u8) void {
        const n = @min(msg.len, s.msg_buf.len - 1);
        @memcpy(s.msg_buf[0..n], msg[0..n]);
        s.msg_len = n;
    }

    fn clearMsg(s: *State) void {
        s.msg_len = 0;
    }

    fn reset(s: *State) void {
        s.status = .idle;
        s.iteration = 0;
        s.clearMsg();
    }

    fn msgText(s: *const State) []const u8 {
        return s.msg_buf[0..s.msg_len];
    }
};

var state = State{};

// ── Handlers ──────────────────────────────────────────────────────────────── //

// Widget IDs for the single panel (pi=0): 0*256 + wi.
// draw_fn emits buttons with explicit IDs in [0..255]; on_button routes them.
const WID_RUN = 0;
const WID_STOP = 1;
const WID_RESET = 2;

fn setStatusAndRefresh(w: *P.Writer, status: []const u8) void {
    w.setStatus(status);
    w.requestRefresh();
}

fn startRun(s: *State) void {
    s.status = .running;
    s.iteration = 0;
    s.setMsg("Starting optimization...");
}

fn stopRun(s: *State, msg: []const u8) void {
    s.status = .idle;
    s.setMsg(msg);
}

fn drawMsgLine(s: *const State, w: *P.Writer) void {
    const st = s.msgText();
    if (st.len > 0) w.label(st, 11);
}

fn drawPanel(s: *State, w: *P.Writer) void {
    w.label("Circuit Optimizer", 100);
    w.separator(101);

    switch (s.status) {
        .idle => {
            w.label("Status: Idle", 10);
            w.button("Run Optimization", WID_RUN);
        },
        .running => {
            var buf: [64]u8 = undefined;
            const lbl = std.fmt.bufPrint(&buf, "Running... iteration {d}", .{s.iteration}) catch "Running...";
            w.label(lbl, 10);
            w.button("Stop", WID_STOP);
        },
        .done => {
            w.label("Status: Done", 10);
            drawMsgLine(s, w);
            w.button("Run Again", WID_RUN);
            w.button("Reset", WID_RESET);
        },
        .err => {
            w.label("Status: Error", 10);
            drawMsgLine(s, w);
            w.button("Reset", WID_RESET);
        },
    }

    w.separator(20);

    var iter_buf: [64]u8 = undefined;
    const iter_str = std.fmt.bufPrint(&iter_buf, "Iterations: {d}", .{s.iteration}) catch "Iterations: ?";
    w.label(iter_str, 30);
}

fn onButton(s: *State, widget_id: u32, w: *P.Writer) void {
    switch (widget_id) {
        WID_RUN => {
            startRun(s);
            setStatusAndRefresh(w, "Optimizer: running");
        },
        WID_STOP => {
            stopRun(s, "Stopped by user");
            setStatusAndRefresh(w, "Optimizer: stopped");
        },
        WID_RESET => {
            s.reset();
            setStatusAndRefresh(w, "Optimizer: reset");
        },
        else => {},
    }
}

fn onLoad(s: *State, w: *P.Writer) void {
    w.setStatus("Optimizer ready");
    w.log(.info, "Optimizer", "on_load");
    _ = s;
}

fn onUnload(s: *State, w: *P.Writer) void {
    w.log(.info, "Optimizer", "on_unload");
    s.reset();
}

fn onCommand(s: *State, tag: []const u8, _: []const u8, w: *P.Writer) void {
    if (std.mem.eql(u8, tag, "optimizer_run")) {
        s.status = .running;
        s.iteration = 0;
        setStatusAndRefresh(w, "Optimizer: started via command");
    } else if (std.mem.eql(u8, tag, "optimizer_stop")) {
        s.status = .idle;
        setStatusAndRefresh(w, "Optimizer: stopped via command");
    }
}

// ── Plugin definition ─────────────────────────────────────────────────────── //

const MyPlugin = F.define(State, &state, .{
    .name = "Optimizer",
    .version = "0.1.0",
    .panels = &.{
        F.PanelSpec{
            .id = "optimizer",
            .title = "Optimizer",
            .vim_cmd = "opt",
            .layout = .right_sidebar,
            .keybind = 'O',
            .draw_fn = F.wrapDrawFn(State, drawPanel),
            .on_button = F.wrapOnButton(State, onButton),
        },
    },
    .on_load = F.wrapWriterHook(State, onLoad),
    .on_unload = F.wrapWriterHook(State, onUnload),
    .on_command = F.wrapCommandHook(State, onCommand),
});

comptime {
    MyPlugin.export_plugin();
}
