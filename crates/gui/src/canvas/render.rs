//! Committed-content painting — HOT PATH: free functions, flat matches on
//! object kind, no trait dispatch. Runs every frame over every visible
//! object.

use std::collections::HashMap;

use eframe::egui::{self, Color32, FontId, Painter, Pos2, Stroke,
    StrokeKind};

use schemify_editor::handler::{App, ObjectRef};
use schemify_editor::schemify::{self as prim, DeviceKind, InstanceFlags, PinDirection,
    Tool};
use schemify_plugin_host::{MarkerKind, OverlayLayer, OverlayShape};

use crate::state::{color_or, GuiState, Theme};

use super::*;

// ── Geometry helpers ─────────────────────────────────────────────────────────

/// Arc approximated with line segments. Angles in degrees, positive CCW.
pub(crate) fn stroke_arc(painter: &Painter, center: Pos2, radius_px: f32, start_deg: f32, sweep_deg: f32,
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
pub(crate) fn stroke_circle(painter: &Painter, center: Pos2, radius_px: f32, n_segs: usize, stroke: Stroke) {
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
pub(crate) fn thickness_width(thickness: u8) -> f32 {
    if thickness > 0 {
        thickness as f32 / 10.0
    } else {
        1.0
    }
}
// ════════════════════════════════════════════════════════════
// Grid
// ════════════════════════════════════════════════════════════

const GRID_MIN_STEP_PX: f32 = 3.0;
const GRID_MAX_POINTS: usize = 16_000;
const DEFAULT_GRID_SPACING: f32 = 10.0;

pub(crate) fn render_grid(painter: &Painter, vp: &CanvasViewport, theme: &Theme, show_grid: bool) {
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

pub(crate) fn render_wires(painter: &Painter, app: &App, vp: &CanvasViewport, theme: &Theme) {
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

pub(crate) fn render_buses(painter: &Painter, app: &App, vp: &CanvasViewport, theme: &Theme) {
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
        let (dx, dy) = match ripper.direction {
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
pub(crate) fn draw_prim_geometry(painter: &Painter, entry: &prim::PrimEntry, origin: Pos2,
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
            // Angles follow the point transform: flip mirrors (θ → 180−θ,
            // sweep reversed), then each rotation step subtracts 90°.
            let (mut start, mut sweep) = (a.start as f32, a.sweep as f32);
            if flags.flip() {
                start = 180.0 - start;
                sweep = -sweep;
            }
            start -= 90.0 * flags.rotation() as f32;
            stroke_arc(painter, tp(a.cx, a.cy), radius_px, start, sweep, stroke);
        }
    }
    for r in &entry.rects {
        let rect = egui::Rect::from_two_pos(tp(r.x0, r.y0), tp(r.x1, r.y1));
        painter.rect_stroke(rect, 0.0, stroke, StrokeKind::Outside);
    }
}

pub(crate) fn render_instances(painter: &Painter, app: &App, vp: &CanvasViewport, theme: &Theme,
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

            for dt in &entry.texts {
                if dt.content == "@name" || !dt.content.starts_with('@') {
                    continue;
                }
                let label = dt.content[1..] // strip leading @
                    .split('/')
                    .map(|part| {
                        // "@w/@l": each part carries its own @ prefix.
                        let part = part.strip_prefix('@').unwrap_or(part);
                        props
                            .iter()
                            .find(|p| app.resolve(p.key) == part)
                            .map(|p| app.resolve(p.value))
                            .unwrap_or(part)
                    })
                    .collect::<Vec<_>>()
                    .join("/");

                let (tx, ty) = flags.transform_point(dt.x as i32, dt.y as i32);
                let pos = Pos2::new(
                    origin.x + tx as f32 * vp.zoom,
                    origin.y + ty as f32 * vp.zoom,
                );
                painter.text(pos, egui::Align2::LEFT_CENTER, &label, pfont.clone(), param_col);
            }
        }
    }
}

pub(crate) fn render_geometry(painter: &Painter, app: &App, vp: &CanvasViewport, theme: &Theme,
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

pub(crate) fn render_symbol_pins(painter: &Painter, app: &App, vp: &CanvasViewport, theme: &Theme) {
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
pub(crate) fn render_auto_symbol_box(painter: &Painter, app: &App, vp: &CanvasViewport, theme: &Theme) {
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

pub(crate) fn render_selection(painter: &Painter, app: &App, vp: &CanvasViewport, theme: &Theme) {
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

pub(crate) const WIRE_PREVIEW_DOT_RADIUS: f32 = 4.0;
pub(crate) const WIRE_PREVIEW_ARM: f32 = 8.0;
pub(crate) const WIRE_ENDPOINT_RADIUS: f32 = 2.5;

pub(crate) fn render_overlays(painter: &Painter, app: &App, gui: &GuiState, vp: &CanvasViewport,
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
pub(crate) fn render_plugin_overlays(painter: &Painter, layers: &[OverlayLayer], vp: &CanvasViewport) {
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
