use std::collections::HashMap;

use egui::{Color32, FontId, Painter, PointerButton, Pos2, Response, Stroke, StrokeKind};

use schemify_core::commands::{Command, Tool};
use schemify_core::primitives;
use schemify_core::types::Color;
use schemify_handler::state::{ArcStep, PanMode};
use schemify_handler::App;

// ── Viewport ─────────────────────────────────────────────────────────────────

/// Coordinate transform between world (schematic i32) and pixel (screen f32).
///
/// Transform: `pixel = center + (world - pan) * zoom`
pub struct CanvasViewport {
    /// Center of the canvas area in pixel coordinates.
    pub center: Pos2,
    /// Current zoom factor (from app state).
    pub zoom: f32,
    /// Pan offset in world coordinates.
    pub pan: [f32; 2],
}

impl CanvasViewport {
    /// Build a viewport from the current app state and canvas rect.
    pub fn from_app(app: &App, rect: egui::Rect) -> Self {
        Self {
            center: rect.center(),
            zoom: app.zoom(),
            pan: app.pan(),
        }
    }

    /// Convert world coordinates to pixel position.
    #[inline]
    pub fn world_to_pixel(&self, wx: f32, wy: f32) -> Pos2 {
        Pos2::new(
            self.center.x + (wx - self.pan[0]) * self.zoom,
            self.center.y + (wy - self.pan[1]) * self.zoom,
        )
    }

    /// Convert pixel position to world coordinates (unsnapped f32).
    #[inline]
    pub fn pixel_to_world(&self, px: f32, py: f32) -> [f32; 2] {
        [
            (px - self.center.x) / self.zoom + self.pan[0],
            (py - self.center.y) / self.zoom + self.pan[1],
        ]
    }

    /// Convert pixel position to snapped world coordinates (i32).
    pub fn snap_to_grid(&self, px: f32, py: f32, grid_size: f32) -> [i32; 2] {
        let [wx, wy] = self.pixel_to_world(px, py);
        let gs = if grid_size > 0.0 { grid_size } else { 1.0 };
        [
            (wx / gs).round() as i32 * gs as i32,
            (wy / gs).round() as i32 * gs as i32,
        ]
    }

    /// World-to-pixel for integer coords (convenience).
    #[inline]
    pub fn w2p(&self, wx: i32, wy: i32) -> Pos2 {
        self.world_to_pixel(wx as f32, wy as f32)
    }
}

// ── Palette ──────────────────────────────────────────────────────────────────

/// Canvas color constants for schematic rendering.
pub struct CanvasPalette {
    pub canvas_bg: Color32,
    pub grid_dot: Color32,
    pub wire: Color32,
    pub wire_selected: Color32,
    pub wire_endpoint: Color32,
    pub bus: Color32,
    pub inst_body: Color32,
    pub inst_selected: Color32,
    pub inst_pin: Color32,
    pub symbol_line: Color32,
    pub wire_preview: Color32,
    pub origin: Color32,
    pub selection_rect: Color32,
    pub rubber_band: Color32,
    pub text_label: Color32,
    pub geometry_line: Color32,
    pub geometry_fill: Color32,
}

impl CanvasPalette {
    pub fn dark() -> Self {
        Self {
            canvas_bg: Color32::from_rgb(30, 30, 36),
            grid_dot: Color32::from_rgba_premultiplied(80, 80, 90, 120),
            wire: Color32::from_rgb(100, 200, 100),
            wire_selected: Color32::from_rgb(255, 200, 50),
            wire_endpoint: Color32::from_rgb(130, 220, 130),
            bus: Color32::from_rgb(80, 140, 220),
            inst_body: Color32::from_rgb(200, 200, 210),
            inst_selected: Color32::from_rgb(255, 200, 50),
            inst_pin: Color32::from_rgb(200, 80, 80),
            symbol_line: Color32::from_rgb(200, 200, 210),
            wire_preview: Color32::from_rgb(255, 140, 40),
            origin: Color32::from_rgba_premultiplied(100, 100, 120, 80),
            selection_rect: Color32::from_rgba_premultiplied(80, 140, 255, 60),
            rubber_band: Color32::from_rgba_premultiplied(80, 140, 255, 40),
            text_label: Color32::from_rgba_premultiplied(180, 180, 195, 200),
            geometry_line: Color32::from_rgb(180, 180, 195),
            geometry_fill: Color32::from_rgba_premultiplied(60, 60, 80, 40),
        }
    }

    pub fn light() -> Self {
        Self {
            canvas_bg: Color32::from_rgb(245, 245, 248),
            grid_dot: Color32::from_rgba_premultiplied(160, 160, 170, 120),
            wire: Color32::from_rgb(30, 140, 30),
            wire_selected: Color32::from_rgb(200, 140, 0),
            wire_endpoint: Color32::from_rgb(40, 160, 40),
            bus: Color32::from_rgb(40, 80, 180),
            inst_body: Color32::from_rgb(50, 50, 60),
            inst_selected: Color32::from_rgb(200, 140, 0),
            inst_pin: Color32::from_rgb(180, 40, 40),
            symbol_line: Color32::from_rgb(50, 50, 60),
            wire_preview: Color32::from_rgb(220, 100, 20),
            origin: Color32::from_rgba_premultiplied(140, 140, 160, 80),
            selection_rect: Color32::from_rgba_premultiplied(40, 100, 220, 60),
            rubber_band: Color32::from_rgba_premultiplied(40, 100, 220, 30),
            text_label: Color32::from_rgba_premultiplied(60, 60, 70, 200),
            geometry_line: Color32::from_rgb(60, 60, 70),
            geometry_fill: Color32::from_rgba_premultiplied(200, 200, 220, 40),
        }
    }
}

// ── Geometry helpers ─────────────────────────────────────────────────────────

/// Draw an arc approximated with line segments.
/// Angles in degrees. Positive sweep is CCW.
fn stroke_arc(
    painter: &Painter,
    center: Pos2,
    radius_px: f32,
    start_deg: f32,
    sweep_deg: f32,
    stroke: Stroke,
) {
    let n_segs = ((sweep_deg.abs() / 10.0) as usize).clamp(8, 64);
    let start_rad = start_deg.to_radians();
    let sweep_rad = sweep_deg.to_radians();

    let mut prev = Pos2::new(
        center.x + radius_px * start_rad.cos(),
        center.y - radius_px * start_rad.sin(),
    );

    for i in 1..=n_segs {
        let t = i as f32 / n_segs as f32;
        let angle = start_rad + sweep_rad * t;
        let cur = Pos2::new(
            center.x + radius_px * angle.cos(),
            center.y - radius_px * angle.sin(),
        );
        painter.line_segment([prev, cur], stroke);
        prev = cur;
    }
}

/// Draw a circle approximated with line segments.
/// n_segs controls fidelity (24 for rendering, 16 for ghosts).
fn stroke_circle(
    painter: &Painter,
    center: Pos2,
    radius_px: f32,
    n_segs: usize,
    stroke: Stroke,
) {
    let mut prev = Pos2::new(center.x + radius_px, center.y);
    for i in 1..=n_segs {
        let angle = (i as f32) * std::f32::consts::TAU / n_segs as f32;
        let cur = Pos2::new(
            center.x + radius_px * angle.cos(),
            center.y + radius_px * angle.sin(),
        );
        painter.line_segment([prev, cur], stroke);
        prev = cur;
    }
}

/// Convert thickness field (tenths) to stroke width, default 1.0.
#[inline]
fn thickness_width(thickness: u8) -> f32 {
    if thickness > 0 {
        thickness as f32 / 10.0
    } else {
        1.0
    }
}

/// Convert schematic Color to egui Color32, with fallback default.
fn color_or(c: Color, default: Color32) -> Color32 {
    if c.is_none() {
        default
    } else {
        Color32::from_rgba_premultiplied(c.r, c.g, c.b, c.a)
    }
}

// ── Grid ─────────────────────────────────────────────────────────────────────

const GRID_MIN_STEP_PX: f32 = 3.0;
const GRID_MAX_POINTS: usize = 16_000;
const DEFAULT_GRID_SPACING: f32 = 10.0;

/// Render the background dot grid and origin crosshair.
fn render_grid(
    painter: &Painter,
    viewport: &CanvasViewport,
    palette: &CanvasPalette,
    show_grid: bool,
) {
    let clip = painter.clip_rect();

    // Origin crosshair (always shown).
    draw_origin(painter, viewport, palette, clip);

    if !show_grid {
        return;
    }

    draw_dot_grid(painter, viewport, palette, clip);
}

fn draw_origin(
    painter: &Painter,
    vp: &CanvasViewport,
    palette: &CanvasPalette,
    clip: egui::Rect,
) {
    let origin = vp.world_to_pixel(0.0, 0.0);
    let arm = 20.0_f32;
    let stroke = Stroke::new(1.0, palette.origin);

    // Horizontal arm
    let x0 = origin.x - arm;
    let x1 = origin.x + arm;
    if origin.y >= clip.min.y && origin.y <= clip.max.y {
        painter.line_segment(
            [Pos2::new(x0.max(clip.min.x), origin.y), Pos2::new(x1.min(clip.max.x), origin.y)],
            stroke,
        );
    }

    // Vertical arm
    let y0 = origin.y - arm;
    let y1 = origin.y + arm;
    if origin.x >= clip.min.x && origin.x <= clip.max.x {
        painter.line_segment(
            [Pos2::new(origin.x, y0.max(clip.min.y)), Pos2::new(origin.x, y1.min(clip.max.y))],
            stroke,
        );
    }
}

fn draw_dot_grid(
    painter: &Painter,
    vp: &CanvasViewport,
    palette: &CanvasPalette,
    clip: egui::Rect,
) {
    let spacing = DEFAULT_GRID_SPACING;
    let step_px = spacing * vp.zoom;

    // Skip if dots would be too dense to see.
    if step_px < GRID_MIN_STEP_PX {
        return;
    }

    // Determine visible world range.
    let [w_left, w_top] = vp.pixel_to_world(clip.min.x, clip.min.y);
    let [w_right, w_bottom] = vp.pixel_to_world(clip.max.x, clip.max.y);

    let x_start = (w_left / spacing).floor() as i32;
    let x_end = (w_right / spacing).ceil() as i32;
    let y_start = (w_top / spacing).floor() as i32;
    let y_end = (w_bottom / spacing).ceil() as i32;

    let cols = (x_end - x_start + 1).max(0) as usize;
    let rows = (y_end - y_start + 1).max(0) as usize;
    let total = cols.saturating_mul(rows);

    if total == 0 || total > GRID_MAX_POINTS {
        return;
    }

    let dot_radius = (0.8 * vp.zoom.min(2.0)).max(0.5);
    let color = palette.grid_dot;

    for gy in y_start..=y_end {
        let wy = gy as f32 * spacing;
        for gx in x_start..=x_end {
            let wx = gx as f32 * spacing;
            let p = vp.world_to_pixel(wx, wy);
            painter.circle_filled(p, dot_radius, color);
        }
    }
}

// ── Show (entry point) ───────────────────────────────────────────────────────

/// Render the schematic canvas and handle all interaction.
pub fn show(ui: &mut egui::Ui, app: &mut App) {
    let rect = ui.available_rect_before_wrap();
    let viewport = CanvasViewport::from_app(app, rect);
    let palette = if app.view_flags().dark_mode {
        CanvasPalette::dark()
    } else {
        CanvasPalette::light()
    };

    // Background fill.
    ui.painter().rect_filled(rect, 0.0, palette.canvas_bg);

    // Allocate interaction area (click + drag + scroll).
    let response = ui.allocate_rect(rect, egui::Sense::click_and_drag());
    let painter = ui.painter_at(rect);

    // Render layers (bottom to top).
    render_grid(&painter, &viewport, &palette, app.show_grid());
    render_wires(&painter, app, &viewport, &palette);
    render_instances(&painter, app, &viewport, &palette);
    render_geometry(&painter, app, &viewport, &palette);
    render_selection(&painter, app, &viewport, &palette);
    render_overlays(&painter, app, &viewport, &palette);

    // Handle interaction.
    handle(&response, app, &viewport, ui.ctx());

    // Update cursor world position.
    if let Some(pos) = response.hover_pos() {
        let [wx, wy] = viewport.pixel_to_world(pos.x, pos.y);
        app.set_cursor_world(wx as i32, wy as i32);
    }
}

// ── Wire rendering ───────────────────────────────────────────────────────────

fn render_wires(
    painter: &Painter,
    app: &App,
    viewport: &CanvasViewport,
    palette: &CanvasPalette,
) {
    let wires = app.wires();
    let n = wires.len();
    if n == 0 {
        return;
    }

    let wire_w = (1.8 * viewport.zoom).max(0.8);
    let wire_w_sel = (2.8 * viewport.zoom).max(1.2);
    let bus_w = wire_w * 2.5;
    let bus_w_sel = wire_w_sel * 2.5;

    // Build endpoint occurrence counts for junction detection.
    let mut point_counts: HashMap<(i32, i32), u8> = HashMap::with_capacity((n * 2).min(4096));
    for i in 0..n {
        let p0 = (wires.x0[i], wires.y0[i]);
        let p1 = (wires.x1[i], wires.y1[i]);
        *point_counts.entry(p0).or_insert(0) = point_counts.get(&p0).copied().unwrap_or(0).saturating_add(1);
        *point_counts.entry(p1).or_insert(0) = point_counts.get(&p1).copied().unwrap_or(0).saturating_add(1);
    }

    // Draw wire segments.
    for i in 0..n {
        let selected = app.is_wire_selected(i);
        let is_bus = wires.bus[i];
        let a = viewport.w2p(wires.x0[i], wires.y0[i]);
        let b = viewport.w2p(wires.x1[i], wires.y1[i]);

        let col = if selected {
            palette.wire_selected
        } else if !wires.color[i].is_none() {
            let c = wires.color[i];
            Color32::from_rgb(c.r, c.g, c.b)
        } else if is_bus {
            palette.bus
        } else {
            palette.wire
        };

        let base_w = if is_bus {
            if selected { bus_w_sel } else { bus_w }
        } else if selected {
            wire_w_sel
        } else {
            wire_w
        };

        let thickness_mult = thickness_width(wires.thickness[i]);
        let w = base_w * thickness_mult;

        painter.line_segment([a, b], Stroke::new(w, col));

        // Bus slash indicator at midpoint.
        if is_bus {
            let mx = (a.x + b.x) * 0.5;
            let my = (a.y + b.y) * 0.5;
            let slash_len = (6.0 * viewport.zoom.min(2.0)).max(4.0);
            let half = slash_len * 0.5;
            painter.line_segment(
                [Pos2::new(mx - half, my + half), Pos2::new(mx + half, my - half)],
                Stroke::new(wire_w, col),
            );
        }
    }

    // Draw junction markers (filled square) where 3+ wire endpoints meet.
    let junction_sz = (2.5 * viewport.zoom.min(2.0)).max(2.0);
    for (&(wx, wy), &count) in &point_counts {
        if count >= 3 {
            let p = viewport.w2p(wx, wy);
            let half = junction_sz;
            painter.rect_filled(
                egui::Rect::from_center_size(p, egui::Vec2::splat(half * 2.0)),
                0.0,
                palette.symbol_line,
            );
        }
    }

    // Wire endpoint dots.
    let ep_radius = (2.0 * viewport.zoom.min(2.0)).max(1.5);
    for i in 0..n {
        let a = viewport.w2p(wires.x0[i], wires.y0[i]);
        let b = viewport.w2p(wires.x1[i], wires.y1[i]);
        painter.circle_filled(a, ep_radius, palette.wire_endpoint);
        painter.circle_filled(b, ep_radius, palette.wire_endpoint);
    }

    // Net name labels (only when zoomed in enough and show_netlist is on).
    if viewport.zoom >= 0.3 && app.view_flags().show_netlist {
        let label_col = palette.text_label;
        for i in 0..n {
            let net_str = app.resolve(wires.net_name[i]);
            if net_str.is_empty() {
                continue;
            }
            let a = viewport.w2p(wires.x0[i], wires.y0[i]);
            let b = viewport.w2p(wires.x1[i], wires.y1[i]);
            let mx = (a.x + b.x) * 0.5;
            let my = (a.y + b.y) * 0.5 - 14.0;
            let font = FontId::proportional((11.0 * viewport.zoom.min(2.0)).max(9.0));
            painter.text(
                Pos2::new(mx, my),
                egui::Align2::CENTER_BOTTOM,
                net_str,
                font,
                label_col,
            );

            // Zero-length wires (net label markers) get a visible dot.
            if wires.x0[i] == wires.x1[i] && wires.y0[i] == wires.y1[i] {
                painter.circle_filled(
                    a,
                    (5.0 * viewport.zoom.min(2.0)).max(3.0),
                    Color32::from_rgba_premultiplied(220, 224, 232, 240),
                );
            }
        }
    }
}

// ── Instance rendering ───────────────────────────────────────────────────────

fn render_instances(
    painter: &Painter,
    app: &App,
    viewport: &CanvasViewport,
    palette: &CanvasPalette,
) {
    let insts = app.instances();
    let n = insts.len();
    if n == 0 {
        return;
    }

    let sym_w = (1.8 * viewport.zoom).max(0.9);
    let pin_r = (3.0 * viewport.zoom.min(2.0)).max(2.0);
    let dec_w = sym_w * 0.6;

    for i in 0..n {
        let selected = app.is_instance_selected(i);
        let origin = viewport.w2p(insts.x[i], insts.y[i]);
        let flags = insts.flags[i];
        let kind = insts.kind[i];

        let color = if selected {
            palette.inst_selected
        } else {
            palette.symbol_line
        };

        let stroke = Stroke::new(sym_w, color);

        // Look up the primitive entry for this device kind.
        let prim = primitives::find_by_name(kind.symbol_name());

        if let Some(entry) = prim {
            // Draw line segments from the primitive geometry.
            for seg in &entry.segments {
                let (ax, ay) = flags.transform_point(seg.x0 as i32, seg.y0 as i32);
                let (bx, by) = flags.transform_point(seg.x1 as i32, seg.y1 as i32);
                let pa = Pos2::new(
                    origin.x + ax as f32 * viewport.zoom,
                    origin.y + ay as f32 * viewport.zoom,
                );
                let pb = Pos2::new(
                    origin.x + bx as f32 * viewport.zoom,
                    origin.y + by as f32 * viewport.zoom,
                );
                painter.line_segment([pa, pb], stroke);
            }

            // Draw circles from the primitive geometry.
            for c in &entry.circles {
                let (cx, cy) = flags.transform_point(c.cx as i32, c.cy as i32);
                let center = Pos2::new(
                    origin.x + cx as f32 * viewport.zoom,
                    origin.y + cy as f32 * viewport.zoom,
                );
                let radius_px = c.r as f32 * viewport.zoom;
                if radius_px > 0.5 {
                    stroke_circle(painter, center, radius_px, 24, stroke);
                }
            }

            // Draw arcs from the primitive geometry.
            for a in &entry.arcs {
                let (cx, cy) = flags.transform_point(a.cx as i32, a.cy as i32);
                let center = Pos2::new(
                    origin.x + cx as f32 * viewport.zoom,
                    origin.y + cy as f32 * viewport.zoom,
                );
                let radius_px = a.r as f32 * viewport.zoom;
                if radius_px > 0.5 {
                    stroke_arc(
                        painter,
                        center,
                        radius_px,
                        a.start as f32,
                        a.sweep as f32,
                        stroke,
                    );
                }
            }

            // Draw rects from the primitive geometry.
            for r in &entry.rects {
                let (x0, y0) = flags.transform_point(r.x0 as i32, r.y0 as i32);
                let (x1, y1) = flags.transform_point(r.x1 as i32, r.y1 as i32);
                let p0 = Pos2::new(
                    origin.x + x0 as f32 * viewport.zoom,
                    origin.y + y0 as f32 * viewport.zoom,
                );
                let p1 = Pos2::new(
                    origin.x + x1 as f32 * viewport.zoom,
                    origin.y + y1 as f32 * viewport.zoom,
                );
                let rect = egui::Rect::from_two_pos(p0, p1);
                painter.rect_stroke(rect, 0.0, stroke, StrokeKind::Outside);
            }

            // Pin markers (small hollow circles at pin positions).
            for pp in &entry.pin_positions {
                if entry.non_electrical && pp.x == 0 && pp.y == 0 {
                    continue;
                }
                let (px, py) = flags.transform_point(pp.x as i32, pp.y as i32);
                let pin_pos = Pos2::new(
                    origin.x + px as f32 * viewport.zoom,
                    origin.y + py as f32 * viewport.zoom,
                );
                painter.circle_stroke(pin_pos, pin_r, Stroke::new(dec_w, color));
            }
        } else {
            // Generic fallback box for subcircuits without primitives.
            let half = 20.0 * viewport.zoom;
            let rect = egui::Rect::from_center_size(origin, egui::Vec2::splat(half * 2.0));
            painter.rect_stroke(rect, 0.0, stroke, StrokeKind::Outside);

            // Show the symbol name inside the box.
            if viewport.zoom >= 0.2 {
                let sym_str = app.resolve(insts.symbol[i]);
                if !sym_str.is_empty() {
                    let font = FontId::proportional((10.0 * viewport.zoom.min(2.0)).max(8.0));
                    painter.text(origin, egui::Align2::CENTER_CENTER, sym_str, font, color);
                }
            }
        }
    }

    // Instance name labels (only when zoom is sufficient).
    if viewport.zoom >= 0.3 {
        let label_alpha = 180;
        let label_col = Color32::from_rgba_premultiplied(
            palette.symbol_line.r(),
            palette.symbol_line.g(),
            palette.symbol_line.b(),
            label_alpha,
        );
        let font = FontId::proportional((11.0 * viewport.zoom.min(2.0)).max(9.0));

        for i in 0..n {
            let name_str = app.resolve(insts.name[i]);
            if name_str.is_empty() {
                continue;
            }
            let origin = viewport.w2p(insts.x[i], insts.y[i]);
            let flags = insts.flags[i];
            let kind = insts.kind[i];

            // Try to use the @name text position from the primitive.
            let prim = primitives::find_by_name(kind.symbol_name());
            let mut placed = false;
            if let Some(entry) = prim {
                for dt in &entry.texts {
                    if dt.content == "@name" {
                        let (tx, ty) =
                            flags.transform_point(dt.x as i32, dt.y as i32);
                        painter.text(
                            Pos2::new(
                                origin.x + tx as f32 * viewport.zoom,
                                origin.y + ty as f32 * viewport.zoom,
                            ),
                            egui::Align2::LEFT_CENTER,
                            name_str,
                            font.clone(),
                            label_col,
                        );
                        placed = true;
                        break;
                    }
                }
            }
            if !placed {
                painter.text(
                    Pos2::new(origin.x + 15.0 * viewport.zoom, origin.y - 15.0 * viewport.zoom),
                    egui::Align2::LEFT_CENTER,
                    name_str,
                    font.clone(),
                    label_col,
                );
            }
        }
    }
}

// ── Geometry rendering (lines, rects, circles, arcs, polygons, texts) ────────

fn render_geometry(
    painter: &Painter,
    app: &App,
    viewport: &CanvasViewport,
    palette: &CanvasPalette,
) {
    let sch = app.schematic();

    // Lines
    for line in &sch.lines {
        let a = viewport.w2p(line.x0, line.y0);
        let b = viewport.w2p(line.x1, line.y1);
        let col = color_or(line.color, palette.geometry_line);
        let w = thickness_width(line.thickness);
        painter.line_segment([a, b], Stroke::new(w, col));
    }

    // Rects
    for r in &sch.rects {
        let p0 = viewport.w2p(r.x, r.y);
        let p1 = viewport.w2p(r.x + r.width, r.y + r.height);
        let rect = egui::Rect::from_two_pos(p0, p1);
        let fill_col = color_or(r.fill, palette.geometry_fill);
        let stroke_col = color_or(r.stroke, palette.geometry_line);
        let w = thickness_width(r.thickness);
        if !r.fill.is_none() || app.view_flags().fill_rects {
            painter.rect_filled(rect, 0.0, fill_col);
        }
        painter.rect_stroke(rect, 0.0, Stroke::new(w, stroke_col), StrokeKind::Outside);
    }

    // Circles
    for c in &sch.circles {
        let center = viewport.w2p(c.cx, c.cy);
        let radius_px = c.radius as f32 * viewport.zoom;
        let fill_col = color_or(c.fill, Color32::TRANSPARENT);
        let stroke_col = color_or(c.stroke, palette.geometry_line);
        let w = thickness_width(c.thickness);
        if !c.fill.is_none() {
            painter.circle_filled(center, radius_px, fill_col);
        }
        painter.circle_stroke(center, radius_px, Stroke::new(w, stroke_col));
    }

    // Arcs
    for a in &sch.arcs {
        let center = viewport.w2p(a.cx, a.cy);
        let radius_px = a.radius as f32 * viewport.zoom;
        let col = color_or(a.stroke, palette.geometry_line);
        let w = thickness_width(a.thickness);
        if radius_px > 0.5 {
            stroke_arc(
                painter,
                center,
                radius_px,
                a.start_angle,
                a.sweep_angle,
                Stroke::new(w, col),
            );
        }
    }

    // Polygons
    for poly in &sch.polygons {
        if poly.points.len() < 2 {
            continue;
        }
        let stroke_col = color_or(poly.stroke, palette.geometry_line);
        let w = thickness_width(poly.thickness);
        let points: Vec<Pos2> = poly
            .points
            .iter()
            .map(|p| viewport.w2p(p[0], p[1]))
            .collect();

        // Fill if there is a fill color.
        if !poly.fill.is_none() && points.len() >= 3 {
            let fill_col = color_or(poly.fill, Color32::TRANSPARENT);
            painter.add(egui::Shape::convex_polygon(
                points.clone(),
                fill_col,
                Stroke::NONE,
            ));
        }

        // Stroke outline.
        for win in points.windows(2) {
            painter.line_segment([win[0], win[1]], Stroke::new(w, stroke_col));
        }
        // Close the polygon.
        if points.len() >= 3 {
            painter.line_segment(
                [*points.last().unwrap(), points[0]],
                Stroke::new(w, stroke_col),
            );
        }
    }

    // Texts
    if viewport.zoom >= 0.3 {
        for t in &sch.texts {
            let content = app.resolve(t.content);
            if content.is_empty() {
                continue;
            }
            let p = viewport.w2p(t.x, t.y);
            let col = color_or(t.color, palette.text_label);
            let size = (t.font_size * viewport.zoom).max(8.0);
            let font = FontId::proportional(size);
            painter.text(p, egui::Align2::LEFT_TOP, content, font, col);
        }
    }
}

// ── Selection highlight overlays ─────────────────────────────────────────────

fn render_selection(
    painter: &Painter,
    app: &App,
    viewport: &CanvasViewport,
    palette: &CanvasPalette,
) {
    let sel = app.selection();
    if sel.is_empty() {
        return;
    }

    let highlight_stroke = Stroke::new(
        (3.0 * viewport.zoom).max(1.5),
        palette.inst_selected,
    );
    let halo = 4.0;

    // Instance selection halos.
    let insts = app.instances();
    for &idx in &sel.instances {
        if idx >= insts.len() {
            continue;
        }
        let origin = viewport.w2p(insts.x[idx], insts.y[idx]);

        // Use primitive bounding box if available, otherwise a default box.
        let kind = insts.kind[idx];
        let prim = primitives::find_by_name(kind.symbol_name());
        let half = if let Some(entry) = prim {
            // Estimate bounding box from segments.
            let mut max_ext: f32 = 20.0;
            for seg in &entry.segments {
                max_ext = max_ext
                    .max(seg.x0.unsigned_abs() as f32)
                    .max(seg.y0.unsigned_abs() as f32)
                    .max(seg.x1.unsigned_abs() as f32)
                    .max(seg.y1.unsigned_abs() as f32);
            }
            for pp in &entry.pin_positions {
                max_ext = max_ext
                    .max(pp.x.unsigned_abs() as f32)
                    .max(pp.y.unsigned_abs() as f32);
            }
            (max_ext + halo) * viewport.zoom
        } else {
            (20.0 + halo) * viewport.zoom
        };

        let rect = egui::Rect::from_center_size(origin, egui::Vec2::splat(half * 2.0));
        painter.rect_stroke(rect, 2.0, highlight_stroke, StrokeKind::Outside);
    }

    // Wire selection highlights.
    let wires = app.wires();
    for &idx in &sel.wires {
        if idx >= wires.len() {
            continue;
        }
        let a = viewport.w2p(wires.x0[idx], wires.y0[idx]);
        let b = viewport.w2p(wires.x1[idx], wires.y1[idx]);
        painter.line_segment([a, b], highlight_stroke);
    }

    // Line selection highlights.
    let sch = app.schematic();
    for &idx in &sel.lines {
        if idx >= sch.lines.len() {
            continue;
        }
        let l = &sch.lines[idx];
        let a = viewport.w2p(l.x0, l.y0);
        let b = viewport.w2p(l.x1, l.y1);
        painter.line_segment([a, b], highlight_stroke);
    }

    // Rect selection highlights.
    for &idx in &sel.rects {
        if idx >= sch.rects.len() {
            continue;
        }
        let r = &sch.rects[idx];
        let p0 = viewport.w2p(r.x, r.y);
        let p1 = viewport.w2p(r.x + r.width, r.y + r.height);
        let rect = egui::Rect::from_two_pos(p0, p1);
        painter.rect_stroke(rect, 0.0, highlight_stroke, StrokeKind::Outside);
    }

    // Circle selection highlights.
    for &idx in &sel.circles {
        if idx >= sch.circles.len() {
            continue;
        }
        let c = &sch.circles[idx];
        let center = viewport.w2p(c.cx, c.cy);
        let radius_px = c.radius as f32 * viewport.zoom;
        painter.circle_stroke(center, radius_px, highlight_stroke);
    }
}

// ── Overlays ─────────────────────────────────────────────────────────────────

const WIRE_PREVIEW_DOT_RADIUS: f32 = 4.0;
const WIRE_PREVIEW_ARM: f32 = 8.0;
const WIRE_ENDPOINT_RADIUS: f32 = 2.5;

/// Render all dynamic overlays (wire preview, placement ghost, drawing tool
/// preview, rubber band, crosshair).
fn render_overlays(
    painter: &Painter,
    app: &App,
    viewport: &CanvasViewport,
    palette: &CanvasPalette,
) {
    let tool = app.active_tool();
    let tool_state = app.tool_state();

    // Wire preview overlay.
    if tool == Tool::Wire {
        draw_wire_preview(painter, app, viewport, palette);
    }

    // Placement ghost.
    if tool_state.placement.is_some() {
        draw_placement_ghost(painter, app, viewport, palette);
    }

    // Drawing tool preview (line, rect, circle, arc, polygon).
    match tool {
        Tool::Line | Tool::Rect | Tool::Circle | Tool::Arc | Tool::Polygon => {
            draw_drawing_preview(painter, app, viewport, palette);
        }
        _ => {}
    }

    // Rubber band selection rectangle.
    if app.canvas().rubber_band_active {
        draw_rubber_band(painter, app, viewport, palette);
    }

    // Full-canvas crosshair at cursor.
    if app.view_flags().crosshair {
        draw_crosshair(painter, app, viewport, palette);
    }
}

// ── Wire preview ─────────────────────────────────────────────────────────────

fn draw_wire_preview(
    painter: &Painter,
    app: &App,
    viewport: &CanvasViewport,
    palette: &CanvasPalette,
) {
    let ws = match app.tool_state().wire_start {
        Some(s) => s,
        None => return,
    };

    let preview_col = palette.wire_preview;
    let start = viewport.w2p(ws[0], ws[1]);

    // Crosshair at start point.
    painter.circle_filled(start, WIRE_PREVIEW_DOT_RADIUS, preview_col);
    painter.line_segment(
        [
            Pos2::new(start.x - WIRE_PREVIEW_ARM, start.y),
            Pos2::new(start.x + WIRE_PREVIEW_ARM, start.y),
        ],
        Stroke::new(1.5, preview_col),
    );
    painter.line_segment(
        [
            Pos2::new(start.x, start.y - WIRE_PREVIEW_ARM),
            Pos2::new(start.x, start.y + WIRE_PREVIEW_ARM),
        ],
        Stroke::new(1.5, preview_col),
    );

    // Manhattan-constrained preview from start to cursor.
    let cur = app.canvas().cursor_world;
    let dx = (cur[0] - ws[0]).unsigned_abs();
    let dy = (cur[1] - ws[1]).unsigned_abs();
    // Route horizontal-first if dx >= dy, else vertical-first.
    let end_world = if dx >= dy {
        [cur[0], ws[1]]
    } else {
        [ws[0], cur[1]]
    };
    let end = viewport.w2p(end_world[0], end_world[1]);
    painter.line_segment([start, end], Stroke::new(1.5, preview_col));
    painter.circle_filled(end, WIRE_ENDPOINT_RADIUS, preview_col);
}

// ── Placement ghost ──────────────────────────────────────────────────────────

fn draw_placement_ghost(
    painter: &Painter,
    app: &App,
    viewport: &CanvasViewport,
    palette: &CanvasPalette,
) {
    let pl = match &app.tool_state().placement {
        Some(p) => p,
        None => return,
    };

    let ghost_col = Color32::from_rgba_premultiplied(
        palette.symbol_line.r(),
        palette.symbol_line.g(),
        palette.symbol_line.b(),
        120,
    );
    let ww = (1.5 * viewport.zoom).max(1.0);
    let stroke = Stroke::new(ww, ghost_col);
    let cursor = app.canvas().cursor_world;
    let origin = viewport.w2p(cursor[0], cursor[1]);
    let flags = schemify_core::types::InstanceFlags::new(pl.rotation, pl.flip, false);

    let entry = primitives::find_by_name(&pl.symbol_path);

    if let Some(entry) = entry {
        if entry.has_drawing() {
            // Draw segments.
            for seg in &entry.segments {
                let (ax, ay) = flags.transform_point(seg.x0 as i32, seg.y0 as i32);
                let (bx, by) = flags.transform_point(seg.x1 as i32, seg.y1 as i32);
                let pa = Pos2::new(
                    origin.x + ax as f32 * viewport.zoom,
                    origin.y + ay as f32 * viewport.zoom,
                );
                let pb = Pos2::new(
                    origin.x + bx as f32 * viewport.zoom,
                    origin.y + by as f32 * viewport.zoom,
                );
                painter.line_segment([pa, pb], stroke);
            }

            // Draw circles.
            for c in &entry.circles {
                let (cx, cy) = flags.transform_point(c.cx as i32, c.cy as i32);
                let center = Pos2::new(
                    origin.x + cx as f32 * viewport.zoom,
                    origin.y + cy as f32 * viewport.zoom,
                );
                let radius_px = c.r as f32 * viewport.zoom;
                if radius_px > 0.5 {
                    stroke_circle(painter, center, radius_px, 16, stroke);
                }
            }
        } else {
            draw_ghost_fallback_box(painter, origin, &flags, viewport.zoom, stroke);
        }
    } else {
        draw_ghost_fallback_box(painter, origin, &flags, viewport.zoom, stroke);
    }

    // Label at cursor.
    let font = FontId::proportional(11.0);
    painter.text(
        Pos2::new(origin.x + 10.0, origin.y - 12.0),
        egui::Align2::LEFT_BOTTOM,
        &pl.symbol_path,
        font,
        ghost_col,
    );
}

fn draw_ghost_fallback_box(
    painter: &Painter,
    origin: Pos2,
    flags: &schemify_core::types::InstanceFlags,
    zoom: f32,
    stroke: Stroke,
) {
    let sz = 20.0_f32;
    let corners: [[f32; 2]; 4] = [[-sz, -sz], [sz, -sz], [sz, sz], [-sz, sz]];
    for ci in 0..4 {
        let (ax, ay) = flags.transform_point(corners[ci][0] as i32, corners[ci][1] as i32);
        let (bx, by) =
            flags.transform_point(corners[(ci + 1) % 4][0] as i32, corners[(ci + 1) % 4][1] as i32);
        let pa = Pos2::new(origin.x + ax as f32 * zoom, origin.y + ay as f32 * zoom);
        let pb = Pos2::new(origin.x + bx as f32 * zoom, origin.y + by as f32 * zoom);
        painter.line_segment([pa, pb], stroke);
    }
}

// ── Drawing tool previews ────────────────────────────────────────────────────

fn draw_drawing_preview(
    painter: &Painter,
    app: &App,
    viewport: &CanvasViewport,
    palette: &CanvasPalette,
) {
    let tool = app.active_tool();
    let draw = &app.tool_state().draw;
    let cursor = app.canvas().cursor_world;
    let preview_col = Color32::from_rgba_premultiplied(
        palette.wire_preview.r(),
        palette.wire_preview.g(),
        palette.wire_preview.b(),
        180,
    );
    let thickness = 1.5;
    let dot_radius = WIRE_PREVIEW_DOT_RADIUS;

    match tool {
        Tool::Line => {
            if let Some(fp) = draw.first_point {
                let start = viewport.w2p(fp[0], fp[1]);
                let end = viewport.w2p(cursor[0], cursor[1]);
                painter.circle_filled(start, dot_radius, preview_col);
                painter.line_segment([start, end], Stroke::new(thickness, preview_col));
                painter.circle_filled(end, WIRE_ENDPOINT_RADIUS, preview_col);
            }
        }
        Tool::Rect => {
            if let Some(fp) = draw.first_point {
                let x0 = fp[0].min(cursor[0]);
                let y0 = fp[1].min(cursor[1]);
                let x1 = fp[0].max(cursor[0]);
                let y1 = fp[1].max(cursor[1]);
                let tl = viewport.w2p(x0, y0);
                let br = viewport.w2p(x1, y1);
                let rect = egui::Rect::from_two_pos(tl, br);
                painter.rect_stroke(rect, 0.0, Stroke::new(thickness, preview_col), StrokeKind::Outside);
            }
        }
        Tool::Circle => {
            if let Some(fp) = draw.first_point {
                let center = viewport.w2p(fp[0], fp[1]);
                let dx = (cursor[0] - fp[0]) as f64;
                let dy = (cursor[1] - fp[1]) as f64;
                let radius_world = (dx * dx + dy * dy).sqrt() as f32;
                let radius_px = radius_world * viewport.zoom;
                if radius_px > 1.0 {
                    painter.circle_stroke(
                        center,
                        radius_px,
                        Stroke::new(thickness, preview_col),
                    );
                }
                painter.circle_filled(center, dot_radius, preview_col);
            }
        }
        Tool::Arc => {
            if let Some(fp) = draw.first_point {
                let center = viewport.w2p(fp[0], fp[1]);
                painter.circle_filled(center, dot_radius, preview_col);

                match draw.arc_step {
                    ArcStep::Center => {}
                    ArcStep::RadiusStart => {
                        // Line from center to cursor (radius preview).
                        let edge = viewport.w2p(cursor[0], cursor[1]);
                        painter.line_segment(
                            [center, edge],
                            Stroke::new(thickness, preview_col),
                        );
                    }
                    ArcStep::Sweep => {
                        if let Some(start_pt) = draw.arc_second {
                            let dx1 = (start_pt[0] - fp[0]) as f64;
                            let dy1 = (start_pt[1] - fp[1]) as f64;
                            let radius_world = (dx1 * dx1 + dy1 * dy1).sqrt() as f32;
                            let radius_px = radius_world * viewport.zoom;
                            let start_angle = (-(start_pt[1] - fp[1]) as f64)
                                .atan2((start_pt[0] - fp[0]) as f64);
                            let start_deg = start_angle.to_degrees() as f32;
                            let dx2 = (cursor[0] - fp[0]) as f64;
                            let dy2 = (cursor[1] - fp[1]) as f64;
                            let end_angle = (-dy2).atan2(dx2);
                            let end_deg = end_angle.to_degrees() as f32;
                            let mut sweep = end_deg - start_deg;
                            if sweep <= 0.0 {
                                sweep += 360.0;
                            }
                            if radius_px > 1.0 {
                                stroke_arc(
                                    painter,
                                    center,
                                    radius_px,
                                    start_deg,
                                    sweep,
                                    Stroke::new(thickness, preview_col),
                                );
                            }
                        }
                    }
                }
            }
        }
        Tool::Polygon => {
            let pts = &draw.polygon_points;
            if !pts.is_empty() {
                // Draw existing edges.
                for win in pts.windows(2) {
                    let a = viewport.w2p(win[0][0], win[0][1]);
                    let b = viewport.w2p(win[1][0], win[1][1]);
                    painter.line_segment([a, b], Stroke::new(thickness, preview_col));
                }
                // Preview line from last point to cursor.
                let last = pts.last().unwrap();
                let a = viewport.w2p(last[0], last[1]);
                let b = viewport.w2p(cursor[0], cursor[1]);
                painter.line_segment([a, b], Stroke::new(thickness, preview_col));
                // Close preview to first point.
                if pts.len() >= 2 {
                    let first = &pts[0];
                    let c = viewport.w2p(first[0], first[1]);
                    painter.line_segment(
                        [b, c],
                        Stroke::new(
                            thickness * 0.5,
                            Color32::from_rgba_premultiplied(
                                preview_col.r(),
                                preview_col.g(),
                                preview_col.b(),
                                80,
                            ),
                        ),
                    );
                }
                // Dots at vertices.
                for p in pts {
                    let px = viewport.w2p(p[0], p[1]);
                    painter.circle_filled(px, WIRE_ENDPOINT_RADIUS, preview_col);
                }
            }
        }
        _ => {}
    }
}

// ── Rubber band ──────────────────────────────────────────────────────────────

fn draw_rubber_band(
    painter: &Painter,
    app: &App,
    viewport: &CanvasViewport,
    palette: &CanvasPalette,
) {
    let cs = &app.canvas();
    let start = cs.rubber_band_start;
    let end = cs.rubber_band_end;

    let x0 = start[0].min(end[0]);
    let y0 = start[1].min(end[1]);
    let x1 = start[0].max(end[0]);
    let y1 = start[1].max(end[1]);

    let tl = viewport.w2p(x0, y0);
    let br = viewport.w2p(x1, y1);
    let rect = egui::Rect::from_two_pos(tl, br);

    // Fill.
    painter.rect_filled(rect, 0.0, palette.rubber_band);
    // Stroke.
    painter.rect_stroke(rect, 0.0, Stroke::new(1.0, palette.selection_rect), StrokeKind::Outside);
}

// ── Crosshair ────────────────────────────────────────────────────────────────

fn draw_crosshair(
    painter: &Painter,
    app: &App,
    viewport: &CanvasViewport,
    palette: &CanvasPalette,
) {
    let cursor = app.canvas().cursor_world;
    let p = viewport.w2p(cursor[0], cursor[1]);
    let clip = painter.clip_rect();
    let col = Color32::from_rgba_premultiplied(
        palette.wire_preview.r(),
        palette.wire_preview.g(),
        palette.wire_preview.b(),
        60,
    );
    let stroke = Stroke::new(0.5, col);

    painter.line_segment(
        [Pos2::new(clip.min.x, p.y), Pos2::new(clip.max.x, p.y)],
        stroke,
    );
    painter.line_segment(
        [Pos2::new(p.x, clip.min.y), Pos2::new(p.x, clip.max.y)],
        stroke,
    );
}

// ── Interaction ──────────────────────────────────────────────────────────────

const MOVE_DRAG_THRESHOLD_PX: f32 = 4.0;
const SELECT_HIT_RADIUS_SQ: f64 = 400.0;

/// Handle all mouse/keyboard interaction on the canvas response area.
fn handle(
    response: &Response,
    app: &mut App,
    viewport: &CanvasViewport,
    ctx: &egui::Context,
) {
    let snap = app.tool_state().snap_size;

    handle_space_key(app, ctx);
    handle_scroll_zoom(response, app, viewport);
    handle_mouse_press(response, app, viewport, snap);
    handle_mouse_drag(response, app, viewport, snap);
    handle_mouse_release(response, app, viewport, snap);
}

// ── Space key (pan toggle) ───────────────────────────────────────────────────

fn handle_space_key(app: &mut App, ctx: &egui::Context) {
    ctx.input(|i| {
        if i.key_pressed(egui::Key::Space) {
            app.canvas_mut().space_held = true;
            app.canvas_mut().space_drag_happened = false;
        }
        if i.key_released(egui::Key::Space) {
            let cs = &app.canvas();
            let drag_happened = cs.space_drag_happened;
            app.canvas_mut().space_held = false;
            if !drag_happened {
                // Toggle sticky grab mode.
                app.canvas_mut().pan_mode = PanMode::Grab;
            }
            app.canvas_mut().space_drag_happened = false;
        }
    });
}

// ── Scroll zoom (centered on cursor) ─────────────────────────────────────────

fn handle_scroll_zoom(response: &Response, app: &mut App, viewport: &CanvasViewport) {
    if !response.hovered() {
        return;
    }

    let scroll_delta = response.ctx.input(|i| i.smooth_scroll_delta.y);
    if scroll_delta == 0.0 {
        return;
    }

    let hover_pos = match response.hover_pos() {
        Some(p) => p,
        None => return,
    };

    let world_before = viewport.pixel_to_world(hover_pos.x, hover_pos.y);

    let old_zoom = app.zoom();

    // Apply zoom.
    if scroll_delta > 0.0 {
        app.dispatch(Command::ZoomIn);
    } else {
        app.dispatch(Command::ZoomOut);
    }

    // Adjust pan so the world point under the cursor stays stationary.
    // After zoom change, compute where world_before now maps and correct pan.
    let actual_zoom = app.zoom();
    if (actual_zoom - old_zoom).abs() > f32::EPSILON {
        let new_vp = CanvasViewport {
            center: viewport.center,
            zoom: actual_zoom,
            pan: app.pan(),
        };
        let world_after = new_vp.pixel_to_world(hover_pos.x, hover_pos.y);
        let mut pan = app.pan();
        pan[0] += world_before[0] - world_after[0];
        pan[1] += world_before[1] - world_after[1];
        app.set_pan(pan[0], pan[1]);
    }
}

// ── Mouse press ──────────────────────────────────────────────────────────────

fn handle_mouse_press(
    response: &Response,
    app: &mut App,
    viewport: &CanvasViewport,
    snap: f32,
) {
    // Middle button -> start pan.
    if response.middle_clicked() || (response.clicked_by(PointerButton::Primary) && response.ctx.input(|i| i.pointer.button_pressed(PointerButton::Middle))) {
        // Handled below in drag.
    }

    if response.clicked_by(PointerButton::Primary) {
        let cs = &app.canvas();

        if cs.pan_mode == PanMode::Grab {
            // Click to exit grab mode.
            app.canvas_mut().pan_mode = PanMode::Off;
            app.canvas_mut().dragging = false;
            app.canvas_mut().move_active = false;
            app.canvas_mut().move_hit_idx = None;
            return;
        }

        if cs.space_held {
            // Space + click -> start pan drag (handled in drag section).
            if let Some(pos) = response.interact_pointer_pos() {
                app.canvas_mut().dragging = true;
                app.canvas_mut().drag_is_pan = true;
                app.canvas_mut().drag_last = [pos.x, pos.y];
            }
            return;
        }

        if let Some(pos) = response.interact_pointer_pos() {
            let [wx, wy] = snap_world(viewport, pos, snap);
            let tool = app.active_tool();

            match tool {
                Tool::Select => handle_select_click(app, viewport, pos, wx, wy),
                Tool::Wire => handle_wire_click(app, wx, wy),
                Tool::Line | Tool::Rect | Tool::Circle | Tool::Arc | Tool::Polygon => {
                    handle_draw_click(app, tool, wx, wy);
                }
                _ => {}
            }

            // If placement is active, click to place the component.
            if app.tool_state().placement.is_some() {
                handle_placement_click(app, wx, wy);
            }
        }
    }

    // Right click -> context menu.
    if response.clicked_by(PointerButton::Secondary) {
        if let Some(pos) = response.interact_pointer_pos() {
            let [wx, wy] = snap_world(viewport, pos, snap);

            let inst_hit = hit_test_instance(app, wx, wy);
            let wire_hit = hit_test_wire(app, wx, wy);

            app.ctx_menu_mut().open = true;
            app.ctx_menu_mut().pixel_pos = [pos.x, pos.y];
            app.ctx_menu_mut().inst_idx = inst_hit;
            app.ctx_menu_mut().wire_idx = wire_hit;
        }
    }

    // Double click -> open properties.
    if response.double_clicked_by(PointerButton::Primary) {
        app.dispatch(Command::OpenPropsDialog);
    }
}

// ── Mouse drag ───────────────────────────────────────────────────────────────

fn handle_mouse_drag(
    response: &Response,
    app: &mut App,
    viewport: &CanvasViewport,
    snap: f32,
) {
    // Middle-drag -> pan.
    if response.dragged_by(PointerButton::Middle) {
        let delta = response.drag_delta();
        if delta.length_sq() > 0.0 {
            pan_by_pixel_delta(app, viewport, delta);
        }
        return;
    }

    // Left-drag handling.
    if !response.dragged_by(PointerButton::Primary) {
        return;
    }

    let cs = &app.canvas();

    // Space + drag -> pan.
    if cs.drag_is_pan || cs.space_held {
        let delta = response.drag_delta();
        if delta.length_sq() > 0.0 {
            app.canvas_mut().space_drag_happened = true;
            pan_by_pixel_delta(app, viewport, delta);
        }
        return;
    }

    // Move-drag promotion: check if we exceed the threshold.
    if let Some(pos) = response.interact_pointer_pos() {
        let cs = &app.canvas();
        if !cs.move_active && cs.move_hit_idx.is_some() {
            let dx_px = pos.x - cs.move_press_pixel[0];
            let dy_px = pos.y - cs.move_press_pixel[1];
            if dx_px * dx_px + dy_px * dy_px >= MOVE_DRAG_THRESHOLD_PX * MOVE_DRAG_THRESHOLD_PX {
                app.canvas_mut().move_active = true;
                app.canvas_mut().drag_last = [pos.x, pos.y];
            }
        }

        let cs = &app.canvas();
        if cs.move_active {
            // Move selected objects by drag delta.
            let prev = snap_world(viewport, Pos2::new(cs.drag_last[0], cs.drag_last[1]), snap);
            let curr = snap_world(viewport, pos, snap);
            let dx = curr[0] - prev[0];
            let dy = curr[1] - prev[1];
            if dx != 0 || dy != 0 {
                app.dispatch(Command::MoveSelected { dx, dy });
            }
            app.canvas_mut().drag_last = [pos.x, pos.y];
            return;
        }

        // Rubber-band selection drag.
        let cs = &app.canvas();
        if app.active_tool() == Tool::Select && cs.move_hit_idx.is_none() {
            let dx_px = pos.x - cs.move_press_pixel[0];
            let dy_px = pos.y - cs.move_press_pixel[1];
            if !cs.rubber_band_active
                && dx_px * dx_px + dy_px * dy_px
                    >= MOVE_DRAG_THRESHOLD_PX * MOVE_DRAG_THRESHOLD_PX
            {
                app.canvas_mut().rubber_band_active = true;
            }

            if app.canvas().rubber_band_active {
                let [wx, wy] = snap_world(viewport, pos, snap);
                app.canvas_mut().rubber_band_end = [wx, wy];
            }
        }
    }
}

// ── Mouse release ────────────────────────────────────────────────────────────

fn handle_mouse_release(
    response: &Response,
    app: &mut App,
    _viewport: &CanvasViewport,
    _snap: f32,
) {
    // We detect release indirectly: if the button was being dragged and is no longer.
    // egui doesn't have a direct "released" event, but drag_stopped works.
    if response.drag_stopped_by(PointerButton::Primary) {
        let cs = &app.canvas();

        // Complete rubber-band selection.
        if cs.rubber_band_active {
            let start = cs.rubber_band_start;
            let end = cs.rubber_band_end;
            let min_x = start[0].min(end[0]);
            let min_y = start[1].min(end[1]);
            let max_x = start[0].max(end[0]);
            let max_y = start[1].max(end[1]);

            select_in_rect(app, min_x, min_y, max_x, max_y);
        }

        app.canvas_mut().rubber_band_active = false;
        app.canvas_mut().move_active = false;
        app.canvas_mut().move_hit_idx = None;
        app.canvas_mut().dragging = false;
        app.canvas_mut().drag_is_pan = false;
    }

    if response.drag_stopped_by(PointerButton::Middle) {
        app.canvas_mut().dragging = false;
        app.canvas_mut().drag_is_pan = false;
    }
}

// ── Select click handler ─────────────────────────────────────────────────────

fn handle_select_click(app: &mut App, _viewport: &CanvasViewport, pos: Pos2, wx: i32, wy: i32) {

    // Hit test.
    let inst_hit = hit_test_instance(app, wx, wy);
    let wire_hit = hit_test_wire(app, wx, wy);

    if inst_hit.is_some() || wire_hit.is_some() {
        // Prime move: record which object was hit in case of drag.
        app.canvas_mut().move_press_pixel = [pos.x, pos.y];
        app.canvas_mut().move_start_world = [wx, wy];
        app.canvas_mut().drag_last = [pos.x, pos.y];
    }

    // Check if we clicked on an already-selected object (for move).
    if let Some(idx) = inst_hit {
        if app.is_instance_selected(idx) {
            app.canvas_mut().move_hit_idx = Some(idx);
            return;
        }
    }
    if let Some(idx) = wire_hit {
        if app.is_wire_selected(idx) {
            app.canvas_mut().move_hit_idx = Some(idx);
            return;
        }
    }

    // Not on a selected object, so do selection.
    app.dispatch(Command::SelectNone);

    if let Some(idx) = inst_hit {
        app.canvas_mut().move_hit_idx = Some(idx);
        app.select_instance(idx);
        return;
    }

    if let Some(idx) = wire_hit {
        app.canvas_mut().move_hit_idx = Some(idx);
        app.select_wire(idx);
        return;
    }

    // Clicked on empty space — prepare for rubber band.
    app.canvas_mut().rubber_band_start = [wx, wy];
    app.canvas_mut().rubber_band_end = [wx, wy];
    app.canvas_mut().rubber_band_active = false;
    app.canvas_mut().move_press_pixel = [pos.x, pos.y];
    app.canvas_mut().move_hit_idx = None;
}

// ── Wire tool click ──────────────────────────────────────────────────────────

fn handle_wire_click(app: &mut App, wx: i32, wy: i32) {
    if let Some(start) = app.tool_state().wire_start {
        // Second click: commit the wire.
        if start[0] != wx || start[1] != wy {
            // Manhattan routing: pick the dominant axis.
            let dx = (wx - start[0]).unsigned_abs();
            let dy = (wy - start[1]).unsigned_abs();
            let end = if dx >= dy {
                [wx, start[1]]
            } else {
                [start[0], wy]
            };

            let bus = app.tool_state().bus_mode;
            app.dispatch(Command::AddWire {
                x0: start[0],
                y0: start[1],
                x1: end[0],
                y1: end[1],
                net_name: None,
                bus,
            });
        }
        // Chain from endpoint for continuous wire drawing.
        app.set_wire_start(Some([wx, wy]));
    } else {
        // First click: set wire start.
        app.set_wire_start(Some([wx, wy]));
    }
}

// ── Drawing tool click ───────────────────────────────────────────────────────

fn handle_draw_click(app: &mut App, tool: Tool, wx: i32, wy: i32) {
    if app.tool_state().draw.first_point.is_none() {
        // First click: set start point.
        app.set_draw_first_point(Some([wx, wy]));
    } else {
        let start = app.tool_state().draw.first_point.unwrap();
        // Second click: commit the shape.
        match tool {
            Tool::Line => {
                app.dispatch(Command::AddLine {
                    x0: start[0], y0: start[1], x1: wx, y1: wy,
                });
            }
            Tool::Rect => {
                app.dispatch(Command::AddRect {
                    x: start[0].min(wx), y: start[1].min(wy),
                    w: (wx - start[0]).abs(), h: (wy - start[1]).abs(),
                });
            }
            Tool::Circle => {
                let dx = (wx - start[0]) as f64;
                let dy = (wy - start[1]) as f64;
                let radius = (dx * dx + dy * dy).sqrt() as i32;
                app.dispatch(Command::AddCircle {
                    cx: start[0], cy: start[1], radius,
                });
            }
            Tool::Arc => {
                let dx = (wx - start[0]) as f64;
                let dy = (wy - start[1]) as f64;
                let radius = (dx * dx + dy * dy).sqrt() as i32;
                let start_angle = dy.atan2(dx) as f32;
                app.dispatch(Command::AddArc {
                    cx: start[0], cy: start[1], radius,
                    start: start_angle, sweep: std::f32::consts::PI,
                });
            }
            _ => {}
        }
        app.set_draw_first_point(None);
    }
}

// ── Placement click ──────────────────────────────────────────────────────────

fn handle_placement_click(app: &mut App, wx: i32, wy: i32) {
    let pl = match &app.tool_state().placement {
        Some(p) => p.clone(),
        None => return,
    };

    app.dispatch(Command::PlaceDevice {
        symbol_path: pl.symbol_path.clone(),
        name: pl.name.clone(),
        x: wx,
        y: wy,
        rotation: pl.rotation,
        flip: pl.flip,
    });

    // Clear placement (PlaceDevice doesn't reset tool state, SetTool does).
    app.dispatch(Command::SetTool(Tool::Select));
}

// ── Pan helper ───────────────────────────────────────────────────────────────

fn pan_by_pixel_delta(app: &mut App, viewport: &CanvasViewport, delta: egui::Vec2) {
    // Pan is in world coordinates, so convert pixel delta to world delta.
    // delta_world = delta_pixel / zoom
    // Pan moves opposite to drag direction (dragging right -> scene moves left -> pan decreases).
    let _ = viewport; // zoom accessible from app
    let zoom = app.zoom();
    if zoom <= 0.0 {
        return;
    }
    let pan = app.pan();
    let new_pan = [pan[0] - delta.x / zoom, pan[1] - delta.y / zoom];

    app.set_pan(new_pan[0], new_pan[1]);
}

// ── Hit testing ──────────────────────────────────────────────────────────────

fn hit_test_instance(app: &App, wx: i32, wy: i32) -> Option<usize> {
    let insts = app.instances();
    let n = insts.len();
    for i in 0..n {
        let dx = wx as f64 - insts.x[i] as f64;
        let dy = wy as f64 - insts.y[i] as f64;

        // For instances with primitives, check against the bounding extent.
        let kind = insts.kind[i];
        let prim = primitives::find_by_name(kind.symbol_name());
        let tol_sq = if let Some(entry) = prim {
            let mut max_ext: f64 = 14.0;
            for seg in &entry.segments {
                max_ext = max_ext
                    .max(seg.x0.unsigned_abs() as f64)
                    .max(seg.y0.unsigned_abs() as f64)
                    .max(seg.x1.unsigned_abs() as f64)
                    .max(seg.y1.unsigned_abs() as f64);
            }
            for pp in &entry.pin_positions {
                max_ext = max_ext
                    .max(pp.x.unsigned_abs() as f64)
                    .max(pp.y.unsigned_abs() as f64);
            }
            (max_ext + 5.0) * (max_ext + 5.0)
        } else {
            (25.0_f64) * 25.0
        };

        if dx * dx + dy * dy < tol_sq {
            return Some(i);
        }
    }
    None
}

fn hit_test_wire(app: &App, wx: i32, wy: i32) -> Option<usize> {
    let wires = app.wires();
    let n = wires.len();
    let wpx = wx as f64;
    let wpy = wy as f64;

    for i in 0..n {
        let ax = wires.x0[i] as f64;
        let ay = wires.y0[i] as f64;
        let bx = wires.x1[i] as f64;
        let by = wires.y1[i] as f64;

        let abx = bx - ax;
        let aby = by - ay;
        let len2 = abx * abx + aby * aby;

        let d2 = if len2 <= 0.0 {
            let ddx = wpx - ax;
            let ddy = wpy - ay;
            ddx * ddx + ddy * ddy
        } else {
            let mut t = ((wpx - ax) * abx + (wpy - ay) * aby) / len2;
            t = t.clamp(0.0, 1.0);
            let cx = ax + t * abx;
            let cy = ay + t * aby;
            let ddx = wpx - cx;
            let ddy = wpy - cy;
            ddx * ddx + ddy * ddy
        };

        if d2 < SELECT_HIT_RADIUS_SQ {
            return Some(i);
        }
    }
    None
}

// ── Rubber-band selection ────────────────────────────────────────────────────

fn select_in_rect(app: &mut App, min_x: i32, min_y: i32, max_x: i32, max_y: i32) {
    app.dispatch(Command::SelectNone);

    let insts = app.instances();
    let n = insts.len();
    let mut inst_hits = Vec::new();
    for i in 0..n {
        let x = insts.x[i];
        let y = insts.y[i];
        if x >= min_x && x <= max_x && y >= min_y && y <= max_y {
            inst_hits.push(i);
        }
    }

    let wires = app.wires();
    let wn = wires.len();
    let mut wire_hits = Vec::new();
    for i in 0..wn {
        let x0 = wires.x0[i];
        let y0 = wires.y0[i];
        let x1 = wires.x1[i];
        let y1 = wires.y1[i];
        if x0 >= min_x && x0 <= max_x && y0 >= min_y && y0 <= max_y
            && x1 >= min_x && x1 <= max_x && y1 >= min_y && y1 <= max_y
        {
            wire_hits.push(i);
        }
    }

    for idx in inst_hits {
        app.select_instance(idx);
    }
    for idx in wire_hits {
        app.select_wire(idx);
    }
}

// ── Helpers ──────────────────────────────────────────────────────────────────

fn snap_world(viewport: &CanvasViewport, pos: Pos2, snap_size: f32) -> [i32; 2] {
    viewport.snap_to_grid(pos.x, pos.y, snap_size)
}
