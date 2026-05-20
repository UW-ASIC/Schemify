pub mod examples;
pub mod geometry;
pub mod ir;
pub mod s2s;
pub mod state;
pub mod transform;
pub mod plugin_dist;
mod connectivity;
mod dispatch;
mod spice_import;

use std::collections::HashSet;
use std::path::PathBuf;

#[cfg(not(target_arch = "wasm32"))]
use std::io;
#[cfg(not(target_arch = "wasm32"))]
use std::path::Path;

use schemify_core::commands::{Command, Tool};
use schemify_core::devices::Pdk;
use schemify_core::schematic::{InstanceVec, Pin, Property, Schematic, WireVec};
use schemify_core::simulation::SimResult;
use schemify_core::traits::{AppRead, AppWrite};
use schemify_core::types::{Connectivity, Sym};

use state::*;

/// Opaque application handle. All mutation goes through `dispatch(Command)`.
/// Display crate reads state through accessor methods.
pub struct App {
    state: AppState,
}

impl App {
    pub fn new() -> Self {
        Self {
            state: AppState::new(),
        }
    }

    // ── File operations (called by display after OS file dialog) ──

    #[cfg(not(target_arch = "wasm32"))]
    pub fn open_file(&mut self, path: &Path) -> io::Result<()> {
        let content = std::fs::read_to_string(path)?;
        let schematic =
            schemify_io::reader::read_chn(&content, &mut self.state.interner);
        let name = path
            .file_stem()
            .unwrap_or_default()
            .to_string_lossy()
            .into_owned();
        let doc = Document {
            schematic,
            name,
            origin: Origin::File(path.to_owned()),
            ..Default::default()
        };
        self.state.documents.push(doc);
        self.state.active_doc = self.state.documents.len() - 1;
        Ok(())
    }

    #[cfg(not(target_arch = "wasm32"))]
    pub fn save_to_path(&mut self, path: &Path) -> io::Result<()> {
        let doc = &self.state.documents[self.state.active_doc];
        match schemify_io::writer::write_chn(&doc.schematic, &self.state.interner) {
            Some(content) => {
                std::fs::write(path, &content)?;
                let doc = self.state.active_document_mut();
                doc.origin = Origin::File(path.to_owned());
                doc.dirty = false;
                doc.name = path
                    .file_stem()
                    .unwrap_or_default()
                    .to_string_lossy()
                    .into_owned();
                Ok(())
            }
            None => Err(io::Error::new(
                io::ErrorKind::Other,
                "serialization failed",
            )),
        }
    }

    /// Load a schematic from in-memory content (used by WASM / tests).
    pub fn open_from_content(&mut self, name: &str, content: &str) {
        let schematic =
            schemify_io::reader::read_chn(content, &mut self.state.interner);
        let doc = Document {
            schematic,
            name: name.to_string(),
            origin: Origin::Memory,
            ..Default::default()
        };
        self.state.documents.push(doc);
        self.state.active_doc = self.state.documents.len() - 1;
    }

    // ── Core type accessors (display reads these to render) ──

    pub fn schematic(&self) -> &Schematic {
        &self.active_doc().schematic
    }

    pub fn wires(&self) -> &WireVec {
        &self.active_doc().schematic.wires
    }

    pub fn instances(&self) -> &InstanceVec {
        &self.active_doc().schematic.instances
    }

    pub fn pins(&self) -> &[Pin] {
        &self.active_doc().schematic.pins
    }

    pub fn properties(&self) -> &[Property] {
        &self.active_doc().schematic.properties
    }

    pub fn resolve(&self, sym: Sym) -> &str {
        self.state.interner.resolve(&sym)
    }

    // ── Connectivity (lazy-computed, cached) ──

    pub fn connectivity(&mut self) -> &Connectivity {
        if self.state.active_document().connectivity.is_none() {
            let conn = connectivity::resolve(
                &self.state.active_document().schematic,
                &self.state.interner,
            );
            self.state.active_document_mut().connectivity = Some(conn);
        }
        self.state.active_document().connectivity.as_ref().unwrap()
    }

    // ── Simulation / PDK ──

    pub fn sim_results(&self) -> Option<&SimResult> {
        self.active_doc().sim_results.as_ref()
    }

    pub fn pdk(&self) -> Option<&Pdk> {
        self.state.pdk.as_ref()
    }

    // ── View state (decomposed primitives at API surface) ──

    pub fn zoom(&self) -> f32 {
        self.active_doc().viewport.zoom
    }

    pub fn pan(&self) -> [f32; 2] {
        self.active_doc().viewport.pan
    }

    pub fn active_tool(&self) -> Tool {
        self.state.tool.active
    }

    pub fn active_doc_name(&self) -> &str {
        &self.active_doc().name
    }

    pub fn active_doc_idx(&self) -> usize {
        self.state.active_doc
    }

    pub fn documents(&self) -> &[Document] {
        &self.state.documents
    }

    pub fn is_dirty(&self) -> bool {
        self.active_doc().dirty
    }

    pub fn can_undo(&self) -> bool {
        !self.active_doc().undo_history.is_empty()
    }

    pub fn can_redo(&self) -> bool {
        !self.active_doc().redo_history.is_empty()
    }

    // ── Selection ──

    pub fn selection(&self) -> &Selection {
        &self.active_doc().selection
    }

    pub fn is_instance_selected(&self, idx: usize) -> bool {
        self.active_doc().selection.instances.contains(&idx)
    }

    pub fn is_wire_selected(&self, idx: usize) -> bool {
        self.active_doc().selection.wires.contains(&idx)
    }

    // ── GUI state ──

    pub fn view_flags(&self) -> &ViewFlags {
        &self.state.gui.view_flags
    }

    pub fn gui(&self) -> &GuiState {
        &self.state.gui
    }

    pub fn tool_state(&self) -> &ToolState {
        &self.state.tool
    }

    pub fn status_msg(&self) -> &str {
        &self.state.status_msg
    }

    pub fn canvas_size(&self) -> [f32; 2] {
        self.state.canvas_size
    }

    pub fn show_grid(&self) -> bool {
        self.state.show_grid
    }

    // ── Setters for display-driven state ──

    pub fn set_canvas_size(&mut self, w: f32, h: f32) {
        self.state.canvas_size = [w, h];
    }

    pub fn set_cursor_world(&mut self, x: i32, y: i32) {
        self.state.gui.canvas.cursor_world = [x, y];
    }

    // ── Mutable GUI state (display-driven, not schematic mutations) ──

    pub fn gui_mut(&mut self) -> &mut GuiState {
        &mut self.state.gui
    }

    pub fn start_placement(&mut self, symbol_path: String, name: String) {
        self.state.tool.active = Tool::Select;
        self.state.tool.placement = Some(Placement {
            symbol_path,
            name,
            rotation: 0,
            flip: false,
        });
    }

    pub fn project_dir(&self) -> &Path {
        &self.state.project_dir
    }

    pub fn set_project_dir(&mut self, path: PathBuf) {
        self.state.project_dir = path;
    }

    // ── Canvas interaction helpers (display-driven viewport/selection) ──

    pub fn set_pan(&mut self, x: f32, y: f32) {
        self.state.active_document_mut().viewport.pan = [x, y];
    }

    pub fn select_instance(&mut self, idx: usize) {
        self.state.active_document_mut().selection.instances.insert(idx);
    }

    pub fn select_wire(&mut self, idx: usize) {
        self.state.active_document_mut().selection.wires.insert(idx);
    }

    pub fn set_wire_start(&mut self, pos: Option<[i32; 2]>) {
        self.state.tool.wire_start = pos;
    }

    pub fn set_draw_first_point(&mut self, pos: Option<[i32; 2]>) {
        self.state.tool.draw.first_point = pos;
    }

    // ── Private ──

    fn active_doc(&self) -> &Document {
        self.state.active_document()
    }
}

// ── AppRead / AppWrite trait impls ──

impl AppRead for App {
    fn schematic(&self) -> &Schematic {
        self.schematic()
    }

    fn resolve(&self, sym: Sym) -> &str {
        self.resolve(sym)
    }

    fn zoom(&self) -> f32 {
        self.zoom()
    }

    fn pan(&self) -> [f32; 2] {
        self.pan()
    }

    fn selected_instances(&self) -> &HashSet<usize> {
        &self.active_doc().selection.instances
    }

    fn selected_wires(&self) -> &HashSet<usize> {
        &self.active_doc().selection.wires
    }

    fn show_grid(&self) -> bool {
        self.show_grid()
    }

    fn canvas_size(&self) -> [f32; 2] {
        self.canvas_size()
    }

    fn active_tool(&self) -> Tool {
        self.active_tool()
    }
}

impl AppWrite for App {
    fn dispatch(&mut self, cmd: Command) {
        self.dispatch(cmd)
    }

    fn set_canvas_size(&mut self, w: f32, h: f32) {
        self.set_canvas_size(w, h)
    }

    fn set_cursor_world(&mut self, x: i32, y: i32) {
        self.set_cursor_world(x, y)
    }
}
