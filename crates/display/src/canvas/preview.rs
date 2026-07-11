//! Tool-feedback painting: wire preview, placement ghost, drawing preview,
//! rubber band, crosshair, text-input overlay.


use eframe::egui::{self, Color32, FontId, Painter, Pos2, Stroke,
    StrokeKind};

use schemify_core::handler::{App, ArcStep};
use schemify_core::schemify::{self as prim, InstanceFlags,
    Tool};

use crate::state::Theme;

use super::*;

pub(crate) fn draw_wire_preview(painter: &Painter, app: &App, vp: &CanvasViewport, theme: &Theme) {
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

pub(crate) fn draw_placement_ghost(painter: &Painter, app: &App, vp: &CanvasViewport, theme: &Theme) {
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

pub(crate) fn draw_drawing_preview(painter: &Painter, app: &App, vp: &CanvasViewport, theme: &Theme) {
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

pub(crate) fn draw_rubber_band(painter: &Painter, app: &App, vp: &CanvasViewport, theme: &Theme) {
    let cs = &app.state.canvas;
    let (s, e) = (cs.rubber_band_start, cs.rubber_band_end);
    let rect = egui::Rect::from_two_pos(
        vp.w2p(s[0].min(e[0]), s[1].min(e[1])),
        vp.w2p(s[0].max(e[0]), s[1].max(e[1])),
    );
    painter.rect_filled(rect, 0.0, theme.rubber_band);
    painter.rect_stroke(rect, 0.0, Stroke::new(1.0_f32, theme.selection_rect), StrokeKind::Outside);
}

pub(crate) fn draw_crosshair(painter: &Painter, app: &App, vp: &CanvasViewport, theme: &Theme) {
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
pub(crate) fn show_text_input_overlay(ui: &mut egui::Ui, app: &mut App, vp: &CanvasViewport) {
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
