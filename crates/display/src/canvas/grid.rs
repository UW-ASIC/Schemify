use egui::{Painter, Pos2, Stroke};

use super::palette::CanvasPalette;
use super::viewport::CanvasViewport;

const GRID_MIN_STEP_PX: f32 = 3.0;
const GRID_MAX_POINTS: usize = 16_000;
const DEFAULT_GRID_SPACING: f32 = 10.0;

/// Render the background dot grid and origin crosshair.
pub fn render(
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
