//! Schemify MCP server — transport/runtime-agnostic JSON-RPC 2.0 library.
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

use std::collections::BTreeMap;
use std::fmt::Write as FmtWrite;
use std::io::{self, BufRead, Write};
use std::path::{Path, PathBuf};
use std::sync::mpsc::Sender;
use std::sync::{Arc, Mutex};

use anyhow::{anyhow, Context, Result};
use serde_json::{json, Value};

use schemify_core::config;
use schemify_core::handler::{self, App, Document, Origin, ViewMode};
use schemify_core::schemify::{Color, Command, DeviceKind, NetConnKind, Tool};
use schemify_core::sim::codegen::emit_pyspice;
use schemify_marketplace::Marketplace;
use schemify_net2schem::emit::schematic_from_subcircuit;
use schemify_plugins::PluginManager;

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
    marketplace: Marketplace,
    plugin_manager: PluginManager,
}

/// JSON-RPC error (code + message). `anyhow::Error` converts to -32603.
struct RpcErr {
    code: i32,
    message: String,
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
    pub fn new(app: Arc<Mutex<App>>, sink: Sink) -> Self {
        let plugins_dir = config::global_plugins_dir();
        let cache_dir = config::cache_dir();
        let marketplace = Marketplace::new(plugins_dir.clone(), cache_dir);
        let mut plugin_manager = PluginManager::new();
        plugin_manager.add_scan_dir(plugins_dir);
        Self {
            app,
            sink,
            marketplace,
            plugin_manager,
        }
    }

    /// Headless server owning a fresh-wrapped App.
    pub fn direct(app: App) -> Self {
        Self::new(Arc::new(Mutex::new(app)), Sink::Direct)
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

    /// Route a mutation through the configured sink: dispatch inline
    /// (headless) or forward to the live GUI loop (headful).
    fn dispatch_sink(&mut self, cmd: Command) -> Result<Value> {
        match &self.sink {
            Sink::Direct => {
                let mut app = self.lock_app()?;
                app.dispatch(cmd);
                Ok(json!({"ok": true, "status": app.state.status_msg}))
            }
            Sink::Channel(tx) => {
                tx.send(cmd)
                    .map_err(|_| anyhow!("GUI command channel closed"))?;
                Ok(json!({"ok": true, "queued": true}))
            }
        }
    }

    fn handle_method(&mut self, method: &str, params: &Value) -> Result<Value, RpcErr> {
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
                self.plugin_manager
                    .add_scan_dir(PathBuf::from(&path).join("plugins"));
                let errs = self.plugin_manager.scan_directories();
                let ids: Vec<&str> = self.plugin_manager.plugin_ids().collect();
                if errs.is_empty() {
                    json!({"ok": true, "plugins": ids})
                } else {
                    let msgs: Vec<String> = errs.iter().map(|e| e.to_string()).collect();
                    json!({"ok": true, "plugins": ids, "errors": msgs})
                }
            }
            "session/dispatch" | "document/dispatch" => {
                let payload = params.get("command").unwrap_or(params);
                let cmd = command_from_json(payload)?;
                // Commands handled at the MCP level (core handler stubs them).
                match &cmd {
                    Command::ImportSpice { path } => {
                        let mut app = self.lock_app()?;
                        import_spice(&mut app, path)?
                    }
                    Command::MarketplaceFetch => {
                        let index = self
                            .marketplace
                            .fetch_index()
                            .map_err(|e| anyhow!("{e}"))?;
                        json!({"ok": true, "count": index.plugins.len()})
                    }
                    Command::MarketplaceInstall { name } => {
                        self.marketplace
                            .install(name)
                            .map_err(|e| anyhow!("{e}"))?;
                        self.plugin_manager.scan_directories();
                        json!({"ok": true, "id": name})
                    }
                    Command::MarketplaceUninstall { name } => {
                        let _ = self.plugin_manager.stop(name);
                        self.plugin_manager.remove(name);
                        self.marketplace
                            .uninstall(name)
                            .map_err(|e| anyhow!("{e}"))?;
                        json!({"ok": true, "id": name})
                    }
                    Command::PluginsRefresh => {
                        self.plugin_manager.scan_directories();
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
                let errs = self.plugin_manager.scan_directories();
                let ids: Vec<&str> = self.plugin_manager.plugin_ids().collect();
                if errs.is_empty() {
                    json!({"ok": true, "plugins": ids})
                } else {
                    let msgs: Vec<String> = errs.iter().map(|e| e.to_string()).collect();
                    json!({"ok": true, "plugins": ids, "errors": msgs})
                }
            }
            "plugins/list" => {
                let ids: Vec<&str> = self.plugin_manager.plugin_ids().collect();
                let list: Vec<Value> = ids
                    .iter()
                    .map(|id| {
                        json!({
                            "id": id,
                            "state": self.plugin_manager.state(id)
                                .map(|s| format!("{s:?}"))
                                .unwrap_or_else(|| "Unknown".into()),
                            "error": self.plugin_manager.error_msg(id),
                        })
                    })
                    .collect();
                json!(list)
            }
            "plugins/start" => {
                let id = req_str(params, "id")?;
                self.plugin_manager
                    .start(&id)
                    .map_err(|e| anyhow!("{e}"))?;
                json!({"ok": true})
            }
            "plugins/stop" => {
                let id = req_str(params, "id")?;
                self.plugin_manager
                    .stop(&id)
                    .map_err(|e| anyhow!("{e}"))?;
                json!({"ok": true})
            }

            // ── Marketplace ──
            "marketplace/fetch" => {
                let index = self
                    .marketplace
                    .fetch_index()
                    .map_err(|e| anyhow!("{e}"))?;
                let count = index.plugins.len();
                json!({"ok": true, "count": count, "updated_at": index.updated_at})
            }
            "marketplace/search" => {
                let query = params.get("query").and_then(Value::as_str).unwrap_or("");
                let results = self.marketplace.search(query);
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
                let installed = &self.marketplace.installed().plugins;
                let updates = self.marketplace.check_updates();
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
                self.marketplace
                    .install(&id)
                    .map_err(|e| anyhow!("{e}"))?;
                self.plugin_manager.scan_directories();
                json!({"ok": true, "id": id})
            }
            "marketplace/install_local" => {
                let path = req_str(params, "path")?;
                let id = self
                    .marketplace
                    .install_from_file(Path::new(&path))
                    .map_err(|e| anyhow!("{e}"))?;
                self.plugin_manager.scan_directories();
                json!({"ok": true, "id": id})
            }
            "marketplace/uninstall" => {
                let id = req_plugin_id(params)?;
                let _ = self.plugin_manager.stop(&id);
                self.plugin_manager.remove(&id);
                self.marketplace
                    .uninstall(&id)
                    .map_err(|e| anyhow!("{e}"))?;
                json!({"ok": true, "id": id})
            }
            "marketplace/update" => {
                let id = req_plugin_id(params)?;
                let _ = self.plugin_manager.stop(&id);
                self.plugin_manager.remove(&id);
                self.marketplace
                    .uninstall(&id)
                    .map_err(|e| anyhow!("{e}"))?;
                self.marketplace
                    .install(&id)
                    .map_err(|e| anyhow!("{e}"))?;
                self.plugin_manager.scan_directories();
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

    let circuit = schemify_net2schem::netlist_to_circuit(&source)?;

    let mut opened = Vec::new();
    for sub in circuit.subcircuits.values() {
        let sch = schematic_from_subcircuit(sub, &mut app.state.interner);
        push_imported_doc(app, sch, &sub.name);
        opened.push(sub.name.clone());
    }
    let sch = schematic_from_subcircuit(&circuit.top, &mut app.state.interner);
    push_imported_doc(app, sch, &top_name);
    opened.push(top_name);

    app.state.status_msg = format!("Imported {} document(s) from {path}", opened.len());
    Ok(json!({"ok": true, "documents": opened}))
}

fn push_imported_doc(app: &mut App, schematic: schemify_core::schemify::Schematic, name: &str) {
    let (stem, kind) = schemify_core::handler::DocKind::split_name(name);
    let mut doc = Document::default();
    doc.schematic = schematic;
    doc.name = stem.to_string();
    doc.kind = kind;
    doc.origin = Origin::Memory;
    doc.dirty = true;
    app.adopt_document(doc);
}

// ════════════════════════════════════════════════════════════
// Queries
// ════════════════════════════════════════════════════════════

fn session_state(app: &App) -> Value {
    let s = &app.state;
    json!({
        "status": s.status_msg,
        "active_doc": s.active_doc,
        "active_tool": format!("{:?}", s.tool.active),
        "view_mode": view_mode_name(s.view.view_mode),
        "documents": s.documents.iter().enumerate().map(|(idx, doc)| {
            json!({
                "idx": idx,
                "name": doc.name,
                "dirty": doc.dirty,
                "origin": origin_name(&doc.origin),
                "instances": doc.schematic.instances.len(),
                "wires": doc.schematic.wires.len(),
                "lines": doc.schematic.lines.len(),
                "texts": doc.schematic.texts.len(),
            })
        }).collect::<Vec<_>>(),
    })
}

fn query_instances(app: &App) -> Value {
    let sch = app.schematic();
    Value::Array(
        (0..sch.instances.len())
            .map(|idx| {
                json!({
                    "idx": idx,
                    "name": app.resolve(sch.instances.name[idx]),
                    "symbol": app.resolve(sch.instances.symbol[idx]),
                    "kind": format!("{:?}", sch.instances.kind[idx]),
                    "x": sch.instances.x[idx],
                    "y": sch.instances.y[idx],
                    "rotation": sch.instances.flags[idx].rotation(),
                    "flip": sch.instances.flags[idx].flip(),
                })
            })
            .collect(),
    )
}

fn query_nets(app: &mut App) -> Value {
    Value::Array(
        app.connectivity()
            .net_names
            .iter()
            .enumerate()
            .map(|(idx, name)| json!({"idx": idx, "name": name}))
            .collect(),
    )
}

/// Compact human/agent-readable view of the schematic: header, ports,
/// devices with pin→net bindings, multi-endpoint nets, and DRC-ish warnings.
fn query_view(app: &mut App) -> Value {
    // Snapshot instance names/symbols/kinds before borrowing connectivity.
    let sch = app.schematic();
    let wire_count = sch.wires.len();
    let sch_name = sch.name.clone();
    let inst_info: Vec<(String, String, DeviceKind)> = (0..sch.instances.len())
        .map(|i| {
            (
                app.resolve(sch.instances.name[i]).to_owned(),
                app.resolve(sch.instances.symbol[i]).to_owned(),
                sch.instances.kind[i],
            )
        })
        .collect();

    let connectivity = app.connectivity();
    let net_names = &connectivity.net_names;
    let nets = &connectivity.nets;
    let conns = &connectivity.instance_connections;

    let is_device = |name: &str, k: DeviceKind| !k.is_non_electrical() && !name.starts_with('.');

    let mut buf = String::new();
    let device_count = inst_info.iter().filter(|(n, _, k)| is_device(n, *k)).count();
    let _ = writeln!(
        buf,
        "{sch_name} | {device_count} devices, {wire_count} wires, {} nets",
        nets.len()
    );

    // Ports
    let ports: Vec<String> = inst_info
        .iter()
        .filter(|(_, _, k)| k.is_label())
        .map(|(name, _, kind)| {
            let dir = match kind {
                DeviceKind::InputPin => "in",
                DeviceKind::OutputPin => "out",
                DeviceKind::InoutPin => "io",
                _ => "lab",
            };
            format!("{name}({dir})")
        })
        .collect();
    if !ports.is_empty() {
        let _ = writeln!(buf, "ports: {}", ports.join(" "));
    }

    // Devices — one line each: "name symbol(kind) pin=net pin=net"
    for (i, (name, symbol, kind)) in inst_info.iter().enumerate() {
        if !is_device(name, *kind) {
            continue;
        }
        let pins = conns
            .get(i)
            .map(|cs| {
                cs.iter()
                    .map(|c| {
                        let net = net_names.get(c.net_idx).map(String::as_str).unwrap_or("?");
                        format!("{}={}", c.pin_name, net)
                    })
                    .collect::<Vec<_>>()
                    .join(" ")
            })
            .unwrap_or_default();
        if symbol.is_empty() || symbol == name {
            let _ = writeln!(buf, "  {name} ({kind:?}) {pins}");
        } else {
            let _ = writeln!(buf, "  {name} {symbol}({kind:?}) {pins}");
        }
    }

    // Per-net device-pin endpoints ("net" -> ["inst.pin", ...]), skipping
    // labels/supply symbols. Used for both the nets section and warnings.
    let mut net_device_pins: BTreeMap<&str, Vec<String>> = BTreeMap::new();
    for (idx, net) in nets.iter().enumerate() {
        let nname = net_names.get(idx).map(String::as_str).unwrap_or("?");
        for ep in &net.connections {
            if let NetConnKind::InstancePin {
                instance_idx,
                pin_name,
            } = &ep.kind
            {
                let (iname, _, ikind) = &inst_info[*instance_idx];
                if is_device(iname, *ikind) {
                    let entry = net_device_pins.entry(nname).or_default();
                    let tag = format!("{iname}.{pin_name}");
                    if !entry.contains(&tag) {
                        entry.push(tag);
                    }
                }
            }
        }
    }

    let merged: BTreeMap<&str, &Vec<String>> = net_device_pins
        .iter()
        .filter(|(_, eps)| eps.len() > 1)
        .map(|(n, eps)| (*n, eps))
        .collect();
    if !merged.is_empty() {
        let _ = writeln!(buf, "nets:");
        for (nname, eps) in &merged {
            let _ = writeln!(buf, "  {nname}: {}", eps.join(" "));
        }
    }

    // Warnings: floating pins, single-endpoint stub nets, isolated devices.
    let mut warnings: Vec<String> = Vec::new();
    for (i, (name, _, kind)) in inst_info.iter().enumerate() {
        if !is_device(name, *kind) {
            continue;
        }
        let Some(cs) = conns.get(i) else { continue };
        if cs.is_empty() {
            warnings.push(format!("{name} has no pin connections — fully isolated"));
            continue;
        }
        for pin in cs.iter().filter(|c| {
            net_names
                .get(c.net_idx)
                .is_none_or(|n| n.is_empty() || n == "?")
        }) {
            let hint = pin_connection_hint(*kind, pin.pin_name, &merged);
            if hint.is_empty() {
                warnings.push(format!("{name}.{} is floating", pin.pin_name));
            } else {
                warnings.push(format!("{name}.{} is floating — {hint}", pin.pin_name));
            }
        }
    }
    for (nname, eps) in &net_device_pins {
        if eps.len() == 1 && !nname.is_empty() && *nname != "?" {
            warnings.push(format!(
                "net '{nname}' only connects to {} — stub or missing wire",
                eps[0]
            ));
        }
    }

    if !warnings.is_empty() {
        let _ = writeln!(buf, "warnings:");
        for w in &warnings {
            let _ = writeln!(buf, "  ⚠ {w}");
        }
    }

    json!(buf.trim_end())
}

fn pin_connection_hint(
    kind: DeviceKind,
    pin: &str,
    existing_nets: &BTreeMap<&str, &Vec<String>>,
) -> String {
    use DeviceKind::*;
    let has = |n: &str| existing_nets.contains_key(n);
    let gnd = *["0", "GND", "gnd"].iter().find(|n| has(n)).unwrap_or(&"0");
    let vdd = *["VDD", "vdd"].iter().find(|n| has(n)).unwrap_or(&"VDD");

    match (kind, pin) {
        (Nmos4 | Nmos3 | Nmos4Depl | NmosSub, "b") => {
            format!("typically connect to {gnd} (substrate)")
        }
        (Pmos4 | Pmos3 | PmosSub, "b") => format!("typically connect to {vdd} (n-well)"),
        (Nmos4 | Nmos3 | Nmos4Depl | NmosSub, "s") => {
            format!("typically connect to {gnd} or signal net")
        }
        (Pmos4 | Pmos3 | PmosSub, "s") => format!("typically connect to {vdd} or signal net"),
        (Nmos4 | Nmos3 | Pmos4 | Pmos3, "d") => "connect to output signal net".to_string(),
        (Resistor | Capacitor | Inductor, "n") => format!("connect to {gnd} or signal net"),
        (Resistor | Capacitor | Inductor, "p") => "connect to signal net".to_string(),
        (Vsource | Isource, "n") => format!("typically connect to {gnd}"),
        (Npn | Pnp, "e") => format!("typically connect to {gnd} or signal"),
        (Npn | Pnp, "c") => format!("typically connect to {vdd} or signal"),
        _ => String::new(),
    }
}

// ════════════════════════════════════════════════════════════
// Param marshaling helpers
// ════════════════════════════════════════════════════════════

fn save_path(app: &App, params: &Value) -> Result<PathBuf> {
    if let Some(path) = params.get("path").and_then(Value::as_str) {
        return Ok(PathBuf::from(path));
    }
    match app
        .state
        .documents
        .get(app.state.active_doc)
        .map(|doc| &doc.origin)
    {
        Some(Origin::File(path)) => Ok(path.clone()),
        _ => Err(anyhow!("save path required for unsaved documents")),
    }
}

fn req_str(params: &Value, key: &str) -> Result<String> {
    params
        .get(key)
        .and_then(Value::as_str)
        .map(ToOwned::to_owned)
        .ok_or_else(|| anyhow!("missing string parameter '{key}'"))
}

/// Plugin id for marketplace methods: `id` preferred, `name` accepted
/// for backwards compatibility.
fn req_plugin_id(params: &Value) -> Result<String> {
    req_str(params, "id")
        .or_else(|_| req_str(params, "name"))
        .map_err(|_| anyhow!("missing string parameter 'id'"))
}

fn origin_name(origin: &Origin) -> &'static str {
    match origin {
        Origin::Unsaved => "unsaved",
        Origin::Buffer(_) => "buffer",
        Origin::File(_) => "file",
        Origin::Memory => "memory",
    }
}

fn view_mode_name(mode: ViewMode) -> &'static str {
    match mode {
        ViewMode::Schematic => "schematic",
        ViewMode::Symbol => "symbol",
        ViewMode::Documentation => "documentation",
    }
}

// ════════════════════════════════════════════════════════════
// Waveform queries — read the app-wide wave viewer. External AI drives the
// viewer through these + dispatched Wave* commands (no embedded assistant).
// ════════════════════════════════════════════════════════════

fn wave_of(app: &App) -> Result<&schemify_core::wave::WaveState> {
    app.state
        .wave
        .as_deref()
        .ok_or_else(|| anyhow!("no waveform loaded (use wave/open first)"))
}

fn kind_str(k: schemify_wave::VarKind) -> &'static str {
    use schemify_wave::VarKind::*;
    match k {
        Time => "time",
        Frequency => "frequency",
        Voltage => "voltage",
        Current => "current",
        Other => "other",
    }
}

fn color_hex(c: Color) -> String {
    format!("#{:02x}{:02x}{:02x}", c.r, c.g, c.b)
}

/// All loaded files → analysis blocks → variables. The AI's signal browser.
fn query_signals(app: &App) -> Result<Value> {
    let w = wave_of(app)?;
    let files: Vec<Value> = w
        .files
        .iter()
        .enumerate()
        .map(|(fi, f)| {
            let blocks: Vec<Value> = f
                .plots
                .iter()
                .enumerate()
                .map(|(bi, p)| {
                    let vars: Vec<Value> = p
                        .variables
                        .iter()
                        .map(|v| {
                            json!({
                                "name": v.name,
                                "kind": kind_str(v.kind),
                                "unit": v.kind.unit(),
                            })
                        })
                        .collect();
                    json!({
                        "idx": bi,
                        "plotname": p.plotname,
                        "complex": p.complex,
                        "n_points": p.n_points,
                        "n_steps": p.steps.len(),
                        "variables": vars,
                    })
                })
                .collect();
            json!({
                "idx": fi,
                "name": f.name,
                "path": f.path,
                "blocks": blocks,
            })
        })
        .collect();
    Ok(json!({ "files": files }))
}

/// Plotted traces + pane/view state.
fn query_traces(app: &App) -> Result<Value> {
    let w = wave_of(app)?;
    let traces: Vec<Value> = w
        .traces
        .iter()
        .enumerate()
        .map(|(i, t)| {
            json!({
                "idx": i,
                "expr": t.expr,
                "file": t.file,
                "block": t.block,
                "pane": t.pane,
                "color": color_hex(w.trace_color(i)),
                "width": t.style.width,
                "line_style": match t.style.line_style {
                    schemify_core::wave::LineStyle::Solid => "solid",
                    schemify_core::wave::LineStyle::Dash => "dash",
                    schemify_core::wave::LineStyle::Dot => "dot",
                },
                "visible": t.style.visible,
            })
        })
        .collect();
    Ok(json!({
        "traces": traces,
        "panes": w.panes.len(),
        "active_pane": w.active_pane,
        "x_log": w.x_log,
        "x_range": w.x_range,
        "window_open": app.state.wave_window_open,
    }))
}

/// Cursor positions, ΔX, 1/ΔX, and per-trace Y readouts at each cursor.
fn query_cursors(app: &App) -> Result<Value> {
    let w = wave_of(app)?;
    let readouts: Vec<Value> = w
        .traces
        .iter()
        .enumerate()
        .map(|(i, t)| {
            let ya = w
                .cursor_a
                .visible
                .then(|| w.value_at(i as u32, w.cursor_a.x))
                .flatten();
            let yb = w
                .cursor_b
                .visible
                .then(|| w.value_at(i as u32, w.cursor_b.x))
                .flatten();
            let dy = match (ya, yb) {
                (Some(a), Some(b)) => Some(b - a),
                _ => None,
            };
            json!({
                "trace": i,
                "expr": t.expr,
                "a": ya,
                "b": yb,
                "dy": dy,
            })
        })
        .collect();
    let both = w.cursor_a.visible && w.cursor_b.visible;
    let dx = both.then(|| w.cursor_b.x - w.cursor_a.x);
    Ok(json!({
        "a": {"x": w.cursor_a.x, "visible": w.cursor_a.visible},
        "b": {"x": w.cursor_b.x, "visible": w.cursor_b.visible},
        "dx": dx,
        "inv_dx": dx.and_then(|d| (d != 0.0).then(|| 1.0 / d)),
        "readouts": readouts,
    }))
}

/// Sampled (x, y) data of one trace, strided down to `max_points`
/// (default 1000) so the AI can read actual waveform values.
fn query_wave_data(app: &App, params: &Value) -> Result<Value> {
    let w = wave_of(app)?;
    let ti: usize = num(params, "trace")?;
    let max_points = opt_num::<i64>(params, "max_points", 1000)?.max(1) as usize;
    let t = w
        .traces
        .get(ti)
        .ok_or_else(|| anyhow!("bad trace index {ti}"))?;
    let cached = t
        .cached
        .as_ref()
        .ok_or_else(|| anyhow!("trace {ti} has no evaluated data"))?;
    let xs = w
        .trace_x(t)
        .ok_or_else(|| anyhow!("trace {ti} has no x data"))?;
    let n = cached.re.len().min(xs.len());
    let stride = n.div_ceil(max_points).max(1);
    let x: Vec<f64> = xs[..n].iter().step_by(stride).copied().collect();
    let y: Vec<f64> = cached.re[..n].iter().step_by(stride).copied().collect();
    Ok(json!({
        "trace": ti,
        "expr": t.expr,
        "total_points": n,
        "stride": stride,
        "x": x,
        "y": y,
    }))
}

// ════════════════════════════════════════════════════════════
// Optimizer queries — read the App's optimizer instances. External AI runs
// the ask-tell loop via optimizer/suggest (pure read) + optimizer/report.
// ════════════════════════════════════════════════════════════

fn find_optimizer(app: &App, id: u32) -> Result<&handler::OptimizerInstance> {
    app.state
        .optimizers
        .iter()
        .find(|o| o.id == id)
        .ok_or_else(|| anyhow!("unknown optimizer id {id}"))
}

/// All optimizer instances, one summary row each.
fn query_optimizers(app: &App) -> Value {
    Value::Array(
        app.state
            .optimizers
            .iter()
            .map(|o| {
                json!({
                    "id": o.id,
                    "name": o.opt.name(),
                    "algorithm": o.opt.algorithm().as_str(),
                    "window_open": o.window_open,
                    "n_params": o.opt.params().len(),
                    "n_objectives": o.opt.objectives().len(),
                    "n_evals": o.opt.n_evals(),
                })
            })
            .collect(),
    )
}

/// Full state of one instance: config, flat history, pending suggestion,
/// derived best/n_evals — plus the instance id and window flag.
fn query_optimizer_state(app: &App, params: &Value) -> Result<Value> {
    let id: u32 = num(params, "id")?;
    let o = find_optimizer(app, id)?;
    let mut v = o.opt.to_json();
    v["id"] = json!(o.id);
    v["window_open"] = json!(o.window_open);
    Ok(v)
}

/// The pending candidate as `{params: {name: value}, raw: [..]}`, or null
/// when no params are defined. Read-only: `suggest()` does not mutate —
/// only optimizer/report records an evaluation and advances the algorithm.
fn optimizer_suggest(app: &App, params: &Value) -> Result<Value> {
    let id: u32 = num(params, "id")?;
    let o = find_optimizer(app, id)?;
    Ok(match o.opt.suggest() {
        Some(raw) => {
            let named: serde_json::Map<String, Value> = o
                .opt
                .params()
                .iter()
                .zip(raw)
                .map(|(p, v)| (p.name.clone(), json!(v)))
                .collect();
            json!({"params": named, "raw": raw})
        }
        None => Value::Null,
    })
}

// ════════════════════════════════════════════════════════════
// JSON → Command (core's Command enum carries no serde derives,
// so marshal serde's externally-tagged shape by hand:
//   "ZoomIn"  |  {"CloseTab": 2}  |  {"PlaceDevice": {...}} )
// ════════════════════════════════════════════════════════════

pub fn command_from_json(v: &Value) -> Result<Command> {
    if let Some(name) = v.as_str() {
        return unit_command(name).ok_or_else(|| anyhow!("unknown unit command '{name}'"));
    }
    let obj = v
        .as_object()
        .filter(|o| o.len() == 1)
        .context("command must be a string or a single-key {Variant: params} object")?;
    let (name, p) = obj.iter().next().unwrap();
    if let Some(cmd) = unit_command(name) {
        return Ok(cmd);
    }

    use Command::*;
    Ok(match name.as_str() {
        // Tuple variants
        "CloseTab" => CloseTab(scalar_usize(p)?),
        "SwitchTab" => SwitchTab(scalar_usize(p)?),
        "DeleteInstance" => DeleteInstance(scalar_usize(p)?),
        "DeleteWire" => DeleteWire(scalar_usize(p)?),
        "DeleteBus" => DeleteBus(scalar_usize(p)?),
        "DeleteBusRipper" => DeleteBusRipper(scalar_usize(p)?),
        "SetSpiceCode" => SetSpiceCode(scalar_str(p)?),
        "SetDocumentation" => SetDocumentation(scalar_str(p)?),
        "SetStimulusLang" => SetStimulusLang(scalar_str(p)?),
        "SetSimBackend" => SetSimBackend(scalar_str(p)?),
        "SetSimCorner" => SetSimCorner(scalar_str(p)?),
        "SetTool" => SetTool(tool_from_name(&scalar_str(p)?)?),

        // Struct variants
        "PlaceDevice" => PlaceDevice {
            symbol_path: req_str(p, "symbol_path")?,
            name: req_str(p, "name")?,
            x: num(p, "x")?,
            y: num(p, "y")?,
            rotation: opt_num(p, "rotation", 0u8)?,
            flip: p.get("flip").and_then(Value::as_bool).unwrap_or(false),
        },
        "AddWire" => AddWire {
            x0: num(p, "x0")?,
            y0: num(p, "y0")?,
            x1: num(p, "x1")?,
            y1: num(p, "y1")?,
        },
        "AddLine" => AddLine {
            x0: num(p, "x0")?,
            y0: num(p, "y0")?,
            x1: num(p, "x1")?,
            y1: num(p, "y1")?,
        },
        "AddRect" => AddRect {
            x: num(p, "x")?,
            y: num(p, "y")?,
            w: num(p, "w")?,
            h: num(p, "h")?,
        },
        "AddCircle" => AddCircle {
            cx: num(p, "cx")?,
            cy: num(p, "cy")?,
            radius: num(p, "radius")?,
        },
        "AddArc" => AddArc {
            cx: num(p, "cx")?,
            cy: num(p, "cy")?,
            radius: num(p, "radius")?,
            start: float(p, "start")?,
            sweep: float(p, "sweep")?,
        },
        "AddText" => AddText {
            x: num(p, "x")?,
            y: num(p, "y")?,
            content: req_str(p, "content")?,
        },
        "AddPolygon" => AddPolygon {
            points: points_array(p)?,
        },
        "MoveInstance" => MoveInstance {
            idx: num(p, "idx")?,
            dx: num(p, "dx")?,
            dy: num(p, "dy")?,
        },
        "MoveWire" => MoveWire {
            idx: num(p, "idx")?,
            dx: num(p, "dx")?,
            dy: num(p, "dy")?,
        },
        "MoveSelected" => MoveSelected {
            dx: num(p, "dx")?,
            dy: num(p, "dy")?,
        },
        "SetInstanceProp" => SetInstanceProp {
            idx: num(p, "idx")?,
            key: req_str(p, "key")?,
            value: req_str(p, "value")?,
        },
        "RenameInstance" => RenameInstance {
            idx: num(p, "idx")?,
            new_name: req_str(p, "new_name")?,
        },
        "SetWireColor" => SetWireColor {
            idx: num(p, "idx")?,
            color: Color::from_hex(&req_str(p, "color")?).map_err(|e| anyhow!(e))?,
        },
        "AddBus" => AddBus {
            label: req_str(p, "label")?,
            width: num(p, "width")?,
            start_bit: opt_num(p, "start_bit", 0u16)?,
            x0: num(p, "x0")?,
            y0: num(p, "y0")?,
            x1: num(p, "x1")?,
            y1: num(p, "y1")?,
        },
        "SetBusWidth" => SetBusWidth {
            idx: num(p, "idx")?,
            width: num(p, "width")?,
        },
        "RenameBus" => RenameBus {
            idx: num(p, "idx")?,
            new_name: req_str(p, "new_name")?,
        },
        "AddBusRipper" => AddBusRipper {
            bus_idx: num(p, "bus_idx")?,
            bit: num(p, "bit")?,
            x: num(p, "x")?,
            y: num(p, "y")?,
            direction: opt_num(p, "direction", 0u8)?,
        },
        "SplitWire" => SplitWire {
            idx: num(p, "idx")?,
            x: num(p, "x")?,
            y: num(p, "y")?,
        },
        "ExportSpice" => ExportSpice {
            path: req_str(p, "path")?,
        },
        "ImportSpice" => ImportSpice {
            path: req_str(p, "path")?,
        },
        "MarketplaceInstall" => MarketplaceInstall {
            name: req_str(p, "name")?,
        },
        "MarketplaceUninstall" => MarketplaceUninstall {
            name: req_str(p, "name")?,
        },

        // Waveform viewer. {"WaveOpen": "f.raw"} and {"WaveOpen": {"path":
        // "f.raw"}} both accepted; x positions accept numbers or SI-suffix
        // strings ("10n", "2.5meg").
        "WaveOpen" => WaveOpen {
            path: scalar_str(p).or_else(|_| req_str(p, "path"))?,
        },
        "WaveAddTrace" => WaveAddTrace {
            expr: scalar_str(p).or_else(|_| req_str(p, "expr"))?,
            file: opt_u16(p, "file")?,
            block: opt_num(p, "block", 0u16)?,
            pane: opt_u16(p, "pane")?,
        },
        "WaveRemoveTrace" => WaveRemoveTrace(scalar_usize(p)? as u32),
        "WaveSetTraceStyle" => WaveSetTraceStyle {
            idx: num(p, "idx")?,
            color: match p.get("color").and_then(Value::as_str) {
                Some(hex) => Color::from_hex(hex).map_err(|e| anyhow!(e))?,
                None => Color::NONE, // auto palette
            },
            width: p
                .get("width")
                .and_then(Value::as_f64)
                .map(|f| f as f32)
                .unwrap_or(1.5),
            line_style: line_style_code(p)?,
            visible: p.get("visible").and_then(Value::as_bool).unwrap_or(true),
        },
        "WaveRemovePane" => WaveRemovePane(scalar_u16(p)?),
        "WaveSetActivePane" => WaveSetActivePane(scalar_u16(p)?),
        "WaveSetCursor" => WaveSetCursor {
            cursor: cursor_code(p)?,
            x: f64_or_si(p, "x")?,
            visible: p.get("visible").and_then(Value::as_bool).unwrap_or(true),
        },
        "WaveSetXLog" => WaveSetXLog(
            p.as_bool()
                .or_else(|| p.get("on").and_then(Value::as_bool))
                .ok_or_else(|| anyhow!("expected boolean payload"))?,
        ),
        "WaveSetXRange" => WaveSetXRange {
            min: f64_or_si(p, "min")?,
            max: f64_or_si(p, "max")?,
        },
        "WaveSetYRange" => WaveSetYRange {
            pane: opt_num(p, "pane", 0u16)?,
            min: f64_or_si(p, "min")?,
            max: f64_or_si(p, "max")?,
        },
        "WaveExportCsv" => WaveExportCsv {
            path: scalar_str(p).or_else(|_| req_str(p, "path"))?,
        },

        // Optimizer. {"OptimizerNew": "amp"} and {"OptimizerNew": {"name":
        // "amp"}} both accepted; bounds accept numbers or SI-suffix strings.
        "OptimizerNew" => OptimizerNew {
            name: scalar_str(p)
                .ok()
                .or_else(|| p.get("name").and_then(Value::as_str).map(ToOwned::to_owned))
                .unwrap_or_default(),
        },
        "OptimizerClose" => OptimizerClose { id: num(p, "id")? },
        "OptimizerSetWindowOpen" => OptimizerSetWindowOpen {
            id: num(p, "id")?,
            open: req_bool(p, "open")?,
        },
        "OptimizerAddParam" => OptimizerAddParam {
            id: num(p, "id")?,
            name: req_str(p, "name")?,
            min: f64_or_si(p, "min")?,
            max: f64_or_si(p, "max")?,
            init: f64_or_si(p, "init")?,
        },
        "OptimizerRemoveParam" => OptimizerRemoveParam {
            id: num(p, "id")?,
            name: req_str(p, "name")?,
        },
        "OptimizerAddObjective" => OptimizerAddObjective {
            id: num(p, "id")?,
            name: req_str(p, "name")?,
            target: target_str(p)?,
            weight: opt_f64(p, "weight", 1.0)?,
        },
        "OptimizerRemoveObjective" => OptimizerRemoveObjective {
            id: num(p, "id")?,
            name: req_str(p, "name")?,
        },
        "OptimizerSetAlgorithm" => OptimizerSetAlgorithm {
            id: num(p, "id")?,
            algorithm: req_str(p, "algorithm")?,
        },
        "OptimizerReport" => OptimizerReport {
            id: num(p, "id")?,
            params: opt_f64_vec(p, "params")?,
            measured: f64_vec(p, "measured")?,
        },
        "OptimizerReset" => OptimizerReset { id: num(p, "id")? },

        other => return Err(anyhow!("unknown command '{other}'")),
    })
}

fn unit_command(name: &str) -> Option<Command> {
    use Command::*;
    Some(match name {
        "ZoomIn" => ZoomIn,
        "ZoomOut" => ZoomOut,
        "ZoomFit" => ZoomFit,
        "ZoomReset" => ZoomReset,
        "ToggleFullscreen" => ToggleFullscreen,
        "ToggleColorScheme" => ToggleColorScheme,
        "ToggleGrid" => ToggleGrid,
        "FileNew" => FileNew,
        "FileOpen" => FileOpen,
        "FileSave" => FileSave,
        "FileSaveAs" => FileSaveAs,
        "NewTab" => NewTab,
        "CloseActiveTab" => CloseActiveTab,
        "ReloadFromDisk" => ReloadFromDisk,
        "SelectAll" => SelectAll,
        "SelectNone" => SelectNone,
        "InvertSelection" => InvertSelection,
        "Copy" => Copy,
        "Cut" => Cut,
        "Paste" => Paste,
        "OpenFindDialog" => OpenFindDialog,
        "OpenPropsDialog" => OpenPropsDialog,
        "OpenSettings" => OpenSettings,
        "OpenSpiceCodeEditor" => OpenSpiceCodeEditor,
        "OpenNewPrimDialog" => OpenNewPrimDialog,
        "OpenMarketplace" => OpenMarketplace,
        "OpenImportDialog" => OpenImportDialog,
        "OpenLibraryBrowser" => OpenLibraryBrowser,
        "OpenFileExplorer" => OpenFileExplorer,
        "Undo" => Undo,
        "Redo" => Redo,
        "DeleteSelected" => DeleteSelected,
        "DuplicateSelected" => DuplicateSelected,
        "RotateCw" => RotateCw,
        "RotateCcw" => RotateCcw,
        "FlipHorizontal" => FlipHorizontal,
        "FlipVertical" => FlipVertical,
        "NudgeUp" => NudgeUp,
        "NudgeDown" => NudgeDown,
        "NudgeLeft" => NudgeLeft,
        "NudgeRight" => NudgeRight,
        "AlignToGrid" => AlignToGrid,
        "RunSim" => RunSim,
        "ExportNetlist" => ExportNetlist,
        "GenerateSymbolFromSchematic" => GenerateSymbolFromSchematic,
        "AlignLeft" => AlignLeft,
        "AlignRight" => AlignRight,
        "AlignTop" => AlignTop,
        "AlignBottom" => AlignBottom,
        "AlignCenterH" => AlignCenterH,
        "AlignCenterV" => AlignCenterV,
        "DistributeH" => DistributeH,
        "DistributeV" => DistributeV,
        "MarketplaceFetch" => MarketplaceFetch,
        "PluginsRefresh" => PluginsRefresh,
        "ReloadProjectConfig" => ReloadProjectConfig,
        "WaveReload" => WaveReload,
        "WaveClearTraces" => WaveClearTraces,
        "WaveAddPane" => WaveAddPane,
        "WaveZoomFit" => WaveZoomFit,
        _ => return None,
    })
}

fn tool_from_name(s: &str) -> Result<Tool> {
    Ok(match s.to_ascii_lowercase().as_str() {
        "select" => Tool::Select,
        "wire" => Tool::Wire,
        "bus" => Tool::Bus,
        "busripper" | "bus_ripper" => Tool::BusRipper,
        "move" => Tool::Move,
        "pan" => Tool::Pan,
        "line" => Tool::Line,
        "rect" => Tool::Rect,
        "polygon" => Tool::Polygon,
        "arc" => Tool::Arc,
        "circle" => Tool::Circle,
        "text" => Tool::Text,
        other => return Err(anyhow!("unknown tool '{other}'")),
    })
}

/// Required integer field, range-checked into the target type.
fn num<T: TryFrom<i64>>(p: &Value, key: &str) -> Result<T> {
    let n = p
        .get(key)
        .and_then(Value::as_i64)
        .ok_or_else(|| anyhow!("missing integer parameter '{key}'"))?;
    T::try_from(n).map_err(|_| anyhow!("parameter '{key}' out of range"))
}

/// Optional integer field with default.
fn opt_num<T: TryFrom<i64>>(p: &Value, key: &str, default: T) -> Result<T> {
    match p.get(key) {
        None | Some(Value::Null) => Ok(default),
        Some(_) => num(p, key),
    }
}

fn float(p: &Value, key: &str) -> Result<f32> {
    p.get(key)
        .and_then(Value::as_f64)
        .map(|f| f as f32)
        .ok_or_else(|| anyhow!("missing number parameter '{key}'"))
}

fn scalar_usize(p: &Value) -> Result<usize> {
    p.as_u64()
        .map(|n| n as usize)
        .ok_or_else(|| anyhow!("expected integer payload"))
}

fn scalar_u16(p: &Value) -> Result<u16> {
    scalar_usize(p).and_then(|n| u16::try_from(n).map_err(|_| anyhow!("index out of range")))
}

/// Optional u16 field — absent/null stays `None` (core picks the default).
fn opt_u16(p: &Value, key: &str) -> Result<Option<u16>> {
    match p.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(_) => num(p, key).map(Some),
    }
}

/// Required f64 accepting a JSON number or an SI-suffix string ("10n").
fn f64_or_si(p: &Value, key: &str) -> Result<f64> {
    match p.get(key) {
        Some(Value::Number(n)) => n
            .as_f64()
            .ok_or_else(|| anyhow!("parameter '{key}' is not a finite number")),
        Some(Value::String(s)) => schemify_wave::parse_si(s)
            .ok_or_else(|| anyhow!("parameter '{key}': cannot parse '{s}'")),
        _ => Err(anyhow!("missing number parameter '{key}'")),
    }
}

/// Optional f64 (number or SI-suffix string) with default.
fn opt_f64(p: &Value, key: &str, default: f64) -> Result<f64> {
    match p.get(key) {
        None | Some(Value::Null) => Ok(default),
        Some(_) => f64_or_si(p, key),
    }
}

/// Required boolean field.
fn req_bool(p: &Value, key: &str) -> Result<bool> {
    p.get(key)
        .and_then(Value::as_bool)
        .ok_or_else(|| anyhow!("missing boolean parameter '{key}'"))
}

/// Required array of f64.
fn f64_vec(p: &Value, key: &str) -> Result<Vec<f64>> {
    p.get(key)
        .and_then(Value::as_array)
        .ok_or_else(|| anyhow!("missing array parameter '{key}'"))?
        .iter()
        .map(|v| {
            v.as_f64()
                .ok_or_else(|| anyhow!("parameter '{key}' must be an array of numbers"))
        })
        .collect()
}

/// Optional array of f64 — absent/null stays `None`.
fn opt_f64_vec(p: &Value, key: &str) -> Result<Option<Vec<f64>>> {
    match p.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(_) => f64_vec(p, key).map(Some),
    }
}

/// Objective target: "min", "max", or a number (string or JSON number) to
/// approach. Core parses the string; numbers pass through as their text.
fn target_str(p: &Value) -> Result<String> {
    match p.get("target") {
        Some(Value::String(s)) => Ok(s.clone()),
        Some(Value::Number(n)) => Ok(n.to_string()),
        _ => Err(anyhow!(
            "missing parameter 'target' (\"min\", \"max\", or a number)"
        )),
    }
}

/// Cursor selector: "A"/"B" (case-insensitive) or 0/1.
fn cursor_code(p: &Value) -> Result<u8> {
    match p.get("cursor") {
        Some(Value::String(s)) if s.eq_ignore_ascii_case("a") => Ok(0),
        Some(Value::String(s)) if s.eq_ignore_ascii_case("b") => Ok(1),
        Some(Value::Number(n)) if n.as_u64() == Some(0) => Ok(0),
        Some(Value::Number(n)) if n.as_u64() == Some(1) => Ok(1),
        _ => Err(anyhow!("cursor must be \"A\", \"B\", 0, or 1")),
    }
}

/// Line style: "solid"/"dash"/"dot" or 0/1/2; default solid.
fn line_style_code(p: &Value) -> Result<u8> {
    match p.get("line_style") {
        None | Some(Value::Null) => Ok(0),
        Some(Value::String(s)) => match s.to_ascii_lowercase().as_str() {
            "solid" => Ok(0),
            "dash" | "dashed" => Ok(1),
            "dot" | "dotted" => Ok(2),
            other => Err(anyhow!("unknown line style '{other}'")),
        },
        Some(Value::Number(n)) if n.as_u64().is_some_and(|v| v <= 2) => {
            Ok(n.as_u64().unwrap() as u8)
        }
        _ => Err(anyhow!("line_style must be solid|dash|dot or 0..=2")),
    }
}

fn scalar_str(p: &Value) -> Result<String> {
    p.as_str()
        .map(ToOwned::to_owned)
        .ok_or_else(|| anyhow!("expected string payload"))
}

fn points_array(p: &Value) -> Result<Vec<[i32; 2]>> {
    p.get("points")
        .and_then(Value::as_array)
        .context("missing 'points' array")?
        .iter()
        .map(|pt| {
            let xy = pt.as_array().filter(|a| a.len() == 2)?;
            Some([xy[0].as_i64()? as i32, xy[1].as_i64()? as i32])
        })
        .collect::<Option<Vec<_>>>()
        .context("polygon points must be [x, y] integer pairs")
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
        let mut srv = McpServer::new(Arc::clone(&app), Sink::Channel(tx));
        let r = result(&mut srv, "session/dispatch", json!({"command": "ZoomIn"}));
        assert_eq!(r["queued"], true);
        assert!(matches!(rx.try_recv(), Ok(Command::ZoomIn)));
    }
}
