pub mod connectivity;
mod dispatch;
pub mod examples;
pub mod geometry;
pub mod ir;
pub mod netlist;
pub mod plugin_dist;
pub mod s2s;
pub mod spice_import;
pub mod state;
pub mod transform;

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
use schemify_core::theme::ThemeOverride;
use schemify_core::traits::{AppRead, AppWrite};
use schemify_core::types::{Connectivity, Sym};

use state::*;

/// Opaque application handle. All mutation goes through `dispatch(Command)`.
/// Display crate reads state through accessor methods.
pub struct App {
    state: AppState,
}

impl Default for App {
    fn default() -> Self {
        Self::new()
    }
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
        let schematic = schemify_io::reader::read_chn(&content, &mut self.state.interner);
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
            None => Err(io::Error::other("serialization failed")),
        }
    }

    /// Load a schematic from in-memory content (used by WASM / tests).
    pub fn open_from_content(&mut self, name: &str, content: &str) {
        let schematic = schemify_io::reader::read_chn(content, &mut self.state.interner);
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
        &self.state.view.view_flags
    }

    pub fn canvas(&self) -> &CanvasState {
        &self.state.canvas
    }

    pub fn canvas_mut(&mut self) -> &mut CanvasState {
        &mut self.state.canvas
    }

    pub fn view(&self) -> &ViewState {
        &self.state.view
    }

    pub fn view_mut(&mut self) -> &mut ViewState {
        &mut self.state.view
    }

    pub fn dialogs(&self) -> &DialogStates {
        &self.state.dialogs
    }

    pub fn dialogs_mut(&mut self) -> &mut DialogStates {
        &mut self.state.dialogs
    }

    pub fn panels(&self) -> &PanelState {
        &self.state.panels
    }

    pub fn panels_mut(&mut self) -> &mut PanelState {
        &mut self.state.panels
    }

    pub fn editor(&self) -> &EditorState {
        &self.state.editor
    }

    pub fn editor_mut(&mut self) -> &mut EditorState {
        &mut self.state.editor
    }

    pub fn ctx_menu(&self) -> &ContextMenu {
        &self.state.ctx_menu
    }

    pub fn ctx_menu_mut(&mut self) -> &mut ContextMenu {
        &mut self.state.ctx_menu
    }

    pub fn tool_state(&self) -> &ToolState {
        &self.state.tool
    }

    pub fn status_msg(&self) -> &str {
        &self.state.status_msg
    }

    pub fn last_netlist(&self) -> &str {
        &self.state.last_netlist
    }

    pub fn canvas_size(&self) -> [f32; 2] {
        self.state.view.canvas_size
    }

    pub fn show_grid(&self) -> bool {
        self.state.view.show_grid
    }

    // ── Setters for display-driven state ──

    pub fn set_canvas_size(&mut self, w: f32, h: f32) {
        self.state.view.canvas_size = [w, h];
    }

    pub fn set_cursor_world(&mut self, x: i32, y: i32) {
        self.state.canvas.cursor_world = [x, y];
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

    pub fn set_zoom(&mut self, z: f32) {
        let v = &mut self.state.active_document_mut().viewport;
        v.zoom = z.clamp(Viewport::MIN_ZOOM, Viewport::MAX_ZOOM);
    }

    pub fn select_instance(&mut self, idx: usize) {
        self.state
            .active_document_mut()
            .selection
            .instances
            .insert(idx);
    }

    pub fn select_wire(&mut self, idx: usize) {
        self.state.active_document_mut().selection.wires.insert(idx);
    }

    pub fn select_line(&mut self, idx: usize) {
        self.state.active_document_mut().selection.lines.insert(idx);
    }

    pub fn select_rect(&mut self, idx: usize) {
        self.state.active_document_mut().selection.rects.insert(idx);
    }

    pub fn select_circle(&mut self, idx: usize) {
        self.state
            .active_document_mut()
            .selection
            .circles
            .insert(idx);
    }

    pub fn select_arc(&mut self, idx: usize) {
        self.state.active_document_mut().selection.arcs.insert(idx);
    }

    pub fn select_text(&mut self, idx: usize) {
        self.state.active_document_mut().selection.texts.insert(idx);
    }

    pub fn select_polygon(&mut self, idx: usize) {
        self.state
            .active_document_mut()
            .selection
            .polygons
            .insert(idx);
    }

    pub fn is_line_selected(&self, idx: usize) -> bool {
        self.active_doc().selection.lines.contains(&idx)
    }

    pub fn is_rect_selected(&self, idx: usize) -> bool {
        self.active_doc().selection.rects.contains(&idx)
    }

    pub fn is_circle_selected(&self, idx: usize) -> bool {
        self.active_doc().selection.circles.contains(&idx)
    }

    pub fn is_arc_selected(&self, idx: usize) -> bool {
        self.active_doc().selection.arcs.contains(&idx)
    }

    pub fn is_text_selected(&self, idx: usize) -> bool {
        self.active_doc().selection.texts.contains(&idx)
    }

    pub fn is_polygon_selected(&self, idx: usize) -> bool {
        self.active_doc().selection.polygons.contains(&idx)
    }

    pub fn push_polygon_point(&mut self, pt: [i32; 2]) {
        self.state.tool.draw.polygon_points.push(pt);
    }

    pub fn commit_polygon(&mut self) {
        let pts = std::mem::take(&mut self.state.tool.draw.polygon_points);
        if pts.len() >= 3 {
            self.dispatch(Command::AddPolygon { points: pts });
        }
    }

    pub fn clear_polygon_points(&mut self) {
        self.state.tool.draw.polygon_points.clear();
    }

    pub fn toggle_bus_mode(&mut self) {
        self.state.tool.bus_mode = !self.state.tool.bus_mode;
    }

    pub fn set_wire_start(&mut self, pos: Option<[i32; 2]>) {
        self.state.tool.wire_start = pos;
    }

    /// Commit accumulated move delta as a single undo entry (call on drag release).
    pub fn commit_move_drag(&mut self) {
        let [dx, dy] = self.state.canvas.move_accum;
        if dx != 0 || dy != 0 {
            use schemify_core::commands::Command;
            let entry = UndoEntry::Inverse(Command::MoveSelected { dx: -dx, dy: -dy });
            let doc = self.state.active_document_mut();
            doc.redo_history.clear();
            if doc.undo_history.len() >= MAX_UNDO_HISTORY {
                doc.undo_history.pop_front();
            }
            doc.undo_history.push_back(entry);
            doc.dirty = true;
        }
        self.state.canvas.move_accum = [0, 0];
    }

    pub fn set_draw_first_point(&mut self, pos: Option<[i32; 2]>) {
        self.state.tool.draw.first_point = pos;
    }

    // ── Text tool helpers ──

    pub fn set_text_pos(&mut self, pos: Option<[i32; 2]>) {
        self.state.tool.draw.text_pos = pos;
    }

    pub fn set_text_input_active(&mut self, active: bool) {
        self.state.tool.draw.text_input_active = active;
    }

    pub fn text_buf_mut(&mut self) -> &mut String {
        &mut self.state.tool.draw.text_buf
    }

    /// Commit the current text input as an AddText command.
    /// Clears text_pos, text_buf, and text_input_active afterward.
    /// No-op if text_pos is None or text_buf is empty.
    pub fn commit_text(&mut self) {
        let pos = match self.state.tool.draw.text_pos {
            Some(p) => p,
            None => return,
        };
        let content = std::mem::take(&mut self.state.tool.draw.text_buf);
        if content.is_empty() {
            // Nothing to commit — just clear state.
            self.state.tool.draw.text_pos = None;
            self.state.tool.draw.text_input_active = false;
            return;
        }
        self.state.tool.draw.text_pos = None;
        self.state.tool.draw.text_input_active = false;
        self.dispatch(Command::AddText {
            x: pos[0],
            y: pos[1],
            content,
        });
    }

    /// Clear all text draw state without committing.
    pub fn clear_text_input(&mut self) {
        self.state.tool.draw.text_pos = None;
        self.state.tool.draw.text_buf.clear();
        self.state.tool.draw.text_input_active = false;
    }

    // ── Plugin integration ──

    pub fn drain_plugin_commands(&mut self) -> Vec<(String, Vec<u8>)> {
        std::mem::take(&mut self.state.pending_plugin_commands)
    }

    pub fn plugin_refresh_requested(&self) -> bool {
        self.state.plugin_refresh_requested
    }

    pub fn clear_plugin_refresh(&mut self) {
        self.state.plugin_refresh_requested = false;
    }

    // ── Theme overrides ──

    /// Store a theme override from a plugin.
    /// Replaces any existing override from the same plugin.
    pub fn apply_theme_override(&mut self, theme_override: ThemeOverride) {
        let id = &theme_override.plugin_id;
        if let Some(existing) = self
            .state
            .theme_overrides
            .iter_mut()
            .find(|o| o.plugin_id == *id)
        {
            *existing = theme_override;
        } else {
            self.state.theme_overrides.push(theme_override);
        }
    }

    /// Get all active theme overrides.
    pub fn theme_overrides(&self) -> &[ThemeOverride] {
        &self.state.theme_overrides
    }

    // ── Netlist / Simulation ──

    pub(crate) fn generate_netlist(&mut self) {
        let ir = netlist::to_circuit_ir(
            &self.state.active_document().schematic,
            &self.state.interner,
        );
        let title = format!(
            "SchemifyRS netlist\n* {}",
            self.state.active_document().name
        );
        self.state.last_netlist = schemify_sim::codegen::emit_netlist(&ir, &title);
    }

    #[cfg(not(target_arch = "wasm32"))]
    pub(crate) fn run_simulation(&mut self) {
        // Generate netlist first
        self.generate_netlist();

        let doc = self.state.active_document();
        let spice_body = doc.schematic.spice_body.clone();

        if spice_body.trim().is_empty() {
            self.state.status_msg = "No analysis code. Open SPICE Code editor (Simulate > Edit SPICE Code) and write analysis commands.".into();
            return;
        }

        // Build the analysis Python script
        let circuit_json = {
            let ir = netlist::to_circuit_ir(
                &self.state.active_document().schematic,
                &self.state.interner,
            );
            match serde_json::to_string(&ir) {
                Ok(j) => j,
                Err(e) => {
                    self.state.status_msg = format!("Failed to serialize circuit: {e}");
                    return;
                }
            }
        };

        let script = format!(
            r#"#!/usr/bin/env python3
import sys, json
try:
    import pyspice_rs
except ImportError:
    print("ERROR: pyspice_rs not found. Install it or check PYTHONPATH.", file=sys.stderr)
    sys.exit(1)

circuit_json = '''{}'''
circuit = pyspice_rs.load_circuit(circuit_json)

# === USER ANALYSIS ===
{}
"#,
            circuit_json.replace('\'', "\\'"),
            spice_body,
        );

        // Write temp script and run
        let tmp = std::env::temp_dir().join("schemify_analysis.py");
        if let Err(e) = std::fs::write(&tmp, &script) {
            self.state.status_msg = format!("Failed to write analysis script: {e}");
            return;
        }

        let python = schemify_sim::pyspice::python_bin();
        let pypath = match schemify_sim::pyspice::python_path() {
            Some(p) => p,
            None => {
                self.state.status_msg = "PySpice not available (not bundled at build time)".into();
                return;
            }
        };

        self.state.status_msg = "Running simulation...".into();

        match std::process::Command::new(&python)
            .arg(&tmp)
            .env("PYTHONPATH", &pypath)
            .output()
        {
            Ok(output) => {
                let stdout = String::from_utf8_lossy(&output.stdout);
                let stderr = String::from_utf8_lossy(&output.stderr);
                if output.status.success() {
                    self.state.status_msg = format!(
                        "Simulation complete. {}",
                        stdout.lines().next().unwrap_or("")
                    );
                    if !stdout.is_empty() {
                        self.state.last_netlist = format!(
                            "{}\n\n* === Simulation Output ===\n{}",
                            self.state.last_netlist, stdout
                        );
                    }
                } else {
                    let first_err = stderr.lines().next().unwrap_or("Unknown error");
                    self.state.status_msg = format!("Simulation failed: {first_err}");
                }
            }
            Err(e) => {
                self.state.status_msg = format!("Failed to run python: {e}");
            }
        }
    }

    #[cfg(target_arch = "wasm32")]
    pub(crate) fn run_simulation(&mut self) {
        self.state.status_msg = "Simulation not available in web mode".into();
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn set_text_pos_stores_position() {
        let mut app = App::new();
        assert!(app.tool_state().draw.text_pos.is_none());

        app.set_text_pos(Some([100, 200]));
        assert_eq!(app.tool_state().draw.text_pos, Some([100, 200]));

        app.set_text_pos(None);
        assert!(app.tool_state().draw.text_pos.is_none());
    }

    #[test]
    fn commit_text_dispatches_add_text_and_clears_state() {
        let mut app = App::new();
        app.set_text_pos(Some([50, 75]));
        app.set_text_input_active(true);
        app.text_buf_mut().push_str("hello");

        app.commit_text();

        // State is cleared.
        assert!(app.tool_state().draw.text_pos.is_none());
        assert!(app.tool_state().draw.text_buf.is_empty());
        assert!(!app.tool_state().draw.text_input_active);

        // Text was added to the schematic.
        assert_eq!(app.schematic().texts.len(), 1);
        let text = &app.schematic().texts[0];
        assert_eq!(text.x, 50);
        assert_eq!(text.y, 75);
        assert_eq!(app.resolve(text.content), "hello");
    }

    #[test]
    fn commit_text_no_position_is_noop() {
        let mut app = App::new();
        // No text_pos set.
        app.text_buf_mut().push_str("orphan");

        app.commit_text();

        // Nothing dispatched — buffer still has its content (commit_text returns early).
        assert_eq!(app.schematic().texts.len(), 0);
        // Buffer is untouched since commit_text returned before take.
        assert_eq!(app.tool_state().draw.text_buf, "orphan");
    }

    #[test]
    fn commit_text_empty_buffer_clears_state_without_dispatch() {
        let mut app = App::new();
        app.set_text_pos(Some([10, 20]));
        app.set_text_input_active(true);
        // text_buf is empty.

        app.commit_text();

        // State cleared.
        assert!(app.tool_state().draw.text_pos.is_none());
        assert!(!app.tool_state().draw.text_input_active);
        // No text added.
        assert_eq!(app.schematic().texts.len(), 0);
    }

    #[test]
    fn clear_text_input_resets_all_text_draw_state() {
        let mut app = App::new();
        app.set_text_pos(Some([30, 40]));
        app.set_text_input_active(true);
        app.text_buf_mut().push_str("discard me");

        app.clear_text_input();

        assert!(app.tool_state().draw.text_pos.is_none());
        assert!(app.tool_state().draw.text_buf.is_empty());
        assert!(!app.tool_state().draw.text_input_active);
        // Nothing dispatched.
        assert_eq!(app.schematic().texts.len(), 0);
    }
}
