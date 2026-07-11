//! Shell-facing dispatch helpers: wave/optimizer plumbing, tab lifecycle,
//! document adoption.



use crate::wave;

use super::*;

impl App {    /// Run `f` against the app-wide wave state; status bar reports errors
    /// (and "no waveform loaded" when there is none).
    pub(crate) fn with_wave(
        &mut self,
        f: impl FnOnce(&mut wave::WaveState) -> Result<(), wave::WaveError>,
    ) {
        let Some(w) = self.state.wave.as_deref_mut() else {
            self.state.status_msg = "No waveform loaded (WaveOpen first)".into();
            return;
        };
        if let Err(e) = f(w) {
            self.state.status_msg = format!("Wave: {e}");
        }
    }

    /// Open a `.raw` into the viewer (created on first open) and show the
    /// viewer window.
    pub(crate) fn handle_wave_open(&mut self, path: &str) {
        let w = self
            .state
            .wave
            .get_or_insert_with(|| Box::new(wave::WaveState::new()));
        match w.open_file(std::path::Path::new(path)) {
            Ok(_) => {
                self.state.wave_window_open = true;
                self.state.status_msg = format!("Loaded {path}");
            }
            Err(e) => self.state.status_msg = format!("Wave: {e}"),
        }
    }

    /// Create an optimizer instance and open its window. Any number of
    /// instances may exist; ids are monotonic and never reused.
    pub(crate) fn handle_optimizer_new(&mut self, name: String) {
        let id = self.state.next_optimizer_id;
        self.state.next_optimizer_id += 1;
        let name = if name.is_empty() {
            format!("Optimizer {}", id + 1)
        } else {
            name
        };
        let mut opt = schemify_optimizer::Optimizer::new(&*name);
        // Decorrelate concurrent instances without losing determinism.
        opt.set_seed(0x9E37_79B9_7F4A_7C15 ^ u64::from(id));
        self.state.optimizers.push(OptimizerInstance {
            id,
            window_open: true,
            opt,
        });
        self.state.status_msg = format!("{name} opened");
    }

    /// Run `f` against optimizer `id`; status bar reports the outcome.
    pub(crate) fn with_optimizer(
        &mut self,
        id: u32,
        f: impl FnOnce(&mut OptimizerInstance) -> Result<String, schemify_optimizer::OptError>,
    ) {
        let Some(o) = self.state.optimizers.iter_mut().find(|o| o.id == id) else {
            self.state.status_msg = format!("No optimizer with id {id}");
            return;
        };
        match f(o) {
            Ok(msg) if !msg.is_empty() => self.state.status_msg = msg,
            Ok(_) => {}
            Err(e) => self.state.status_msg = format!("Optimizer: {e}"),
        }
    }

    /// Close tab `idx`, keeping at least one document open and
    /// re-pointing `active_doc` past the removal.
    pub(crate) fn close_tab(&mut self, idx: usize) {
        if idx >= self.state.documents.len() {
            return;
        }
        if self.state.documents.len() == 1 {
            // Closing the last tab returns to the welcome screen.
            self.state.documents[0] = Document::default();
            self.state.active_doc = 0;
            self.state.view.show_welcome = true;
            return;
        }
        self.state.documents.remove(idx);
        if self.state.active_doc >= self.state.documents.len() {
            self.state.active_doc = self.state.documents.len() - 1;
        } else if self.state.active_doc > idx {
            self.state.active_doc -= 1;
        }
    }

    /// True while the only document is the pristine startup placeholder
    /// backing the welcome screen.
    pub(crate) fn welcome_placeholder(&self) -> bool {
        let docs = &self.state.documents;
        self.state.view.show_welcome
            && docs.len() == 1
            && !docs[0].dirty
            && docs[0].schematic.instances.is_empty()
            && docs[0].schematic.wires.is_empty()
    }

    /// Install a document: reuse the welcome placeholder slot if present,
    /// otherwise open a new tab. Dismisses the welcome screen either way.
    pub fn adopt_document(&mut self, doc: Document) {
        if self.welcome_placeholder() {
            self.state.documents[0] = doc;
            self.state.active_doc = 0;
        } else {
            self.state.documents.push(doc);
            self.state.active_doc = self.state.documents.len() - 1;
        }
        self.state.view.show_welcome = false;
    }
}
