//! Vacask (Spectre-compatible) specific emit logic.
//! All functions here match the signature used in backend/lib.zig dispatch.

const std = @import("std");
const SpiceIF = @import("../SpiceIF.zig");

pub fn emitAnalysis(writer: anytype, an: SpiceIF.Analysis) !void {
    switch (an) {
        .op => try writer.writeAll("analysis op\n"),
        .dc => |d| {
            try writer.print("analysis dc opfile=raw timeout=10 annotate=stb sweep={s} {e} {e} {e}", .{
                d.src1, d.start1, d.stop1, d.step1,
            });
            if (d.src2) |s2| try writer.print(" {s} {e} {e} {e}", .{ s2, d.start2.?, d.stop2.?, d.step2.? });
            try writer.writeByte('\n');
        },
        .ac => |a| try writer.print("analysis ac freq=class rich timeout=10 sweep={s} points={d} start={e} stop={e}\n", .{
            SpiceIF.sweepStr(a.sweep), a.n_points, a.f_start, a.f_stop,
        }),
        .tran => |t| {
            try writer.print("analysis tran tstop={e}", .{t.stop});
            if (t.step != 0) try writer.print(" tstep={e}", .{t.step});
            if (t.start != 0) try writer.print(" tstart={e}", .{t.start});
            if (t.max_step) |ms| try writer.print(" maxiter={e}", .{ms});
            if (t.uic) try writer.writeAll(" UIC=1");
            try writer.writeByte('\n');
        },
        .noise => |n| {
            try writer.print("analysis noise freq=class rich timeout=10 sweep={s} points={d} start={e} stop={e}", .{
                SpiceIF.sweepStr(n.sweep), n.n_points, n.f_start, n.f_stop,
            });
            try writer.print(" outnode=V({s}) insrc={s}", .{ n.output_node, n.input_src });
            if (n.output_ref) |r| try writer.print(" refnode={s}", .{r});
            if (n.points_per_summary) |pts| try writer.print(" summary={d}", .{pts});
            try writer.writeByte('\n');
        },
        .sens => {
            try writer.writeAll("* [UNSUPPORTED] .sens not available in VACASK.\n");
            try writer.writeAll("* Workaround: use Python postprocessing with finite differences.\n");
        },
        .tf => {
            try writer.writeAll("* [UNSUPPORTED] .tf not available in VACASK.\n");
        },
        .pz => {
            try writer.writeAll("* [UNSUPPORTED] .PZ not available in VACASK.\n");
            try writer.writeAll("* Workaround: use dense .AC sweep + external vector fitting.\n");
        },
        .disto => {
            try writer.writeAll("* [UNSUPPORTED] .DISTO not available in VACASK.\n");
            try writer.writeAll("* Workaround: use harmonic balance analysis.\n");
        },
        .pss => {
            try writer.writeAll("* [UNSUPPORTED] .PSS not available in VACASK.\n");
            try writer.writeAll("* Workaround: use harmonic balance (hb) analysis instead.\n");
        },
        .sp => {
            try writer.writeAll("* [UNSUPPORTED] .sp (S-parameter) not yet available in VACASK.\n");
            try writer.writeAll("* Workaround: use .ac analysis and export touchstone manually.\n");
        },
        .hb => |h| {
            try writer.writeAll("analysis hb1 hb freq=[");
            for (h.freqs, 0..) |f, i| {
                if (i > 0) try writer.writeAll(", ");
                try writer.print("{e}", .{f});
            }
            try writer.writeAll("]");
            try writer.print(" sidebands={d}", .{h.n_harmonics});
            if (h.startup) {
                try writer.writeAll(" startup=yes");
                if (h.startup_periods) |p| try writer.print(" startupperiods={d}", .{p});
            }
            try writer.writeByte('\n');
        },
        .mpde => try writer.writeAll("* [UNSUPPORTED] .MPDE not available in VACASK.\n"),
        .four => {}, // emitted separately after .tran by emitTo
    }
}

pub fn emitSweep(writer: anytype, sw: SpiceIF.Sweep) !void {
    switch (sw) {
        .step => |s| {
            try writer.writeAll("sweep ");
            switch (s.kind) {
                .lin => |lin| {
                    const points: u32 = if (lin.step != 0)
                        @as(u32, @intFromFloat(@ceil((lin.stop - lin.start) / lin.step))) + 1
                    else
                        2;
                    try writer.print("lin_sweep instance=\"{s}\" parameter=\"dc\" from={e} to={e} mode=\"lin\" points={d}", .{
                        s.param, lin.start, lin.stop, points,
                    });
                },
                .dec => |d| try writer.print("log_sweep instance=\"{s}\" parameter=\"dc\" from={e} to={e} mode=\"log\" points={d}", .{
                    s.param, d.start, d.stop, d.points,
                }),
                .oct => |o| try writer.print("log_sweep instance=\"{s}\" parameter=\"dc\" from={e} to={e} mode=\"log\" points={d}", .{
                    s.param, o.start, o.stop, o.points,
                }),
                .list => |l| {
                    try writer.print("values_sweep instance=\"{s}\" parameter=\"dc\" values=[", .{s.param});
                    for (l.values, 0..) |v, i| {
                        if (i > 0) try writer.writeAll(", ");
                        try writer.print("{e}", .{v});
                    }
                    try writer.writeByte(']');
                },
            }
            try writer.writeByte('\n');
        },
        .sampling => {
            try writer.writeAll("* [UNSUPPORTED] Monte Carlo sampling not available in VACASK.\n");
            try writer.writeAll("* Workaround: use Python scripting for statistical analysis.\n");
        },
        .embedded_sampling => try writer.writeAll("* [UNSUPPORTED] .EMBEDDEDSAMPLING not available in VACASK.\n"),
        .pce => try writer.writeAll("* [UNSUPPORTED] .PCE not available in VACASK.\n"),
        .data => {
            try writer.writeAll("* [UNSUPPORTED] .DATA not available in VACASK.\n");
            try writer.writeAll("* Workaround: use Python scripting for table-based analysis.\n");
        },
    }
}

pub fn emitNetlistComponent(writer: anytype, comp: SpiceIF.ComponentType) !void {
    // Vacask component syntax handled by SpiceIF.emitComponent with .vacask backend
    try SpiceIF.emitComponent(writer, comp, .vacask);
}
