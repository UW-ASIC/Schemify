//! PDK Switcher plugin: list ciel-releases builds, one-click download /
//! install / enable into `$PDK_ROOT` (ciel-compatible layout), and activate
//! the PDK in the current Schemify project.
//!
//! `cargo run -- selftest <family> [hash]` exercises the full pipeline
//! headless using only the smallest asset (see `selftest`).

mod families;
mod installer;
mod remote;
mod sink;
mod view;

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use schemify_plugin_api::sdk::{
    CommandInvocation, InitializeEvent, PanelLayout, Plugin, PluginRuntime, RuntimeError,
    UiAction,
};

use families::PdkFamily;
use sink::HostSink;
use view::{Model, Phase, PANEL};

struct PdkSwitcher {
    model: Arc<Mutex<Model>>,
    cancel: Arc<AtomicBool>,
    sink: HostSink,
    worker: Option<std::thread::JoinHandle<()>>,
}

impl PdkSwitcher {
    fn new() -> Self {
        Self {
            model: Arc::new(Mutex::new(Model::default())),
            cancel: Arc::new(AtomicBool::new(false)),
            sink: HostSink,
            worker: None,
        }
    }

    fn render(&self, rt: &mut PluginRuntime) -> Result<(), RuntimeError> {
        let widgets = view::render(&self.model.lock().unwrap());
        rt.update_widgets(PANEL, widgets)
    }

    fn busy(&self) -> bool {
        self.worker.as_ref().is_some_and(|w| !w.is_finished())
    }

    /// Remote refresh (blocking; listing is one or two small requests).
    fn refresh_remote(&mut self, rt: &mut PluginRuntime) -> Result<(), RuntimeError> {
        let result = remote::list_remote();
        {
            let mut m = self.model.lock().unwrap();
            match result {
                Ok(builds) => {
                    m.set_remote(builds);
                    m.notice = None;
                }
                Err(e) => m.notice = Some(format!("listing failed: {e}")),
            }
        }
        self.render(rt)
    }

    fn start_install(&mut self, rt: &mut PluginRuntime) -> Result<(), RuntimeError> {
        if self.busy() {
            return rt.set_status("PDK install already running");
        }
        let (family, hash, full) = {
            let mut m = self.model.lock().unwrap();
            let Some(row) = m.selected_row.and_then(|i| m.builds[m.selected_tab].get(i)) else {
                return rt.set_status("Select a version first");
            };
            let triple = (m.family(), row.hash.clone(), m.full_install);
            m.busy = true;
            m.phase = Phase::Downloading {
                file: "starting...".into(),
                asset_idx: 0,
                asset_count: 0,
                bytes: 0,
                total: 0,
            };
            triple
        };
        self.cancel.store(false, Ordering::Relaxed);
        let (model, cancel, sink) = (self.model.clone(), self.cancel.clone(), self.sink.clone());
        self.worker = Some(std::thread::spawn(move || {
            installer::install(family, hash, full, model.clone(), cancel, sink);
            model.lock().unwrap().busy = false;
        }));
        self.render(rt)
    }

    fn enable_selected(&mut self, rt: &mut PluginRuntime) -> Result<(), RuntimeError> {
        let (family, hash) = {
            let m = self.model.lock().unwrap();
            let Some(row) = m.selected_row.and_then(|i| m.builds[m.selected_tab].get(i)) else {
                return Ok(());
            };
            (m.family(), row.hash.clone())
        };
        let result = installer::enable(family, &hash);
        {
            let mut m = self.model.lock().unwrap();
            m.phase = match result {
                Ok(()) => {
                    m.refresh_installed();
                    Phase::Done(format!("{} enabled", family.name()))
                }
                Err(e) => Phase::Failed(e),
            };
        }
        self.render(rt)
    }

    /// Point the current project at the enabled variant: edit Config.toml's
    /// `[pdk_switcher]` table (format-preserving) + ask the host to reload.
    fn activate_in_project(&mut self, rt: &mut PluginRuntime) -> Result<(), RuntimeError> {
        let (family, variant) = {
            let m = self.model.lock().unwrap();
            let family = m.family();
            let variant = family
                .variants()
                .get(m.selected_variant)
                .copied()
                .unwrap_or(family.default_variant());
            (family, variant.to_owned())
        };
        let _ = family;

        let project = rt.query_project()?;
        if project.project_dir.is_empty() {
            return rt.set_status("No project open; cannot edit Config.toml");
        }
        let config_path = std::path::Path::new(&project.project_dir).join("Config.toml");
        let content = std::fs::read_to_string(&config_path).unwrap_or_default();
        let mut doc = content
            .parse::<toml_edit::DocumentMut>()
            .unwrap_or_default();

        doc["pdk_switcher"]["active"] = toml_edit::value(variant.as_str());
        if std::env::var("PDK_ROOT").map(|v| v.is_empty()).unwrap_or(true) {
            // No $PDK_ROOT: record the explicit path so core can find it.
            let path = installer::pdk_root().join(&variant);
            doc["pdk_switcher"]["path"] = toml_edit::value(path.display().to_string());
        }
        if let Err(e) = std::fs::write(&config_path, doc.to_string()) {
            return rt.set_status(format!("Config.toml write failed: {e}"));
        }

        rt.dispatch_action("reload_project_config")?;
        rt.set_status(format!("Project PDK → {variant}"))
    }
}

impl Plugin for PdkSwitcher {
    fn on_initialize(
        &mut self,
        rt: &mut PluginRuntime,
        _event: InitializeEvent,
    ) -> Result<(), RuntimeError> {
        rt.register_panel(PANEL, PanelLayout::RightSidebar, 15, true)?;
        rt.register_command("refresh_pdk_list", "Refresh the remote PDK version list", None)?;
        {
            // Offline startup: cached release list + disk scan only.
            let mut m = self.model.lock().unwrap();
            m.set_remote(remote::list_cached());
            if m.builds.iter().all(Vec::is_empty) {
                m.notice = Some("Press Refresh to fetch the version list".into());
            }
        }
        self.render(rt)
    }

    fn on_ui_action(&mut self, rt: &mut PluginRuntime, action: UiAction) -> Result<(), RuntimeError> {
        let payload_u64 =
            |a: &UiAction| a.payload.as_ref().and_then(|v| v.as_u64()).unwrap_or(0) as usize;
        match action.action.as_str() {
            "select_tab" => {
                let mut m = self.model.lock().unwrap();
                m.selected_tab = payload_u64(&action).min(2);
                m.selected_row = None;
                m.selected_variant = 0;
                drop(m);
                self.render(rt)
            }
            "select_version" => {
                let mut m = self.model.lock().unwrap();
                let idx = payload_u64(&action);
                if idx < m.builds[m.selected_tab].len() {
                    m.selected_row = Some(idx);
                    m.phase = Phase::Idle;
                }
                drop(m);
                self.render(rt)
            }
            "select_variant" => {
                self.model.lock().unwrap().selected_variant = payload_u64(&action);
                self.render(rt)
            }
            "toggle_full" => {
                let v = action
                    .payload
                    .as_ref()
                    .and_then(|v| v.as_bool())
                    .unwrap_or(false);
                self.model.lock().unwrap().full_install = v;
                self.render(rt)
            }
            "install" => self.start_install(rt),
            "enable" => self.enable_selected(rt),
            "activate" => self.activate_in_project(rt),
            "cancel" => {
                self.cancel.store(true, Ordering::Relaxed);
                rt.set_status("Cancelling download...")
            }
            "refresh" => self.refresh_remote(rt),
            _ => Ok(()),
        }
    }

    fn on_command(
        &mut self,
        rt: &mut PluginRuntime,
        command: CommandInvocation,
    ) -> Result<(), RuntimeError> {
        if command.command == "refresh_pdk_list" {
            self.refresh_remote(rt)?;
        }
        Ok(())
    }
}

/// Headless pipeline check: list → plan → download smallest asset → extract
/// → enable, against a temp PDK_ROOT unless one is set. Network required.
fn selftest(family_name: &str, hash_arg: Option<&str>) -> Result<(), String> {
    let family = PdkFamily::from_name(family_name).ok_or("unknown family")?;
    let listing = remote::list_remote()?;
    let hash = match hash_arg {
        Some(h) => h.to_owned(),
        None => {
            listing
                .iter()
                .find(|(f, b)| *f == family && !b.prerelease)
                .map(|(_, b)| b.hash.clone())
                .ok_or("no remote build found")?
        }
    };
    println!("selftest: {} {hash}", family.name());

    let assets = remote::release_assets(family, &hash)?;
    let smallest = assets
        .iter()
        .min_by_key(|a| a.size)
        .ok_or("no assets")?
        .clone();
    println!(
        "smallest asset: {} ({} bytes, sha256 {})",
        smallest.filename,
        smallest.size,
        smallest.sha256.as_deref().unwrap_or("n/a")
    );

    // Reuse the real worker path with a model + null sink, restricted to the
    // smallest asset via a fake "default set".
    let model = Arc::new(Mutex::new(Model::default()));
    let cancel = Arc::new(AtomicBool::new(false));

    // Download + verify + extract just the one asset, then enable.
    let dl_dir = remote::cache_dir().join("selftest");
    let _ = std::fs::remove_dir_all(&dl_dir);
    std::fs::create_dir_all(&dl_dir).map_err(|e| e.to_string())?;
    installer::download_one_for_test(&smallest, &dl_dir, &model, &cancel)?;
    println!("downloaded + sha256 verified");

    let extract_dir = dl_dir.join("extract");
    std::fs::create_dir_all(&extract_dir).map_err(|e| e.to_string())?;
    let file = std::fs::File::open(dl_dir.join(&smallest.filename)).map_err(|e| e.to_string())?;
    let decoder = zstd::Decoder::new(file).map_err(|e| e.to_string())?;
    tar::Archive::new(decoder)
        .unpack(&extract_dir)
        .map_err(|e| e.to_string())?;
    let entries: Vec<String> = std::fs::read_dir(&extract_dir)
        .map_err(|e| e.to_string())?
        .flatten()
        .map(|e| e.file_name().to_string_lossy().to_string())
        .collect();
    println!("extracted top-level entries: {entries:?}");
    println!("selftest OK");
    Ok(())
}

fn main() -> Result<(), RuntimeError> {
    let args: Vec<String> = std::env::args().collect();
    if args.get(1).map(String::as_str) == Some("selftest") {
        let family = args.get(2).map(String::as_str).unwrap_or("sky130");
        match selftest(family, args.get(3).map(String::as_str)) {
            Ok(()) => return Ok(()),
            Err(e) => {
                eprintln!("selftest failed: {e}");
                std::process::exit(1);
            }
        }
    }
    PluginRuntime::stdio().run(&mut PdkSwitcher::new())
}
