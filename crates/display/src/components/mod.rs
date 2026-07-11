//! Chrome (menu bar, tab bar, status bar with vim command line), floating
//! panels (file explorer, library browser), the right-click context menu,
//! and all dialogs (properties, find, settings, import, SPICE code, new
//! primitive).
//
// deferred: math_render / LaTeX in doc view — later phase
// deferred: highlight.rs (SPICE/LaTeX syntax highlighting) — later phase

pub mod plugin_panels;
pub mod chrome;
pub mod context_menu;
pub mod dialogs;
pub mod doc_view;
pub mod explorer;
pub mod menus;

// Flat re-exports: pre-split `components::X` paths keep working.
pub use chrome::*;
pub use context_menu::*;
pub use dialogs::*;
pub use doc_view::*;
pub use explorer::*;
pub use menus::*;




