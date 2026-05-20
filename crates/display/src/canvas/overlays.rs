use egui::{Color32, FontId, Painter, Pos2, Stroke, StrokeKind};

use schemify_core::commands::Tool;
use schemify_core::primitives;
use schemify_handler::App;
use schemify_handler::state::ArcStep;

use super::palette::CanvasPalette;
use super::viewport::CanvasViewport;

const WIRE_PREVIEW_DOT_RADIUS: f32 = 4.0;
const WIRE_PREVIEW_ARM: f32 = 8.0;
const WIRE_ENDPOINT_RADIUS: f32 = 2.5;

/// Render all dynamic overlays (wire preview, placement ghost, drawing tool
/// preview, rubber band, crosshair).
pub fn render(
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
    if app.gui().canvas.rubber_band_active {
        draw_rubber_band(painter, app, viewport, palette);
    }

    // Full-canvas crosshair at cursor.
    if app.view_flags().crosshair {
        draw_crosshair(painter, app, viewport, palette);
    }
}

// ── Wire preview ────────────────────────────────────────────────────────────

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
    let cur = app.gui().canvas.cursor_world;
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

// ── Placement ghost ─────────────────────────────────────────────────────────

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
    let cursor = app.gui().canvas.cursor_world;
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
                    let n = 16_usize;
                    let mut prev = Pos2::new(center.x + radius_px, center.y);
                    for si in 1..=n {
                        let angle = si as f32 * std::f32::consts::TAU / n as f32;
                        let cur = Pos2::new(
                            center.x + radius_px * angle.cos(),
                            center.y + radius_px * angle.sin(),
                        );
                        painter.line_segment([prev, cur], stroke);
                        prev = cur;
                    }
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

// ── Drawing tool previews ───────────────────────────────────────────────────

fn draw_drawing_preview(
    painter: &Painter,
    app: &App,
    viewport: &CanvasViewport,
    palette: &CanvasPalette,
) {
    let tool = app.active_tool();
    let draw = &app.tool_state().draw;
    let cursor = app.gui().canvas.cursor_world;
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
                                stroke_arc_overlay(
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

fn stroke_arc_overlay(
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

// ── Rubber band ─────────────────────────────────────────────────────────────

fn draw_rubber_band(
    painter: &Painter,
    app: &App,
    viewport: &CanvasViewport,
    palette: &CanvasPalette,
) {
    let cs = &app.gui().canvas;
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

// ── Crosshair ───────────────────────────────────────────────────────────────

fn draw_crosshair(
    painter: &Painter,
    app: &App,
    viewport: &CanvasViewport,
    palette: &CanvasPalette,
) {
    let cursor = app.gui().canvas.cursor_world;
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
