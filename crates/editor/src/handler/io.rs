//! File and project I/O: open/save/reload, symbol generation, project
//! config/library indexing, doc-variable expansion.

use std::io;
use std::path::{Path, PathBuf};

use lasso::Rodeo;

use crate::config::{self, ProjectConfig};
use crate::schemify::{
    self as prim, Color, DeviceKind, Pin,
    PinDirection, Rect, Schematic, SchematicType,
    Sym,
};

use super::*;

impl App {
    /// Parse CHN content, logging parse warnings to stderr and the status
    /// bar. Returns the schematic and the warning count.
    pub(crate) fn read_chn_reported(&mut self, content: &str) -> (Schematic, usize) {
        let (schematic, warnings) = prim::read_chn_report(content, &mut self.state.interner);
        if !warnings.is_empty() {
            for warn in &warnings {
                eprintln!("chn parse warning: {warn:?}");
            }
            self.state.status_msg = format!(
                "{} parse warning(s) — see console for details",
                warnings.len()
            );
        }
        (schematic, warnings.len())
    }

    pub fn open_file(&mut self, path: &Path) -> io::Result<()> {
        let content = std::fs::read_to_string(path)?;
        let (schematic, _) = self.read_chn_reported(&content);
        let name = path
            .file_stem()
            .unwrap_or_default()
            .to_string_lossy()
            .into_owned();
        self.adopt_document(Document {
            schematic,
            name,
            kind: DocKind::from_path(path),
            origin: Origin::File(path.to_owned()),
            ..Default::default()
        });
        Ok(())
    }

    pub fn save_to_path(&mut self, path: &Path) -> io::Result<()> {
        let doc = &self.state.documents[self.state.active_doc];
        // Default the extension from the doc kind when the dialog/caller
        // omitted one ("foo" -> "foo.chn").
        let path = if path.extension().is_none() {
            path.with_extension(doc.kind.ext_no_dot())
        } else {
            path.to_owned()
        };
        match prim::write_chn(&doc.schematic, &self.state.interner) {
            Some(content) => {
                std::fs::write(&path, &content)?;
                let kind = DocKind::from_path(&path);
                let doc = self.state.active_document_mut();
                doc.origin = Origin::File(path.clone());
                doc.dirty = false;
                doc.kind = kind;
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

    /// Serialize any open document to `.chn` text (agent checkpoints,
    /// exports). None if the index is out of range or writing fails.
    pub fn document_text(&self, idx: usize) -> Option<String> {
        let doc = self.state.documents.get(idx)?;
        prim::write_chn(&doc.schematic, &self.state.interner)
    }

    pub fn open_from_content(&mut self, name: &str, content: &str) {
        let (schematic, _) = self.read_chn_reported(content);
        let (stem, kind) = DocKind::split_name(name);
        self.adopt_document(Document {
            schematic,
            name: stem.to_string(),
            kind,
            origin: Origin::Memory,
            ..Default::default()
        });
    }

    pub(crate) fn handle_file_save(&mut self) {
        let doc_idx = self.state.active_doc;
        let path = match &self.state.documents[doc_idx].origin {
            Origin::File(p) => Some(p.clone()),
            _ => None, // no file origin: display crate shows save-as dialog
        };
        if let Some(path) = path {
            if let Some(content) = prim::write_chn(
                &self.state.documents[doc_idx].schematic,
                &self.state.interner,
            ) {
                if std::fs::write(&path, &content).is_ok() {
                    self.state.documents[doc_idx].dirty = false;
                    self.state.status_msg = format!("Saved {}", path.display());
                } else {
                    self.state.status_msg = format!("Failed to write {}", path.display());
                }
            }
        }
    }

    pub(crate) fn handle_reload(&mut self) {
        let doc_idx = self.state.active_doc;
        let path = match &self.state.documents[doc_idx].origin {
            Origin::File(p) => Some(p.clone()),
            _ => None,
        };
        if let Some(path) = path {
            if let Ok(content) = std::fs::read_to_string(&path) {
                let (schematic, nwarn) = self.read_chn_reported(&content);
                let doc = &mut self.state.documents[doc_idx];
                doc.schematic = schematic;
                doc.dirty = false;
                doc.undo_history.clear();
                doc.redo_history.clear();
                doc.generation += 1;
                doc.selection.clear();
                if nwarn == 0 {
                    self.state.status_msg = format!("Reloaded {}", path.display());
                }
            }
        }
    }

    pub(crate) fn handle_zoom_fit(&mut self) {
        let Some((min_x, min_y, max_x, max_y)) =
            compute_bounds(&self.state.active_document().schematic)
        else {
            return;
        };
        let [cw, ch] = self.state.view.canvas_size;
        let w = (max_x - min_x) as f32;
        let h = (max_y - min_y) as f32;
        if w > 0.0 && h > 0.0 {
            let margin = 1.1;
            let zoom = (cw / (w * margin)).min(ch / (h * margin));
            let zoom = zoom.clamp(Viewport::MIN_ZOOM, Viewport::MAX_ZOOM);
            let cx = (min_x + max_x) as f32 / 2.0;
            let cy = (min_y + max_y) as f32 / 2.0;
            let doc = self.state.active_document_mut();
            doc.viewport.zoom = zoom;
            doc.viewport.pan = [cw / 2.0 - cx * zoom, ch / 2.0 - cy * zoom];
        }
    }
}

// ════════════════════════════════════════════════════════════
// Symbol generation
// ════════════════════════════════════════════════════════════

impl App {
    pub(crate) fn generate_symbol_from_schematic(&mut self) {
        // Collect label data (name sym, position, direction) from the schematic.
        let label_data: Vec<(Sym, i32, i32, PinDirection)> = {
            let sch = &self.state.active_document().schematic;
            (0..sch.instances.len())
                .filter_map(|i| {
                    let kind = sch.instances.kind[i];
                    if !kind.is_label() {
                        return None;
                    }
                    let dir = match kind {
                        DeviceKind::InputPin => PinDirection::Input,
                        DeviceKind::OutputPin => PinDirection::Output,
                        _ => PinDirection::InOut,
                    };
                    Some((
                        sch.instances.name[i],
                        sch.instances.x[i],
                        sch.instances.y[i],
                        dir,
                    ))
                })
                .collect()
        };

        if label_data.is_empty() {
            self.state.status_msg = "No I/O pins found in schematic".into();
            return;
        }

        self.push_undo_snapshot();

        // Bounding box from label positions with 40px padding.
        let mut lo_x = i32::MAX;
        let mut lo_y = i32::MAX;
        let mut hi_x = i32::MIN;
        let mut hi_y = i32::MIN;
        for &(_, x, y, _) in &label_data {
            lo_x = lo_x.min(x);
            lo_y = lo_y.min(y);
            hi_x = hi_x.max(x);
            hi_y = hi_y.max(y);
        }
        lo_x -= 40;
        lo_y -= 40;
        hi_x += 40;
        hi_y += 40;

        let doc = self.state.active_document_mut();

        // Replace existing pins.
        doc.schematic.pins.clear();
        doc.schematic.pins.reserve(label_data.len());
        for &(name, x, y, dir) in &label_data {
            doc.schematic.pins.push(Pin {
                name,
                x,
                y,
                width: 1,
                direction: dir,
            });
        }

        // Add a bounding rectangle only if no symbol geometry exists yet.
        let has_geometry = !doc.schematic.lines.is_empty()
            || !doc.schematic.rects.is_empty()
            || !doc.schematic.circles.is_empty()
            || !doc.schematic.arcs.is_empty();
        if !has_geometry {
            doc.schematic.rects.push(Rect {
                x: lo_x,
                y: lo_y,
                width: hi_x - lo_x,
                height: hi_y - lo_y,
                fill: Color::NONE,
                stroke: Color::NONE,
                thickness: 15, // 1.5 in tenths
            });
        }

        doc.dirty = true;
        self.state.status_msg = format!("Symbol generated: {} pins", doc.schematic.pins.len());
    }
}

// ════════════════════════════════════════════════════════════
// Project config / library reload
// ════════════════════════════════════════════════════════════

impl App {
    pub fn set_project_dir(&mut self, path: PathBuf) {
        self.state.project_dir = path;
        self.reload_project_config();
    }

    /// (Re)load Config.toml from the project dir and resolve its PDK.
    pub fn reload_project_config(&mut self) {
        match ProjectConfig::load(&self.state.project_dir) {
            Ok(cfg) => self.state.config = cfg,
            Err(e) => {
                self.state.status_msg = format!("Config.toml error: {e}");
                return;
            }
        }
        self.state.pdk = None;
        if let Some(name) = self.state.config.pdk.clone() {
            match config::load_pdk(&name, self.state.config.pdk_path.as_deref()) {
                Ok(p) => {
                    self.state.status_msg = format!(
                        "PDK {}: {} cells, corners [{}]",
                        p.name,
                        p.cells.len(),
                        p.corners.join(", ")
                    );
                    self.state.pdk = Some(p);
                }
                Err(e) => self.state.status_msg = format!("PDK load failed: {e}"),
            }
        }
        self.reload_project_library();
    }

    /// Rebuild the library browser sections sourced from the project: PDK
    /// manifest cells, `.chn_prim` primitives, and `.chn` subcircuit symbols.
    /// Runtime prims are registered globally so rendering/connectivity resolve
    /// them by symbol name; sources are leaked (lifetime = program, a reload
    /// leaks a few KB).
    pub(crate) fn reload_project_library(&mut self) {
        let mut lib = LibraryIndex::default();
        let mut runtime: Vec<prim::PrimEntry> = Vec::new();
        let mut symbol_schematics: Vec<Schematic> = Vec::new();
        let mut testbenches: Vec<ProjectTestbench> = Vec::new();

        if let Some(p) = &self.state.pdk {
            lib.pdk_cells = p
                .cells
                .iter()
                .filter(|(k, _)| DeviceKind::from_name(k) != DeviceKind::Unknown)
                .map(|(k, c)| (k.clone(), c.model.clone()))
                .collect();
            lib.pdk_cells.sort();
        }

        // Project .chn_prim primitives (globbed by Config.toml paths).
        for path in self.state.config.paths.primitives.clone() {
            let Ok(content) = std::fs::read_to_string(&path) else {
                continue;
            };
            let src: &'static str = Box::leak(content.into_boxed_str());
            if let Some(entry) = prim::parse_chn_prim(src) {
                lib.project_prims.push(entry.kind_name.to_owned());
                runtime.push(entry);
            }
        }
        lib.project_prims.sort();

        // Project .chn schematics with pins become placeable subckt symbols.
        let chn_paths: Vec<PathBuf> = if self.state.config.paths.schematics.is_empty() {
            std::fs::read_dir(&self.state.project_dir)
                .map(|rd| {
                    rd.filter_map(|e| e.ok().map(|e| e.path()))
                        .filter(|p| p.extension().is_some_and(|e| e == "chn"))
                        .collect()
                })
                .unwrap_or_default()
        } else {
            self.state.config.paths.schematics.clone()
        };
        for path in chn_paths {
            let Ok(content) = std::fs::read_to_string(&path) else {
                continue;
            };
            // Warnings deliberately discarded: project-scan preload, not a
            // user-initiated open (that path reports via read_chn_reported).
            let (mut sch, _) = prim::read_chn_report(&content, &mut self.state.interner);
            let Some(stem) = path.file_stem().and_then(|s| s.to_str()) else {
                continue;
            };
            // Testbenches are sim entry points, not instanceable cells —
            // cache them for the "used in" canvas overlay instead.
            if sch.stype == SchematicType::Testbench {
                sch.name = stem.to_owned();
                testbenches.push(ProjectTestbench {
                    name: stem.to_owned(),
                    path: path.clone(),
                    schematic: sch,
                });
                continue;
            }
            // A schematic without pins has no ports to connect.
            if sch.stype != SchematicType::Schematic || sch.pins.is_empty() {
                continue;
            }
            // Subckt def name must match the instance's symbol name.
            sch.name = stem.to_owned();
            let stem: &'static str = Box::leak(stem.to_owned().into_boxed_str());

            let pins: Vec<(&'static str, bool)> = sch
                .pins
                .iter()
                .map(|p| {
                    let name: &'static str = Box::leak(
                        self.state
                            .interner
                            .resolve(&p.name)
                            .to_owned()
                            .into_boxed_str(),
                    );
                    (name, p.direction == PinDirection::Input)
                })
                .collect();

            lib.project_symbols.push((stem.to_owned(), pins.len()));
            let mut entry = prim::box_symbol(stem, &pins);
            entry.params = sch
                .sym_properties
                .iter()
                .map(|p| {
                    let k: &'static str = Box::leak(
                        self.state.interner.resolve(&p.key).to_owned().into_boxed_str(),
                    );
                    let v: &'static str = Box::leak(
                        self.state.interner.resolve(&p.value).to_owned().into_boxed_str(),
                    );
                    (k, v)
                })
                .collect();
            runtime.push(entry);
            symbol_schematics.push(sch);
        }
        lib.project_symbols.sort();

        prim::register_runtime(runtime);

        // Instances referencing runtime symbols parse as Unknown when their
        // file was read before registration (cached children above, or
        // documents opened before the project dir was set). Re-derive.
        let fixup = |interner: &Rodeo, sch: &mut Schematic| {
            for i in 0..sch.instances.len() {
                if sch.instances.kind[i] == DeviceKind::Unknown {
                    let sym = interner.resolve(&sch.instances.symbol[i]);
                    if let Some(p) = prim::find_by_name(sym) {
                        sch.instances.kind[i] = p.kind;
                    }
                }
            }
        };
        for sch in &mut symbol_schematics {
            fixup(&self.state.interner, sch);
        }
        for tb in &mut testbenches {
            fixup(&self.state.interner, &mut tb.schematic);
        }
        for doc in &mut self.state.documents {
            fixup(&self.state.interner, &mut doc.schematic);
            doc.generation += 1;
        }

        self.state.library = lib;
        self.state.project_symbol_schematics = symbol_schematics;
        self.state.project_testbenches = testbenches;
    }

    /// Indices of project testbenches that instance `symbol`.
    pub fn testbenches_using(&self, symbol: &str) -> Vec<usize> {
        if symbol.is_empty() {
            return Vec::new();
        }
        self.state
            .project_testbenches
            .iter()
            .enumerate()
            .filter(|(_, tb)| {
                let insts = &tb.schematic.instances;
                (0..insts.len()).any(|i| self.state.interner.resolve(&insts.symbol[i]) == symbol)
            })
            .map(|(i, _)| i)
            .collect()
    }

    /// Open a cached project testbench as a document (canvas overlay click).
    pub fn open_project_testbench(&mut self, idx: usize) {
        let Some(path) = self
            .state
            .project_testbenches
            .get(idx)
            .map(|t| t.path.clone())
        else {
            return;
        };
        // Already open → just focus it.
        if let Some(di) = self.state.documents.iter().position(|d| match &d.origin {
            Origin::File(p) => *p == path,
            _ => false,
        }) {
            self.state.active_doc = di;
            return;
        }
        if let Err(e) = self.open_file(&path) {
            self.state.status_msg = format!("Failed to open {}: {e}", path.display());
        }
    }
}

// ════════════════════════════════════════════════════════════
// Object transforms — plain fns + match (replaces SchematicCollection)
// ════════════════════════════════════════════════════════════

/// Rotate (x, y) 90° around (cx, cy).
/// Expand `{{Name.key}}` / `{{Name}}` documentation references to live
/// schematic values (`{{R1}}` reads R1's "value" prop). Unknown references
/// render unchanged so typos stay visible.
pub fn expand_doc_vars(text: &str, sch: &Schematic, interner: &Rodeo) -> String {
    let lookup = |name: &str, key: &str| -> Option<String> {
        let idx = (0..sch.instances.len())
            .find(|&i| interner.resolve(&sch.instances.name[i]) == name)?;
        sch.instance_props(idx)
            .iter()
            .find(|p| interner.resolve(&p.key) == key)
            .map(|p| interner.resolve(&p.value).to_owned())
    };

    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(start) = rest.find("{{") {
        out.push_str(&rest[..start]);
        let after = &rest[start + 2..];
        let Some(end) = after.find("}}") else {
            // Unterminated ref: emit the tail verbatim.
            out.push_str(&rest[start..]);
            return out;
        };
        let inner = after[..end].trim();
        let (name, key) = match inner.split_once('.') {
            Some((n, k)) => (n.trim(), k.trim()),
            None => (inner, "value"),
        };
        match lookup(name, key) {
            Some(v) => out.push_str(&v),
            None => out.push_str(&rest[start..start + 2 + end + 2]),
        }
        rest = &after[end + 2..];
    }
    out.push_str(rest);
    out
}

