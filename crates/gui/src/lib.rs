//! egui/eframe display crate for Schemify.
//!
//! Module map:
//! * [`ui`] — eframe App impl + `run_gui` entry point (Arc<Mutex<App>> +
//!   optional external Command channel for headful CLI/MCP driving)
//! * [`canvas`] — viewport transform, grid, rendering layers, interaction,
//!   previews
//! * [`components`] — menus/chrome, dialogs, panels
//! * [`handler`] — command pump, keyboard shortcuts, vim command parser
//! * [`keybinds`] — keybind table → `KeyCommand`
//! * [`state`] — GUI-side state (theme, dialog scratch)

#[cfg(not(target_arch = "wasm32"))]
pub mod agent_view;
pub mod canvas;
pub mod components;
pub mod handler;
pub mod keybinds;
pub mod optimizer_view;
pub mod plugin_host;
pub mod state;
pub mod ui;
pub mod wave_view;

pub use canvas::CanvasViewport;
pub use handler::CommandPump;
pub use keybinds::{KeyCommand, Keybind, KEYBINDS};
pub use plugin_host::PluginHost;
pub use state::{GuiState, Theme};
pub use ui::{run_gui, run_gui_standalone, SchemifyGui};
