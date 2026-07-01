//! Schematic canvas: viewport transform, dot grid, layered rendering,
//! interaction (select / move / draw / pan / zoom), and tool previews.
//!
//! Render order (bottom → top): grid → wires → buses → instances →
//! geometry → pins → selection → overlays.
//
// deferred: tb_overlay.rs (testbench usage thumbnails) — phase-7 wiring

use std::collections::HashMap;

use eframe::egui::{self, Color32, FontId, Painter, PointerButton, Pos2, Response, Stroke,
    StrokeKind};

use schemify_core::handler::{App, ArcStep, ObjectRef, PanMode, SELECT_HIT_RADIUS_SQ};
use schemify_core::schemify::{self as prim, Command, DeviceKind, InstanceFlags, PinDirection,
    Tool};
use schemify_plugins::{MarkerKind, OverlayLayer, OverlayShape};

use crate::state::{color_or, CtxHit, GuiState, Theme};

// ════════════════════════════════════════════════════════════
// Viewport — world (schematic i32) ↔ pixel (screen f32)
// ════════════════════════════════════════════════════════════

/// Transform: `pixel = center + (world - pan) * zoom`
pub struct CanvasViewport {
    /// Center of the canvas area in pixel coordinates.
    pub center: Pos2,
    pub zoom: f32,
    /// Pan offset in world coordinates.
    pub pan: [f32; 2],
}

impl CanvasViewport {
    pub fn from_app(app: &App, rect: egui::Rect) -> Self {
        let vp = &app.active_doc().viewport;
        Self {
            center: rect.center(),
            zoom: vp.zoom,
            pan: vp.pan,
        }
    }

    #[inline]
    pub fn world_to_pixel(&self, wx: f32, wy: f32) -> Pos2 {
        Pos2::new(
            self.center.x + (wx - self.pan[0]) * self.zoom,
            self.center.y + (wy - self.pan[1]) * self.zoom,
        )
    }

    #[inline]
    pub fn pixel_to_world(&self, px: f32, py: f32) -> [f32; 2] {
        [
            (px - self.center.x) / self.zoom + self.pan[0],
            (py - self.center.y) / self.zoom + self.pan[1],
        ]
    }

    /// Pixel position → snapped world coordinates (i32).
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

/// Arc approximated with line segments. Angles in degrees, positive CCW.
fn stroke_arc(painter: &Painter, center: Pos2, radius_px: f32, start_deg: f32, sweep_deg: f32,
    stroke: Stroke) {
    let n_segs = ((sweep_deg.abs() / 10.0) as usize).clamp(8, 64);
    let (start_rad, sweep_rad) = (start_deg.to_radians(), sweep_deg.to_radians());
    let mut prev = Pos2::new(
        center.x + radius_px * start_rad.cos(),
        center.y - radius_px * start_rad.sin(),
    );
    for i in 1..=n_segs {
        let angle = start_rad + sweep_rad * (i as f32 / n_segs as f32);
        let cur = Pos2::new(
            center.x + radius_px * angle.cos(),
            center.y - radius_px * angle.sin(),
        );
        painter.line_segment([prev, cur], stroke);
        prev = cur;
    }
}

/// Circle approximated with line segments (24 segs render, 16 ghost).
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

/// Thickness field (tenths) → stroke width, default 1.0.
#[inline]
fn thickness_width(thickness: u8) -> f32 {
    if thickness > 0 {
        thickness as f32 / 10.0
    } else {
        1.0
    }
}

// ════════════════════════════════════════════════════════════
// Entry point
// ════════════════════════════════════════════════════════════

/// Render the schematic canvas and handle all interaction.
pub fn show(
    ui: &mut egui::Ui,
    app: &mut App,
    gui: &mut GuiState,
    plugin_overlays: &[OverlayLayer],
) {
    use schemify_core::handler::ViewMode;

    let rect = ui.available_rect_before_wrap();
    let viewport = CanvasViewport::from_app(app, rect);
    let theme = gui.theme.clone();

    ui.painter().rect_filled(rect, 0.0, theme.canvas_bg);
    let response = ui.allocate_rect(rect, egui::Sense::click_and_drag());
    let painter = ui.painter_at(rect);

    let is_symbol_mode = app.state.view.view_mode == ViewMode::Symbol;

    // Layer 1: grid + origin crosshair.
    render_grid(&painter, &viewport, &theme, app.state.view.show_grid);

    if is_symbol_mode {
        let sch = app.schematic();
        let has_symbol_data = !sch.pins.is_empty()
            || !sch.lines.is_empty()
            || !sch.rects.is_empty()
            || !sch.circles.is_empty()
            || !sch.arcs.is_empty()
            || !sch.instances.is_empty(); // labels count for auto-gen
        if has_symbol_data {
            render_geometry(&painter, app, &viewport, &theme, gui.fill_rects);
            render_symbol_pins(&painter, app, &viewport, &theme);
        } else {
            painter.text(
                viewport.w2p(0, 0),
                egui::Align2::CENTER_CENTER,
                "No symbol defined\n\nUse \"Generate Symbol\" in SCH mode\nor draw geometry here",
                FontId::proportional(16.0),
                theme.text_label,
            );
        }
    } else {
        // Connectivity (label-conflict detection) before rendering.
        let conflicts: Vec<usize> = app.connectivity().label_conflicts.iter().copied().collect();

        // Layers 2-7.
        render_wires(&painter, app, &viewport, &theme);
        render_buses(&painter, app, &viewport, &theme);
        render_instances(&painter, app, &viewport, &theme, &conflicts);
        render_geometry(&painter, app, &viewport, &theme, gui.fill_rects);
        if !app.schematic().pins.is_empty() {
            render_symbol_pins(&painter, app, &viewport, &theme);
        }
        render_selection(&painter, app, &viewport, &theme);

        // Layer 8: dynamic overlays (previews, rubber band, crosshair).
        render_overlays(&painter, app, gui, &viewport, &theme);

        // Layer 9: plugin overlay layers (z-ordered).
        render_plugin_overlays(&painter, plugin_overlays, &viewport);
    }

    // Interaction.
    handle_interaction(&response, app, gui, &viewport, ui.ctx());

    // Text input overlay for the Text tool.
    show_text_input_overlay(ui, app, &viewport);

    // Cursor world position for status bar / previews.
    if let Some(pos) = response.hover_pos() {
        let [wx, wy] = viewport.pixel_to_world(pos.x, pos.y);
        app.state.canvas.cursor_world = [wx as i32, wy as i32];
    }
}

// ════════════════════════════════════════════════════════════
// Grid
// ════════════════════════════════════════════════════════════

const GRID_MIN_STEP_PX: f32 = 3.0;
const GRID_MAX_POINTS: usize = 16_000;
const DEFAULT_GRID_SPACING: f32 = 10.0;

fn render_grid(painter: &Painter, vp: &CanvasViewport, theme: &Theme, show_grid: bool) {
    let clip = painter.clip_rect();

    // Origin crosshair (always shown).
    let origin = vp.world_to_pixel(0.0, 0.0);
    let arm = 20.0_f32;
    let stroke = Stroke::new(1.0_f32, theme.origin);
    if origin.y >= clip.min.y && origin.y <= clip.max.y {
        painter.line_segment(
            [
                Pos2::new((origin.x - arm).max(clip.min.x), origin.y),
                Pos2::new((origin.x + arm).min(clip.max.x), origin.y),
            ],
            stroke,
        );
    }
    if origin.x >= clip.min.x && origin.x <= clip.max.x {
        painter.line_segment(
            [
                Pos2::new(origin.x, (origin.y - arm).max(clip.min.y)),
                Pos2::new(origin.x, (origin.y + arm).min(clip.max.y)),
            ],
            stroke,
        );
    }

    if !show_grid {
        return;
    }

    let spacing = DEFAULT_GRID_SPACING;
    let step_px = spacing * vp.zoom;
    if step_px < GRID_MIN_STEP_PX {
        return;
    }

    let [w_left, w_top] = vp.pixel_to_world(clip.min.x, clip.min.y);
    let [w_right, w_bottom] = vp.pixel_to_world(clip.max.x, clip.max.y);
    let x_start = (w_left / spacing).floor() as i32;
    let x_end = (w_right / spacing).ceil() as i32;
    let y_start = (w_top / spacing).floor() as i32;
    let y_end = (w_bottom / spacing).ceil() as i32;

    let total = ((x_end - x_start + 1).max(0) as usize)
        .saturating_mul((y_end - y_start + 1).max(0) as usize);
    if total == 0 || total > GRID_MAX_POINTS {
        return;
    }

    let dot_radius = (0.8 * vp.zoom.min(2.0)).max(0.5);
    for gy in y_start..=y_end {
        for gx in x_start..=x_end {
            let p = vp.world_to_pixel(gx as f32 * spacing, gy as f32 * spacing);
            painter.circle_filled(p, dot_radius, theme.grid_dot);
        }
    }
}

// ════════════════════════════════════════════════════════════
// Rendering layers
// ════════════════════════════════════════════════════════════

fn render_wires(painter: &Painter, app: &App, vp: &CanvasViewport, theme: &Theme) {
    let sel = &app.active_doc().selection;
    let wires = &app.schematic().wires;
    let n = wires.len();
    if n == 0 {
        return;
    }

    let wire_w = (1.8 * vp.zoom).max(0.8);
    let wire_w_sel = (2.8 * vp.zoom).max(1.2);

    // Endpoint occurrence counts for junction detection.
    let mut point_counts: HashMap<(i32, i32), u8> = HashMap::with_capacity((n * 2).min(4096));
    for i in 0..n {
        for p in [(wires.x0[i], wires.y0[i]), (wires.x1[i], wires.y1[i])] {
            let e = point_counts.entry(p).or_insert(0);
            *e = e.saturating_add(1);
        }
    }

    for i in 0..n {
        let selected = sel.contains(ObjectRef::Wire(i as u32));
        let a = vp.w2p(wires.x0[i], wires.y0[i]);
        let b = vp.w2p(wires.x1[i], wires.y1[i]);
        let col = if selected {
            theme.wire_selected
        } else if !wires.color[i].is_none() {
            let c = wires.color[i];
            Color32::from_rgb(c.r, c.g, c.b)
        } else {
            theme.wire
        };
        let w = if selected { wire_w_sel } else { wire_w } * thickness_width(wires.thickness[i]);
        painter.line_segment([a, b], Stroke::new(w, col));
    }

    // Junction markers where 3+ wire endpoints meet.
    let junction_sz = (2.5 * vp.zoom.min(2.0)).max(2.0);
    for (&(wx, wy), &count) in &point_counts {
        if count >= 3 {
            let p = vp.w2p(wx, wy);
            painter.rect_filled(
                egui::Rect::from_center_size(p, egui::Vec2::splat(junction_sz * 2.0)),
                0.0,
                theme.symbol_line,
            );
        }
    }

    // Endpoint dots.
    let ep_radius = (2.0 * vp.zoom.min(2.0)).max(1.5);
    for i in 0..n {
        painter.circle_filled(vp.w2p(wires.x0[i], wires.y0[i]), ep_radius, theme.wire_endpoint);
        painter.circle_filled(vp.w2p(wires.x1[i], wires.y1[i]), ep_radius, theme.wire_endpoint);
    }
}

fn render_buses(painter: &Painter, app: &App, vp: &CanvasViewport, theme: &Theme) {
    let sch = app.schematic();
    let buses = &sch.buses;
    let n = buses.len();
    if n == 0 && sch.bus_rippers.is_empty() {
        return;
    }

    let wire_w = (1.8 * vp.zoom).max(0.8);
    let bus_w = wire_w * 3.0;
    let sel = &app.active_doc().selection;

    for i in 0..n {
        let a = vp.w2p(buses.x0[i], buses.y0[i]);
        let b = vp.w2p(buses.x1[i], buses.y1[i]);
        let col = if sel.contains(ObjectRef::Bus(i as u32)) {
            theme.wire_selected
        } else if !buses.color[i].is_none() {
            let c = buses.color[i];
            Color32::from_rgb(c.r, c.g, c.b)
        } else {
            theme.bus
        };
        let w = bus_w * thickness_width(buses.thickness[i]);
        painter.line_segment([a, b], Stroke::new(w, col));

        // Diagonal slash at midpoint + width annotation.
        let mx = (a.x + b.x) * 0.5;
        let my = (a.y + b.y) * 0.5;
        let half = (8.0 * vp.zoom.min(2.0)).max(5.0) * 0.5;
        painter.line_segment(
            [Pos2::new(mx - half, my + half), Pos2::new(mx + half, my - half)],
            Stroke::new(wire_w * 1.2, col),
        );
        if vp.zoom >= 0.2 {
            painter.text(
                Pos2::new(mx + half + 2.0, my - half - 2.0),
                egui::Align2::LEFT_BOTTOM,
                format!("{}", buses.width[i]),
                FontId::proportional((10.0 * vp.zoom.min(2.0)).max(8.0)),
                col,
            );
        }
        if vp.zoom >= 0.3 {
            let label = app.resolve(buses.label[i]);
            if !label.is_empty() {
                painter.text(
                    Pos2::new(mx, my - bus_w - 6.0),
                    egui::Align2::CENTER_BOTTOM,
                    label,
                    FontId::proportional((11.0 * vp.zoom.min(2.0)).max(9.0)),
                    theme.text_label,
                );
            }
        }
    }

    // Bus rippers: stub + filled circle.
    let ripper_radius = (3.0 * vp.zoom.min(2.0)).max(2.0);
    for ripper in &sch.bus_rippers {
        let p = vp.w2p(ripper.x, ripper.y);
        let stub = ripper.stub_len as f32 * vp.zoom;
        let (dx, dy) = match ripper.direction & 0x03 {
            0 => (stub, 0.0),
            1 => (0.0, -stub),
            2 => (-stub, 0.0),
            _ => (0.0, stub),
        };
        painter.line_segment([p, Pos2::new(p.x + dx, p.y + dy)], Stroke::new(wire_w, theme.bus));
        painter.circle_filled(p, ripper_radius, theme.bus);
    }
}

/// Draw a primitive entry's geometry at `origin` with the given transform.
fn draw_prim_geometry(painter: &Painter, entry: &prim::PrimEntry, origin: Pos2,
    flags: InstanceFlags, zoom: f32, stroke: Stroke) {
    let tp = |x: i16, y: i16| {
        let (ax, ay) = flags.transform_point(x as i32, y as i32);
        Pos2::new(origin.x + ax as f32 * zoom, origin.y + ay as f32 * zoom)
    };
    for seg in &entry.segments {
        painter.line_segment([tp(seg.x0, seg.y0), tp(seg.x1, seg.y1)], stroke);
    }
    for c in &entry.circles {
        let radius_px = c.r as f32 * zoom;
        if radius_px > 0.5 {
            stroke_circle(painter, tp(c.cx, c.cy), radius_px, 24, stroke);
        }
    }
    for a in &entry.arcs {
        let radius_px = a.r as f32 * zoom;
        if radius_px > 0.5 {
            stroke_arc(painter, tp(a.cx, a.cy), radius_px, a.start as f32, a.sweep as f32, stroke);
        }
    }
    for r in &entry.rects {
        let rect = egui::Rect::from_two_pos(tp(r.x0, r.y0), tp(r.x1, r.y1));
        painter.rect_stroke(rect, 0.0, stroke, StrokeKind::Outside);
    }
}

fn render_instances(painter: &Painter, app: &App, vp: &CanvasViewport, theme: &Theme,
    conflicts: &[usize]) {
    let sel = &app.active_doc().selection;
    let insts = &app.schematic().instances;
    let n = insts.len();
    if n == 0 {
        return;
    }

    let sym_w = (1.8 * vp.zoom).max(0.9);
    let pin_r = (3.0 * vp.zoom.min(2.0)).max(2.0);
    let dec_w = sym_w * 0.6;

    for i in 0..n {
        let selected = sel.contains(ObjectRef::Instance(i as u32));
        let origin = vp.w2p(insts.x[i], insts.y[i]);
        let flags = insts.flags[i];
        let kind = insts.kind[i];

        let color = if conflicts.contains(&i) {
            theme.inst_error
        } else if selected {
            theme.inst_selected
        } else {
            theme.symbol_line
        };
        let stroke = Stroke::new(sym_w, color);

        if let Some(entry) = prim::find_symbol(app.resolve(insts.symbol[i]), kind) {
            draw_prim_geometry(painter, entry, origin, flags, vp.zoom, stroke);
            // Pin markers (hollow circles).
            for pp in &entry.pin_positions {
                if entry.non_electrical && pp.x == 0 && pp.y == 0 {
                    continue;
                }
                let (px, py) = flags.transform_point(pp.x as i32, pp.y as i32);
                let pin_pos = Pos2::new(
                    origin.x + px as f32 * vp.zoom,
                    origin.y + py as f32 * vp.zoom,
                );
                painter.circle_stroke(pin_pos, pin_r, Stroke::new(dec_w, color));
            }
        } else {
            // Generic fallback box for subcircuits without primitives.
            let half = 20.0 * vp.zoom;
            let rect = egui::Rect::from_center_size(origin, egui::Vec2::splat(half * 2.0));
            painter.rect_stroke(rect, 0.0, stroke, StrokeKind::Outside);
            if vp.zoom >= 0.2 {
                let sym_str = app.resolve(insts.symbol[i]);
                if !sym_str.is_empty() {
                    painter.text(
                        origin,
                        egui::Align2::CENTER_CENTER,
                        sym_str,
                        FontId::proportional((10.0 * vp.zoom.min(2.0)).max(8.0)),
                        color,
                    );
                }
            }
        }
    }

    // Instance name labels.
    if vp.zoom >= 0.3 {
        let label_col = Color32::from_rgba_premultiplied(
            theme.symbol_line.r(),
            theme.symbol_line.g(),
            theme.symbol_line.b(),
            180,
        );
        let font = FontId::proportional((11.0 * vp.zoom.min(2.0)).max(9.0));
        for i in 0..n {
            let name_str = app.resolve(insts.name[i]);
            if name_str.is_empty() {
                continue;
            }
            let origin = vp.w2p(insts.x[i], insts.y[i]);
            let flags = insts.flags[i];

            // Use the @name text anchor from the primitive when present.
            let anchor = prim::find_symbol(app.resolve(insts.symbol[i]), insts.kind[i])
                .and_then(|e| e.texts.iter().find(|dt| dt.content == "@name"))
                .map(|dt| {
                    let (tx, ty) = flags.transform_point(dt.x as i32, dt.y as i32);
                    Pos2::new(
                        origin.x + tx as f32 * vp.zoom,
                        origin.y + ty as f32 * vp.zoom,
                    )
                })
                .unwrap_or_else(|| {
                    Pos2::new(origin.x + 15.0 * vp.zoom, origin.y - 15.0 * vp.zoom)
                });
            painter.text(anchor, egui::Align2::LEFT_CENTER, name_str, font.clone(), label_col);
        }

        // Parameter value labels (e.g. @r, @dc, @w/@l).
        let param_col = Color32::from_rgba_premultiplied(
            theme.symbol_line.r(),
            theme.symbol_line.g(),
            theme.symbol_line.b(),
            140,
        );
        let pfont = FontId::proportional((10.0 * vp.zoom.min(2.0)).max(8.0));
        let sch = app.schematic();
        for i in 0..n {
            let entry = match prim::find_symbol(app.resolve(insts.symbol[i]), insts.kind[i]) {
                Some(e) => e,
                None => continue,
            };
            let props = sch.instance_props(i);
            if props.is_empty() {
                continue;
            }
            let origin = vp.w2p(insts.x[i], insts.y[i]);
            let flags = insts.flags[i];
            let po = insts.param_offset[i];

            for dt in &entry.texts {
                if dt.content == "@name" || !dt.content.starts_with('@') {
                    continue;
                }
                let label = dt.content[1..] // strip leading @
                    .split('/')
                    .map(|part| {
                        props
                            .iter()
                            .find(|p| app.resolve(p.key) == part)
                            .map(|p| app.resolve(p.value))
                            .unwrap_or(part)
                    })
                    .collect::<Vec<_>>()
                    .join("/");

                let (tx, ty) = flags.transform_point(
                    dt.x as i32 + po[0] as i32,
                    dt.y as i32 + po[1] as i32,
                );
                let pos = Pos2::new(
                    origin.x + tx as f32 * vp.zoom,
                    origin.y + ty as f32 * vp.zoom,
                );
                painter.text(pos, egui::Align2::LEFT_CENTER, &label, pfont.clone(), param_col);
            }
        }
    }
}

fn render_geometry(painter: &Painter, app: &App, vp: &CanvasViewport, theme: &Theme,
    fill_rects: bool) {
    let sch = app.schematic();

    for line in &sch.lines {
        painter.line_segment(
            [vp.w2p(line.x0, line.y0), vp.w2p(line.x1, line.y1)],
            Stroke::new(thickness_width(line.thickness), color_or(line.color, theme.geometry_line)),
        );
    }

    for r in &sch.rects {
        let rect = egui::Rect::from_two_pos(vp.w2p(r.x, r.y), vp.w2p(r.x + r.width, r.y + r.height));
        if !r.fill.is_none() || fill_rects {
            painter.rect_filled(rect, 0.0, color_or(r.fill, theme.geometry_fill));
        }
        painter.rect_stroke(
            rect,
            0.0,
            Stroke::new(thickness_width(r.thickness), color_or(r.stroke, theme.geometry_line)),
            StrokeKind::Outside,
        );
    }

    for c in &sch.circles {
        let center = vp.w2p(c.cx, c.cy);
        let radius_px = c.radius as f32 * vp.zoom;
        if !c.fill.is_none() {
            painter.circle_filled(center, radius_px, color_or(c.fill, Color32::TRANSPARENT));
        }
        painter.circle_stroke(
            center,
            radius_px,
            Stroke::new(thickness_width(c.thickness), color_or(c.stroke, theme.geometry_line)),
        );
    }

    for a in &sch.arcs {
        let radius_px = a.radius as f32 * vp.zoom;
        if radius_px > 0.5 {
            stroke_arc(
                painter,
                vp.w2p(a.cx, a.cy),
                radius_px,
                a.start_angle,
                a.sweep_angle,
                Stroke::new(thickness_width(a.thickness), color_or(a.stroke, theme.geometry_line)),
            );
        }
    }

    // Polygons — point buffer reused across polygons.
    let mut points: Vec<Pos2> = Vec::new();
    for poly in &sch.polygons {
        if poly.points.len() < 2 {
            continue;
        }
        let stroke = Stroke::new(
            thickness_width(poly.thickness),
            color_or(poly.stroke, theme.geometry_line),
        );
        points.clear();
        points.extend(poly.points.iter().map(|p| vp.w2p(p[0], p[1])));
        if !poly.fill.is_none() && points.len() >= 3 {
            painter.add(egui::Shape::convex_polygon(
                points.clone(),
                color_or(poly.fill, Color32::TRANSPARENT),
                Stroke::NONE,
            ));
        }
        for win in points.windows(2) {
            painter.line_segment([win[0], win[1]], stroke);
        }
        if points.len() >= 3 {
            painter.line_segment([*points.last().unwrap(), points[0]], stroke);
        }
    }

    if vp.zoom >= 0.3 {
        for t in &sch.texts {
            let content = app.resolve(t.content);
            if content.is_empty() {
                continue;
            }
            painter.text(
                vp.w2p(t.x, t.y),
                egui::Align2::LEFT_TOP,
                content,
                FontId::proportional((t.font_size * vp.zoom).max(8.0)),
                color_or(t.color, theme.text_label),
            );
        }
    }
}

fn render_symbol_pins(painter: &Painter, app: &App, vp: &CanvasViewport, theme: &Theme) {
    let sch = app.schematic();
    let pin_arm = 6.0 * vp.zoom;

    let has_geometry = !sch.lines.is_empty()
        || !sch.rects.is_empty()
        || !sch.circles.is_empty()
        || !sch.arcs.is_empty();
    if !has_geometry && sch.pins.is_empty() {
        render_auto_symbol_box(painter, app, vp, theme);
        return;
    }

    for pin in &sch.pins {
        let p = vp.w2p(pin.x, pin.y);

        // Crosshair.
        let s1 = Stroke::new(1.0_f32, theme.inst_pin);
        painter.line_segment([Pos2::new(p.x - pin_arm, p.y), Pos2::new(p.x + pin_arm, p.y)], s1);
        painter.line_segment([Pos2::new(p.x, p.y - pin_arm), Pos2::new(p.x, p.y + pin_arm)], s1);

        // Direction indicator.
        let sz = pin_arm * 0.75;
        let s2 = Stroke::new(0.9_f32, theme.wire_endpoint);
        match pin.direction {
            PinDirection::Input => {
                painter.line_segment([p, Pos2::new(p.x - sz, p.y - sz * 0.6)], s2);
                painter.line_segment([p, Pos2::new(p.x - sz, p.y + sz * 0.6)], s2);
            }
            PinDirection::Output => {
                painter.line_segment([p, Pos2::new(p.x + sz, p.y - sz * 0.6)], s2);
                painter.line_segment([p, Pos2::new(p.x + sz, p.y + sz * 0.6)], s2);
            }
            PinDirection::InOut => {
                let pts = [
                    Pos2::new(p.x - sz, p.y),
                    Pos2::new(p.x, p.y - sz * 0.6),
                    Pos2::new(p.x + sz, p.y),
                    Pos2::new(p.x, p.y + sz * 0.6),
                ];
                for k in 0..4 {
                    painter.line_segment([pts[k], pts[(k + 1) % 4]], s2);
                }
            }
            PinDirection::Power | PinDirection::Ground => {
                let s = sz * 0.7;
                painter.line_segment([Pos2::new(p.x - s, p.y), Pos2::new(p.x + s, p.y)], s2);
                painter.line_segment([Pos2::new(p.x, p.y - s), Pos2::new(p.x, p.y + s)], s2);
            }
        }

        if vp.zoom >= 0.3 {
            let name = app.resolve(pin.name);
            if !name.is_empty() {
                painter.text(
                    Pos2::new(p.x + pin_arm + 2.0, p.y - 6.0 * vp.zoom),
                    egui::Align2::LEFT_TOP,
                    name,
                    FontId::proportional((12.0 * vp.zoom).max(8.0)),
                    theme.text_label,
                );
            }
        }
    }
}

/// Auto-generated symbol box preview from label instances (symbol mode
/// without explicit geometry/pins).
fn render_auto_symbol_box(painter: &Painter, app: &App, vp: &CanvasViewport, theme: &Theme) {
    let sch = app.schematic();

    let mut labels: Vec<(String, bool)> = Vec::new(); // (name, is_output)
    for i in 0..sch.instances.len() {
        let kind = sch.instances.kind[i];
        if kind.is_label() {
            labels.push((
                app.resolve(sch.instances.name[i]).to_string(),
                kind == DeviceKind::OutputPin,
            ));
        }
    }

    if labels.is_empty() {
        painter.text(
            vp.world_to_pixel(0.0, 0.0),
            egui::Align2::CENTER_CENTER,
            "No symbol data. Add pins or click \"Generate Symbol\".",
            FontId::proportional(14.0),
            theme.text_label,
        );
        return;
    }

    let (mut left, mut right): (Vec<&(String, bool)>, Vec<&(String, bool)>) =
        labels.iter().partition(|(_, out)| !out);
    if left.is_empty() && !right.is_empty() {
        let half = right.len() / 2;
        left.extend(right.drain(..half));
    }

    let max_pins = left.len().max(right.len()).max(1);
    let pin_spacing: i32 = 20;
    let stub_len: i32 = 10;
    let max_name_len = labels.iter().map(|(n, _)| n.len()).max().unwrap_or(3);
    let box_w: i32 = 120.max(max_name_len as i32 * 8 + 40);
    let box_h: i32 = (max_pins as i32 + 1) * pin_spacing;

    let body = egui::Rect::from_two_pos(vp.w2p(0, 0), vp.w2p(box_w, box_h));
    painter.rect_stroke(body, 0.0, Stroke::new(1.5_f32, theme.symbol_line), StrokeKind::Outside);

    let draw_side = |pins: &[&(String, bool)], left_side: bool| {
        for (slot, (name, _)) in pins.iter().enumerate() {
            let py = (slot as i32 + 1) * pin_spacing;
            let (stub_a, stub_b, circle_at, text_x, align) = if left_side {
                (vp.w2p(-stub_len, py), vp.w2p(0, py), vp.w2p(-stub_len, py), 4,
                    egui::Align2::LEFT_TOP)
            } else {
                (vp.w2p(box_w, py), vp.w2p(box_w + stub_len, py), vp.w2p(box_w + stub_len, py),
                    box_w - 4, egui::Align2::RIGHT_TOP)
            };
            painter.line_segment([stub_a, stub_b], Stroke::new(1.0_f32, theme.inst_pin));
            painter.circle_filled(circle_at, 3.0, theme.inst_pin);
            if vp.zoom >= 0.3 {
                let label_pos = vp.w2p(text_x, py);
                painter.text(
                    Pos2::new(label_pos.x, label_pos.y - 6.0 * vp.zoom),
                    align,
                    name,
                    FontId::proportional((11.0 * vp.zoom).max(8.0)),
                    theme.text_label,
                );
            }
        }
    };
    draw_side(&left, true);
    draw_side(&right, false);

    if !sch.name.is_empty() {
        painter.text(
            vp.w2p(box_w / 2, box_h / 2),
            egui::Align2::CENTER_CENTER,
            &sch.name,
            FontId::proportional((13.0 * vp.zoom).max(8.0)),
            theme.symbol_line,
        );
    }
}

fn render_selection(painter: &Painter, app: &App, vp: &CanvasViewport, theme: &Theme) {
    let sel = &app.active_doc().selection;
    if sel.is_empty() {
        return;
    }
    let sch = app.schematic();
    let hl = Stroke::new((3.0 * vp.zoom).max(1.5), theme.inst_selected);
    let halo = 4.0;

    for &r in &sel.objs {
        let i = r.index();
        match r {
            ObjectRef::Instance(_) if i < sch.instances.len() => {
                let origin = vp.w2p(sch.instances.x[i], sch.instances.y[i]);
                // Bounding halo from primitive extents (default 20).
                let entry =
                    prim::find_symbol(app.resolve(sch.instances.symbol[i]), sch.instances.kind[i]);
                let mut max_ext: f32 = 20.0;
                if let Some(e) = entry {
                    for seg in &e.segments {
                        max_ext = max_ext
                            .max(seg.x0.unsigned_abs() as f32)
                            .max(seg.y0.unsigned_abs() as f32)
                            .max(seg.x1.unsigned_abs() as f32)
                            .max(seg.y1.unsigned_abs() as f32);
                    }
                    for pp in &e.pin_positions {
                        max_ext = max_ext
                            .max(pp.x.unsigned_abs() as f32)
                            .max(pp.y.unsigned_abs() as f32);
                    }
                }
                let half = (max_ext + halo) * vp.zoom;
                let rect = egui::Rect::from_center_size(origin, egui::Vec2::splat(half * 2.0));
                painter.rect_stroke(rect, 2.0, hl, StrokeKind::Outside);
            }
            // Wires/buses get a thicker colored stroke in their own layers;
            // halos here are redundant.
            ObjectRef::Wire(_) | ObjectRef::Bus(_) => {}
            ObjectRef::Line(_) if i < sch.lines.len() => {
                let l = &sch.lines[i];
                painter.line_segment([vp.w2p(l.x0, l.y0), vp.w2p(l.x1, l.y1)], hl);
            }
            ObjectRef::Rect(_) if i < sch.rects.len() => {
                let r = &sch.rects[i];
                let rect = egui::Rect::from_two_pos(
                    vp.w2p(r.x, r.y),
                    vp.w2p(r.x + r.width, r.y + r.height),
                );
                painter.rect_stroke(rect, 0.0, hl, StrokeKind::Outside);
            }
            ObjectRef::Circle(_) if i < sch.circles.len() => {
                let c = &sch.circles[i];
                painter.circle_stroke(vp.w2p(c.cx, c.cy), c.radius as f32 * vp.zoom, hl);
            }
            ObjectRef::Arc(_) if i < sch.arcs.len() => {
                let a = &sch.arcs[i];
                stroke_arc(
                    painter,
                    vp.w2p(a.cx, a.cy),
                    a.radius as f32 * vp.zoom,
                    a.start_angle,
                    a.sweep_angle,
                    hl,
                );
            }
            ObjectRef::Text(_) if i < sch.texts.len() => {
                let t = &sch.texts[i];
                let p = vp.w2p(t.x, t.y);
                let content = app.resolve(t.content);
                let approx_w = (content.len() as f32 * t.font_size * 0.6 * vp.zoom).max(12.0);
                let approx_h = (t.font_size * vp.zoom).max(12.0);
                let rect = egui::Rect::from_min_size(p, egui::Vec2::new(approx_w, approx_h));
                painter.rect_stroke(rect, 2.0, hl, StrokeKind::Outside);
            }
            ObjectRef::Polygon(_) if i < sch.polygons.len() => {
                let poly = &sch.polygons[i];
                if poly.points.len() < 2 {
                    continue;
                }
                let pts: Vec<Pos2> = poly.points.iter().map(|p| vp.w2p(p[0], p[1])).collect();
                for win in pts.windows(2) {
                    painter.line_segment([win[0], win[1]], hl);
                }
                if pts.len() >= 3 {
                    painter.line_segment([*pts.last().unwrap(), pts[0]], hl);
                }
            }
            _ => {} // out-of-range refs
        }
    }
}

// ════════════════════════════════════════════════════════════
// Overlays / previews
// ════════════════════════════════════════════════════════════

const WIRE_PREVIEW_DOT_RADIUS: f32 = 4.0;
const WIRE_PREVIEW_ARM: f32 = 8.0;
const WIRE_ENDPOINT_RADIUS: f32 = 2.5;

fn render_overlays(painter: &Painter, app: &App, gui: &GuiState, vp: &CanvasViewport,
    theme: &Theme) {
    let tool = app.state.tool.active;

    if tool == Tool::Wire || tool == Tool::Bus {
        draw_wire_preview(painter, app, vp, theme);
    }
    if app.state.tool.placement.is_some() {
        draw_placement_ghost(painter, app, vp, theme);
    }
    if matches!(tool, Tool::Line | Tool::Rect | Tool::Circle | Tool::Arc | Tool::Polygon) {
        draw_drawing_preview(painter, app, vp, theme);
    }
    if app.state.canvas.rubber_band_active {
        draw_rubber_band(painter, app, vp, theme);
    }
    if gui.crosshair {
        draw_crosshair(painter, app, vp, theme);
    }
}

/// Paint plugin overlay layers (world coordinates, z-ordered ascending).
fn render_plugin_overlays(painter: &Painter, layers: &[OverlayLayer], vp: &CanvasViewport) {
    let mut order: Vec<usize> = (0..layers.len()).filter(|&i| layers[i].visible).collect();
    order.sort_by_key(|&i| layers[i].z_order);

    let col = |c: [u8; 4]| Color32::from_rgba_unmultiplied(c[0], c[1], c[2], c[3]);
    for &li in &order {
        for shape in &layers[li].shapes {
            match *shape {
                OverlayShape::Line { x0, y0, x1, y1, color, width } => {
                    painter.line_segment(
                        [vp.world_to_pixel(x0, y0), vp.world_to_pixel(x1, y1)],
                        Stroke::new(width.max(0.5) * vp.zoom.min(1.0), col(color)),
                    );
                }
                OverlayShape::Circle { cx, cy, radius, stroke, fill, width } => {
                    let center = vp.world_to_pixel(cx, cy);
                    let r = radius * vp.zoom;
                    if let Some(f) = fill {
                        painter.circle_filled(center, r, col(f));
                    }
                    stroke_circle(painter, center, r, 24, Stroke::new(width.max(0.5), col(stroke)));
                }
                OverlayShape::Rect { x, y, w, h, stroke, fill, width } => {
                    let rect = egui::Rect::from_min_max(
                        vp.world_to_pixel(x, y),
                        vp.world_to_pixel(x + w, y + h),
                    );
                    if let Some(f) = fill {
                        painter.rect_filled(rect, 0.0, col(f));
                    }
                    painter.rect_stroke(
                        rect,
                        0.0,
                        Stroke::new(width.max(0.5), col(stroke)),
                        StrokeKind::Outside,
                    );
                }
                OverlayShape::Text { x, y, ref content, color, size } => {
                    painter.text(
                        vp.world_to_pixel(x, y),
                        egui::Align2::LEFT_BOTTOM,
                        content,
                        FontId::proportional((size * vp.zoom).clamp(8.0, 48.0)),
                        col(color),
                    );
                }
                OverlayShape::Marker { x, y, kind, color } => {
                    let p = vp.world_to_pixel(x, y);
                    let c = col(color);
                    let glyph = match kind {
                        MarkerKind::Error => "\u{2716}",
                        MarkerKind::Warning => "\u{26A0}",
                        MarkerKind::Info => "\u{2139}",
                        MarkerKind::Pin => "\u{25CF}",
                    };
                    painter.text(
                        p,
                        egui::Align2::CENTER_CENTER,
                        glyph,
                        FontId::proportional(14.0),
                        c,
                    );
                }
            }
        }
    }
}

fn draw_wire_preview(painter: &Painter, app: &App, vp: &CanvasViewport, theme: &Theme) {
    let Some(ws) = app.state.tool.wire_start else {
        return;
    };
    let preview_col = theme.wire_preview;
    let start = vp.w2p(ws[0], ws[1]);

    // Crosshair at the anchor.
    painter.circle_filled(start, WIRE_PREVIEW_DOT_RADIUS, preview_col);
    let s = Stroke::new(1.5_f32, preview_col);
    painter.line_segment(
        [Pos2::new(start.x - WIRE_PREVIEW_ARM, start.y), Pos2::new(start.x + WIRE_PREVIEW_ARM, start.y)],
        s,
    );
    painter.line_segment(
        [Pos2::new(start.x, start.y - WIRE_PREVIEW_ARM), Pos2::new(start.x, start.y + WIRE_PREVIEW_ARM)],
        s,
    );

    // Manhattan-constrained preview to the cursor.
    let cur = app.state.canvas.cursor_world;
    let end_world = app.manhattan_route(ws, cur);
    let end = vp.w2p(end_world[0], end_world[1]);
    painter.line_segment([start, end], s);
    painter.circle_filled(end, WIRE_ENDPOINT_RADIUS, preview_col);
}

fn draw_placement_ghost(painter: &Painter, app: &App, vp: &CanvasViewport, theme: &Theme) {
    let Some(pl) = &app.state.tool.placement else {
        return;
    };
    let ghost_col = Color32::from_rgba_premultiplied(
        theme.symbol_line.r(),
        theme.symbol_line.g(),
        theme.symbol_line.b(),
        120,
    );
    let stroke = Stroke::new((1.5 * vp.zoom).max(1.0), ghost_col);
    let cursor = app.state.canvas.cursor_world;
    let origin = vp.w2p(cursor[0], cursor[1]);
    let flags = InstanceFlags::new(pl.rotation, pl.flip);

    match prim::find_by_name(&pl.symbol_path) {
        Some(entry) if entry.has_drawing() => {
            draw_prim_geometry(painter, entry, origin, flags, vp.zoom, stroke);
        }
        _ => {
            // Fallback ghost box.
            let sz = 20.0_f32;
            let corners: [[f32; 2]; 4] = [[-sz, -sz], [sz, -sz], [sz, sz], [-sz, sz]];
            for ci in 0..4 {
                let (ax, ay) =
                    flags.transform_point(corners[ci][0] as i32, corners[ci][1] as i32);
                let (bx, by) = flags.transform_point(
                    corners[(ci + 1) % 4][0] as i32,
                    corners[(ci + 1) % 4][1] as i32,
                );
                painter.line_segment(
                    [
                        Pos2::new(origin.x + ax as f32 * vp.zoom, origin.y + ay as f32 * vp.zoom),
                        Pos2::new(origin.x + bx as f32 * vp.zoom, origin.y + by as f32 * vp.zoom),
                    ],
                    stroke,
                );
            }
        }
    }

    painter.text(
        Pos2::new(origin.x + 10.0, origin.y - 12.0),
        egui::Align2::LEFT_BOTTOM,
        &pl.symbol_path,
        FontId::proportional(11.0),
        ghost_col,
    );
}

fn draw_drawing_preview(painter: &Painter, app: &App, vp: &CanvasViewport, theme: &Theme) {
    let tool = app.state.tool.active;
    let draw = &app.state.tool.draw;
    let cursor = app.state.canvas.cursor_world;
    let preview_col = Color32::from_rgba_premultiplied(
        theme.wire_preview.r(),
        theme.wire_preview.g(),
        theme.wire_preview.b(),
        180,
    );
    let stroke = Stroke::new(1.5_f32, preview_col);

    match tool {
        Tool::Line => {
            if let Some(fp) = draw.first_point {
                let start = vp.w2p(fp[0], fp[1]);
                let end = vp.w2p(cursor[0], cursor[1]);
                painter.circle_filled(start, WIRE_PREVIEW_DOT_RADIUS, preview_col);
                painter.line_segment([start, end], stroke);
                painter.circle_filled(end, WIRE_ENDPOINT_RADIUS, preview_col);
            }
        }
        Tool::Rect => {
            if let Some(fp) = draw.first_point {
                let rect = egui::Rect::from_two_pos(
                    vp.w2p(fp[0].min(cursor[0]), fp[1].min(cursor[1])),
                    vp.w2p(fp[0].max(cursor[0]), fp[1].max(cursor[1])),
                );
                painter.rect_stroke(rect, 0.0, stroke, StrokeKind::Outside);
            }
        }
        Tool::Circle => {
            if let Some(fp) = draw.first_point {
                let center = vp.w2p(fp[0], fp[1]);
                let dx = (cursor[0] - fp[0]) as f64;
                let dy = (cursor[1] - fp[1]) as f64;
                let radius_px = (dx * dx + dy * dy).sqrt() as f32 * vp.zoom;
                if radius_px > 1.0 {
                    painter.circle_stroke(center, radius_px, stroke);
                }
                painter.circle_filled(center, WIRE_PREVIEW_DOT_RADIUS, preview_col);
            }
        }
        Tool::Arc => {
            if let Some(fp) = draw.first_point {
                let center = vp.w2p(fp[0], fp[1]);
                painter.circle_filled(center, WIRE_PREVIEW_DOT_RADIUS, preview_col);
                match draw.arc_step {
                    ArcStep::Center => {}
                    ArcStep::RadiusStart => {
                        painter.line_segment([center, vp.w2p(cursor[0], cursor[1])], stroke);
                    }
                    ArcStep::Sweep => {
                        if let Some(sp) = draw.arc_second {
                            let dx1 = (sp[0] - fp[0]) as f64;
                            let dy1 = (sp[1] - fp[1]) as f64;
                            let radius_px = (dx1 * dx1 + dy1 * dy1).sqrt() as f32 * vp.zoom;
                            let start_deg =
                                (-(sp[1] - fp[1]) as f64).atan2(dx1).to_degrees() as f32;
                            let end_deg = (-(cursor[1] - fp[1]) as f64)
                                .atan2((cursor[0] - fp[0]) as f64)
                                .to_degrees() as f32;
                            let mut sweep = end_deg - start_deg;
                            if sweep <= 0.0 {
                                sweep += 360.0;
                            }
                            if radius_px > 1.0 {
                                stroke_arc(painter, center, radius_px, start_deg, sweep, stroke);
                            }
                        }
                    }
                }
            }
        }
        Tool::Polygon => {
            let pts = &draw.polygon_points;
            if pts.is_empty() {
                return;
            }
            for win in pts.windows(2) {
                painter.line_segment(
                    [vp.w2p(win[0][0], win[0][1]), vp.w2p(win[1][0], win[1][1])],
                    stroke,
                );
            }
            let last = pts.last().unwrap();
            let a = vp.w2p(last[0], last[1]);
            let b = vp.w2p(cursor[0], cursor[1]);
            painter.line_segment([a, b], stroke);
            if pts.len() >= 2 {
                let c = vp.w2p(pts[0][0], pts[0][1]);
                let faint = Color32::from_rgba_premultiplied(
                    preview_col.r(),
                    preview_col.g(),
                    preview_col.b(),
                    80,
                );
                painter.line_segment([b, c], Stroke::new(0.75_f32, faint));
            }
            for p in pts {
                painter.circle_filled(vp.w2p(p[0], p[1]), WIRE_ENDPOINT_RADIUS, preview_col);
            }
        }
        _ => {}
    }
}

fn draw_rubber_band(painter: &Painter, app: &App, vp: &CanvasViewport, theme: &Theme) {
    let cs = &app.state.canvas;
    let (s, e) = (cs.rubber_band_start, cs.rubber_band_end);
    let rect = egui::Rect::from_two_pos(
        vp.w2p(s[0].min(e[0]), s[1].min(e[1])),
        vp.w2p(s[0].max(e[0]), s[1].max(e[1])),
    );
    painter.rect_filled(rect, 0.0, theme.rubber_band);
    painter.rect_stroke(rect, 0.0, Stroke::new(1.0_f32, theme.selection_rect), StrokeKind::Outside);
}

fn draw_crosshair(painter: &Painter, app: &App, vp: &CanvasViewport, theme: &Theme) {
    let cursor = app.state.canvas.cursor_world;
    let p = vp.w2p(cursor[0], cursor[1]);
    let clip = painter.clip_rect();
    let col = Color32::from_rgba_premultiplied(
        theme.wire_preview.r(),
        theme.wire_preview.g(),
        theme.wire_preview.b(),
        60,
    );
    let stroke = Stroke::new(0.5_f32, col);
    painter.line_segment([Pos2::new(clip.min.x, p.y), Pos2::new(clip.max.x, p.y)], stroke);
    painter.line_segment([Pos2::new(p.x, clip.min.y), Pos2::new(p.x, clip.max.y)], stroke);
}

/// Floating TextEdit at the text tool's click position.
/// Enter commits, Escape cancels.
fn show_text_input_overlay(ui: &mut egui::Ui, app: &mut App, vp: &CanvasViewport) {
    if !app.state.tool.draw.text_input_active {
        return;
    }
    let Some(pos) = app.state.tool.draw.text_pos else {
        return;
    };
    let pixel = vp.w2p(pos[0], pos[1]);

    egui::Area::new(egui::Id::new("text_tool_input"))
        .fixed_pos(pixel)
        .order(egui::Order::Foreground)
        .show(ui.ctx(), |ui| {
            let te = egui::TextEdit::singleline(&mut app.state.tool.draw.text_buf)
                .desired_width(150.0)
                .hint_text("Enter text...");
            let response = ui.add(te);
            if !response.has_focus() {
                response.request_focus();
            }
            if ui.input(|i| i.key_pressed(egui::Key::Enter)) {
                app.commit_text();
            }
            if ui.input(|i| i.key_pressed(egui::Key::Escape)) {
                app.clear_text_input();
            }
        });
}

// ════════════════════════════════════════════════════════════
// Interaction
// ════════════════════════════════════════════════════════════

const MOVE_DRAG_THRESHOLD_PX: f32 = 4.0;

fn snap_world(vp: &CanvasViewport, pos: Pos2, snap_size: f32) -> [i32; 2] {
    vp.snap_to_grid(pos.x, pos.y, snap_size)
}

fn set_zoom(app: &mut App, zoom: f32) {
    use schemify_core::handler::Viewport;
    app.state.active_document_mut().viewport.zoom =
        zoom.clamp(Viewport::MIN_ZOOM, Viewport::MAX_ZOOM);
}

fn pan_by_pixel_delta(app: &mut App, delta: egui::Vec2) {
    let vp = &mut app.state.active_document_mut().viewport;
    if vp.zoom <= 0.0 {
        return;
    }
    vp.pan[0] -= delta.x / vp.zoom;
    vp.pan[1] -= delta.y / vp.zoom;
}

fn handle_interaction(response: &Response, app: &mut App, gui: &mut GuiState,
    vp: &CanvasViewport, ctx: &egui::Context) {
    let snap = app.state.tool.snap_size;
    handle_space_key(app, ctx);
    handle_scroll_zoom(response, app, vp);
    handle_mouse_press(response, app, gui, vp, snap);
    handle_mouse_drag(response, app, vp, snap);
    handle_mouse_release(response, app, vp, snap);
}

/// Space: hold to pan-drag; tap toggles sticky grab mode.
fn handle_space_key(app: &mut App, ctx: &egui::Context) {
    let (pressed, released) = ctx.input(|i| {
        (i.key_pressed(egui::Key::Space), i.key_released(egui::Key::Space))
    });
    let cs = &mut app.state.canvas;
    if pressed {
        cs.space_held = true;
        cs.space_drag_happened = false;
    }
    if released {
        let drag_happened = cs.space_drag_happened;
        cs.space_held = false;
        if !drag_happened {
            cs.pan_mode = PanMode::Grab;
        }
        cs.space_drag_happened = false;
    }
}

/// Scroll zoom centered on the cursor: the world point under the pointer
/// stays stationary.
fn handle_scroll_zoom(response: &Response, app: &mut App, vp: &CanvasViewport) {
    if !response.hovered() {
        return;
    }
    let scroll_delta = response.ctx.input(|i| i.smooth_scroll_delta.y);
    if scroll_delta == 0.0 {
        return;
    }
    let Some(hover_pos) = response.hover_pos() else {
        return;
    };

    let world_before = vp.pixel_to_world(hover_pos.x, hover_pos.y);
    let old_zoom = app.active_doc().viewport.zoom;

    // ~0.001 per scroll pixel — smooth on touchpads, sane on mice.
    set_zoom(app, old_zoom * (scroll_delta * 0.001).exp());

    let actual_zoom = app.active_doc().viewport.zoom;
    if (actual_zoom - old_zoom).abs() > f32::EPSILON {
        let new_vp = CanvasViewport {
            center: vp.center,
            zoom: actual_zoom,
            pan: app.active_doc().viewport.pan,
        };
        let world_after = new_vp.pixel_to_world(hover_pos.x, hover_pos.y);
        let pan = &mut app.state.active_document_mut().viewport.pan;
        pan[0] += world_before[0] - world_after[0];
        pan[1] += world_before[1] - world_after[1];
    }
}

fn handle_mouse_press(response: &Response, app: &mut App, gui: &mut GuiState,
    vp: &CanvasViewport, snap: f32) {
    if response.clicked_by(PointerButton::Primary) {
        if app.state.canvas.pan_mode == PanMode::Grab {
            // Click exits sticky grab mode.
            let cs = &mut app.state.canvas;
            cs.pan_mode = PanMode::Off;
            cs.dragging = false;
            cs.move_active = false;
            cs.move_hit = None;
            return;
        }

        if app.state.canvas.space_held {
            if let Some(pos) = response.interact_pointer_pos() {
                let cs = &mut app.state.canvas;
                cs.dragging = true;
                cs.drag_is_pan = true;
                cs.drag_last = [pos.x, pos.y];
            }
            return;
        }

        if let Some(pos) = response.interact_pointer_pos() {
            let [wx, wy] = snap_world(vp, pos, snap);
            let tool = app.state.tool.active;
            let shift = response.ctx.input(|i| i.modifiers.shift);

            match tool {
                Tool::Select | Tool::Move => handle_select_click(app, pos, wx, wy, shift),
                Tool::Wire => handle_wire_click(app, wx, wy),
                Tool::Bus => handle_bus_click(app, wx, wy),
                Tool::BusRipper => handle_bus_ripper_click(app, wx, wy),
                Tool::Polygon => app.state.tool.draw.polygon_points.push([wx, wy]),
                Tool::Line | Tool::Rect | Tool::Circle | Tool::Arc => {
                    handle_draw_click(app, tool, wx, wy);
                }
                Tool::Text if !app.state.tool.draw.text_input_active => {
                    app.state.tool.draw.text_pos = Some([wx, wy]);
                    app.state.tool.draw.text_input_active = true;
                }
                _ => {}
            }

            // Active placement: click places the component.
            if app.state.tool.placement.is_some() {
                handle_placement_click(app, wx, wy);
            }
        }
    }

    // Right click → context menu.
    if response.clicked_by(PointerButton::Secondary) {
        if let Some(pos) = response.interact_pointer_pos() {
            let [wx, wy] = snap_world(vp, pos, snap);
            let hit = match app.hit_test(wx, wy) {
                Some(r) => CtxHit::Obj(r),
                // Buses/rippers aren't in the main hit test; probe here.
                None => {
                    if let Some(i) = app.hit_test_bus_ripper(wx, wy) {
                        CtxHit::BusRipper(i)
                    } else if let Some(i) = app.hit_test_bus(wx, wy, SELECT_HIT_RADIUS_SQ) {
                        CtxHit::Obj(ObjectRef::Bus(i as u32))
                    } else {
                        CtxHit::None
                    }
                }
            };
            // Seed inline bus editors from the hit bus.
            if let CtxHit::Obj(ObjectRef::Bus(i)) = hit {
                let i = i as usize;
                gui.ctx_menu.bus_rename = app.resolve(app.schematic().buses.label[i]).to_string();
                gui.ctx_menu.bus_width = app.schematic().buses.width[i];
            }
            gui.ctx_menu.open = true;
            gui.ctx_menu.pixel_pos = [pos.x, pos.y];
            gui.ctx_menu.world_pos = [wx, wy];
            gui.ctx_menu.hit = hit;
        }
    }

    // Double click → commit polygon or open properties.
    if response.double_clicked_by(PointerButton::Primary) {
        if app.state.tool.active == Tool::Polygon {
            app.commit_polygon();
        } else {
            app.dispatch(Command::OpenPropsDialog);
        }
    }
}

fn handle_mouse_drag(response: &Response, app: &mut App, vp: &CanvasViewport, snap: f32) {
    // Middle-drag → pan.
    if response.dragged_by(PointerButton::Middle) {
        let delta = response.drag_delta();
        if delta.length_sq() > 0.0 {
            pan_by_pixel_delta(app, delta);
        }
        return;
    }

    if !response.dragged_by(PointerButton::Primary) {
        return;
    }

    // Space-drag or pan-drag → pan.
    if app.state.canvas.drag_is_pan || app.state.canvas.space_held {
        let delta = response.drag_delta();
        if delta.length_sq() > 0.0 {
            app.state.canvas.space_drag_happened = true;
            pan_by_pixel_delta(app, delta);
        }
        return;
    }

    // Pan tool: left-drag pans.
    if app.state.tool.active == Tool::Pan {
        let delta = response.drag_delta();
        if delta.length_sq() > 0.0 {
            pan_by_pixel_delta(app, delta);
        }
        return;
    }

    // First drag frame: seed drag state from the press origin.
    if response.drag_started_by(PointerButton::Primary) {
        if let Some(origin) = response.ctx.input(|i| i.pointer.press_origin()) {
            app.state.canvas.move_press_pixel = [origin.x, origin.y];
            match app.state.tool.active {
                Tool::Select => {
                    let [wx, wy] = snap_world(vp, origin, snap);
                    if app.hit_test(wx, wy).is_none() {
                        let cs = &mut app.state.canvas;
                        cs.rubber_band_start = [wx, wy];
                        cs.rubber_band_end = [wx, wy];
                        cs.rubber_band_active = false;
                        cs.move_hit = None;
                    }
                }
                Tool::Move => {
                    // Grab whatever is under the cursor so drag promotion
                    // moves it immediately.
                    let [wx, wy] = snap_world(vp, origin, snap);
                    if app.hit_test(wx, wy).is_some() {
                        handle_select_click(app, origin, wx, wy, false);
                    }
                }
                _ => {}
            }
        }
    }

    if let Some(pos) = response.interact_pointer_pos() {
        // Move-drag promotion past the threshold.
        let cs = &app.state.canvas;
        if !cs.move_active && cs.move_hit.is_some() {
            let dx = pos.x - cs.move_press_pixel[0];
            let dy = pos.y - cs.move_press_pixel[1];
            if dx * dx + dy * dy >= MOVE_DRAG_THRESHOLD_PX * MOVE_DRAG_THRESHOLD_PX {
                let cs = &mut app.state.canvas;
                cs.move_active = true;
                cs.move_accum = [0, 0];
                cs.drag_last = [pos.x, pos.y];
            }
        }

        let cs = &app.state.canvas;
        if cs.move_active {
            let prev = snap_world(vp, Pos2::new(cs.drag_last[0], cs.drag_last[1]), snap);
            let curr = snap_world(vp, pos, snap);
            let (dx, dy) = (curr[0] - prev[0], curr[1] - prev[1]);
            if dx != 0 || dy != 0 {
                app.dispatch(Command::MoveSelected { dx, dy });
            }
            app.state.canvas.drag_last = [pos.x, pos.y];
            return;
        }

        // Rubber-band drag.
        let cs = &app.state.canvas;
        if app.state.tool.active == Tool::Select && cs.move_hit.is_none() {
            let dx = pos.x - cs.move_press_pixel[0];
            let dy = pos.y - cs.move_press_pixel[1];
            if !cs.rubber_band_active
                && dx * dx + dy * dy >= MOVE_DRAG_THRESHOLD_PX * MOVE_DRAG_THRESHOLD_PX
            {
                app.state.canvas.rubber_band_active = true;
            }
            if app.state.canvas.rubber_band_active {
                app.state.canvas.rubber_band_end = snap_world(vp, pos, snap);
            }
        }
    }
}

fn handle_mouse_release(response: &Response, app: &mut App, vp: &CanvasViewport, snap: f32) {
    if response.drag_stopped_by(PointerButton::Primary) {
        let cs = &app.state.canvas;
        let (move_active, rubber_band_active, drag_is_pan) =
            (cs.move_active, cs.rubber_band_active, cs.drag_is_pan);
        let (rb_start, rb_end) = (cs.rubber_band_start, cs.rubber_band_end);

        // Wire/draw tools: fast mouse movement turns clicks into drags in
        // egui — treat a non-move drag release as a click.
        if !move_active && !rubber_band_active && !drag_is_pan {
            let tool = app.state.tool.active;
            if matches!(tool, Tool::Wire | Tool::Bus | Tool::Line | Tool::Rect | Tool::Circle
                | Tool::Arc)
            {
                if let Some(pos) = response.interact_pointer_pos() {
                    let [wx, wy] = snap_world(vp, pos, snap);
                    match tool {
                        Tool::Wire => handle_wire_click(app, wx, wy),
                        Tool::Bus => handle_bus_click(app, wx, wy),
                        _ => handle_draw_click(app, tool, wx, wy),
                    }
                }
            }
        }

        if rubber_band_active {
            app.select_in_rect(
                rb_start[0].min(rb_end[0]),
                rb_start[1].min(rb_end[1]),
                rb_start[0].max(rb_end[0]),
                rb_start[1].max(rb_end[1]),
            );
        }

        app.state.canvas.rubber_band_active = false;
        if move_active {
            // Commit coalesced move undo before clearing move_active.
            app.commit_move_drag();
        }
        let cs = &mut app.state.canvas;
        cs.move_active = false;
        cs.move_hit = None;
        cs.dragging = false;
        cs.drag_is_pan = false;
    }

    if response.drag_stopped_by(PointerButton::Middle) {
        let cs = &mut app.state.canvas;
        cs.dragging = false;
        cs.drag_is_pan = false;
    }
}

fn handle_select_click(app: &mut App, pos: Pos2, wx: i32, wy: i32, shift: bool) {
    let hit = app.hit_test(wx, wy);

    if let Some(r) = hit {
        {
            let cs = &mut app.state.canvas;
            cs.move_press_pixel = [pos.x, pos.y];
            cs.move_start_world = [wx, wy];
            cs.drag_last = [pos.x, pos.y];
        }

        // Click on an already-selected object → arm move for the whole set.
        if app.active_doc().selection.contains(r) {
            app.state.canvas.move_hit = Some(r);
            return;
        }

        if !shift {
            app.dispatch(Command::SelectNone);
        }
        app.state.canvas.move_hit = Some(r);
        app.selection_mut().insert(r);
    } else {
        let cs = &mut app.state.canvas;
        cs.rubber_band_start = [wx, wy];
        cs.rubber_band_end = [wx, wy];
        cs.rubber_band_active = false;
        cs.move_press_pixel = [pos.x, pos.y];
        cs.move_hit = None;
    }
}

/// Two-click wire placement: first click anchors, second commits a
/// Manhattan segment and chains from its endpoint.
fn handle_wire_click(app: &mut App, wx: i32, wy: i32) {
    if let Some(start) = app.state.tool.wire_start {
        if start != [wx, wy] {
            let end = app.manhattan_route(start, [wx, wy]);
            app.dispatch(Command::AddWire {
                x0: start[0],
                y0: start[1],
                x1: end[0],
                y1: end[1],
            });
            app.state.tool.wire_start = Some(end);
            return;
        }
    }
    app.state.tool.wire_start = Some([wx, wy]);
}

/// Same two-click flow for buses; width/start_bit are defaults, edited
/// later via the context menu.
fn handle_bus_click(app: &mut App, wx: i32, wy: i32) {
    if let Some(start) = app.state.tool.wire_start {
        if start != [wx, wy] {
            let end = app.manhattan_route(start, [wx, wy]);
            let label = format!("BUS{}", app.schematic().buses.len());
            app.dispatch(Command::AddBus {
                label,
                width: 8,
                start_bit: 0,
                x0: start[0],
                y0: start[1],
                x1: end[0],
                y1: end[1],
            });
            app.state.tool.wire_start = Some(end);
            return;
        }
    }
    app.state.tool.wire_start = Some([wx, wy]);
}

/// Click on (or near) a bus drops a ripper there.
fn handle_bus_ripper_click(app: &mut App, wx: i32, wy: i32) {
    if let Some(bus_idx) = app.hit_test_bus(wx, wy, SELECT_HIT_RADIUS_SQ) {
        app.dispatch(Command::AddBusRipper {
            bus_idx: bus_idx as u32,
            bit: 0,
            x: wx,
            y: wy,
            direction: 0,
        });
    }
}

fn handle_draw_click(app: &mut App, tool: Tool, wx: i32, wy: i32) {
    let Some(start) = app.state.tool.draw.first_point else {
        app.state.tool.draw.first_point = Some([wx, wy]);
        return;
    };
    match tool {
        Tool::Line => app.dispatch(Command::AddLine {
            x0: start[0],
            y0: start[1],
            x1: wx,
            y1: wy,
        }),
        Tool::Rect => app.dispatch(Command::AddRect {
            x: start[0].min(wx),
            y: start[1].min(wy),
            w: (wx - start[0]).abs(),
            h: (wy - start[1]).abs(),
        }),
        Tool::Circle => {
            let dx = (wx - start[0]) as f64;
            let dy = (wy - start[1]) as f64;
            app.dispatch(Command::AddCircle {
                cx: start[0],
                cy: start[1],
                radius: (dx * dx + dy * dy).sqrt() as i32,
            });
        }
        Tool::Arc => {
            let dx = (wx - start[0]) as f64;
            let dy = (wy - start[1]) as f64;
            app.dispatch(Command::AddArc {
                cx: start[0],
                cy: start[1],
                radius: (dx * dx + dy * dy).sqrt() as i32,
                start: dy.atan2(dx) as f32,
                sweep: std::f32::consts::PI,
            });
        }
        _ => unreachable!(),
    }
    app.state.tool.draw.first_point = None;
}

fn handle_placement_click(app: &mut App, wx: i32, wy: i32) {
    let Some(pl) = app.state.tool.placement.clone() else {
        return;
    };
    app.dispatch(Command::PlaceDevice {
        symbol_path: pl.symbol_path,
        name: pl.name,
        x: wx,
        y: wy,
        rotation: pl.rotation,
        flip: pl.flip,
    });
    // PlaceDevice doesn't reset tool state; SetTool does.
    app.dispatch(Command::SetTool(Tool::Select));
}

// ════════════════════════════════════════════════════════════
// Tests
// ════════════════════════════════════════════════════════════

#[cfg(test)]
mod tests {
    use super::*;

    fn vp(zoom: f32, pan: [f32; 2]) -> CanvasViewport {
        CanvasViewport {
            center: Pos2::new(400.0, 300.0),
            zoom,
            pan,
        }
    }

    #[test]
    fn world_to_pixel_basics() {
        let v = vp(1.0, [0.0, 0.0]);
        let p = v.world_to_pixel(0.0, 0.0);
        assert!((p.x - 400.0).abs() < 1e-4 && (p.y - 300.0).abs() < 1e-4);

        let v = vp(2.0, [0.0, 0.0]);
        let p = v.world_to_pixel(50.0, 0.0);
        assert!((p.x - 500.0).abs() < 1e-4 && (p.y - 300.0).abs() < 1e-4);
    }

    #[test]
    fn roundtrip_world_pixel_world() {
        let v = vp(1.5, [30.0, -20.0]);
        let (wx, wy) = (42.0_f32, -17.0_f32);
        let p = v.world_to_pixel(wx, wy);
        let [rx, ry] = v.pixel_to_world(p.x, p.y);
        assert!((rx - wx).abs() < 1e-3 && (ry - wy).abs() < 1e-3);
    }

    #[test]
    fn roundtrip_pixel_world_pixel() {
        let v = vp(0.75, [100.0, 200.0]);
        let (px, py) = (550.0_f32, 350.0_f32);
        let [wx, wy] = v.pixel_to_world(px, py);
        let p = v.world_to_pixel(wx, wy);
        assert!((p.x - px).abs() < 1e-3 && (p.y - py).abs() < 1e-3);
    }

    #[test]
    fn roundtrip_negative_coords() {
        let v = vp(2.0, [-50.0, -100.0]);
        let p = v.world_to_pixel(-200.0, -300.0);
        let [rx, ry] = v.pixel_to_world(p.x, p.y);
        assert!((rx + 200.0).abs() < 1e-3 && (ry + 300.0).abs() < 1e-3);
    }

    #[test]
    fn pixel_to_world_at_center_is_pan() {
        let v = vp(1.0, [50.0, 60.0]);
        let [wx, wy] = v.pixel_to_world(400.0, 300.0);
        assert!((wx - 50.0).abs() < 1e-4 && (wy - 60.0).abs() < 1e-4);
    }

    #[test]
    fn snap_to_grid_rounds_to_nearest() {
        let v = vp(1.0, [0.0, 0.0]);
        assert_eq!(v.snap_to_grid(404.0, 300.0, 10.0), [0, 0]);
        assert_eq!(v.snap_to_grid(406.0, 300.0, 10.0), [10, 0]);
        assert_eq!(v.snap_to_grid(394.0, 300.0, 10.0), [-10, 0]);
        // Zoom 2: pixel (410, 300) = world (5, 0) → snaps to 10.
        let v = vp(2.0, [0.0, 0.0]);
        assert_eq!(v.snap_to_grid(410.0, 300.0, 10.0), [10, 0]);
    }

    #[test]
    fn snap_to_grid_degenerate_grid_uses_one() {
        let v = vp(1.0, [0.0, 0.0]);
        assert_eq!(v.snap_to_grid(403.0, 302.0, 0.0), [3, 2]);
        assert_eq!(v.snap_to_grid(403.0, 302.0, -5.0), [3, 2]);
    }

    #[test]
    fn w2p_matches_world_to_pixel() {
        let v = vp(1.5, [10.0, 20.0]);
        let p1 = v.w2p(100, -50);
        let p2 = v.world_to_pixel(100.0, -50.0);
        assert!((p1.x - p2.x).abs() < 1e-4 && (p1.y - p2.y).abs() < 1e-4);
    }

    #[test]
    fn thickness_width_tenths() {
        assert!((thickness_width(0) - 1.0).abs() < f32::EPSILON);
        assert!((thickness_width(10) - 1.0).abs() < f32::EPSILON);
        assert!((thickness_width(20) - 2.0).abs() < f32::EPSILON);
        assert!((thickness_width(5) - 0.5).abs() < f32::EPSILON);
    }
}
