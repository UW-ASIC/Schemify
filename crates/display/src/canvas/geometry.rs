use egui::{Color32, Painter, Pos2, Stroke};
use schemify_core::types::Color;

/// Draw an arc approximated with line segments.
/// Angles in degrees. Positive sweep is CCW.
pub(super) fn stroke_arc(
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
pub(super) fn stroke_circle(
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
pub(super) fn thickness_width(thickness: u8) -> f32 {
    if thickness > 0 {
        thickness as f32 / 10.0
    } else {
        1.0
    }
}

/// Convert schematic Color to egui Color32, with fallback default.
pub(super) fn color_or(c: Color, default: Color32) -> Color32 {
    if c.is_none() {
        default
    } else {
        Color32::from_rgba_premultiplied(c.r, c.g, c.b, c.a)
    }
}
