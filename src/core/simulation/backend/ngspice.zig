//! ngspice-specific emit logic.
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
        .sens => |s| try writer.print(".sens {s}\n", .{s.output_var}),
        .tf => |t| try writer.print(".tf {s} {s}\n", .{ t.output_var, t.input_src }),
        .pz => |p| {
            const tf = switch (p.tf_type) {
                .vol => "vol",
                .cur => "cur",
            };
            const pzt = switch (p.pz_type) {
                .pol => "pol",
                .zer => "zer",
                .pz => "pz",
            };
            try writer.print(".pz {s} {s} {s} {s} {s} {s}\n", .{ p.in_pos, p.in_neg, p.out_pos, p.out_neg, tf, pzt });
        },
        .disto => |d| {
            try writer.print(".disto {s} {d} {e} {e}", .{ SpiceIF.sweepStr(d.sweep), d.n_points, d.f_start, d.f_stop });
            if (d.f2_over_f1) |r| try writer.print(" {e}", .{r});
            try writer.writeByte('\n');
        },
        .pss => |p| try writer.print(".pss {e} {e} {d} {d} {d} {e}\n", .{ p.gfreq, p.tstab, p.fft_points, p.harms, p.sciter, p.steadycoeff }),
        .sp => |s| try writer.print(".sp {s} {d} {e} {e}\n", .{ SpiceIF.sweepStr(s.sweep), s.n_points, s.f_start, s.f_stop }),
        .hb => {
            try writer.writeAll("* [UNSUPPORTED] .HB not available in ngspice.\n");
            if (an.hb.freqs.len == 1) {
                try writer.writeAll("* Partial workaround: using .PSS (experimental)\n");
                try writer.print(".pss {e} 0 1024 {d} 150 1e-3\n", .{ an.hb.freqs[0], an.hb.n_harmonics });
            }
        },
        .mpde => try writer.writeAll("* [UNSUPPORTED] .MPDE not available in ngspice.\n"),
        .four => {}, // emitted separately after .tran by emitTo
    }
}

pub fn emitSweep(writer: anytype, sw: SpiceIF.Sweep) !void {
    switch (sw) {
        .step, .sampling, .data => {
            // ngspice sweeps handled in control section, not here
        },
        .embedded_sampling => try writer.writeAll("* [UNSUPPORTED] .EMBEDDEDSAMPLING not available in ngspice.\n"),
        .pce => try writer.writeAll("* [UNSUPPORTED] .PCE not available in ngspice.\n"),
    }
}

pub fn emitNetlistComponent(writer: anytype, comp: SpiceIF.ComponentType) !void {
    try SpiceIF.emitComponent(writer, comp, .ngspice);
}

pub fn emitControlSection(writer: anytype, nl: *const SpiceIF.Netlist) !void {
    var needs_control = false;
    for (nl.sweeps.items) |sw| {
        switch (sw) {
            .step, .sampling, .data => {
                needs_control = true;
                break;
            },
            else => {},
        }
    }
    if (!needs_control) return;

    try writer.writeAll("\n.control\n");

    for (nl.sweeps.items) |sw| {
        switch (sw) {
            .step => |s| switch (s.kind) {
                .list => |l| {
                    try writer.writeAll("foreach __step_val");
                    for (l.values) |v| try writer.print(" {e}", .{v});
                    try writer.writeByte('\n');
                    try writer.print("  alterparam {s} = $__step_val\n", .{s.param});
                    try writer.writeAll("  reset\n  run\nend\n");
                },
                .lin => |lin| {
                    try writer.print("let __start = {e}\nlet __stop = {e}\nlet __step = {e}\n", .{ lin.start, lin.stop, lin.step });
                    try writer.writeAll("let __val = __start\nwhile __val le __stop\n");
                    try writer.print("  alterparam {s} = $&__val\n", .{s.param});
                    try writer.writeAll("  reset\n  run\n  let __val = __val + __step\nend\n");
                },
                .dec, .oct => try writer.writeAll("* TODO: logarithmic step emulation\n"),
            },
            .sampling => |s| {
                try writer.print("let __nsamples = {d}\nlet __i = 0\nwhile __i < __nsamples\n", .{s.num_samples});
                for (s.params) |p| {
                    switch (p.dist) {
                        .normal => |n| try writer.print("  let __rv = {e} + {e} * sgauss(0)\n", .{ n.mean, n.std_dev }),
                        .uniform => |u| try writer.print("  let __rv = {e} + ({e} - {e}) * sunif(0)\n", .{ u.lo, u.hi, u.lo }),
                        .lognormal => |l| try writer.print("  let __rv = exp({e} + {e} * sgauss(0))\n", .{ l.mean, l.std_dev }),
                    }
                    try writer.print("  alterparam {s} = $&__rv\n", .{p.name});
                }
                try writer.writeAll("  reset\n  run\n  let __i = __i + 1\nend\n");
            },
            .data => |d| {
                for (d.rows) |row| {
                    for (d.param_names, 0..) |pn, col| try writer.print("  alterparam {s} = {e}\n", .{ pn, row[col] });
                    try writer.writeAll("  reset\n  run\n");
                }
            },
            else => {},
        }
    }
    try writer.writeAll(".endc\n");
}
