use std::collections::HashMap;

use egui::{Color32, FontId, Painter, PointerButton, Pos2, Response, Stroke, StrokeKind};

use schemify_core::commands::{Command, Tool};
use schemify_core::primitives;
use schemify_core::types::Color;
use schemify_handler::state::{ArcStep, PanMode};
use schemify_handler::App;

use crate::theme::CanvasPalette;

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
fn stroke_circle(painter: &Painter, center: Pos2, radius_px: f32, n_segs: usize, stroke: Stroke) {
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

fn draw_origin(painter: &Painter, vp: &CanvasViewport, palette: &CanvasPalette, clip: egui::Rect) {
    let origin = vp.world_to_pixel(0.0, 0.0);
    let arm = 20.0_f32;
    let stroke = Stroke::new(1.0_f32, palette.origin);

    // Horizontal arm
    let x0 = origin.x - arm;
    let x1 = origin.x + arm;
    if origin.y >= clip.min.y && origin.y <= clip.max.y {
        painter.line_segment(
            [
                Pos2::new(x0.max(clip.min.x), origin.y),
                Pos2::new(x1.min(clip.max.x), origin.y),
            ],
            stroke,
        );
    }

    // Vertical arm
    let y0 = origin.y - arm;
    let y1 = origin.y + arm;
    if origin.x >= clip.min.x && origin.x <= clip.max.x {
        painter.line_segment(
            [
                Pos2::new(origin.x, y0.max(clip.min.y)),
                Pos2::new(origin.x, y1.min(clip.max.y)),
            ],
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

    // Render layers (bottom to top) — schematic vs symbol mode.
    let is_symbol_mode = app.view().view_mode == schemify_handler::state::ViewMode::Symbol;

    render_grid(&painter, &viewport, &palette, app.show_grid());

    if is_symbol_mode {
        // Symbol mode: geometry + pins only (no instances/wires).
        let sch = app.schematic();
        let has_symbol_data = !sch.pins.is_empty()
            || !sch.lines.is_empty()
            || !sch.rects.is_empty()
            || !sch.circles.is_empty()
            || !sch.arcs.is_empty()
            || !sch.instances.is_empty(); // labels count for auto-gen

        if has_symbol_data {
            render_geometry(&painter, app, &viewport, &palette);
            render_symbol_pins(&painter, app, &viewport, &palette);
        } else {
            // Placeholder when no symbol data exists
            let center = viewport.w2p(0, 0);
            painter.text(
                center,
                egui::Align2::CENTER_CENTER,
                "No symbol defined\n\nUse \"Generate Symbol\" in SCH mode\nor draw geometry here",
                egui::FontId::proportional(16.0),
                palette.text_label,
            );
        }
    } else {
        // Schematic mode: full rendering.
        render_wires(&painter, app, &viewport, &palette);
        render_instances(&painter, app, &viewport, &palette);
        render_geometry(&painter, app, &viewport, &palette);
        render_selection(&painter, app, &viewport, &palette);
        render_overlays(&painter, app, &viewport, &palette);
    }

    // Handle interaction.
    handle(&response, app, &viewport, ui.ctx());

    // Text input overlay: show a TextEdit when the text tool is active and a position is set.
    show_text_input_overlay(ui, app, &viewport);

    // Update cursor world position.
    if let Some(pos) = response.hover_pos() {
        let [wx, wy] = viewport.pixel_to_world(pos.x, pos.y);
        app.set_cursor_world(wx as i32, wy as i32);
    }
}

// ── Wire rendering ───────────────────────────────────────────────────────────

fn render_wires(painter: &Painter, app: &App, viewport: &CanvasViewport, palette: &CanvasPalette) {
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
        *point_counts.entry(p0).or_insert(0) = point_counts
            .get(&p0)
            .copied()
            .unwrap_or(0)
            .saturating_add(1);
        *point_counts.entry(p1).or_insert(0) = point_counts
            .get(&p1)
            .copied()
            .unwrap_or(0)
            .saturating_add(1);
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
            if selected {
                bus_w_sel
            } else {
                bus_w
            }
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
                [
                    Pos2::new(mx - half, my + half),
                    Pos2::new(mx + half, my - half),
                ],
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
                        let (tx, ty) = flags.transform_point(dt.x as i32, dt.y as i32);
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
                    Pos2::new(
                        origin.x + 15.0 * viewport.zoom,
                        origin.y - 15.0 * viewport.zoom,
                    ),
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

// ── Symbol pin rendering (symbol view mode) ─────────────────────────────────

fn render_symbol_pins(
    painter: &Painter,
    app: &App,
    viewport: &CanvasViewport,
    palette: &CanvasPalette,
) {
    use schemify_core::types::PinDirection;

    let sch = app.schematic();
    let pin_col = palette.inst_pin;
    let label_col = palette.text_label;
    let pin_arm = 6.0 * viewport.zoom;

    // If no geometry and no pins, show auto-generated box from label instances.
    let has_geometry = !sch.lines.is_empty()
        || !sch.rects.is_empty()
        || !sch.circles.is_empty()
        || !sch.arcs.is_empty();

    if !has_geometry && sch.pins.is_empty() {
        // Auto-generate from label instances.
        render_auto_symbol_box(painter, app, viewport, palette);
        return;
    }

    // Draw explicit pins with crosshair + direction indicator + label.
    for pin in &sch.pins {
        let p = viewport.w2p(pin.x, pin.y);

        // Pin crosshair
        painter.line_segment(
            [Pos2::new(p.x - pin_arm, p.y), Pos2::new(p.x + pin_arm, p.y)],
            Stroke::new(1.0_f32, pin_col),
        );
        painter.line_segment(
            [Pos2::new(p.x, p.y - pin_arm), Pos2::new(p.x, p.y + pin_arm)],
            Stroke::new(1.0_f32, pin_col),
        );

        // Direction indicator
        let sz = pin_arm * 0.75;
        match pin.direction {
            PinDirection::Input => {
                // Arrow pointing right
                painter.line_segment(
                    [Pos2::new(p.x, p.y), Pos2::new(p.x - sz, p.y - sz * 0.6)],
                    Stroke::new(0.9_f32, palette.wire_endpoint),
                );
                painter.line_segment(
                    [Pos2::new(p.x, p.y), Pos2::new(p.x - sz, p.y + sz * 0.6)],
                    Stroke::new(0.9_f32, palette.wire_endpoint),
                );
            }
            PinDirection::Output => {
                // Arrow pointing left
                painter.line_segment(
                    [Pos2::new(p.x, p.y), Pos2::new(p.x + sz, p.y - sz * 0.6)],
                    Stroke::new(0.9_f32, palette.wire_endpoint),
                );
                painter.line_segment(
                    [Pos2::new(p.x, p.y), Pos2::new(p.x + sz, p.y + sz * 0.6)],
                    Stroke::new(0.9_f32, palette.wire_endpoint),
                );
            }
            PinDirection::InOut => {
                // Diamond
                painter.line_segment(
                    [Pos2::new(p.x - sz, p.y), Pos2::new(p.x, p.y - sz * 0.6)],
                    Stroke::new(0.9_f32, palette.wire_endpoint),
                );
                painter.line_segment(
                    [Pos2::new(p.x, p.y - sz * 0.6), Pos2::new(p.x + sz, p.y)],
                    Stroke::new(0.9_f32, palette.wire_endpoint),
                );
                painter.line_segment(
                    [Pos2::new(p.x + sz, p.y), Pos2::new(p.x, p.y + sz * 0.6)],
                    Stroke::new(0.9_f32, palette.wire_endpoint),
                );
                painter.line_segment(
                    [Pos2::new(p.x, p.y + sz * 0.6), Pos2::new(p.x - sz, p.y)],
                    Stroke::new(0.9_f32, palette.wire_endpoint),
                );
            }
            PinDirection::Power | PinDirection::Ground => {
                // Cross
                let s = sz * 0.7;
                painter.line_segment(
                    [Pos2::new(p.x - s, p.y), Pos2::new(p.x + s, p.y)],
                    Stroke::new(0.9_f32, palette.wire_endpoint),
                );
                painter.line_segment(
                    [Pos2::new(p.x, p.y - s), Pos2::new(p.x, p.y + s)],
                    Stroke::new(0.9_f32, palette.wire_endpoint),
                );
            }
        }

        // Pin name label
        if viewport.zoom >= 0.3 {
            let name = app.resolve(pin.name);
            if !name.is_empty() {
                let font = FontId::proportional((12.0 * viewport.zoom).max(8.0));
                painter.text(
                    Pos2::new(p.x + pin_arm + 2.0, p.y - 6.0 * viewport.zoom),
                    egui::Align2::LEFT_TOP,
                    name,
                    font,
                    label_col,
                );
            }
        }
    }
}

/// Auto-generate a symbol box from label instances when no explicit
/// symbol geometry or pins exist.
fn render_auto_symbol_box(
    painter: &Painter,
    app: &App,
    viewport: &CanvasViewport,
    palette: &CanvasPalette,
) {
    use schemify_core::types::DeviceKind;

    let sch = app.schematic();

    // Collect label instances.
    struct LabelInfo {
        name: String,
        is_output: bool,
    }

    let mut labels: Vec<LabelInfo> = Vec::new();
    for i in 0..sch.instances.len() {
        let kind = sch.instances.kind[i];
        if !kind.is_label() {
            continue;
        }
        let name = app.resolve(sch.instances.name[i]).to_string();
        labels.push(LabelInfo {
            name,
            is_output: kind == DeviceKind::OutputPin,
        });
    }

    if labels.is_empty() {
        // Nothing to auto-generate — show hint text.
        let center = viewport.world_to_pixel(0.0, 0.0);
        let font = FontId::proportional(14.0);
        painter.text(
            center,
            egui::Align2::CENTER_CENTER,
            "No symbol data. Add pins or click \"Generate Symbol\".",
            font,
            palette.text_label,
        );
        return;
    }

    // Partition into left (input/inout) and right (output) pins.
    let mut left: Vec<&LabelInfo> = Vec::new();
    let mut right: Vec<&LabelInfo> = Vec::new();
    for l in &labels {
        if l.is_output {
            right.push(l);
        } else {
            left.push(l);
        }
    }
    // Balance inout pins.
    if left.is_empty() && !right.is_empty() {
        let half = right.len() / 2;
        let moved: Vec<&LabelInfo> = right.drain(..half).collect();
        left.extend(moved);
    }

    let max_pins = left.len().max(right.len()).max(1);
    let pin_spacing: i32 = 20;
    let stub_len: i32 = 10;
    let max_name_len = labels.iter().map(|l| l.name.len()).max().unwrap_or(3);
    let box_w: i32 = (120_i32).max(max_name_len as i32 * 8 + 40);
    let box_h: i32 = (max_pins as i32 + 1) * pin_spacing;

    // Draw rectangle body.
    let tl = viewport.w2p(0, 0);
    let br = viewport.w2p(box_w, box_h);
    let body = egui::Rect::from_two_pos(tl, br);
    painter.rect_stroke(
        body,
        0.0,
        Stroke::new(1.5_f32, palette.symbol_line),
        StrokeKind::Outside,
    );

    // Draw left pins (input side).
    for (slot, lbl) in left.iter().enumerate() {
        let py = (slot as i32 + 1) * pin_spacing;
        let stub_start = viewport.w2p(-stub_len, py);
        let stub_end = viewport.w2p(0, py);
        painter.line_segment(
            [stub_start, stub_end],
            Stroke::new(1.0_f32, palette.inst_pin),
        );
        // Pin circle at stub start
        painter.circle_filled(stub_start, 3.0, palette.inst_pin);
        // Label
        if viewport.zoom >= 0.3 {
            let label_pos = viewport.w2p(4, py);
            let font = FontId::proportional((11.0 * viewport.zoom).max(8.0));
            painter.text(
                Pos2::new(label_pos.x, label_pos.y - 6.0 * viewport.zoom),
                egui::Align2::LEFT_TOP,
                &lbl.name,
                font,
                palette.text_label,
            );
        }
    }

    // Draw right pins (output side).
    for (slot, lbl) in right.iter().enumerate() {
        let py = (slot as i32 + 1) * pin_spacing;
        let stub_start = viewport.w2p(box_w, py);
        let stub_end = viewport.w2p(box_w + stub_len, py);
        painter.line_segment(
            [stub_start, stub_end],
            Stroke::new(1.0_f32, palette.inst_pin),
        );
        // Pin circle at stub end
        painter.circle_filled(stub_end, 3.0, palette.inst_pin);
        // Label
        if viewport.zoom >= 0.3 {
            let label_pos = viewport.w2p(box_w - 4, py);
            let font = FontId::proportional((11.0 * viewport.zoom).max(8.0));
            painter.text(
                Pos2::new(label_pos.x, label_pos.y - 6.0 * viewport.zoom),
                egui::Align2::RIGHT_TOP,
                &lbl.name,
                font,
                palette.text_label,
            );
        }
    }

    // Schematic name centered in box.
    let name = &sch.name;
    if !name.is_empty() {
        let center = viewport.w2p(box_w / 2, box_h / 2);
        let font = FontId::proportional((13.0 * viewport.zoom).max(8.0));
        painter.text(
            center,
            egui::Align2::CENTER_CENTER,
            name,
            font,
            palette.symbol_line,
        );
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

    let highlight_stroke = Stroke::new((3.0 * viewport.zoom).max(1.5), palette.inst_selected);
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

    // Arc selection highlights.
    for &idx in &sel.arcs {
        if idx >= sch.arcs.len() {
            continue;
        }
        let a = &sch.arcs[idx];
        let center = viewport.w2p(a.cx, a.cy);
        let radius_px = a.radius as f32 * viewport.zoom;
        // Approximate arc with line segments for highlight.
        let steps = 32;
        let start = a.start_angle as f64;
        let sweep = a.sweep_angle as f64;
        for s in 0..steps {
            let t0 = start + sweep * (s as f64 / steps as f64);
            let t1 = start + sweep * ((s + 1) as f64 / steps as f64);
            let p0 = egui::pos2(
                center.x + radius_px * t0.cos() as f32,
                center.y + radius_px * t0.sin() as f32,
            );
            let p1 = egui::pos2(
                center.x + radius_px * t1.cos() as f32,
                center.y + radius_px * t1.sin() as f32,
            );
            painter.line_segment([p0, p1], highlight_stroke);
        }
    }

    // Text selection highlights.
    for &idx in &sel.texts {
        if idx >= sch.texts.len() {
            continue;
        }
        let t = &sch.texts[idx];
        let p = viewport.w2p(t.x, t.y);
        let content = app.resolve(t.content);
        let approx_w = (content.len() as f32 * t.font_size * 0.6 * viewport.zoom).max(12.0);
        let approx_h = (t.font_size * viewport.zoom).max(12.0);
        let rect = egui::Rect::from_min_size(p, egui::Vec2::new(approx_w, approx_h));
        painter.rect_stroke(rect, 2.0, highlight_stroke, StrokeKind::Outside);
    }

    // Polygon selection highlights.
    for &idx in &sel.polygons {
        if idx >= sch.polygons.len() {
            continue;
        }
        let poly = &sch.polygons[idx];
        if poly.points.len() < 2 {
            continue;
        }
        let pts: Vec<Pos2> = poly
            .points
            .iter()
            .map(|p| viewport.w2p(p[0], p[1]))
            .collect();
        for win in pts.windows(2) {
            painter.line_segment([win[0], win[1]], highlight_stroke);
        }
        if pts.len() >= 3 {
            painter.line_segment([*pts.last().unwrap(), pts[0]], highlight_stroke);
        }
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

// ── Text input overlay ──────────────────────────────────────────────────────

/// Render a floating TextEdit at the text tool's click position.
/// On Enter: commit the text. On Escape: cancel.
fn show_text_input_overlay(ui: &mut egui::Ui, app: &mut App, viewport: &CanvasViewport) {
    if !app.tool_state().draw.text_input_active {
        return;
    }
    let pos = match app.tool_state().draw.text_pos {
        Some(p) => p,
        None => return,
    };

    let pixel = viewport.w2p(pos[0], pos[1]);

    egui::Area::new(egui::Id::new("text_tool_input"))
        .fixed_pos(egui::Pos2::new(pixel.x, pixel.y))
        .order(egui::Order::Foreground)
        .show(ui.ctx(), |ui| {
            let te = egui::TextEdit::singleline(app.text_buf_mut())
                .desired_width(150.0)
                .hint_text("Enter text...");
            let response = ui.add(te);

            // Request focus on first frame.
            if !response.has_focus() {
                response.request_focus();
            }

            // Enter → commit.
            if ui.input(|i| i.key_pressed(egui::Key::Enter)) {
                app.commit_text();
            }
            // Escape → cancel.
            if ui.input(|i| i.key_pressed(egui::Key::Escape)) {
                app.clear_text_input();
            }
        });
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
        Stroke::new(1.5_f32, preview_col),
    );
    painter.line_segment(
        [
            Pos2::new(start.x, start.y - WIRE_PREVIEW_ARM),
            Pos2::new(start.x, start.y + WIRE_PREVIEW_ARM),
        ],
        Stroke::new(1.5_f32, preview_col),
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
    painter.line_segment([start, end], Stroke::new(1.5_f32, preview_col));
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
        let (bx, by) = flags.transform_point(
            corners[(ci + 1) % 4][0] as i32,
            corners[(ci + 1) % 4][1] as i32,
        );
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
    let thickness = 1.5_f32;
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
                painter.rect_stroke(
                    rect,
                    0.0,
                    Stroke::new(thickness, preview_col),
                    StrokeKind::Outside,
                );
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
                    painter.circle_stroke(center, radius_px, Stroke::new(thickness, preview_col));
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
                        painter.line_segment([center, edge], Stroke::new(thickness, preview_col));
                    }
                    ArcStep::Sweep => {
                        if let Some(start_pt) = draw.arc_second {
                            let dx1 = (start_pt[0] - fp[0]) as f64;
                            let dy1 = (start_pt[1] - fp[1]) as f64;
                            let radius_world = (dx1 * dx1 + dy1 * dy1).sqrt() as f32;
                            let radius_px = radius_world * viewport.zoom;
                            let start_angle =
                                (-(start_pt[1] - fp[1]) as f64).atan2((start_pt[0] - fp[0]) as f64);
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
                            thickness * 0.5_f32,
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
    painter.rect_stroke(
        rect,
        0.0,
        Stroke::new(1.0_f32, palette.selection_rect),
        StrokeKind::Outside,
    );
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
    let stroke = Stroke::new(0.5_f32, col);

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

/// Handle all mouse/keyboard interaction on the canvas response area.
fn handle(response: &Response, app: &mut App, viewport: &CanvasViewport, ctx: &egui::Context) {
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

    // Proportional zoom: scale factor from scroll delta magnitude.
    // ~0.001 per pixel of scroll → smooth on touchpads, reasonable on mice.
    let factor = (scroll_delta * 0.001).exp();
    let new_zoom = old_zoom * factor;
    app.set_zoom(new_zoom);

    // Adjust pan so the world point under the cursor stays stationary.
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

fn handle_mouse_press(response: &Response, app: &mut App, viewport: &CanvasViewport, snap: f32) {
    // Middle button -> start pan.
    if response.middle_clicked()
        || (response.clicked_by(PointerButton::Primary)
            && response
                .ctx
                .input(|i| i.pointer.button_pressed(PointerButton::Middle)))
    {
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
                Tool::Select => {
                    let shift = response.ctx.input(|i| i.modifiers.shift);
                    handle_select_click(app, viewport, pos, wx, wy, shift);
                }
                Tool::Wire => handle_wire_click(app, wx, wy),
                Tool::Polygon => {
                    app.push_polygon_point([wx, wy]);
                }
                Tool::Line | Tool::Rect | Tool::Circle | Tool::Arc => {
                    handle_draw_click(app, tool, wx, wy);
                }
                Tool::Text
                    // Only open input if not already active (avoid repositioning mid-edit).
                    if !app.tool_state().draw.text_input_active =>
                {
                    app.set_text_pos(Some([wx, wy]));
                    app.set_text_input_active(true);
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
            use schemify_handler::geometry::HitResult;
            let hit = app.hit_test(wx, wy);
            let ctx_hit = match hit {
                HitResult::Instance(i) => schemify_handler::state::ContextHit::Instance(i),
                HitResult::Wire(i) => schemify_handler::state::ContextHit::Wire(i),
                HitResult::Line(i) => schemify_handler::state::ContextHit::Line(i),
                HitResult::Rect(i) => schemify_handler::state::ContextHit::Rect(i),
                HitResult::Circle(i) => schemify_handler::state::ContextHit::Circle(i),
                HitResult::Arc(i) => schemify_handler::state::ContextHit::Arc(i),
                HitResult::Text(i) => schemify_handler::state::ContextHit::Text(i),
                HitResult::Polygon(i) => schemify_handler::state::ContextHit::Polygon(i),
                HitResult::Nothing => schemify_handler::state::ContextHit::None,
            };
            app.ctx_menu_mut().open = true;
            app.ctx_menu_mut().pixel_pos = [pos.x, pos.y];
            app.ctx_menu_mut().hit = ctx_hit;
        }
    }

    // Double click -> commit polygon or open properties.
    if response.double_clicked_by(PointerButton::Primary) {
        if app.active_tool() == Tool::Polygon {
            app.commit_polygon();
        } else {
            app.dispatch(Command::OpenPropsDialog);
        }
    }
}

// ── Mouse drag ───────────────────────────────────────────────────────────────

fn handle_mouse_drag(response: &Response, app: &mut App, viewport: &CanvasViewport, snap: f32) {
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
                app.canvas_mut().move_accum = [0, 0];
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
                && dx_px * dx_px + dy_px * dy_px >= MOVE_DRAG_THRESHOLD_PX * MOVE_DRAG_THRESHOLD_PX
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

fn handle_mouse_release(response: &Response, app: &mut App, viewport: &CanvasViewport, snap: f32) {
    // We detect release indirectly: if the button was being dragged and is no longer.
    // egui doesn't have a direct "released" event, but drag_stopped works.
    if response.drag_stopped_by(PointerButton::Primary) {
        // Snapshot state before mutating to avoid borrow conflicts.
        let move_active = app.canvas().move_active;
        let rubber_band_active = app.canvas().rubber_band_active;
        let drag_is_pan = app.canvas().drag_is_pan;
        let rb_start = app.canvas().rubber_band_start;
        let rb_end = app.canvas().rubber_band_end;

        // Wire/draw tools: treat drag-release as a click too (fast mouse movement
        // causes egui to interpret clicks as drags, breaking wire placement).
        if !move_active && !rubber_band_active && !drag_is_pan {
            let tool = app.active_tool();
            if matches!(
                tool,
                Tool::Wire | Tool::Line | Tool::Rect | Tool::Circle | Tool::Arc
            ) {
                if let Some(pos) = response.interact_pointer_pos() {
                    let [wx, wy] = snap_world(viewport, pos, snap);
                    match tool {
                        Tool::Wire => handle_wire_click(app, wx, wy),
                        Tool::Line | Tool::Rect | Tool::Circle | Tool::Arc => {
                            handle_draw_click(app, tool, wx, wy);
                        }
                        _ => {}
                    }
                }
            }
        }

        // Complete rubber-band selection.
        if rubber_band_active {
            let min_x = rb_start[0].min(rb_end[0]);
            let min_y = rb_start[1].min(rb_end[1]);
            let max_x = rb_start[0].max(rb_end[0]);
            let max_y = rb_start[1].max(rb_end[1]);

            app.select_in_rect(min_x, min_y, max_x, max_y);
        }

        app.canvas_mut().rubber_band_active = false;
        // Commit coalesced move undo before clearing move_active.
        if move_active {
            app.commit_move_drag();
        }
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

fn handle_select_click(
    app: &mut App,
    _viewport: &CanvasViewport,
    pos: Pos2,
    wx: i32,
    wy: i32,
    shift: bool,
) {
    use schemify_handler::geometry::HitResult;

    let hit = app.hit_test(wx, wy);

    if hit != HitResult::Nothing {
        app.canvas_mut().move_press_pixel = [pos.x, pos.y];
        app.canvas_mut().move_start_world = [wx, wy];
        app.canvas_mut().drag_last = [pos.x, pos.y];
    }

    // Check if we clicked on an already-selected object (for move).
    let already_selected = match hit {
        HitResult::Instance(i) => app.is_instance_selected(i),
        HitResult::Wire(i) => app.is_wire_selected(i),
        HitResult::Line(i) => app.is_line_selected(i),
        HitResult::Rect(i) => app.is_rect_selected(i),
        HitResult::Circle(i) => app.is_circle_selected(i),
        HitResult::Arc(i) => app.is_arc_selected(i),
        HitResult::Text(i) => app.is_text_selected(i),
        HitResult::Polygon(i) => app.is_polygon_selected(i),
        HitResult::Nothing => false,
    };

    if already_selected {
        // Use a sentinel index — the actual move uses the full selection set.
        app.canvas_mut().move_hit_idx = Some(0);
        return;
    }

    // New selection.
    if !shift {
        app.dispatch(Command::SelectNone);
    }

    match hit {
        HitResult::Instance(i) => {
            app.canvas_mut().move_hit_idx = Some(i);
            app.select_instance(i);
        }
        HitResult::Wire(i) => {
            app.canvas_mut().move_hit_idx = Some(i);
            app.select_wire(i);
        }
        HitResult::Line(i) => {
            app.canvas_mut().move_hit_idx = Some(0);
            app.select_line(i);
        }
        HitResult::Rect(i) => {
            app.canvas_mut().move_hit_idx = Some(0);
            app.select_rect(i);
        }
        HitResult::Circle(i) => {
            app.canvas_mut().move_hit_idx = Some(0);
            app.select_circle(i);
        }
        HitResult::Arc(i) => {
            app.canvas_mut().move_hit_idx = Some(0);
            app.select_arc(i);
        }
        HitResult::Text(i) => {
            app.canvas_mut().move_hit_idx = Some(0);
            app.select_text(i);
        }
        HitResult::Polygon(i) => {
            app.canvas_mut().move_hit_idx = Some(0);
            app.select_polygon(i);
        }
        HitResult::Nothing => {
            app.canvas_mut().rubber_band_start = [wx, wy];
            app.canvas_mut().rubber_band_end = [wx, wy];
            app.canvas_mut().rubber_band_active = false;
            app.canvas_mut().move_press_pixel = [pos.x, pos.y];
            app.canvas_mut().move_hit_idx = None;
        }
    }
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
            // Chain from the committed wire's endpoint (not cursor position).
            app.set_wire_start(Some(end));
            return;
        }
        // Zero-length click: stay at same point.
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
                    x0: start[0],
                    y0: start[1],
                    x1: wx,
                    y1: wy,
                });
            }
            Tool::Rect => {
                app.dispatch(Command::AddRect {
                    x: start[0].min(wx),
                    y: start[1].min(wy),
                    w: (wx - start[0]).abs(),
                    h: (wy - start[1]).abs(),
                });
            }
            Tool::Circle => {
                let dx = (wx - start[0]) as f64;
                let dy = (wy - start[1]) as f64;
                let radius = (dx * dx + dy * dy).sqrt() as i32;
                app.dispatch(Command::AddCircle {
                    cx: start[0],
                    cy: start[1],
                    radius,
                });
            }
            Tool::Arc => {
                let dx = (wx - start[0]) as f64;
                let dy = (wy - start[1]) as f64;
                let radius = (dx * dx + dy * dy).sqrt() as i32;
                let start_angle = dy.atan2(dx) as f32;
                app.dispatch(Command::AddArc {
                    cx: start[0],
                    cy: start[1],
                    radius,
                    start: start_angle,
                    sweep: std::f32::consts::PI,
                });
            }
            _ => unreachable!(),
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

// ── Helpers ──────────────────────────────────────────────────────────────────

fn snap_world(viewport: &CanvasViewport, pos: Pos2, snap_size: f32) -> [i32; 2] {
    viewport.snap_to_grid(pos.x, pos.y, snap_size)
}

// ── Tests ───────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    /// Helper: build a viewport centered at (400, 300) with given zoom and pan.
    fn vp(zoom: f32, pan: [f32; 2]) -> CanvasViewport {
        CanvasViewport {
            center: Pos2::new(400.0, 300.0),
            zoom,
            pan,
        }
    }

    // ── world_to_pixel / pixel_to_world roundtrip ───────────────────────────

    #[test]
    fn world_to_pixel_origin_no_pan() {
        let v = vp(1.0, [0.0, 0.0]);
        let p = v.world_to_pixel(0.0, 0.0);
        assert!((p.x - 400.0).abs() < 1e-4);
        assert!((p.y - 300.0).abs() < 1e-4);
    }

    #[test]
    fn world_to_pixel_with_pan() {
        let v = vp(1.0, [10.0, 20.0]);
        // pixel = center + (world - pan) * zoom
        // pixel = (400, 300) + (10 - 10, 20 - 20) * 1 = (400, 300)
        let p = v.world_to_pixel(10.0, 20.0);
        assert!((p.x - 400.0).abs() < 1e-4);
        assert!((p.y - 300.0).abs() < 1e-4);
    }

    #[test]
    fn world_to_pixel_with_zoom() {
        let v = vp(2.0, [0.0, 0.0]);
        // pixel = (400, 300) + (50, 0) * 2 = (500, 300)
        let p = v.world_to_pixel(50.0, 0.0);
        assert!((p.x - 500.0).abs() < 1e-4);
        assert!((p.y - 300.0).abs() < 1e-4);
    }

    #[test]
    fn roundtrip_world_pixel_world() {
        let v = vp(1.5, [30.0, -20.0]);
        let wx = 42.0_f32;
        let wy = -17.0_f32;
        let p = v.world_to_pixel(wx, wy);
        let [rx, ry] = v.pixel_to_world(p.x, p.y);
        assert!((rx - wx).abs() < 1e-3, "x mismatch: {rx} vs {wx}");
        assert!((ry - wy).abs() < 1e-3, "y mismatch: {ry} vs {wy}");
    }

    #[test]
    fn roundtrip_pixel_world_pixel() {
        let v = vp(0.75, [100.0, 200.0]);
        let px = 550.0_f32;
        let py = 350.0_f32;
        let [wx, wy] = v.pixel_to_world(px, py);
        let p = v.world_to_pixel(wx, wy);
        assert!((p.x - px).abs() < 1e-3, "px mismatch: {} vs {px}", p.x);
        assert!((p.y - py).abs() < 1e-3, "py mismatch: {} vs {py}", p.y);
    }

    #[test]
    fn roundtrip_negative_coords() {
        let v = vp(2.0, [-50.0, -100.0]);
        let wx = -200.0_f32;
        let wy = -300.0_f32;
        let p = v.world_to_pixel(wx, wy);
        let [rx, ry] = v.pixel_to_world(p.x, p.y);
        assert!((rx - wx).abs() < 1e-3);
        assert!((ry - wy).abs() < 1e-3);
    }

    // ── w2p (integer convenience) ───────────────────────────────────────────

    #[test]
    fn w2p_matches_world_to_pixel_for_integers() {
        let v = vp(1.5, [10.0, 20.0]);
        let p1 = v.w2p(100, -50);
        let p2 = v.world_to_pixel(100.0, -50.0);
        assert!((p1.x - p2.x).abs() < 1e-4);
        assert!((p1.y - p2.y).abs() < 1e-4);
    }

    // ── snap_to_grid ────────────────────────────────────────────────────────

    #[test]
    fn snap_to_grid_basic() {
        let v = vp(1.0, [0.0, 0.0]);
        // Pixel (400, 300) is world (0, 0). Snap to grid=10 -> (0, 0).
        let [sx, sy] = v.snap_to_grid(400.0, 300.0, 10.0);
        assert_eq!(sx, 0);
        assert_eq!(sy, 0);
    }

    #[test]
    fn snap_to_grid_rounds_to_nearest() {
        let v = vp(1.0, [0.0, 0.0]);
        // Pixel (404, 300) is world (4, 0). With grid=10, rounds to (0, 0).
        let [sx, sy] = v.snap_to_grid(404.0, 300.0, 10.0);
        assert_eq!(sx, 0);
        assert_eq!(sy, 0);

        // Pixel (406, 300) is world (6, 0). With grid=10, rounds to (10, 0).
        let [sx, sy] = v.snap_to_grid(406.0, 300.0, 10.0);
        assert_eq!(sx, 10);
        assert_eq!(sy, 0);
    }

    #[test]
    fn snap_to_grid_negative_coords() {
        let v = vp(1.0, [0.0, 0.0]);
        // Pixel (396, 300) is world (-4, 0). With grid=10, rounds to (0, 0).
        let [sx, sy] = v.snap_to_grid(396.0, 300.0, 10.0);
        assert_eq!(sx, 0);
        assert_eq!(sy, 0);

        // Pixel (394, 300) is world (-6, 0). With grid=10, rounds to (-10, 0).
        let [sx, sy] = v.snap_to_grid(394.0, 300.0, 10.0);
        assert_eq!(sx, -10);
        assert_eq!(sy, 0);
    }

    #[test]
    fn snap_to_grid_zero_grid_size_uses_one() {
        let v = vp(1.0, [0.0, 0.0]);
        // Grid size 0 -> fallback to 1.0, so snaps to nearest integer.
        let [sx, sy] = v.snap_to_grid(403.0, 302.0, 0.0);
        assert_eq!(sx, 3);
        assert_eq!(sy, 2);
    }

    #[test]
    fn snap_to_grid_negative_grid_size_uses_one() {
        let v = vp(1.0, [0.0, 0.0]);
        // Negative grid size -> fallback to 1.0.
        let [sx, sy] = v.snap_to_grid(403.0, 302.0, -5.0);
        assert_eq!(sx, 3);
        assert_eq!(sy, 2);
    }

    #[test]
    fn snap_to_grid_with_zoom() {
        let v = vp(2.0, [0.0, 0.0]);
        // Pixel (410, 300) = world ((410-400)/2, 0) = (5, 0).
        // Grid=10 -> rounds to (10, 0).
        let [sx, sy] = v.snap_to_grid(410.0, 300.0, 10.0);
        assert_eq!(sx, 10);
        assert_eq!(sy, 0);
    }

    #[test]
    fn snap_to_grid_small_grid() {
        let v = vp(1.0, [0.0, 0.0]);
        // World (3, 3) with grid=5 -> rounds to (5, 5).
        let [sx, sy] = v.snap_to_grid(403.0, 303.0, 5.0);
        assert_eq!(sx, 5);
        assert_eq!(sy, 5);
    }

    // ── pixel_to_world edge cases ───────────────────────────────────────────

    #[test]
    fn pixel_to_world_at_center_is_pan() {
        let v = vp(1.0, [50.0, 60.0]);
        let [wx, wy] = v.pixel_to_world(400.0, 300.0);
        assert!((wx - 50.0).abs() < 1e-4);
        assert!((wy - 60.0).abs() < 1e-4);
    }

    // ── thickness_width ─────────────────────────────────────────────────────

    #[test]
    fn thickness_width_zero_returns_default() {
        assert!((thickness_width(0) - 1.0).abs() < f32::EPSILON);
    }

    #[test]
    fn thickness_width_converts_tenths() {
        assert!((thickness_width(10) - 1.0).abs() < f32::EPSILON);
        assert!((thickness_width(20) - 2.0).abs() < f32::EPSILON);
        assert!((thickness_width(5) - 0.5).abs() < f32::EPSILON);
    }

    // ── color_or ────────────────────────────────────────────────────────────

    #[test]
    fn color_or_none_returns_default() {
        let default = Color32::from_rgb(100, 200, 50);
        let result = color_or(Color::NONE, default);
        assert_eq!(result, default);
    }

    #[test]
    fn color_or_explicit_returns_explicit() {
        let c = Color {
            r: 10,
            g: 20,
            b: 30,
            a: 255,
        };
        let default = Color32::from_rgb(0, 0, 0);
        let result = color_or(c, default);
        assert_eq!(result, Color32::from_rgba_premultiplied(10, 20, 30, 255));
    }

}
