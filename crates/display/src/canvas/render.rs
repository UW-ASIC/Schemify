use std::collections::HashMap;

use egui::{Color32, FontId, Painter, Pos2, Stroke, StrokeKind};

use schemify_core::primitives;
use schemify_core::types::Color;
use schemify_handler::App;

use super::palette::CanvasPalette;
use super::viewport::CanvasViewport;

// ── Helpers ─────────────────────────────────────────────────────────────────

/// Convert a schematic Color to egui Color32, falling back to a default.
fn color_or(c: Color, default: Color32) -> Color32 {
    if c.is_none() {
        default
    } else {
        Color32::from_rgba_premultiplied(c.r, c.g, c.b, c.a)
    }
}

/// Draw an arc approximated with line segments.
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
fn stroke_circle_approx(painter: &Painter, center: Pos2, radius_px: f32, stroke: Stroke) {
    let n_segs = 24_usize;
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

// ── Wire rendering ──────────────────────────────────────────────────────────

pub fn render_wires(
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

        let thickness_mult = if wires.thickness[i] != 0 {
            wires.thickness[i] as f32 / 10.0
        } else {
            1.0
        };
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

// ── Instance rendering ──────────────────────────────────────────────────────

pub fn render_instances(
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
                    stroke_circle_approx(painter, center, radius_px, stroke);
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

// ── Geometry rendering (lines, rects, circles, arcs, polygons, texts) ───────

pub fn render_geometry(
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
        let w = if line.thickness > 0 {
            line.thickness as f32 / 10.0
        } else {
            1.0
        };
        painter.line_segment([a, b], Stroke::new(w, col));
    }

    // Rects
    for r in &sch.rects {
        let p0 = viewport.w2p(r.x, r.y);
        let p1 = viewport.w2p(r.x + r.width, r.y + r.height);
        let rect = egui::Rect::from_two_pos(p0, p1);
        let fill_col = color_or(r.fill, palette.geometry_fill);
        let stroke_col = color_or(r.stroke, palette.geometry_line);
        let w = if r.thickness > 0 {
            r.thickness as f32 / 10.0
        } else {
            1.0
        };
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
        let w = if c.thickness > 0 {
            c.thickness as f32 / 10.0
        } else {
            1.0
        };
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
        let w = if a.thickness > 0 {
            a.thickness as f32 / 10.0
        } else {
            1.0
        };
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
        let w = if poly.thickness > 0 {
            poly.thickness as f32 / 10.0
        } else {
            1.0
        };
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

// ── Selection highlight overlays ────────────────────────────────────────────

pub fn render_selection(
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
