pub mod find;
pub mod import;
pub mod new_primitive;
pub mod properties;
pub mod settings;
pub mod spice_code;

use eframe::egui;
use schemify_handler::App;

pub fn show_all(ctx: &egui::Context, app: &mut App) {
    properties::show(ctx, app);
    find::show(ctx, app);
    settings::show(ctx, app);
    import::show(ctx, app);
    spice_code::show(ctx, app);
    new_primitive::show(ctx, app);
}
