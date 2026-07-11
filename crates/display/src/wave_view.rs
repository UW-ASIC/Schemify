//! Waveform viewer — its own native window (egui immediate viewport),
//! opened from the toolbar `∿` button or the `WaveOpen` command (MCP/CLI).
//!
//! Layout: top bar (expression bar + view controls) · left signal browser
//! with live filter · right trace/style + cursor readout panel · central
//! stacked panes (shared X, independent Y).
//!
//! View manipulation (pan/zoom/cursor drag) mutates `WaveState` directly,
//! like the schematic canvas does; the `Wave*` commands remain the
//! scriptable/MCP surface for the same state.

use eframe::egui::{self, Color32, Pos2, Rect, Sense, Shape, Stroke, Vec2};

use schemify_editor::handler::App;
use schemify_editor::schemify::{Color, Command};
use schemify_editor::wave::{format_si, LineStyle, WaveState};

use crate::state::GuiState;

const CURSOR_A_COLOR: Color32 = Color32::from_rgb(0, 200, 255);
const CURSOR_B_COLOR: Color32 = Color32::from_rgb(255, 60, 160);
const PANE_GAP: f32 = 6.0;
const TICK_FONT: f32 = 11.0;

// ════════════════════════════════════════════════════════════
// Viewer entry point (Simulate menu)
// ════════════════════════════════════════════════════════════

/// Toggle the viewer window; file dialog on first use (no data loaded yet).
pub fn open_viewer(app: &mut App) {
    if app.state.wave.is_some() {
        app.state.wave_window_open = !app.state.wave_window_open;
    } else {
        open_raw_dialog(app);
    }
}

fn open_raw_dialog(app: &mut App) {
    if let Some(path) = rfd::FileDialog::new()
        .add_filter("SPICE raw", &["raw", "qraw"])
        .pick_file()
    {
        app.dispatch(Command::WaveOpen {
            path: path.to_string_lossy().into_owned(),
        }).or_status(app);
    }
}

// ════════════════════════════════════════════════════════════
// Viewer window (immediate viewport)
// ════════════════════════════════════════════════════════════

pub fn wave_window(ctx: &egui::Context, app: &mut App, gui: &mut GuiState) {
    if !app.state.wave_window_open || app.state.wave.is_none() {
        return;
    }
    let viewport_id = egui::ViewportId::from_hash_of("schemify_wave_viewer");
    let builder = egui::ViewportBuilder::default()
        .with_title("Waveforms — Schemify")
        .with_inner_size([1100.0, 700.0]);

    // Immediate viewport: runs inline on this thread, same App borrow.
    let mut close = false;
    ctx.show_viewport_immediate(viewport_id, builder, |ui, _class| {
        if ui.ctx().input(|i| i.viewport().close_requested()) {
            close = true;
        }
        window_contents(ui, app, gui);
    });
    if close {
        app.state.wave_window_open = false;
    }
}

fn window_contents(ui: &mut egui::Ui, app: &mut App, gui: &mut GuiState) {
    let ctx = ui.ctx().clone();
    handle_screenshot(&ctx, app, gui);

    top_bar(ui, app, gui);
    signal_browser(ui, app, gui);
    trace_panel(ui, app);
    status_line(ui, app);

    let Some(w) = app.state.wave.as_deref_mut() else {
        return;
    };
    panes_view(ui, w, gui);

    // Window-local keys (only when no text field has focus).
    if ctx.memory(|m| m.focused().is_none()) {
        let Some(w) = app.state.wave.as_deref_mut() else {
            return;
        };
        ctx.input(|i| {
            if i.key_pressed(egui::Key::F) {
                w.zoom_fit();
            }
            if i.key_pressed(egui::Key::A) {
                toggle_cursor(w, 0);
            }
            if i.key_pressed(egui::Key::B) {
                toggle_cursor(w, 1);
            }
        });
    }
}

fn toggle_cursor(w: &mut WaveState, which: u8) {
    let [x0, x1] = effective_x_range(w);
    let c = if which == 0 {
        &mut w.cursor_a
    } else {
        &mut w.cursor_b
    };
    c.visible = !c.visible;
    if c.visible && (c.x < x0 || c.x > x1) {
        // Place at 1/3 (A) and 2/3 (B) so a fresh pair doesn't overlap.
        let f = if which == 0 { 1.0 / 3.0 } else { 2.0 / 3.0 };
        c.x = x0 + (x1 - x0) * f;
    }
}

// ════════════════════════════════════════════════════════════
// Top bar — expression bar + view controls
// ════════════════════════════════════════════════════════════

fn top_bar(ui: &mut egui::Ui, app: &mut App, gui: &mut GuiState) {
    egui::Panel::top("wave_top").show(ui, |ui| {
        ui.horizontal(|ui| {
            if ui.button("Open .raw…").clicked() {
                open_raw_dialog(app);
            }
            if ui.button("Reload").on_hover_text("Re-read all files").clicked() {
                app.dispatch(Command::WaveReload).or_status(app);
            }
            ui.separator();

            // Expression bar.
            let edit = egui::TextEdit::singleline(&mut gui.wave.expr)
                .hint_text("e.g. v(out) or db(v(out)/v(in))")
                .desired_width(280.0);
            let resp = ui.add(edit);
            let submit = (resp.lost_focus() && ui.input(|i| i.key_pressed(egui::Key::Enter)))
                || ui.button("Plot").clicked();
            if submit && !gui.wave.expr.trim().is_empty() {
                app.dispatch(Command::WaveAddTrace {
                    expr: gui.wave.expr.trim().to_string(),
                    file: None,
                    block: 0,
                    pane: None,
                }).or_status(app);
            }
            ui.separator();

            let Some(w) = app.state.wave.as_deref_mut() else {
                return;
            };

            if ui.button("Add pane").clicked() {
                w.panes.push(schemify_editor::wave::Pane::default());
                w.active_pane = (w.panes.len() - 1) as u16;
            }
            if w.panes.len() > 1 && ui.button("Remove pane").clicked() {
                let idx = w.active_pane;
                w.panes.remove(idx as usize);
                w.traces.retain(|t| t.pane != idx);
                for t in &mut w.traces {
                    if t.pane > idx {
                        t.pane -= 1;
                    }
                }
                w.active_pane = w.active_pane.min((w.panes.len() - 1) as u16);
            }
            ui.separator();

            if ui
                .selectable_label(
                    w.cursor_a.visible,
                    egui::RichText::new("Cursor A").color(CURSOR_A_COLOR),
                )
                .clicked()
            {
                toggle_cursor(w, 0);
            }
            if ui
                .selectable_label(
                    w.cursor_b.visible,
                    egui::RichText::new("Cursor B").color(CURSOR_B_COLOR),
                )
                .clicked()
            {
                toggle_cursor(w, 1);
            }
            ui.separator();

            let mut x_log = w.x_log;
            if ui.checkbox(&mut x_log, "X log").changed() {
                w.x_log = x_log;
            }
            if ui.button("Zoom fit (F)").clicked() {
                w.zoom_fit();
            }
            ui.separator();

            if ui.button("Export CSV…").clicked() {
                if let Some(path) = rfd::FileDialog::new()
                    .add_filter("CSV", &["csv"])
                    .save_file()
                {
                    app.dispatch(Command::WaveExportCsv {
                        path: path.to_string_lossy().into_owned(),
                    }).or_status(app);
                }
            }
            if ui.button("Export PNG…").clicked() {
                if let Some(path) = rfd::FileDialog::new()
                    .add_filter("PNG", &["png"])
                    .save_file()
                {
                    gui.wave.pending_png = Some(path);
                    // Screenshot of this viewport; arrives as an event.
                    ui.ctx()
                        .send_viewport_cmd(egui::ViewportCommand::Screenshot(
                            egui::UserData::default(),
                        ));
                }
            }
        });
    });
}

/// Save a completed viewport screenshot to the pending PNG path.
fn handle_screenshot(ctx: &egui::Context, app: &mut App, gui: &mut GuiState) {
    if gui.wave.pending_png.is_none() {
        return;
    }
    let image = ctx.input(|i| {
        i.events.iter().find_map(|e| match e {
            egui::Event::Screenshot { image, .. } => Some(image.clone()),
            _ => None,
        })
    });
    let Some(image) = image else {
        return;
    };
    let Some(path) = gui.wave.pending_png.take() else {
        return;
    };
    let [w, h] = image.size;
    app.state.status_msg = match image::save_buffer(
        &path,
        image.as_raw(),
        w as u32,
        h as u32,
        image::ColorType::Rgba8,
    ) {
        Ok(()) => format!("Exported {}", path.display()),
        Err(e) => format!("PNG export failed: {e}"),
    };
}

// ════════════════════════════════════════════════════════════
// Signal browser — live filter + per-file/block variable tree
// ════════════════════════════════════════════════════════════

fn signal_browser(ui: &mut egui::Ui, app: &mut App, gui: &mut GuiState) {
    egui::Panel::left("wave_signals")
        .default_size(220.0)
        .show(ui, |ui| {
            ui.horizontal(|ui| {
                ui.add(
                    egui::TextEdit::singleline(&mut gui.wave.filter)
                        .hint_text("Filter signals…")
                        .desired_width(140.0),
                );
                if !gui.wave.filter.is_empty() && ui.small_button("✕").clicked() {
                    gui.wave.filter.clear();
                }
            });
            let filter = gui.wave.filter.to_ascii_lowercase();

            // Collect plot clicks first (borrow: w immutable during tree walk).
            let mut to_plot: Vec<(String, u16, u16)> = Vec::new();
            let plot_visible = ui
                .button("Plot visible")
                .on_hover_text("Plot every signal matching the filter")
                .clicked();

            let Some(w) = app.state.wave.as_deref() else {
                return;
            };
            egui::ScrollArea::vertical().show(ui, |ui| {
                for (fi, f) in w.files.iter().enumerate() {
                    egui::CollapsingHeader::new(&f.name)
                        .default_open(true)
                        .show(ui, |ui| {
                            for (bi, p) in f.plots.iter().enumerate() {
                                let show_block = |ui: &mut egui::Ui,
                                                  to_plot: &mut Vec<(String, u16, u16)>| {
                                    if p.steps.len() > 1 {
                                        ui.weak(format!("{} sweep steps", p.steps.len()));
                                    }
                                    // Skip the scale variable (column 0).
                                    for v in p.variables.iter().skip(1) {
                                        let name_l = v.name.to_ascii_lowercase();
                                        if !filter.is_empty() && !name_l.contains(&filter) {
                                            continue;
                                        }
                                        let label = if v.kind.unit().is_empty() {
                                            v.name.clone()
                                        } else {
                                            format!("{}  ({})", v.name, v.kind.unit())
                                        };
                                        if ui.selectable_label(false, label).clicked()
                                            || plot_visible
                                        {
                                            to_plot.push((
                                                v.name.clone(),
                                                fi as u16,
                                                bi as u16,
                                            ));
                                        }
                                        if plot_visible {
                                            // Click already queued it above.
                                        }
                                    }
                                };
                                if f.plots.len() > 1 {
                                    egui::CollapsingHeader::new(format!(
                                        "[{}] {}",
                                        bi, p.plotname
                                    ))
                                    .default_open(bi == 0)
                                    .show(ui, |ui| show_block(ui, &mut to_plot));
                                } else {
                                    show_block(ui, &mut to_plot);
                                }
                            }
                        });
                }
            });

            for (expr, file, block) in to_plot {
                app.dispatch(Command::WaveAddTrace {
                    expr,
                    file: Some(file),
                    block,
                    pane: None,
                }).or_status(app);
            }
        });
}

// ════════════════════════════════════════════════════════════
// Trace + cursor readout panel
// ════════════════════════════════════════════════════════════

fn trace_panel(ui: &mut egui::Ui, app: &mut App) {
    egui::Panel::right("wave_traces")
        .default_size(240.0)
        .show(ui, |ui| {
            let Some(w) = app.state.wave.as_deref_mut() else {
                return;
            };
            ui.heading("Traces");
            let mut remove: Option<usize> = None;
            let n_panes = w.panes.len() as u16;
            let palette: Vec<Color32> = (0..w.traces.len())
                .map(|i| {
                    let c = w.trace_color(i);
                    Color32::from_rgb(c.r, c.g, c.b)
                })
                .collect();
            egui::ScrollArea::vertical()
                .max_height(ui.available_height() * 0.55)
                .show(ui, |ui| {
                    for (i, t) in w.traces.iter_mut().enumerate() {
                        ui.horizontal(|ui| {
                            // Color swatch → explicit style color.
                            let mut c32 = palette[i];
                            if ui.color_edit_button_srgba(&mut c32).changed() {
                                t.style.color = Color::rgb(c32.r(), c32.g(), c32.b());
                            }
                            let mut vis = t.style.visible;
                            if ui.checkbox(&mut vis, "").changed() {
                                t.style.visible = vis;
                            }
                            ui.label(egui::RichText::new(&t.expr).color(palette[i]).small())
                                .on_hover_text(format!(
                                    "file {} · block {} · pane {}",
                                    t.file, t.block, t.pane
                                ));
                        });
                        ui.horizontal(|ui| {
                            ui.add(
                                egui::DragValue::new(&mut t.style.width)
                                    .range(0.5..=8.0)
                                    .speed(0.1)
                                    .prefix("w "),
                            );
                            egui::ComboBox::from_id_salt(("ls", i))
                                .selected_text(match t.style.line_style {
                                    LineStyle::Solid => "solid",
                                    LineStyle::Dash => "dash",
                                    LineStyle::Dot => "dot",
                                })
                                .width(70.0)
                                .show_ui(ui, |ui| {
                                    ui.selectable_value(
                                        &mut t.style.line_style,
                                        LineStyle::Solid,
                                        "solid",
                                    );
                                    ui.selectable_value(
                                        &mut t.style.line_style,
                                        LineStyle::Dash,
                                        "dash",
                                    );
                                    ui.selectable_value(
                                        &mut t.style.line_style,
                                        LineStyle::Dot,
                                        "dot",
                                    );
                                });
                            let mut pane = t.pane;
                            if ui
                                .add(
                                    egui::DragValue::new(&mut pane)
                                        .range(0..=n_panes.saturating_sub(1))
                                        .prefix("pane "),
                                )
                                .changed()
                            {
                                t.pane = pane;
                            }
                            if ui.small_button("🗑").on_hover_text("Remove trace").clicked() {
                                remove = Some(i);
                            }
                        });
                        ui.separator();
                    }
                });
            if let Some(i) = remove {
                w.traces.remove(i);
            }

            // Cursor readouts.
            if w.cursor_a.visible || w.cursor_b.visible {
                ui.heading("Cursors");
                if w.cursor_a.visible {
                    ui.colored_label(CURSOR_A_COLOR, format!("A: {}", format_si(w.cursor_a.x, 4)));
                }
                if w.cursor_b.visible {
                    ui.colored_label(CURSOR_B_COLOR, format!("B: {}", format_si(w.cursor_b.x, 4)));
                }
                if w.cursor_a.visible && w.cursor_b.visible {
                    let dx = w.cursor_b.x - w.cursor_a.x;
                    ui.label(format!("ΔX: {}", format_si(dx, 4)));
                    if dx != 0.0 {
                        ui.label(format!("1/ΔX: {}", format_si(1.0 / dx, 4)));
                    }
                }
                ui.separator();
                for i in 0..w.traces.len() {
                    let ya = w.cursor_a.visible.then(|| w.value_at(i as u32, w.cursor_a.x));
                    let yb = w.cursor_b.visible.then(|| w.value_at(i as u32, w.cursor_b.x));
                    let mut line = w.traces[i].expr.clone();
                    if let Some(Some(v)) = ya {
                        line += &format!("  A:{}", format_si(v, 4));
                    }
                    if let Some(Some(v)) = yb {
                        line += &format!("  B:{}", format_si(v, 4));
                    }
                    if let (Some(Some(a)), Some(Some(b))) = (ya, yb) {
                        line += &format!("  ΔY:{}", format_si(b - a, 4));
                    }
                    ui.colored_label(palette[i], egui::RichText::new(line).small());
                }
            }
        });
}

fn status_line(ui: &mut egui::Ui, app: &App) {
    egui::Panel::bottom("wave_status").show(ui, |ui| {
        ui.horizontal(|ui| {
            if let Some(w) = app.state.wave.as_deref() {
                ui.weak(format!(
                    "{} file(s) · {} pane(s) · {} trace(s)",
                    w.files.len(),
                    w.panes.len(),
                    w.traces.len()
                ));
            }
            ui.separator();
            ui.weak(&app.state.status_msg);
        });
    });
}

// ════════════════════════════════════════════════════════════
// Pane rendering — stacked, shared X
// ════════════════════════════════════════════════════════════

/// X range actually drawn: explicit, or auto from trace extents.
fn effective_x_range(w: &WaveState) -> [f64; 2] {
    if !w.x_auto {
        return w.x_range;
    }
    let (mut lo, mut hi) = (f64::INFINITY, f64::NEG_INFINITY);
    for t in &w.traces {
        if let Some(xs) = w.trace_x(t) {
            for &v in xs {
                if v.is_finite() {
                    lo = lo.min(v);
                    hi = hi.max(v);
                }
            }
        }
    }
    if lo < hi {
        [lo, hi]
    } else {
        [0.0, 1.0]
    }
}

/// Y range for one pane: explicit, or min/max of its visible traces within
/// the current X window (5% pad).
fn effective_y_range(w: &WaveState, pane: u16, x_range: [f64; 2]) -> [f64; 2] {
    let p = &w.panes[pane as usize];
    if !p.y_auto {
        return p.y_range;
    }
    let (mut lo, mut hi) = (f64::INFINITY, f64::NEG_INFINITY);
    for t in w.traces.iter().filter(|t| t.pane == pane && t.style.visible) {
        let (Some(xs), Some(cached)) = (w.trace_x(t), t.cached.as_ref()) else {
            continue;
        };
        let n = xs.len().min(cached.re.len());
        for i in 0..n {
            let (x, y) = (xs[i], cached.re[i]);
            if x >= x_range[0] && x <= x_range[1] && y.is_finite() {
                lo = lo.min(y);
                hi = hi.max(y);
            }
        }
    }
    if lo >= hi {
        return [0.0, 1.0];
    }
    let pad = (hi - lo) * 0.05;
    [lo - pad, hi + pad]
}

/// World↔pixel transform for one pane (log-X aware).
struct XForm {
    rect: Rect,
    lx0: f64,
    lx1: f64,
    y0: f64,
    y1: f64,
    log: bool,
}

impl XForm {
    fn new(rect: Rect, x: [f64; 2], y: [f64; 2], log: bool) -> Self {
        let m = |v: f64| if log { v.max(1e-300).log10() } else { v };
        let (lx0, mut lx1) = (m(x[0]), m(x[1]));
        if lx0 == lx1 {
            lx1 = lx0 + 1.0;
        }
        Self {
            rect,
            lx0,
            lx1,
            y0: y[0],
            y1: y[1],
            log,
        }
    }

    fn x_px(&self, x: f64) -> f32 {
        let lx = if self.log { x.max(1e-300).log10() } else { x };
        let f = (lx - self.lx0) / (self.lx1 - self.lx0);
        self.rect.left() + (f as f32) * self.rect.width()
    }

    fn px_x(&self, px: f32) -> f64 {
        let f = ((px - self.rect.left()) / self.rect.width()) as f64;
        let lx = self.lx0 + f * (self.lx1 - self.lx0);
        if self.log {
            10f64.powf(lx)
        } else {
            lx
        }
    }

    fn y_px(&self, y: f64) -> f32 {
        let f = (y - self.y0) / (self.y1 - self.y0);
        self.rect.bottom() - (f as f32) * self.rect.height()
    }
}

fn panes_view(ui: &mut egui::Ui, w: &mut WaveState, gui: &mut GuiState) {
    let total = ui.available_rect_before_wrap();
    let n = w.panes.len().max(1);
    let pane_h = (total.height() - PANE_GAP * (n as f32 - 1.0)) / n as f32;
    let x_range = effective_x_range(w);

    let painter = ui.painter_at(total);
    let bg = if ui.visuals().dark_mode {
        Color32::from_rgb(24, 24, 28)
    } else {
        Color32::from_rgb(250, 250, 252)
    };
    let grid_color = if ui.visuals().dark_mode {
        Color32::from_gray(55)
    } else {
        Color32::from_gray(210)
    };
    let text_color = ui.visuals().weak_text_color();

    let pointer = ui.ctx().pointer_latest_pos();
    let mut hovered_any = false;

    for pi in 0..n {
        let rect = Rect::from_min_size(
            Pos2::new(
                total.left(),
                total.top() + pi as f32 * (pane_h + PANE_GAP),
            ),
            Vec2::new(total.width(), pane_h),
        );
        // Inner plot area leaves room for tick labels.
        let plot = Rect::from_min_max(
            Pos2::new(rect.left() + 8.0, rect.top() + 6.0),
            Pos2::new(rect.right() - 8.0, rect.bottom() - 18.0),
        );
        painter.rect_filled(rect, 3.0, bg);
        let active = w.active_pane as usize == pi;
        if active && n > 1 {
            painter.rect_stroke(
                rect,
                3.0,
                Stroke::new(1.0_f32, ui.visuals().selection.stroke.color),
                egui::StrokeKind::Inside,
            );
        }

        let y_range = effective_y_range(w, pi as u16, x_range);
        let xf = XForm::new(plot, x_range, y_range, w.x_log);

        draw_grid(&painter, &xf, grid_color, text_color);
        draw_traces(&painter, w, pi as u16, &xf);
        draw_legend(&painter, w, pi as u16, plot);

        // Interaction.
        let resp = ui.interact(
            rect,
            egui::Id::new(("wave_pane", pi)),
            Sense::click_and_drag(),
        );
        if resp.hovered() {
            hovered_any = true;
            w.active_pane = pi as u16;
            handle_pane_input(ui, w, pi as u16, &xf, &resp, gui);
        }
        if resp.double_clicked() {
            w.zoom_fit();
        }
    }

    // Cursors span all panes: draw after so they sit on top.
    draw_cursors(ui, w, total, x_range, gui, hovered_any, pointer);
}

/// "Nice" tick positions over [lo, hi] (1/2/5 × 10^k steps).
fn ticks(lo: f64, hi: f64, target: usize) -> Vec<f64> {
    let span = hi - lo;
    if !(span.is_finite()) || span <= 0.0 {
        return vec![];
    }
    let raw = span / target.max(1) as f64;
    let mag = 10f64.powf(raw.log10().floor());
    let norm = raw / mag;
    let step = mag * if norm <= 1.0 {
        1.0
    } else if norm <= 2.0 {
        2.0
    } else if norm <= 5.0 {
        5.0
    } else {
        10.0
    };
    let first = (lo / step).ceil() * step;
    let mut out = Vec::new();
    let mut v = first;
    while v <= hi + step * 1e-9 {
        out.push(v);
        v += step;
    }
    out
}

fn draw_grid(painter: &egui::Painter, xf: &XForm, grid: Color32, text: Color32) {
    let font = egui::FontId::proportional(TICK_FONT);
    // X ticks: log mode ticks at decades.
    let xs = if xf.log {
        let (d0, d1) = (xf.lx0.floor() as i64, xf.lx1.ceil() as i64);
        (d0..=d1).map(|d| 10f64.powi(d as i32)).collect()
    } else {
        ticks(xf.lx0, xf.lx1, 7)
    };
    for x in xs {
        let px = xf.x_px(x);
        if px < xf.rect.left() - 1.0 || px > xf.rect.right() + 1.0 {
            continue;
        }
        painter.line_segment(
            [Pos2::new(px, xf.rect.top()), Pos2::new(px, xf.rect.bottom())],
            Stroke::new(0.5_f32, grid),
        );
        painter.text(
            Pos2::new(px, xf.rect.bottom() + 2.0),
            egui::Align2::CENTER_TOP,
            format_si(x, 3),
            font.clone(),
            text,
        );
    }
    for y in ticks(xf.y0, xf.y1, 4) {
        let py = xf.y_px(y);
        painter.line_segment(
            [
                Pos2::new(xf.rect.left(), py),
                Pos2::new(xf.rect.right(), py),
            ],
            Stroke::new(0.5_f32, grid),
        );
        painter.text(
            Pos2::new(xf.rect.left() + 2.0, py - 1.0),
            egui::Align2::LEFT_BOTTOM,
            format_si(y, 3),
            font.clone(),
            text,
        );
    }
}

fn draw_traces(painter: &egui::Painter, w: &WaveState, pane: u16, xf: &XForm) {
    for (ti, t) in w.traces.iter().enumerate() {
        if t.pane != pane || !t.style.visible {
            continue;
        }
        let (Some(xs), Some(cached), Some(steps)) =
            (w.trace_x(t), t.cached.as_ref(), w.trace_steps(t))
        else {
            continue;
        };
        let c = w.trace_color(ti);
        let stroke = Stroke::new(t.style.width, Color32::from_rgb(c.r, c.g, c.b));
        let n = xs.len().min(cached.re.len());

        for s in steps {
            let (a, b) = (s.start as usize, (s.end as usize).min(n));
            if b - a < 2 {
                continue;
            }
            let pts = decimate(&xs[a..b], &cached.re[a..b], xf);
            if pts.len() < 2 {
                continue;
            }
            match t.style.line_style {
                LineStyle::Solid => {
                    painter.add(Shape::line(pts, stroke));
                }
                LineStyle::Dash => painter.extend(Shape::dashed_line(&pts, stroke, 8.0, 5.0)),
                LineStyle::Dot => painter.extend(Shape::dashed_line(&pts, stroke, 1.5, 4.0)),
            }
        }
    }
}

/// Build screen points for one step, decimating to ~2 points per pixel
/// column (min/max) when the data is denser than the screen.
fn decimate(xs: &[f64], ys: &[f64], xf: &XForm) -> Vec<Pos2> {
    let px_w = xf.rect.width().max(1.0);
    let n = xs.len();
    let mut out = Vec::new();
    if n as f32 <= px_w * 2.0 {
        out.reserve(n);
        for i in 0..n {
            if ys[i].is_finite() && (!xf.log || xs[i] > 0.0) {
                out.push(Pos2::new(xf.x_px(xs[i]), xf.y_px(ys[i])));
            }
        }
        return out;
    }
    // Dense: per pixel column emit (min, max) in x order.
    let mut i = 0;
    while i < n {
        if xf.log && xs[i] <= 0.0 {
            i += 1;
            continue;
        }
        let px = xf.x_px(xs[i]);
        let col = px.floor();
        let (mut ymin, mut ymax) = (f64::INFINITY, f64::NEG_INFINITY);
        let (mut first_y, mut last_y) = (ys[i], ys[i]);
        let start = i;
        while i < n && xf.x_px(xs[i]).floor() == col {
            let y = ys[i];
            if y.is_finite() {
                ymin = ymin.min(y);
                ymax = ymax.max(y);
                if start == i {
                    first_y = y;
                }
                last_y = y;
            }
            i += 1;
        }
        if ymin > ymax {
            continue;
        }
        // Preserve direction: enter at first_y's side, leave at last_y's.
        if (first_y - ymin).abs() < (first_y - ymax).abs() {
            out.push(Pos2::new(px, xf.y_px(ymin)));
            out.push(Pos2::new(px, xf.y_px(ymax)));
        } else {
            out.push(Pos2::new(px, xf.y_px(ymax)));
            out.push(Pos2::new(px, xf.y_px(ymin)));
        }
        let _ = last_y;
    }
    out
}

fn draw_legend(painter: &egui::Painter, w: &WaveState, pane: u16, plot: Rect) {
    let font = egui::FontId::proportional(12.0);
    let mut y = plot.top() + 4.0;
    for (ti, t) in w.traces.iter().enumerate() {
        if t.pane != pane {
            continue;
        }
        let c = w.trace_color(ti);
        let color = if t.style.visible {
            Color32::from_rgb(c.r, c.g, c.b)
        } else {
            Color32::from_gray(110)
        };
        let label = match w.trace_steps(t).map(<[_]>::len).unwrap_or(1) {
            0 | 1 => t.expr.clone(),
            k => format!("{} [{k} steps]", t.expr),
        };
        painter.text(
            Pos2::new(plot.left() + 8.0, y),
            egui::Align2::LEFT_TOP,
            label,
            font.clone(),
            color,
        );
        y += 15.0;
    }
}

// ════════════════════════════════════════════════════════════
// Interaction — pan/zoom per pane, cursor drag spanning panes
// ════════════════════════════════════════════════════════════

fn handle_pane_input(
    ui: &egui::Ui,
    w: &mut WaveState,
    pane: u16,
    xf: &XForm,
    resp: &egui::Response,
    gui: &GuiState,
) {
    let scroll = ui.input(|i| i.smooth_scroll_delta.y);
    let shift = ui.input(|i| i.modifiers.shift);
    let pos = resp.hover_pos();

    if scroll != 0.0 {
        let factor = (-scroll as f64 / 200.0).exp();
        if shift {
            // Zoom Y of this pane around the pointer (drawn range is in xf).
            let [y0, y1] = [xf.y0, xf.y1];
            let cy = pos.map_or((y0 + y1) / 2.0, |p2| {
                y1 - ((p2.y - xf.rect.top()) / xf.rect.height()) as f64 * (y1 - y0)
            });
            let p = &mut w.panes[pane as usize];
            p.y_range = [cy - (cy - y0) * factor, cy + (y1 - cy) * factor];
            p.y_auto = false;
        } else {
            // Zoom X (shared) around the pointer.
            let [x0, x1] = effective_x_range(w);
            let cx = pos.map_or((x0 + x1) / 2.0, |p2| xf.px_x(p2.x));
            if w.x_log {
                let (l0, l1, lc) = (x0.log10(), x1.log10(), cx.max(1e-300).log10());
                w.x_range = [
                    10f64.powf(lc - (lc - l0) * factor),
                    10f64.powf(lc + (l1 - lc) * factor),
                ];
            } else {
                w.x_range = [cx - (cx - x0) * factor, cx + (x1 - cx) * factor];
            }
            w.x_auto = false;
        }
    }

    // Primary drag pans (unless a cursor is being dragged).
    if resp.dragged_by(egui::PointerButton::Primary) && gui.wave.drag_cursor.is_none() {
        let d = resp.drag_delta();
        if d.x != 0.0 {
            let [x0, x1] = effective_x_range(w);
            if w.x_log {
                let per_px = (x1.log10() - x0.log10()) / xf.rect.width() as f64;
                let shift_l = -d.x as f64 * per_px;
                w.x_range = [
                    10f64.powf(x0.log10() + shift_l),
                    10f64.powf(x1.log10() + shift_l),
                ];
            } else {
                let per_px = (x1 - x0) / xf.rect.width() as f64;
                let dx = -d.x as f64 * per_px;
                w.x_range = [x0 + dx, x1 + dx];
            }
            w.x_auto = false;
        }
        if d.y != 0.0 {
            let [y0, y1] = [xf.y0, xf.y1];
            let per_px = (y1 - y0) / xf.rect.height() as f64;
            let dy = d.y as f64 * per_px;
            let p = &mut w.panes[pane as usize];
            p.y_range = [y0 + dy, y1 + dy];
            p.y_auto = false;
        }
    }
}

fn draw_cursors(
    ui: &mut egui::Ui,
    w: &mut WaveState,
    total: Rect,
    x_range: [f64; 2],
    gui: &mut GuiState,
    hovered: bool,
    pointer: Option<Pos2>,
) {
    // Shared x transform across the full stacked area.
    let xf = XForm::new(total, x_range, [0.0, 1.0], w.x_log);
    let font = egui::FontId::proportional(11.0);
    let released = ui.input(|i| i.pointer.any_released());
    let pressed = ui.input(|i| i.pointer.primary_pressed());

    if released {
        gui.wave.drag_cursor = None;
    }

    for (which, color) in [(0u8, CURSOR_A_COLOR), (1u8, CURSOR_B_COLOR)] {
        let c = if which == 0 { w.cursor_a } else { w.cursor_b };
        if !c.visible {
            continue;
        }
        let px = xf.x_px(c.x);
        ui.painter().line_segment(
            [Pos2::new(px, total.top()), Pos2::new(px, total.bottom())],
            Stroke::new(1.0_f32, color),
        );
        // X tag at the bottom.
        let tag = format_si(c.x, 4);
        let galley = ui
            .painter()
            .layout_no_wrap(tag, font.clone(), Color32::BLACK);
        let tag_rect = Rect::from_center_size(
            Pos2::new(px, total.bottom() - 10.0),
            galley.size() + Vec2::new(8.0, 4.0),
        );
        ui.painter().rect_filled(tag_rect, 3.0, color);
        ui.painter().galley(
            tag_rect.min + Vec2::new(4.0, 2.0),
            galley,
            Color32::BLACK,
        );

        // Start drag when pressed near the line.
        if hovered && pressed && gui.wave.drag_cursor.is_none() {
            if let Some(p) = pointer {
                if (p.x - px).abs() < 6.0 {
                    gui.wave.drag_cursor = Some(which);
                }
            }
        }
    }

    // Apply active drag.
    if let (Some(which), Some(p)) = (gui.wave.drag_cursor, pointer) {
        let x = xf.px_x(p.x.clamp(total.left(), total.right()));
        if which == 0 {
            w.cursor_a.x = x;
        } else {
            w.cursor_b.x = x;
        }
    }
}
