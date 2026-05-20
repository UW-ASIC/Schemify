mod geometry;
mod grid;
mod interaction;
mod overlays;
mod palette;
mod render;
mod viewport;

pub use palette::CanvasPalette;
pub use viewport::CanvasViewport;

use eframe::egui;
use schemify_handler::App;

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

    // Render layers (bottom to top).
    grid::render(&painter, &viewport, &palette, app.show_grid());
    render::render_wires(&painter, app, &viewport, &palette);
    render::render_instances(&painter, app, &viewport, &palette);
    render::render_geometry(&painter, app, &viewport, &palette);
    render::render_selection(&painter, app, &viewport, &palette);
    overlays::render(&painter, app, &viewport, &palette);

    // Handle interaction.
    interaction::handle(&response, app, &viewport, ui.ctx());

    // Update cursor world position.
    if let Some(pos) = response.hover_pos() {
        let [wx, wy] = viewport.pixel_to_world(pos.x, pos.y);
        app.set_cursor_world(wx as i32, wy as i32);
    }
}
