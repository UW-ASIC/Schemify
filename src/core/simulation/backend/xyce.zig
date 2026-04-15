//! Xyce-specific emit logic.
//! All functions here match the signature used in backend/lib.zig dispatch.

const std = @import("std");
const SpiceIF = @import("../SpiceIF.zig");

pub fn emitAnalysis(writer: anytype, an: SpiceIF.Analysis) !void {
    switch (an) {
        .op => try writer.writeAll(".op\n"),
        .dc => |d| {
            try writer.print(".dc {s} {e} {e} {e}", .{ d.src1, d.start1, d.stop1, d.step1 });
            if (d.src2) |s2| try writer.print(" {s} {e} {e} {e}", .{ s2, d.start2.?, d.stop2.?, d.step2.? });
            try writer.writeByte('\n');
        },
        .ac => |a| try writer.print(".ac {s} {d} {e} {e}\n", .{ SpiceIF.sweepStr(a.sweep), a.n_points, a.f_start, a.f_stop }),
        .tran => |t| {
            try writer.print(".tran {e} {e}", .{ t.step, t.stop });
            if (t.start != 0) try writer.print(" {e}", .{t.start});
            if (t.max_step) |ms| try writer.print(" {e}", .{ms});
            if (t.uic) try writer.writeAll(" uic");
            try writer.writeByte('\n');
        },
        .noise => |n| {
            try writer.print(".noise V({s}", .{n.output_node});
            if (n.output_ref) |r| try writer.print(",{s}", .{r});
            try writer.print(") {s} {s} {d} {e} {e}", .{ n.input_src, SpiceIF.sweepStr(n.sweep), n.n_points, n.f_start, n.f_stop });
            if (n.points_per_summary) |pts| try writer.print(" {d}", .{pts});
            try writer.writeByte('\n');
        },
        .sens => |s| switch (s.mode) {
            .dc => try writer.print(".sens objfunc={{{s}}}\n", .{s.output_var}),
            .ac => {
                try writer.print(".sens acobjfunc={{{s}}}", .{s.output_var});
                if (s.ac_sweep) |sw| try writer.print("\n.ac {s} {d} {e} {e}", .{ SpiceIF.sweepStr(sw), s.ac_n_points.?, s.ac_f_start.?, s.ac_f_stop.? });
                try writer.writeByte('\n');
            },
            .tran, .tran_adjoint => {
                try writer.print(".sens objfunc={{{s}}}", .{s.output_var});
                if (s.mode == .tran_adjoint) try writer.writeAll(" adjoint=1");
                try writer.writeByte('\n');
            },
        },
        .tf => |t| try writer.print(".tf {s} {s}\n", .{ t.output_var, t.input_src }),
        .pz => {
            try writer.writeAll("* [UNSUPPORTED] .PZ not available in Xyce.\n");
            try writer.writeAll("* Workaround: use dense .AC sweep + external vector fitting.\n");
        },
        .disto => {
            try writer.writeAll("* [UNSUPPORTED] .DISTO not available in Xyce.\n");
            try writer.writeAll("* Workaround: use .HB and extract harmonic magnitudes.\n");
        },
        .pss => {
            try writer.writeAll("* [EMULATED] .PSS lowered to .HB\n");
            try writer.print(".HB {e}\n", .{an.pss.gfreq});
        },
        .sp => {
            try writer.writeAll(".LIN sparcalc=1\n");
            try writer.print(".ac {s} {d} {e} {e}\n", .{ SpiceIF.sweepStr(an.sp.sweep), an.sp.n_points, an.sp.f_start, an.sp.f_stop });
        },
        .hb => |h| {
            try writer.writeAll(".HB");
            for (h.freqs) |f| try writer.print(" {e}", .{f});
            try writer.writeByte('\n');
            try writer.print(".options HBINT numfreq={d}", .{h.n_harmonics});
            if (h.startup) {
                try writer.writeAll(" startup=1");
                if (h.startup_periods) |p| try writer.print(" startupperiods={d}", .{p});
            }
            try writer.writeByte('\n');
        },
        .mpde => try writer.writeAll("* TODO: emit .MPDE\n"),
        .four => {}, // emitted separately after .tran by emitTo
    }
}

pub fn emitSweep(writer: anytype, sw: SpiceIF.Sweep) !void {
    switch (sw) {
        .step => |s| {
            try writer.print(".STEP {s} ", .{s.param});
            switch (s.kind) {
                .lin => |lin| try writer.print("{e} {e} {e}", .{ lin.start, lin.stop, lin.step }),
                .dec => |d| try writer.print("DEC {d} {e} {e}", .{ d.points, d.start, d.stop }),
                .oct => |o| try writer.print("OCT {d} {e} {e}", .{ o.points, o.start, o.stop }),
                .list => |l| {
                    try writer.writeAll("LIST");
                    for (l.values) |v| try writer.print(" {e}", .{v});
                },
            }
            try writer.writeByte('\n');
        },
        .sampling => |s| {
            try writer.print(".SAMPLING\n+ numsamples={d}\n", .{s.num_samples});
            switch (s.method) {
                .mc => try writer.writeAll("+ sample_type=mc\n"),
                .lhs => try writer.writeAll("+ sample_type=lhs\n"),
            }
            for (s.params) |p| {
                try writer.print("+ param={s} ", .{p.name});
                switch (p.dist) {
                    .normal => |n| try writer.print("type=normal mean={e} std_dev={e}", .{ n.mean, n.std_dev }),
                    .uniform => |u| try writer.print("type=uniform lo={e} hi={e}", .{ u.lo, u.hi }),
                    .lognormal => |l| try writer.print("type=lognormal mean={e} std_dev={e}", .{ l.mean, l.std_dev }),
                }
                try writer.writeByte('\n');
            }
        },
        .embedded_sampling => try writer.writeAll("* TODO: emit .EMBEDDEDSAMPLING\n"),
        .pce => try writer.writeAll("* TODO: emit .PCE\n"),
        .data => |d| {
            try writer.print(".DATA {s}", .{d.name});
            for (d.param_names) |pn| try writer.print(" {s}", .{pn});
            try writer.writeByte('\n');
            for (d.rows) |row| {
                try writer.writeByte('+');
                for (row) |v| try writer.print(" {e}", .{v});
                try writer.writeByte('\n');
            }
            try writer.writeAll(".ENDDATA\n");
        },
    }
}

pub fn emitNetlistComponent(writer: anytype, comp: SpiceIF.ComponentType) !void {
    try SpiceIF.emitComponent(writer, comp, .xyce);
}
