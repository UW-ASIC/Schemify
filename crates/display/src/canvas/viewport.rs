use egui::Pos2;

use schemify_handler::App;

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
