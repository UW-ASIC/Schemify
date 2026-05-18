const std = @import("std");
const dvui = @import("dvui");
const st = @import("state");
const AppState = st.AppState;
const theme_config = @import("theme_config");
const simulation = @import("simulation");

inline fn winRectPtr(wr: *st.WinRect) *dvui.Rect {
    return @ptrCast(wr);
}

pub fn drawAll(app: *AppState) void {
    const cold = &app.gui.cold;
    for (0..cold.n_optimizer_windows) |i| {
        drawWindow(app, &cold.optimizer_windows[i], i);
    }
}

fn drawWindow(app: *AppState, win: *st.OptimizerWindowState, win_idx: usize) void {
    if (!win.is_open) return;

    // Run discovery once on first open
    if (!win.discovery_done) {
        runDiscovery(app, win);
        win.discovery_done = true;
    }
    const bg = theme_config.chromeToolbarBg();
    var fwin = dvui.floatingWindow(@src(), .{
        .open_flag = &win.is_open,
        .rect = winRectPtr(&win.win_rect),
    }, .{
        .id_extra = win_idx,
        .min_size_content = .{ .w = 650, .h = 500 },
        .background = true,
        .color_fill = .{ .r = bg.r, .g = bg.g, .b = bg.b, .a = 220 },
        .color_border = .{ .r = bg.r +| 30, .g = bg.g +| 30, .b = bg.b +| 30, .a = 255 },
    });
    defer fwin.deinit();
    fwin.dragAreaSet(dvui.windowHeader("Optimizer", "", &win.is_open));

    drawTabBar(win);

    switch (win.active_tab) {
        .setup => drawSetupTab(win),
        .run => drawRunTab(win),
        .results => drawResultsTab(win),
        .sweep => drawSweepTab(win),
    }
}

// ── Tab bar ──────────────────────────────────────────────────────────────────

fn drawTabBar(win: *st.OptimizerWindowState) void {
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .padding = .{ .x = 8, .y = 4, .w = 8, .h = 4 } });
    defer row.deinit();

    const tabs = [_]struct { tab: st.OptimizerWindowState.Tab, label: [:0]const u8 }{
        .{ .tab = .setup, .label = "Setup" },
        .{ .tab = .run, .label = "Run" },
        .{ .tab = .results, .label = "Results" },
        .{ .tab = .sweep, .label = "Sweep" },
    };

    for (tabs, 0..) |entry, i| {
        const active = win.active_tab == entry.tab;
        if (dvui.button(@src(), entry.label, .{}, .{
            .id_extra = i,
            .style = if (active) .highlight else .control,
        })) {
            win.active_tab = entry.tab;
        }
    }
}

// ── Discovery ────────────────────────────────────────────────────────────────

fn runDiscovery(app: *AppState, win: *st.OptimizerWindowState) void {
    const doc = app.active() orelse return;
    const sch = &doc.sch;

    // Discover optimizable devices from schematic instances
    const inst_slice = sch.instances.slice();
    win.n_discovered_devices = simulation.optimizer.discoverOptimizableDevices(
        inst_slice.items(.kind),
        inst_slice.items(.name),
        inst_slice.items(.prop_start),
        inst_slice.items(.prop_count),
        sch.props.items,
        &sch.strings,
        &win.discovered_devices,
    );

    // Pre-populate device_entries from discovered devices
    for (win.discovered_devices[0..win.n_discovered_devices], 0..) |dd, i| {
        win.device_entries[i].enabled = dd.enabled;
        @memcpy(win.device_entries[i].instance_buf[0..dd.instance_len], dd.instance[0..dd.instance_len]);
        win.device_entries[i].instance_len = dd.instance_len;
        win.device_entries[i].device_type = @intFromEnum(dd.device_type);
        @memcpy(&win.device_entries[i].bound_min_buf, &dd.bound_min);
        @memcpy(&win.device_entries[i].bound_max_buf, &dd.bound_max);
    }
    win.n_devices = win.n_discovered_devices;

    // Discover measurements from .chn_tb measurements_decl field
    const meas_decl = sch.strings.get(sch.measurements_decl);
    if (meas_decl.len > 0) {
        const meas_list = simulation.optimizer.discoverMeasurementsFromDecl(meas_decl);
        const n: u8 = @intCast(@min(meas_list.len, 64));
        @memcpy(win.discovered_measurements[0..n], meas_list.items[0..n]);
        win.n_discovered_measurements = n;

        // Pre-populate spec entries from discovered measurements
        for (win.discovered_measurements[0..n], 0..) |dm, i| {
            if (i >= 32) break;
            @memcpy(win.spec_entries[i].name_buf[0..dm.name_len], dm.name[0..dm.name_len]);
            win.spec_entries[i].name_len = dm.name_len;
        }
        win.n_specs = @intCast(@min(n, 32));
    }
}

// ── Setup tab ────────────────────────────────────────────────────────────────

fn drawSetupTab(win: *st.OptimizerWindowState) void {
    var body = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .padding = .{ .x = 12, .y = 10, .w = 12, .h = 10 } });
    defer body.deinit();

    const muted = theme_config.chromeTextSecondary();

    // Devices section
    dvui.labelNoFmt(@src(), "Devices", .{}, .{ .id_extra = 100, .style = .highlight });
    _ = dvui.separator(@src(), .{ .id_extra = 101 });
    {
        var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .horizontal, .min_size_content = .{ .h = 150 }, .id_extra = 102 });
        defer scroll.deinit();

        if (win.n_discovered_devices == 0 and win.n_devices == 0) {
            dvui.labelNoFmt(@src(), "(no optimizable devices found)", .{}, .{ .id_extra = 103, .color_text = muted });
        } else {
            // Show discovered devices as checkboxes with bounds
            const n = @max(win.n_discovered_devices, win.n_devices);
            for (0..n) |i| {
                var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = i });
                defer row.deinit();

                _ = dvui.checkbox(@src(), &win.device_entries[i].enabled, "", .{ .id_extra = i });

                // Instance name (read-only for discovered, editable for manual)
                if (i < win.n_discovered_devices) {
                    const dd = &win.discovered_devices[i];
                    var label_buf: [80]u8 = undefined;
                    const label = std.fmt.bufPrint(&label_buf, "{s}  {s}", .{ dd.instanceSlice(), dd.kindSlice() }) catch dd.instanceSlice();
                    dvui.labelNoFmt(@src(), label, .{}, .{ .id_extra = i, .min_size_content = .{ .w = 180 }, .gravity_y = 0.5 });
                } else {
                    var te = dvui.textEntry(@src(), .{
                        .text = .{ .buffer = &win.device_entries[i].instance_buf },
                        .placeholder = "Instance name",
                    }, .{ .id_extra = i, .min_size_content = .{ .w = 180 } });
                    te.deinit();
                }

                // Bounds
                var te_min = dvui.textEntry(@src(), .{
                    .text = .{ .buffer = &win.device_entries[i].bound_min_buf },
                    .placeholder = "Min",
                }, .{ .id_extra = i, .min_size_content = .{ .w = 60 } });
                te_min.deinit();

                dvui.labelNoFmt(@src(), "to", .{}, .{ .id_extra = i, .gravity_y = 0.5 });

                var te_max = dvui.textEntry(@src(), .{
                    .text = .{ .buffer = &win.device_entries[i].bound_max_buf },
                    .placeholder = "Max",
                }, .{ .id_extra = i, .min_size_content = .{ .w = 60 } });
                te_max.deinit();
            }
        }
    }

    // Add device button
    if (win.n_devices < 32) {
        if (dvui.button(@src(), "+ Add Device", .{}, .{ .id_extra = 110 })) {
            win.n_devices += 1;
        }
    }

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .h = 8 }, .id_extra = 111 });

    // Specifications section
    dvui.labelNoFmt(@src(), "Specifications", .{}, .{ .id_extra = 120, .style = .highlight });
    _ = dvui.separator(@src(), .{ .id_extra = 121 });
    {
        var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .horizontal, .min_size_content = .{ .h = 100 }, .id_extra = 122 });
        defer scroll.deinit();

        if (win.n_discovered_measurements == 0 and win.n_specs == 0) {
            dvui.labelNoFmt(@src(), "(no measurements discovered)", .{}, .{ .id_extra = 123, .color_text = muted });
        } else {
            const n = @max(win.n_discovered_measurements, win.n_specs);
            for (0..n) |i| {
                if (i >= 32) break;
                var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = i });
                defer row.deinit();

                // Measurement name (read-only for discovered)
                if (i < win.n_discovered_measurements) {
                    const dm = &win.discovered_measurements[i];
                    var label_buf: [80]u8 = undefined;
                    const label = if (dm.unit_len > 0)
                        std.fmt.bufPrint(&label_buf, "{s} ({s})", .{ dm.nameSlice(), dm.unitSlice() }) catch dm.nameSlice()
                    else
                        dm.nameSlice();
                    dvui.labelNoFmt(@src(), label, .{}, .{ .id_extra = i, .min_size_content = .{ .w = 160 }, .gravity_y = 0.5 });
                } else {
                    var te_name = dvui.textEntry(@src(), .{
                        .text = .{ .buffer = &win.spec_entries[i].name_buf },
                        .placeholder = "Spec name",
                    }, .{ .id_extra = i, .min_size_content = .{ .w = 160 } });
                    te_name.deinit();
                }

                var te_target = dvui.textEntry(@src(), .{
                    .text = .{ .buffer = &win.spec_entries[i].target_buf },
                    .placeholder = "Target",
                }, .{ .id_extra = i, .min_size_content = .{ .w = 80 } });
                te_target.deinit();

                var te_weight = dvui.textEntry(@src(), .{
                    .text = .{ .buffer = &win.spec_entries[i].weight_buf },
                    .placeholder = "Weight",
                }, .{ .id_extra = i, .min_size_content = .{ .w = 60 } });
                te_weight.deinit();
            }
        }
    }

    // Add spec button
    if (win.n_specs < 32) {
        if (dvui.button(@src(), "+ Add Spec", .{}, .{ .id_extra = 130 })) {
            win.n_specs += 1;
        }
    }

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .h = 8 }, .id_extra = 131 });

    // Config section
    dvui.labelNoFmt(@src(), "Configuration", .{}, .{ .id_extra = 140, .style = .highlight });
    _ = dvui.separator(@src(), .{ .id_extra = 141 });
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = 142 });
        defer row.deinit();
        dvui.labelNoFmt(@src(), "Max generations", .{}, .{ .min_size_content = .{ .w = 110 }, .gravity_y = 0.5, .id_extra = 143 });
        var te = dvui.textEntry(@src(), .{
            .text = .{ .buffer = &win.max_generations_buf },
            .placeholder = "100",
        }, .{ .id_extra = 144, .min_size_content = .{ .w = 60 } });
        te.deinit();
    }
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = 145 });
        defer row.deinit();
        dvui.labelNoFmt(@src(), "Timeout (s)", .{}, .{ .min_size_content = .{ .w = 110 }, .gravity_y = 0.5, .id_extra = 146 });
        var te = dvui.textEntry(@src(), .{
            .text = .{ .buffer = &win.timeout_buf },
            .placeholder = "300",
        }, .{ .id_extra = 147, .min_size_content = .{ .w = 60 } });
        te.deinit();
    }
    _ = dvui.checkbox(@src(), &win.stop_on_feasible, "Stop on first feasible", .{ .id_extra = 148 });

    _ = dvui.spacer(@src(), .{ .expand = .vertical, .id_extra = 149 });

    // Run button
    _ = dvui.separator(@src(), .{ .id_extra = 150 });
    if (dvui.button(@src(), "Run Optimization", .{}, .{ .id_extra = 151, .style = .highlight })) {
        win.active_tab = .run;
        win.status = .running;
        win.generation = 0;
    }
}

// ── Run tab ──────────────────────────────────────────────────────────────────

fn drawRunTab(win: *st.OptimizerWindowState) void {
    var body = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .padding = .{ .x = 12, .y = 10, .w = 12, .h = 10 } });
    defer body.deinit();

    const muted = theme_config.chromeTextSecondary();

    // Status
    const status_text: [:0]const u8 = switch (win.status) {
        .idle => "Idle",
        .running => "Running...",
        .completed => "Completed",
        .failed => "Failed",
    };
    dvui.labelNoFmt(@src(), status_text, .{}, .{
        .id_extra = 200,
        .style = if (win.status == .running) .highlight else .control,
    });
    _ = dvui.separator(@src(), .{ .id_extra = 201 });

    // Progress
    {
        var gen_buf: [64]u8 = undefined;
        const gen_text = std.fmt.bufPrint(&gen_buf, "Generation {d} / {d}", .{ win.generation, win.max_generations }) catch "---";
        dvui.labelNoFmt(@src(), gen_text, .{}, .{ .id_extra = 202 });
    }

    // Feasibility
    if (win.pop_size > 0) {
        var feas_buf: [64]u8 = undefined;
        const pct = if (win.pop_size > 0) (win.feasible_count * 100) / win.pop_size else 0;
        const feas_text = std.fmt.bufPrint(&feas_buf, "{d} / {d} feasible ({d}%)", .{ win.feasible_count, win.pop_size, pct }) catch "---";
        dvui.labelNoFmt(@src(), feas_text, .{}, .{ .id_extra = 203 });
    }

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .h = 8 }, .id_extra = 204 });

    // Best summary
    dvui.labelNoFmt(@src(), "Best Solution", .{}, .{ .id_extra = 205, .style = .highlight });
    _ = dvui.separator(@src(), .{ .id_extra = 206 });
    {
        const summary = if (win.best_summary_len > 0) win.best_summary[0..win.best_summary_len] else "No results yet";
        dvui.labelNoFmt(@src(), summary, .{}, .{ .id_extra = 207, .color_text = muted });
    }

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .h = 8 }, .id_extra = 208 });

    // Log area
    dvui.labelNoFmt(@src(), "Log", .{}, .{ .id_extra = 209, .style = .highlight });
    _ = dvui.separator(@src(), .{ .id_extra = 210 });
    {
        var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .id_extra = 211 });
        defer scroll.deinit();
        const log_text = if (win.log_len > 0) win.log_buf[0..win.log_len] else "(empty)";
        dvui.labelNoFmt(@src(), log_text, .{}, .{ .id_extra = 212, .color_text = muted });
    }

    _ = dvui.separator(@src(), .{ .id_extra = 213 });

    // Stop button
    if (win.status == .running) {
        if (dvui.button(@src(), "Stop", .{}, .{ .id_extra = 214, .style = .highlight })) {
            win.cancelled.store(true, .release);
        }
    }
}

// ── Results tab ──────────────────────────────────────────────────────────────

fn drawResultsTab(win: *st.OptimizerWindowState) void {
    var body = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .padding = .{ .x = 12, .y = 10, .w = 12, .h = 10 } });
    defer body.deinit();

    const muted = theme_config.chromeTextSecondary();

    dvui.labelNoFmt(@src(), "Optimization Results", .{}, .{ .id_extra = 300, .style = .highlight });
    _ = dvui.separator(@src(), .{ .id_extra = 301 });

    if (win.n_results == 0) {
        dvui.labelNoFmt(@src(), "No results yet. Run the optimizer first.", .{}, .{ .id_extra = 302, .color_text = muted });
    } else {
        // Header
        {
            var hdr = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = 303 });
            defer hdr.deinit();
            dvui.labelNoFmt(@src(), "Rank", .{}, .{ .id_extra = 304, .min_size_content = .{ .w = 50 } });
            dvui.labelNoFmt(@src(), "Feasible", .{}, .{ .id_extra = 305, .min_size_content = .{ .w = 60 } });
            dvui.labelNoFmt(@src(), "Objectives", .{}, .{ .id_extra = 306, .expand = .horizontal });
            dvui.labelNoFmt(@src(), "Apply", .{}, .{ .id_extra = 307, .min_size_content = .{ .w = 50 } });
        }
        _ = dvui.separator(@src(), .{ .id_extra = 308 });

        // Result rows
        {
            var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .id_extra = 309 });
            defer scroll.deinit();

            const count = @min(win.n_results, 32);
            for (0..count) |i| {
                var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = i });
                defer row.deinit();

                var rank_buf: [8]u8 = undefined;
                const rank_text = std.fmt.bufPrint(&rank_buf, "{d}", .{win.result_individuals[i].rank}) catch "-";
                dvui.labelNoFmt(@src(), rank_text, .{}, .{ .id_extra = i, .min_size_content = .{ .w = 50 } });

                const feas_text: [:0]const u8 = if (win.result_individuals[i].feasible) "Yes" else "No";
                dvui.labelNoFmt(@src(), feas_text, .{}, .{ .id_extra = i, .min_size_content = .{ .w = 60 } });

                // Objectives summary
                var obj_buf: [64]u8 = undefined;
                const n_obj = win.result_individuals[i].n_objectives;
                const obj_text = if (n_obj > 0)
                    std.fmt.bufPrint(&obj_buf, "{d:.3}", .{win.result_individuals[i].objectives[0]}) catch "-"
                else
                    "-";
                dvui.labelNoFmt(@src(), obj_text, .{}, .{ .id_extra = i, .expand = .horizontal });

                if (i < 32) {
                    _ = dvui.checkbox(@src(), &win.apply_checks[i], "", .{ .id_extra = i });
                }
            }
        }
    }

    _ = dvui.spacer(@src(), .{ .expand = .vertical, .id_extra = 310 });
    _ = dvui.separator(@src(), .{ .id_extra = 311 });

    if (win.n_results > 0) {
        if (dvui.button(@src(), "Apply Selected", .{}, .{ .id_extra = 312, .style = .highlight })) {
            // Apply logic will be wired later
        }
    }
}

// ── Sweep tab ────────────────────────────────────────────────────────────────

fn drawSweepTab(win: *st.OptimizerWindowState) void {
    var body = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .padding = .{ .x = 12, .y = 10, .w = 12, .h = 10 } });
    defer body.deinit();

    const muted = theme_config.chromeTextSecondary();

    dvui.labelNoFmt(@src(), "Parameter Sweep", .{}, .{ .id_extra = 400, .style = .highlight });
    _ = dvui.separator(@src(), .{ .id_extra = 401 });

    // Device selection
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = 402 });
        defer row.deinit();
        dvui.labelNoFmt(@src(), "Device index", .{}, .{ .min_size_content = .{ .w = 100 }, .gravity_y = 0.5, .id_extra = 403 });
        var idx_buf: [4]u8 = undefined;
        const idx_text = std.fmt.bufPrint(&idx_buf, "{d}", .{win.sweep_device_idx}) catch "0";
        dvui.labelNoFmt(@src(), idx_text, .{}, .{ .id_extra = 404 });
    }

    _ = dvui.checkbox(@src(), &win.sweep_analytical, "Analytical mode", .{ .id_extra = 405 });

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .h = 8 }, .id_extra = 406 });

    // Chart placeholder
    dvui.labelNoFmt(@src(), "Sweep Chart", .{}, .{ .id_extra = 407, .style = .highlight });
    _ = dvui.separator(@src(), .{ .id_extra = 408 });

    if (win.n_sweep_points == 0) {
        dvui.labelNoFmt(@src(), "No sweep data. Run a sweep to see results.", .{}, .{ .id_extra = 409, .color_text = muted });
    } else {
        var pts_buf: [32]u8 = undefined;
        const pts_text = std.fmt.bufPrint(&pts_buf, "{d} data points", .{win.n_sweep_points}) catch "---";
        dvui.labelNoFmt(@src(), pts_text, .{}, .{ .id_extra = 410 });
    }

    _ = dvui.spacer(@src(), .{ .expand = .vertical, .id_extra = 411 });
    _ = dvui.separator(@src(), .{ .id_extra = 412 });

    if (dvui.button(@src(), "Run Sweep", .{}, .{ .id_extra = 413, .style = .highlight })) {
        // Sweep logic will be wired later
    }
}
