use crate::commands::{Command, Tool};
use crate::schematic::Schematic;
use crate::types::Sym;
use std::collections::HashSet;

/// Read-only access to application state. Display crate uses this
/// to render without touching handler internals.
pub trait AppRead {
    // schematic data
    fn schematic(&self) -> &Schematic;
    fn resolve(&self, sym: Sym) -> &str;

    // viewport
    fn zoom(&self) -> f32;
    fn pan(&self) -> [f32; 2];

    // selection (batch-friendly: return set ref, not per-item)
    fn selected_instances(&self) -> &HashSet<usize>;
    fn selected_wires(&self) -> &HashSet<usize>;

    // view state
    fn show_grid(&self) -> bool;
    fn canvas_size(&self) -> [f32; 2];
    fn active_tool(&self) -> Tool;
}

/// Mutable access for dispatching commands and updating display-driven state.
pub trait AppWrite {
    fn dispatch(&mut self, cmd: Command);
    fn set_canvas_size(&mut self, w: f32, h: f32);
    fn set_cursor_world(&mut self, x: i32, y: i32);
}
