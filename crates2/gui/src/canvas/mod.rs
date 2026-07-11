//! Schematic canvas: viewport transform, dot grid, layered rendering,
//! interaction (select / move / draw / pan / zoom), and tool previews.
//!
//! Render order (bottom → top): grid → wires → buses → instances →
//! geometry → pins → selection → overlays.
//
// deferred: tb_overlay.rs (testbench usage thumbnails) — phase-7 wiring


use eframe::egui::{self, FontId, Pos2};

use schemify_editor::handler::App;
use schemify_plugin_host::OverlayLayer;

use crate::state::GuiState;
pub mod interact;
pub mod preview;
pub mod render;

pub(crate) use interact::*;
pub(crate) use preview::*;
pub(crate) use render::*;

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
    use schemify_editor::handler::ViewMode;

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

