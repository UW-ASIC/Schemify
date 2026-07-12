//! Schemify app server — transport/runtime-agnostic JSON-RPC 2.0 library
//! (old `schemify-mcp` crate; [`crate::protocol`] adapts it to real MCP).
//!
//! `McpServer` owns a shared `Arc<Mutex<App>>` (uniform across headless and
//! headful wiring) plus a command [`Sink`]: `Direct` dispatches mutations into
//! the App inline; `Channel` forwards `Command`s into a live GUI loop (which
//! shares the same `Arc<Mutex<App>>` and may insert step-delays). Queries
//! always read the App through the mutex in both modes.
//!
//! `run_stdio` is the newline-delimited stdio loop; `handle_request` is the
//! pure-ish request handler main.rs (or tests) can drive over any transport.
//!
//! Ported from the old `engine/src/mcp_server.rs`. Kept: every old method.
//! Killed: the plugin host pump (plugins/* now return a "not available"
//! error, phase 7) and dead code in `query_view`. New here: SPICE import is
//! implemented via `schemify_net2schem` (the core handler stubs it), and the
//! JSON→`Command` marshaling is by hand (core's `Command` carries no serde).

mod query;
use query::*;

/// Back-compat: marshaling moved to core (next to `Command`).
pub use schemify_editor::marshal::command_from_json;

use std::io::{self, BufRead, Write};
use std::path::{Path, PathBuf};
use std::sync::mpsc::Sender;
use std::sync::{Arc, Mutex};

use anyhow::{anyhow, Context, Result};
use serde_json::{json, Value};

use schemify_editor::config;
use schemify_editor::handler::{self, App, DispatchResult, Document, Origin};
use schemify_editor::schemify::Command;
use schemify_editor::sim::codegen::emit_pyspice;
use schemify_net2schem::emit::schematic_from_subcircuit;
use schemify_plugin_host::PluginService;

// ════════════════════════════════════════════════════════════
// Server
// ════════════════════════════════════════════════════════════

/// Where dispatched `Command`s go.
pub enum Sink {
    /// Headless: dispatch directly into the shared App.
    Direct,
    /// Headful: forward into a live GUI event loop. The GUI owns dispatch
    /// (and any step-delay); it shares the same `Arc<Mutex<App>>` for queries.
    Channel(Sender<Command>),
}

pub struct McpServer {
    app: Arc<Mutex<App>>,
    sink: Sink,
    /// Plugin runtime + marketplace; shared with the GUI in headful mode.
    service: Arc<Mutex<PluginService>>,
}

/// JSON-RPC error (code + message). `anyhow::Error` converts to -32603.
pub(crate) struct RpcErr {
    pub(crate) code: i32,
    pub(crate) message: String,
}

impl From<anyhow::Error> for RpcErr {
    fn from(e: anyhow::Error) -> Self {
        Self {
            code: -32603,
            message: format!("{e:#}"),
        }
    }
}

impl McpServer {
    pub fn new(app: Arc<Mutex<App>>, sink: Sink, service: Arc<Mutex<PluginService>>) -> Self {
        Self { app, sink, service }
    }

    /// Headless server owning a fresh-wrapped App and its own services.
    pub fn direct(app: App) -> Self {
        let service =
            PluginService::new(config::global_plugins_dir(), config::cache_dir());
        Self::new(
            Arc::new(Mutex::new(app)),
            Sink::Direct,
            Arc::new(Mutex::new(service)),
        )
    }

    /// Shared App handle (headful main.rs hands this to the GUI).
    pub fn app(&self) -> Arc<Mutex<App>> {
        Arc::clone(&self.app)
    }

    /// Handle one JSON-RPC request line. Returns the response line, or
    /// `None` for successfully handled notifications (requests without id).
    pub fn handle_request(&mut self, line: &str) -> Option<String> {
        let parsed: Result<Value, _> = serde_json::from_str(line);
        let id = parsed.as_ref().ok().and_then(|v| v.get("id").cloned());

        let outcome = match parsed {
            Ok(req) => self.handle_parsed(&req),
            Err(e) => Err(RpcErr {
                code: -32700,
                message: format!("invalid JSON: {e}"),
            }),
        };

        match outcome {
            Ok(result) => {
                id.map(|id| json!({"jsonrpc": "2.0", "id": id, "result": result}).to_string())
            }
            Err(err) => Some(
                json!({
                    "jsonrpc": "2.0",
                    "id": id.unwrap_or(Value::Null),
                    "error": {"code": err.code, "message": err.message},
                })
                .to_string(),
            ),
        }
    }

    fn handle_parsed(&mut self, req: &Value) -> Result<Value, RpcErr> {
        let method = req
            .get("method")
            .and_then(Value::as_str)
            .ok_or_else(|| RpcErr {
                code: -32600,
                message: "missing method".into(),
            })?;
        let params = req.get("params").cloned().unwrap_or(Value::Null);
        self.handle_method(method, &params)
    }

    fn lock_app(&self) -> Result<std::sync::MutexGuard<'_, App>> {
        self.app.lock().map_err(|_| anyhow!("app mutex poisoned"))
    }

    fn lock_service(&self) -> Result<std::sync::MutexGuard<'_, PluginService>> {
        self.service
            .lock()
            .map_err(|_| anyhow!("plugin service mutex poisoned"))
    }

    /// Route a mutation through the configured sink: dispatch inline
    /// (headless) or forward to the live GUI loop (headful).
    fn dispatch_sink(&mut self, cmd: Command) -> Result<Value> {
        match &self.sink {
            Sink::Direct => {
                let mut app = self.lock_app()?;
                match app.dispatch(cmd) {
                    DispatchResult::Done => {
                        Ok(json!({"ok": true, "status": app.state.status_msg}))
                    }
                    // Shell-owned commands (ImportSpice, Marketplace*) are
                    // intercepted in handle_method before reaching here.
                    DispatchResult::Unhandled(c) => {
                        Err(anyhow!("command not handled by core: {c:?}"))
                    }
                }
            }
            Sink::Channel(tx) => {
                tx.send(cmd)
                    .map_err(|_| anyhow!("GUI command channel closed"))?;
                Ok(json!({"ok": true, "queued": true}))
            }
        }
    }

    pub(crate) fn handle_method(&mut self, method: &str, params: &Value) -> Result<Value, RpcErr> {
        let result = match method {
            "ping" => json!({"ok": true}),
            "session/reset" => {
                *self.lock_app()? = App::new();
                json!({"ok": true})
            }
            "session/open" => {
                let path = req_str(params, "path")?;
                self.lock_app()?
                    .open_file(Path::new(&path))
                    .with_context(|| format!("opening {path}"))?;
                json!({"ok": true})
            }
            "session/open_content" => {
                let name = req_str(params, "name")?;
                let content = req_str(params, "content")?;
                self.lock_app()?.open_from_content(&name, &content);
                json!({"ok": true})
            }
            "session/import_netlist" => {
                let content = req_str(params, "content")?;
                let name = params
                    .get("name")
                    .and_then(Value::as_str)
                    .unwrap_or("imported")
                    .to_string();
                let mut app = self.lock_app()?;
                import_netlist_source(&mut app, &content, &name, "inline netlist")?
            }
            "session/save" => {
                let mut app = self.lock_app()?;
                let path = save_path(&app, params)?;
                app.save_to_path(&path)
                    .with_context(|| format!("saving {}", path.display()))?;
                json!({"ok": true, "path": path})
            }
            "session/set_project_dir" => {
                let path = req_str(params, "path")?;
                self.lock_app()?.set_project_dir(PathBuf::from(&path));
                // Mirror the GUI plugin host: project-local plugins live in
                // <project>/plugins and become discoverable immediately.
                let mut svc = self.lock_service()?;
                svc.manager
                    .add_scan_dir(PathBuf::from(&path).join("plugins"));
                let errs = svc.manager.scan_directories();
                let ids: Vec<&str> = svc.manager.plugin_ids().collect();
                if errs.is_empty() {
                    json!({"ok": true, "plugins": ids})
                } else {
                    let msgs: Vec<String> = errs.iter().map(|e| e.to_string()).collect();
                    json!({"ok": true, "plugins": ids, "errors": msgs})
                }
            }
            "session/dispatch" | "document/dispatch" => {
                let payload = params.get("command").unwrap_or(params);
                // Models sometimes JSON-encode the command object into a
                // string; unwrap that. Bare unit-variant strings ("ZoomIn")
                // don't parse as JSON and pass through untouched.
                let unwrapped = payload
                    .as_str()
                    .and_then(|s| serde_json::from_str::<Value>(s).ok());
                let cmd = command_from_json(unwrapped.as_ref().unwrap_or(payload))?;
                // Commands handled at the MCP level (core handler stubs them).
                match &cmd {
                    Command::ImportSpice { path } => {
                        let mut app = self.lock_app()?;
                        import_spice(&mut app, path)?
                    }
                    Command::MarketplaceFetch => {
                        let mut svc = self.lock_service()?;
                        let index = svc.marketplace.fetch_index().map_err(|e| anyhow!("{e}"))?;
                        json!({"ok": true, "count": index.plugins.len()})
                    }
                    Command::MarketplaceInstall { name } => {
                        let mut svc = self.lock_service()?;
                        svc.marketplace
                            .install(name)
                            .map_err(|e| anyhow!("{e}"))?;
                        svc.manager.scan_directories();
                        json!({"ok": true, "id": name})
                    }
                    Command::MarketplaceUninstall { name } => {
                        let mut svc = self.lock_service()?;
                        let _ = svc.manager.stop(name);
                        svc.manager.remove(name);
                        svc.marketplace
                            .uninstall(name)
                            .map_err(|e| anyhow!("{e}"))?;
                        json!({"ok": true, "id": name})
                    }
                    Command::PluginsRefresh => {
                        let mut svc = self.lock_service()?;
                        svc.manager.scan_directories();
                        json!({"ok": true})
                    }
                    _ => self.dispatch_sink(cmd)?,
                }
            }
            "session/state" => {
                let app = self.lock_app()?;
                session_state(&app)
            }
            "query/instances" => {
                let app = self.lock_app()?;
                query_instances(&app)
            }
            "query/nets" => {
                let mut app = self.lock_app()?;
                query_nets(&mut app)
            }
            "query/view" => {
                let mut app = self.lock_app()?;
                query_view(&mut app)
            }
            // The dispatch command reference, verbatim from the agent skill.
            "query/commands" => json!({"reference": include_str!("../../skill/REFERENCE.md")}),
            "query/files" => {
                let dir = self.lock_app()?.state.project_dir.clone();
                if dir.as_os_str().is_empty() {
                    json!({"files": [],
                        "note": "no project dir set — call session_set_project_dir first"})
                } else {
                    json!({"project_dir": dir, "files": list_workspace_files(&dir)})
                }
            }
            "query/netlist" => json!(emit_pyspice(&self.lock_app()?.build_circuit_ir())),
            "query/documentation" => {
                let app = self.lock_app()?;
                let sch = app.schematic();
                json!({
                    "raw": sch.documentation,
                    // {{R1}} / {{R1.key}} refs expanded to live values.
                    "rendered": handler::expand_doc_vars(
                        &sch.documentation, sch, &app.state.interner),
                })
            }
            "query/theme" => {
                // Theme tokens live in the display crate now; expose the only
                // theme bit the core App tracks.
                json!({"dark_mode": self.lock_app()?.state.view.dark_mode})
            }
            "wave/open" => {
                let path = req_str(params, "path")?;
                self.dispatch_sink(Command::WaveOpen { path })?
            }
            "query/signals" => {
                let app = self.lock_app()?;
                query_signals(&app)?
            }
            "query/traces" => {
                let app = self.lock_app()?;
                query_traces(&app)?
            }
            "query/cursors" => {
                let app = self.lock_app()?;
                query_cursors(&app)?
            }
            "query/wave_data" => {
                let app = self.lock_app()?;
                query_wave_data(&app, params)?
            }
            // ── Optimizer (ask-tell; each instance is its own window) ──
            "optimizer/new" => {
                let name = params
                    .get("name")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_owned();
                self.dispatch_sink(Command::OptimizerNew { name })?
            }
            "optimizer/close" => self.dispatch_sink(Command::OptimizerClose {
                id: num(params, "id")?,
            })?,
            "optimizer/set_window_open" => self.dispatch_sink(Command::OptimizerSetWindowOpen {
                id: num(params, "id")?,
                open: req_bool(params, "open")?,
            })?,
            "optimizer/add_param" => self.dispatch_sink(Command::OptimizerAddParam {
                id: num(params, "id")?,
                name: req_str(params, "name")?,
                min: f64_or_si(params, "min")?,
                max: f64_or_si(params, "max")?,
                init: f64_or_si(params, "init")?,
            })?,
            "optimizer/remove_param" => self.dispatch_sink(Command::OptimizerRemoveParam {
                id: num(params, "id")?,
                name: req_str(params, "name")?,
            })?,
            "optimizer/add_objective" => self.dispatch_sink(Command::OptimizerAddObjective {
                id: num(params, "id")?,
                name: req_str(params, "name")?,
                target: target_str(params)?,
                weight: opt_f64(params, "weight", 1.0)?,
            })?,
            "optimizer/remove_objective" => {
                self.dispatch_sink(Command::OptimizerRemoveObjective {
                    id: num(params, "id")?,
                    name: req_str(params, "name")?,
                })?
            }
            "optimizer/set_algorithm" => self.dispatch_sink(Command::OptimizerSetAlgorithm {
                id: num(params, "id")?,
                algorithm: req_str(params, "algorithm")?,
            })?,
            "optimizer/report" => self.dispatch_sink(Command::OptimizerReport {
                id: num(params, "id")?,
                params: opt_f64_vec(params, "params")?,
                measured: f64_vec(params, "measured")?,
            })?,
            "optimizer/reset" => self.dispatch_sink(Command::OptimizerReset {
                id: num(params, "id")?,
            })?,
            "query/optimizers" => {
                let app = self.lock_app()?;
                query_optimizers(&app)
            }
            "query/optimizer_state" => {
                let app = self.lock_app()?;
                query_optimizer_state(&app, params)?
            }
            // Read-only despite the verb-ish name: `Optimizer::suggest` is a
            // pure read of the precomputed pending candidate. Only
            // optimizer/report advances the algorithm.
            "optimizer/suggest" => {
                let app = self.lock_app()?;
                optimizer_suggest(&app, params)?
            }
            // ── Plugins ──
            "plugins/refresh" => {
                let mut svc = self.lock_service()?;
                let errs = svc.manager.scan_directories();
                let ids: Vec<&str> = svc.manager.plugin_ids().collect();
                if errs.is_empty() {
                    json!({"ok": true, "plugins": ids})
                } else {
                    let msgs: Vec<String> = errs.iter().map(|e| e.to_string()).collect();
                    json!({"ok": true, "plugins": ids, "errors": msgs})
                }
            }
            "plugins/list" => {
                let svc = self.lock_service()?;
                let ids: Vec<&str> = svc.manager.plugin_ids().collect();
                let list: Vec<Value> = ids
                    .iter()
                    .map(|id| {
                        json!({
                            "id": id,
                            "state": svc.manager.state(id)
                                .map(|s| format!("{s:?}"))
                                .unwrap_or_else(|| "Unknown".into()),
                            "error": svc.manager.error_msg(id),
                        })
                    })
                    .collect();
                json!(list)
            }
            "plugins/start" => {
                let id = req_str(params, "id")?;
                let mut svc = self.lock_service()?;
                svc.manager
                    .start(&id)
                    .map_err(|e| anyhow!("{e}"))?;
                json!({"ok": true})
            }
            "plugins/stop" => {
                let id = req_str(params, "id")?;
                let mut svc = self.lock_service()?;
                svc.manager
                    .stop(&id)
                    .map_err(|e| anyhow!("{e}"))?;
                json!({"ok": true})
            }

            // ── Marketplace ──
            "marketplace/fetch" => {
                let mut svc = self.lock_service()?;
                let index = svc.marketplace.fetch_index().map_err(|e| anyhow!("{e}"))?;
                let count = index.plugins.len();
                json!({"ok": true, "count": count, "updated_at": index.updated_at})
            }
            "marketplace/search" => {
                let query = params.get("query").and_then(Value::as_str).unwrap_or("");
                let svc = self.lock_service()?;
                let results = svc.marketplace.search(query);
                let items: Vec<Value> = results
                    .iter()
                    .map(|r| {
                        json!({
                            "id": r.entry.id,
                            "name": r.entry.name,
                            "version": r.entry.version,
                            "description": r.entry.description,
                            "author": r.entry.author,
                            "installed": r.installed,
                        })
                    })
                    .collect();
                json!(items)
            }
            "marketplace/list" => {
                let svc = self.lock_service()?;
                let installed = &svc.marketplace.installed().plugins;
                let updates = svc.marketplace.check_updates();
                let items: Vec<Value> = installed
                    .iter()
                    .map(|p| {
                        let update = updates.iter().find(|u| u.id == p.id);
                        json!({
                            "id": p.id,
                            "name": p.name,
                            "version": p.version,
                            "update_available": update.map(|u| &u.latest_version),
                        })
                    })
                    .collect();
                json!(items)
            }
            "marketplace/install" => {
                let id = req_plugin_id(params)?;
                let mut svc = self.lock_service()?;
                svc.marketplace
                    .install(&id)
                    .map_err(|e| anyhow!("{e}"))?;
                svc.manager.scan_directories();
                json!({"ok": true, "id": id})
            }
            "marketplace/install_local" => {
                let path = req_str(params, "path")?;
                let mut svc = self.lock_service()?;
                let id = svc
                    .marketplace
                    .install_from_file(Path::new(&path))
                    .map_err(|e| anyhow!("{e}"))?;
                svc.manager.scan_directories();
                json!({"ok": true, "id": id})
            }
            "marketplace/uninstall" => {
                let id = req_plugin_id(params)?;
                let mut svc = self.lock_service()?;
                let _ = svc.manager.stop(&id);
                svc.manager.remove(&id);
                svc.marketplace
                    .uninstall(&id)
                    .map_err(|e| anyhow!("{e}"))?;
                json!({"ok": true, "id": id})
            }
            "marketplace/update" => {
                let id = req_plugin_id(params)?;
                let mut svc = self.lock_service()?;
                let _ = svc.manager.stop(&id);
                svc.manager.remove(&id);
                svc.marketplace
                    .uninstall(&id)
                    .map_err(|e| anyhow!("{e}"))?;
                svc.marketplace
                    .install(&id)
                    .map_err(|e| anyhow!("{e}"))?;
                svc.manager.scan_directories();
                json!({"ok": true, "id": id})
            }

            other => {
                return Err(RpcErr {
                    code: -32601,
                    message: format!("unknown method: {other}"),
                });
            }
        };
        Ok(result)
    }
}

/// Newline-delimited JSON-RPC over stdio. main.rs calls this after wiring
/// the server; any other transport can drive `handle_request` directly.
pub fn run_stdio(server: &mut McpServer) -> Result<()> {
    let stdin = io::stdin();
    let mut stdout = io::stdout();
    for line in stdin.lock().lines() {
        let line = line?;
        if line.trim().is_empty() {
            continue;
        }
        if let Some(response) = server.handle_request(&line) {
            writeln!(stdout, "{response}")?;
            stdout.flush()?;
        }
    }
    Ok(())
}

// ════════════════════════════════════════════════════════════
// SPICE import (net2schem) — core handler stubs ImportSpice
// ════════════════════════════════════════════════════════════

fn import_spice(app: &mut App, path: &str) -> Result<Value> {
    let source =
        std::fs::read_to_string(path).with_context(|| format!("reading SPICE file {path}"))?;
    let top_name = Path::new(path)
        .file_stem()
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_else(|| "imported".to_string());
    import_netlist_source(app, &source, &top_name, path)
}

fn import_netlist_source(app: &mut App, source: &str, top_name: &str, origin: &str) -> Result<Value> {
    // A lone .subckt is a cell definition: inline its body and turn its
    // ports into directional pins (PININFO refines, else inout).
    let unwrapped = schemify_net2schem::unwrap_lone_subckt(source);
    let (source, top_name) = match &unwrapped {
        Some((inlined, cell)) => (
            inlined.as_str(),
            // Keep the caller's document name unless it's the default.
            if top_name == "imported" { cell.as_str() } else { top_name },
        ),
        None => (source, top_name),
    };
    // Pick up cells saved earlier in this session: X masters resolve against
    // the on-disk project library, so refresh it before building host symbols.
    if !app.state.project_dir.as_os_str().is_empty() {
        app.reload_project_config();
    }

    // Every project component registers as a runtime DUT class: `.chn` cells
    // (their generated box symbols) AND `.chn_prim` symbols, each with its
    // REAL pin anchors, so a testbench `X` master naming one places as a
    // blackbox whose wires land on the pins the app will draw. Pin direction
    // mirrors the layout convention: left edge (x < 0) is Input, else Inout.
    let symbols: Vec<schemify_net2schem::HostSymbol> = schemify_editor::schemify::runtime_prims()
        .iter()
        .filter(|e| !e.non_electrical && !e.pin_positions.is_empty())
        .map(|e| schemify_net2schem::HostSymbol {
            name: e.kind_name.to_string(),
            pins: e
                .pin_positions
                .iter()
                .map(|p| {
                    let dir = if p.x < 0 {
                        schemify_net2schem::ir::PinDir::Input
                    } else {
                        schemify_net2schem::ir::PinDir::Inout
                    };
                    (p.name.to_string(), dir)
                })
                .collect(),
            offsets: Some(
                e.pin_positions
                    .iter()
                    .map(|p| (p.x as i32, p.y as i32))
                    .collect(),
            ),
        })
        .collect();

    let circuit = schemify_net2schem::cktimg::netlist_to_circuit_with(source, &symbols)?;

    // Subckts REQUIRE an existing project component: an X master with no
    // matching .chn / .chn_prim must fail the whole import with an
    // actionable message, not silently degrade to a skipped line.
    let unresolved: Vec<&str> = circuit
        .diagnostics
        .iter()
        .filter(|d| d.message.contains(schemify_net2schem::cktimg::UNRESOLVED_SUBCKT))
        .map(|d| {
            // "<reason>: <netlist line>" — the master is its last bare token.
            d.message
                .rsplit(':')
                .next()
                .unwrap_or("")
                .split_whitespace()
                .filter(|t| !t.contains('='))
                .next_back()
                .unwrap_or("?")
        })
        .collect();
    if !unresolved.is_empty() {
        anyhow::bail!(
            "netlist→schematic failed: subckt(s) could not resolve: {}. Each X master \
             must already exist in the project as <name>.chn (a schematic cell) or \
             <name>.chn_prim (a symbol) — create the component first, then reference \
             it in the testbench.",
            unresolved.join(", ")
        );
    }

    // Multiple .subckts with no top-level instances still produce an empty
    // top — fail loudly instead of opening a blank document. (A single
    // .subckt was already unwrapped above.)
    if circuit.top.instances.is_empty() {
        anyhow::bail!(
            "netlist has no top-level instances — import one .subckt per call \
             (its ports become pins), or instantiate them (e.g. `X1 in out 0 myfilter`)"
        );
    }

    // cktimg flattens .subckts: one top-level document.
    // *.PININFO comments turn named nets into directional port pins.
    let ports = schemify_net2schem::emit::parse_pininfo(source);
    let mut opened = Vec::new();
    let sch = schematic_from_subcircuit(&circuit.top, &mut app.state.interner, &ports);
    push_imported_doc(app, sch, top_name);
    opened.push(top_name.to_string());

    // Parse report: netlist lines the importer could not represent.
    let skipped: Vec<String> = circuit.diagnostics.iter().map(|d| d.to_string()).collect();
    app.state.status_msg = if skipped.is_empty() {
        format!("Imported {} document(s) from {origin}", opened.len())
    } else {
        format!(
            "Imported {} document(s) from {origin} ({} line(s) skipped)",
            opened.len(),
            skipped.len()
        )
    };
    Ok(json!({"ok": true, "documents": opened, "skipped_lines": skipped}))
}

/// Schematic/netlist/waveform files under the project dir (depth ≤ 3,
/// hidden and build dirs skipped).
fn list_workspace_files(dir: &Path) -> Vec<Value> {
    const EXTS: &[&str] = &[".chn", ".chn_tb", ".chn_prim", ".spice", ".cir", ".raw"];
    let mut out = Vec::new();
    let mut stack = vec![(dir.to_path_buf(), 0u8)];
    while let Some((d, depth)) = stack.pop() {
        let Ok(entries) = std::fs::read_dir(&d) else { continue };
        for e in entries.flatten() {
            let p = e.path();
            let name = e.file_name().to_string_lossy().into_owned();
            if p.is_dir() {
                if depth < 3 && !name.starts_with('.') && name != "target" {
                    stack.push((p, depth + 1));
                }
            } else if EXTS.iter().any(|x| name.ends_with(x)) {
                out.push(json!({"name": name, "path": p}));
            }
        }
    }
    out.sort_by(|a, b| a["path"].as_str().cmp(&b["path"].as_str()));
    out
}

fn push_imported_doc(app: &mut App, schematic: schemify_editor::schemify::Schematic, name: &str) {
    let (stem, kind) = schemify_editor::handler::DocKind::split_name(name);
    let mut doc = Document::default();
    doc.schematic = schematic;
    doc.name = stem.to_string();
    doc.kind = kind;
    doc.origin = Origin::Memory;
    doc.dirty = true;
    app.adopt_document(doc);
}

// ════════════════════════════════════════════════════════════
// Tests
// ════════════════════════════════════════════════════════════

#[cfg(test)]
mod tests {
    use super::*;

    fn server() -> McpServer {
        McpServer::direct(App::new())
    }

    fn call(srv: &mut McpServer, req: Value) -> Value {
        let line = req.to_string();
        let resp = srv.handle_request(&line).expect("expected a response");
        serde_json::from_str(&resp).expect("response is valid JSON")
    }

    fn result(srv: &mut McpServer, method: &str, params: Value) -> Value {
        let resp = call(
            srv,
            json!({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}),
        );
        assert!(resp.get("error").is_none(), "rpc error for {method}: {resp}");
        resp["result"].clone()
    }

    const RC_CHN: &str = "\
chn_testbench 2

TESTBENCH rc
  instances:
    vin  vsource  x=0  y=0  value=1
    r1  res  x=160  y=0  value=1k
    c1  capa  x=0  y=320  value=100n
    vout  lab_pin  x=160  y=30
    vin  lab_pin  x=0  y=-30
    vin  lab_pin  x=160  y=-30
    gnd  gnd  x=0  y=40  net=0
    gnd  gnd  x=0  y=360  net=0

  wires:
    0 270 160 270
    0 270 0 290
    160 30 160 270
";

    #[test]
    fn ping() {
        let mut srv = server();
        let r = result(&mut srv, "ping", Value::Null);
        assert_eq!(r["ok"], true);
    }

    #[test]
    fn wave_end_to_end() {
        // ngspice ascii fixture: 4-point ramp.
        let raw = b"Title: t
Plotname: Transient Analysis
Flags: real
No. Variables: 2
No. Points: 4
Variables:
\t0\ttime\ttime
\t1\tv(out)\tvoltage
Values:
0\t0.0
\t0.0
1\t1e-9
\t1.0
2\t2e-9
\t2.0
3\t3e-9
\t3.0
";
        let mut path = std::env::temp_dir();
        path.push(format!("schemify_mcp_wave_{}.raw", std::process::id()));
        std::fs::write(&path, raw).unwrap();
        let path_str = path.to_string_lossy().into_owned();

        let mut srv = server();

        // Open via convenience method.
        let r = result(&mut srv, "wave/open", json!({"path": path_str}));
        assert_eq!(r["ok"], true);

        // Signals visible.
        let r = result(&mut srv, "query/signals", Value::Null);
        assert_eq!(r["files"][0]["blocks"][0]["variables"][1]["name"], "v(out)");

        // Plot raw + derived trace via dispatch.
        let r = result(
            &mut srv,
            "session/dispatch",
            json!({"command": {"WaveAddTrace": {"expr": "v(out)"}}}),
        );
        assert_eq!(r["ok"], true);
        result(
            &mut srv,
            "session/dispatch",
            json!({"command": {"WaveAddTrace": {"expr": "v(out) * 2"}}}),
        );

        // Style trace 0 red dashed.
        result(
            &mut srv,
            "session/dispatch",
            json!({"command": {"WaveSetTraceStyle": {
                "idx": 0, "color": "#ff0000", "line_style": "dash"
            }}}),
        );
        let r = result(&mut srv, "query/traces", Value::Null);
        assert_eq!(r["traces"][0]["color"], "#ff0000");
        assert_eq!(r["traces"][0]["line_style"], "dash");
        assert_eq!(r["traces"].as_array().unwrap().len(), 2);

        // Cursors with SI-suffix x; readouts interpolate.
        result(
            &mut srv,
            "session/dispatch",
            json!({"command": {"WaveSetCursor": {"cursor": "A", "x": "1n"}}}),
        );
        result(
            &mut srv,
            "session/dispatch",
            json!({"command": {"WaveSetCursor": {"cursor": "B", "x": 2.5e-9}}}),
        );
        let r = result(&mut srv, "query/cursors", Value::Null);
        assert!((r["dx"].as_f64().unwrap() - 1.5e-9).abs() < 1e-15);
        assert!((r["readouts"][0]["a"].as_f64().unwrap() - 1.0).abs() < 1e-9);
        assert!((r["readouts"][1]["b"].as_f64().unwrap() - 5.0).abs() < 1e-9);

        // Raw data readback.
        let r = result(
            &mut srv,
            "query/wave_data",
            json!({"trace": 1, "max_points": 4}),
        );
        assert_eq!(r["y"].as_array().unwrap().len(), 4);
        assert_eq!(r["y"][3], 6.0);

        // Unknown signal errors cleanly (status carries the message).
        let r = result(
            &mut srv,
            "session/dispatch",
            json!({"command": {"WaveAddTrace": {"expr": "v(nope)"}}}),
        );
        assert!(r["status"].as_str().unwrap().contains("unknown signal"));

        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn optimizer_end_to_end() {
        let mut srv = server();

        // Create via convenience method; instance shows up in the list.
        let r = result(&mut srv, "optimizer/new", json!({"name": "sizing"}));
        assert_eq!(r["ok"], true);
        let list = result(&mut srv, "query/optimizers", Value::Null);
        let list = list.as_array().expect("optimizers is an array");
        assert_eq!(list.len(), 1);
        assert_eq!(list[0]["name"], "sizing");
        assert_eq!(list[0]["algorithm"], "random");
        assert_eq!(list[0]["window_open"], true);
        assert_eq!(list[0]["n_params"], 0);
        assert_eq!(list[0]["n_evals"], 0);
        let id = list[0]["id"].as_u64().unwrap();

        // No params yet: suggest is null.
        let r = result(&mut srv, "optimizer/suggest", json!({"id": id}));
        assert!(r.is_null(), "suggest without params: {r}");

        // Add a param + objective; suggest returns the clamped init point.
        result(
            &mut srv,
            "optimizer/add_param",
            json!({"id": id, "name": "w", "min": 1.0, "max": 10.0, "init": 2.0}),
        );
        result(
            &mut srv,
            "optimizer/add_objective",
            json!({"id": id, "name": "gain", "target": "max"}),
        );
        let r = result(&mut srv, "optimizer/suggest", json!({"id": id}));
        assert_eq!(r["raw"][0], 2.0);
        assert_eq!(r["params"]["w"], 2.0);
        let list = result(&mut srv, "query/optimizers", Value::Null);
        assert_eq!(list[0]["n_params"], 1);
        assert_eq!(list[0]["n_objectives"], 1);

        // Suggest is pure: asking twice returns the same candidate.
        let again = result(&mut srv, "optimizer/suggest", json!({"id": id}));
        assert_eq!(again, r);

        // Report the pending candidate; history and best advance
        // (Maximize → score = -value).
        let r = result(
            &mut srv,
            "optimizer/report",
            json!({"id": id, "measured": [3.0]}),
        );
        assert_eq!(r["ok"], true);
        let st = result(&mut srv, "query/optimizer_state", json!({"id": id}));
        assert_eq!(st["id"], id);
        assert_eq!(st["window_open"], true);
        assert_eq!(st["n_evals"], 1);
        assert_eq!(st["best"]["score"], -3.0);
        assert_eq!(st["best"]["params"][0], 2.0);

        // External evaluation at explicit params via generic dispatch.
        result(
            &mut srv,
            "session/dispatch",
            json!({"command": {"OptimizerReport": {
                "id": id, "params": [5.0], "measured": [9.0]
            }}}),
        );
        let st = result(&mut srv, "query/optimizer_state", json!({"id": id}));
        assert_eq!(st["n_evals"], 2);
        assert_eq!(st["best"]["score"], -9.0);
        assert_eq!(st["best"]["params"][0], 5.0);

        // Reset clears history but keeps params/objectives.
        result(&mut srv, "optimizer/reset", json!({"id": id}));
        let st = result(&mut srv, "query/optimizer_state", json!({"id": id}));
        assert_eq!(st["n_evals"], 0);
        assert_eq!(st["params"].as_array().unwrap().len(), 1);

        // Unknown id errors; close drops the instance.
        let resp = call(
            &mut srv,
            json!({"jsonrpc": "2.0", "id": 9, "method": "query/optimizer_state",
                   "params": {"id": 999}}),
        );
        assert!(
            resp["error"]["message"]
                .as_str()
                .unwrap()
                .contains("unknown optimizer id"),
            "error: {resp}"
        );
        result(&mut srv, "optimizer/close", json!({"id": id}));
        let list = result(&mut srv, "query/optimizers", Value::Null);
        assert_eq!(list.as_array().unwrap().len(), 0);
    }

    #[test]
    fn optimizer_dispatch_marshaling_and_window_flag() {
        let mut srv = server();

        // Generic dispatch covers every Optimizer* variant shape.
        result(
            &mut srv,
            "session/dispatch",
            json!({"command": {"OptimizerNew": {}}}),
        );
        // Default name and per-id paths work; SI strings accepted for bounds.
        result(
            &mut srv,
            "session/dispatch",
            json!({"command": {"OptimizerAddParam": {
                "id": 0, "name": "c", "min": "1p", "max": "10n", "init": "100p"
            }}}),
        );
        result(
            &mut srv,
            "session/dispatch",
            json!({"command": {"OptimizerAddObjective": {
                "id": 0, "name": "bw", "target": 1e6
            }}}),
        );
        result(
            &mut srv,
            "session/dispatch",
            json!({"command": {"OptimizerSetAlgorithm": {
                "id": 0, "algorithm": "nelder-mead"
            }}}),
        );
        result(
            &mut srv,
            "session/dispatch",
            json!({"command": {"OptimizerRemoveObjective": {"id": 0, "name": "bw"}}}),
        );
        result(
            &mut srv,
            "session/dispatch",
            json!({"command": {"OptimizerRemoveParam": {"id": 0, "name": "c"}}}),
        );
        result(
            &mut srv,
            "session/dispatch",
            json!({"command": {"OptimizerSetWindowOpen": {"id": 0, "open": false}}}),
        );

        let list = result(&mut srv, "query/optimizers", Value::Null);
        assert_eq!(list[0]["name"], "Optimizer 1");
        assert_eq!(list[0]["algorithm"], "nelder-mead");
        assert_eq!(list[0]["window_open"], false);
        assert_eq!(list[0]["n_params"], 0);
        assert_eq!(list[0]["n_objectives"], 0);

        result(
            &mut srv,
            "session/dispatch",
            json!({"command": {"OptimizerClose": {"id": 0}}}),
        );
        let list = result(&mut srv, "query/optimizers", Value::Null);
        assert!(list.as_array().unwrap().is_empty());
    }

    #[test]
    fn open_content_then_query_nets() {
        let mut srv = server();
        let r = result(
            &mut srv,
            "session/open_content",
            json!({"name": "rc", "content": RC_CHN}),
        );
        assert_eq!(r["ok"], true);

        let nets = result(&mut srv, "query/nets", Value::Null);
        let nets = nets.as_array().expect("nets is an array");
        assert!(!nets.is_empty(), "expected at least one net");
        let names: Vec<&str> = nets.iter().filter_map(|n| n["name"].as_str()).collect();
        assert!(names.contains(&"vout"), "expected net 'vout' in {names:?}");
    }

    #[test]
    fn dispatch_place_device_then_query_instances() {
        let mut srv = server();
        let r = result(
            &mut srv,
            "session/dispatch",
            json!({"command": {"PlaceDevice": {
                "symbol_path": "res", "name": "R1", "x": 100, "y": 200
            }}}),
        );
        assert_eq!(r["ok"], true);

        let instances = result(&mut srv, "query/instances", Value::Null);
        let instances = instances.as_array().expect("instances is an array");
        assert_eq!(instances.len(), 1);
        assert_eq!(instances[0]["name"], "R1");
        assert_eq!(instances[0]["symbol"], "res");
        assert_eq!(instances[0]["x"], 100);
        assert_eq!(instances[0]["y"], 200);
        // Alias "res" resolves to a real kind — the device must not silently
        // vanish from the netlist (regression: kind was Unknown).
        assert_eq!(instances[0]["kind"], "Resistor");
        let netlist = result(&mut srv, "query/netlist", Value::Null);
        assert!(
            netlist.as_str().unwrap().contains("ckt.R("),
            "resistor missing from netlist: {netlist}"
        );
    }

    #[test]
    fn documentation_set_and_query_with_live_vars() {
        let mut srv = server();
        result(
            &mut srv,
            "session/dispatch",
            json!({"command": {"PlaceDevice": {
                "symbol_path": "resistor", "name": "R1", "x": 0, "y": 0
            }}}),
        );
        result(
            &mut srv,
            "session/dispatch",
            json!({"command": {"SetInstanceProp": {
                "idx": 0, "key": "value", "value": "10k"
            }}}),
        );
        result(
            &mut srv,
            "session/dispatch",
            json!({"command": {"SetDocumentation": "R1 = {{R1}}"}}),
        );

        let r = result(&mut srv, "query/documentation", Value::Null);
        assert_eq!(r["raw"], "R1 = {{R1}}");
        assert_eq!(r["rendered"], "R1 = 10k");
    }

    #[test]
    fn unknown_method_is_32601_and_plugins_list_works() {
        let mut srv = server();
        let resp = call(&mut srv, json!({"jsonrpc": "2.0", "id": 7, "method": "nope"}));
        assert_eq!(resp["error"]["code"], -32601);

        // Plugins are implemented now: list returns an array (empty here).
        let resp = call(
            &mut srv,
            json!({"jsonrpc": "2.0", "id": 8, "method": "plugins/list"}),
        );
        assert!(resp["result"].is_array(), "plugins/list result: {resp}");
    }

    #[test]
    fn channel_sink_queues_commands() {
        let (tx, rx) = std::sync::mpsc::channel();
        let app = Arc::new(Mutex::new(App::new()));
        let service = PluginService::new(
            std::env::temp_dir().join("schemify-test-plugins"),
            std::env::temp_dir().join("schemify-test-cache"),
        );
        let mut srv = McpServer::new(
            Arc::clone(&app),
            Sink::Channel(tx),
            Arc::new(Mutex::new(service)),
        );
        let r = result(&mut srv, "session/dispatch", json!({"command": "ZoomIn"}));
        assert_eq!(r["queued"], true);
        assert!(matches!(rx.try_recv(), Ok(Command::ZoomIn)));
    }
}
