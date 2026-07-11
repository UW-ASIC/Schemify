//! Display-side plugin host: owns the [`PluginManager`], drains its per-tick
//! actions into plain GUI state (panels, commands, overlays, theme
//! overrides), answers plugin queries from the core [`App`], and forwards
//! core-side requests (F6 refresh, `PluginCommand`) to plugin processes.
//!
//! Everything here is plain data + loops: panels/commands/overlays are
//! upserted by linear scan, theme overrides resolve by one pass over a
//! priority-sorted vec.

use std::path::Path;

use schemify_core::config::global_plugins_dir;
use schemify_core::handler::App;
use schemify_plugins::{
    methods, CommandRegistration, OverlayLayer, PanelRegistration, PluginHostAction,
    PluginLifecycle, PluginManager, ThemeOverride, WidgetNode, INTERNAL_ERROR,
};
use serde_json::{json, Value};

use crate::state::Theme;

/// One plugin-registered panel plus its current widget tree.
pub struct PanelEntry {
    pub reg: PanelRegistration,
    pub widgets: Vec<WidgetNode>,
    pub visible: bool,
}

/// One host-side log line from a plugin.
pub struct LogEntry {
    pub plugin_id: String,
    pub level: String,
    pub message: String,
}

const LOG_CAP: usize = 256;

/// A widget interaction waiting to be sent back to its plugin.
pub struct PendingUiAction {
    pub plugin_id: String,
    pub action: String,
    pub payload: Option<Value>,
}

pub struct PluginHost {
    pub manager: PluginManager,
    pub panels: Vec<PanelEntry>,
    pub commands: Vec<CommandRegistration>,
    pub overlays: Vec<OverlayLayer>,
    /// Sorted ascending by (priority, plugin_id); applied in order so the
    /// highest priority wins.
    theme_overrides: Vec<ThemeOverride>,
    /// Set when overrides changed; cleared by the frame loop after it
    /// re-resolves the theme.
    pub theme_dirty: bool,
    pub logs: Vec<LogEntry>,
    /// Widget interactions collected during panel rendering, flushed to
    /// plugins on the next pump.
    pub ui_actions: Vec<PendingUiAction>,
    /// (active_doc, generation) at the last schematic_changed broadcast.
    last_generation: (usize, u64),
    /// Hash of the active selection at the last selection_changed broadcast.
    last_selection: u64,
}

impl PluginHost {
    pub fn new() -> Self {
        Self {
            manager: PluginManager::new(),
            panels: Vec::new(),
            commands: Vec::new(),
            overlays: Vec::new(),
            theme_overrides: Vec::new(),
            theme_dirty: false,
            logs: Vec::new(),
            ui_actions: Vec::new(),
            last_generation: (usize::MAX, u64::MAX),
            last_selection: 0,
        }
    }

    /// Rescan plugin directories and start every startable plugin.
    /// Returns a one-line status summary.
    pub fn refresh(&mut self, project_dir: &Path) -> String {
        self.manager.add_scan_dir(global_plugins_dir());
        if !project_dir.as_os_str().is_empty() {
            self.manager.add_scan_dir(project_dir.join("plugins"));
        }
        for err in self.manager.scan_directories() {
            self.push_log("host", "error", err.to_string());
        }

        let ids: Vec<String> = self.manager.plugin_ids().map(str::to_owned).collect();
        for id in &ids {
            if matches!(
                self.manager.state(id),
                Some(
                    PluginLifecycle::Discovered
                        | PluginLifecycle::Stopped
                        | PluginLifecycle::Error
                )
            ) {
                if let Err(e) = self.manager.start(id) {
                    self.push_log(id, "error", e.to_string());
                }
            }
        }

        let (mut running, mut errored) = (0usize, 0usize);
        for id in &ids {
            match self.manager.state(id) {
                Some(PluginLifecycle::Running) => running += 1,
                Some(PluginLifecycle::Error) => errored += 1,
                _ => {}
            }
        }
        if errored > 0 {
            format!("Plugins: {running} running, {errored} failed")
        } else {
            format!("Plugins: {running} running")
        }
    }

    /// True while any plugin process is live (drives repaint scheduling).
    pub fn any_running(&self) -> bool {
        let mut ids = self.manager.plugin_ids();
        ids.any(|id| self.manager.state(id) == Some(PluginLifecycle::Running))
    }

    /// Per-frame hook: drain core requests, pump plugin messages into GUI
    /// state, answer queries, broadcast change events, flush UI actions.
    pub fn pump(&mut self, app: &mut App, theme: &Theme) {
        // 1. Core-side requests (F6 / PluginCommand dispatched in core).
        if app.state.plugin_refresh_requested {
            app.state.plugin_refresh_requested = false;
            let project_dir = app.state.project_dir.clone();
            app.state.status_msg = self.refresh(&project_dir);
        }
        for (tag, _payload) in std::mem::take(&mut app.state.pending_plugin_commands) {
            let Some((plugin_id, command)) = tag.split_once(':') else {
                self.push_log("host", "warn", format!("bad plugin command tag: {tag}"));
                continue;
            };
            let params = json!({ "command": command });
            if let Err(e) = self
                .manager
                .notify(plugin_id, methods::COMMAND_INVOKE, Some(params))
            {
                self.push_log(plugin_id, "error", e.to_string());
            }
        }

        // 2. Drain plugin messages.
        for action in self.manager.tick() {
            self.apply_action(action, app, theme);
        }

        // 3. Change broadcasts.
        let doc = app.active_doc();
        let generation = (app.state.active_doc, doc.generation);
        if generation != self.last_generation {
            self.last_generation = generation;
            self.manager.notify_schematic_changed();
        }
        let selection = selection_hash(app);
        if selection != self.last_selection {
            self.last_selection = selection;
            self.manager.notify_selection_changed();
        }

        // 4. Flush widget interactions back to their plugins.
        for ua in std::mem::take(&mut self.ui_actions) {
            let params = json!({ "action": ua.action, "payload": ua.payload });
            if let Err(e) = self
                .manager
                .notify(&ua.plugin_id, methods::UI_ACTION, Some(params))
            {
                self.push_log(&ua.plugin_id, "error", e.to_string());
            }
        }
    }

    /// Resolve the effective theme: base palette for `dark`, then plugin
    /// overrides in ascending priority order (highest wins).
    pub fn resolve_theme(&self, dark: bool) -> Theme {
        let mut theme = Theme::for_mode(dark);
        for ov in &self.theme_overrides {
            for (name, value) in &ov.overrides {
                theme.set_token(name, value);
            }
        }
        theme
    }

    // ── Action dispatch ─────────────────────────────────────────────

    fn apply_action(&mut self, action: PluginHostAction, app: &mut App, theme: &Theme) {
        use PluginHostAction as A;
        match action {
            A::RegisterPanel(reg) => {
                let key = (reg.plugin_id.as_str(), reg.name.as_str());
                match self
                    .panels
                    .iter_mut()
                    .find(|p| (p.reg.plugin_id.as_str(), p.reg.name.as_str()) == key)
                {
                    Some(p) => p.reg = reg,
                    None => self.panels.push(PanelEntry {
                        visible: reg.default_visible,
                        reg,
                        widgets: Vec::new(),
                    }),
                }
            }
            A::RegisterCommand(reg) => {
                let key = (reg.plugin_id.as_str(), reg.name.as_str());
                match self
                    .commands
                    .iter_mut()
                    .find(|c| (c.plugin_id.as_str(), c.name.as_str()) == key)
                {
                    Some(c) => *c = reg,
                    None => self.commands.push(reg),
                }
            }
            A::UpdateWidgets {
                plugin_id,
                panel_name,
                widgets,
            } => {
                let key = (plugin_id.as_str(), panel_name.as_str());
                if let Some(p) = self
                    .panels
                    .iter_mut()
                    .find(|p| (p.reg.plugin_id.as_str(), p.reg.name.as_str()) == key)
                {
                    p.widgets = widgets;
                }
            }
            A::UpdateOverlay(layer) => {
                let key = (layer.plugin_id.as_str(), layer.name.as_str());
                match self
                    .overlays
                    .iter_mut()
                    .find(|o| (o.plugin_id.as_str(), o.name.as_str()) == key)
                {
                    Some(o) => *o = layer,
                    None => self.overlays.push(layer),
                }
            }
            A::ThemeOverride(ov) => {
                // Empty override map = remove this plugin's entry.
                self.theme_overrides.retain(|o| o.plugin_id != ov.plugin_id);
                if !ov.overrides.is_empty() {
                    self.theme_overrides.push(ov);
                    self.theme_overrides
                        .sort_by(|a, b| (a.priority, &a.plugin_id).cmp(&(b.priority, &b.plugin_id)));
                }
                self.theme_dirty = true;
            }
            A::DispatchCommand {
                plugin_id,
                command_json,
            } => {
                // `{"action": "zoom_in"}` (SDK snake_case action strings,
                // mapped to PascalCase unit commands) or a full
                // externally-tagged Command (`{"SetInstanceProp": {...}}`)
                // routed through the same JSON decoder CLI/MCP use.
                let cmd_value = match command_json.get("action") {
                    Some(Value::String(s)) => Value::String(snake_to_pascal(s)),
                    _ => command_json.clone(),
                };
                match schemify_core::marshal::command_from_json(&cmd_value) {
                    Ok(cmd) => app.dispatch(cmd).or_status(app),
                    Err(e) => {
                        self.push_log(&plugin_id, "error", format!("dispatch failed: {e}"))
                    }
                }
            }
            A::SetStatus { plugin_id, message } => {
                app.state.status_msg = format!("[{plugin_id}] {message}");
            }
            A::Log {
                plugin_id,
                level,
                message,
            } => self.push_log(&plugin_id, &level, message),
            A::QueryInstances {
                plugin_id,
                request_id,
            } => {
                let result = instance_records(app);
                self.respond(&plugin_id, request_id, result);
            }
            A::QueryNets {
                plugin_id,
                request_id,
            } => {
                let conn = app.connectivity();
                let nets: Vec<Value> = conn
                    .net_names
                    .iter()
                    .enumerate()
                    .map(|(idx, name)| json!({ "idx": idx, "name": name }))
                    .collect();
                self.respond(&plugin_id, request_id, Value::Array(nets));
            }
            A::QueryTheme {
                plugin_id,
                request_id,
            } => {
                let result =
                    serde_json::to_value(theme.to_tokens()).unwrap_or(Value::Null);
                self.respond(&plugin_id, request_id, result);
            }
            A::QueryProject {
                plugin_id,
                request_id,
            } => {
                let result = json!({
                    "project_dir": app.state.project_dir.display().to_string(),
                    "pdk": app.state.config.pdk,
                    "pdk_path": app
                        .state
                        .config
                        .pdk_path
                        .as_ref()
                        .map(|p| p.display().to_string()),
                });
                self.respond(&plugin_id, request_id, result);
            }
            A::QueryPdk {
                plugin_id,
                request_id,
            } => {
                let result = match app.state.pdk.as_ref() {
                    Some(pdk) => {
                        let cells: serde_json::Map<String, Value> = pdk
                            .cells
                            .iter()
                            .map(|(k, c)| {
                                (
                                    k.clone(),
                                    json!({
                                        "model": c.model,
                                        "prefix": c.prefix,
                                        "pin_order": c.pin_order,
                                        "params": c
                                            .default_params
                                            .iter()
                                            .cloned()
                                            .collect::<std::collections::HashMap<_, _>>(),
                                    }),
                                )
                            })
                            .collect();
                        json!({
                            "name": pdk.name,
                            "root": pdk.root.display().to_string(),
                            "lib_path": pdk
                                .lib_path
                                .as_ref()
                                .map(|p| p.display().to_string()),
                            "corners": pdk.corners,
                            "default_corner": pdk.default_corner,
                            "cells": cells,
                        })
                    }
                    None => Value::Null,
                };
                self.respond(&plugin_id, request_id, result);
            }
            A::QueryNetlist {
                plugin_id,
                request_id,
            } => {
                let circuit = app.build_circuit_ir();
                let spice = schemify_core::sim::codegen::emit_spice(&circuit);
                let result = json!({
                    "spice": spice,
                    "instance_map": instance_refdes_map(app),
                });
                self.respond(&plugin_id, request_id, result);
            }
            A::QueryOptimizers {
                plugin_id,
                request_id,
                id,
            } => match id {
                // One instance: full optimizer state.
                Some(id) => match app.state.optimizers.iter().find(|o| o.id == id) {
                    Some(o) => {
                        let mut result = o.opt.to_json();
                        result["id"] = json!(o.id);
                        result["window_open"] = json!(o.window_open);
                        self.respond(&plugin_id, request_id, result);
                    }
                    None => {
                        let _ = self.manager.respond_error(
                            &plugin_id,
                            request_id,
                            schemify_plugins::INVALID_PARAMS,
                            &format!("no optimizer with id {id}"),
                        );
                    }
                },
                // No id: summary list.
                None => {
                    let result = Value::Array(
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
                    );
                    self.respond(&plugin_id, request_id, result);
                }
            },
            A::ErrorResponse {
                plugin_id,
                request_id,
                code,
                message,
            } => {
                let _ = self
                    .manager
                    .respond_error(&plugin_id, request_id, code, &message);
            }
        }
    }

    fn respond(&mut self, plugin_id: &str, request_id: u32, result: Value) {
        if self.manager.respond(plugin_id, request_id, result).is_err() {
            let _ = self.manager.respond_error(
                plugin_id,
                request_id,
                INTERNAL_ERROR,
                "failed to send response",
            );
        }
    }

    fn push_log(&mut self, plugin_id: &str, level: &str, message: String) {
        match level {
            "error" => log::error!("[plugin {plugin_id}] {message}"),
            "warn" => log::warn!("[plugin {plugin_id}] {message}"),
            _ => log::info!("[plugin {plugin_id}] {message}"),
        }
        if self.logs.len() >= LOG_CAP {
            self.logs.remove(0);
        }
        self.logs.push(LogEntry {
            plugin_id: plugin_id.to_owned(),
            level: level.to_owned(),
            message,
        });
    }
}

impl Default for PluginHost {
    fn default() -> Self {
        Self::new()
    }
}

/// Build `state/query_instances` rows from the active schematic.
fn instance_records(app: &App) -> Value {
    let sch = app.schematic();
    let n = sch.instances.len();
    let mut rows = Vec::with_capacity(n);
    for i in 0..n {
        let mut props = Vec::new();
        for p in sch.instance_props(i) {
            props.push(json!([app.resolve(p.key), app.resolve(p.value)]));
        }
        rows.push(json!({
            "idx": i,
            "name": app.resolve(sch.instances.name[i]),
            "symbol": app.resolve(sch.instances.symbol[i]),
            "kind": sch.instances.kind[i].symbol_name(),
            "x": sch.instances.x[i],
            "y": sch.instances.y[i],
            "rotation": sch.instances.flags[i].rotation(),
            "flip": sch.instances.flags[i].flip(),
            "props": props,
        }));
    }
    Value::Array(rows)
}

/// Schematic instance index → SPICE element name, mirroring the netlist
/// codegen: instance name with its kind prefix stripped, re-prefixed with
/// the PDK cell prefix (subcircuits → 'X') or the kind's SPICE letter.
fn instance_refdes_map(app: &App) -> Vec<Value> {
    let sch = app.schematic();
    let mut map = Vec::new();
    for i in 0..sch.instances.len() {
        let kind = sch.instances.kind[i];
        if !kind.is_electrical() {
            continue;
        }
        let raw = app.resolve(sch.instances.name[i]).to_owned();
        let kind_prefix = kind.prefix();
        let stripped = match raw.chars().next() {
            Some(first)
                if kind_prefix != 0
                    && first.to_ascii_uppercase() == kind_prefix.to_ascii_uppercase() as char =>
            {
                &raw[first.len_utf8()..]
            }
            _ => raw.as_str(),
        };
        let cell_prefix = app.state.pdk.as_ref().and_then(|pdk| {
            pdk.cells
                .iter()
                .find(|(k, _)| schemify_core::schemify::DeviceKind::from_name(k) == kind)
                .map(|(_, c)| c.prefix)
        });
        let prefix = cell_prefix.unwrap_or(kind_prefix as char);
        map.push(json!({ "idx": i, "refdes": format!("{prefix}{stripped}") }));
    }
    map
}

/// `"zoom_in"` → `"ZoomIn"`: SDK action strings are snake_case, the JSON
/// command decoder takes PascalCase variant names.
fn snake_to_pascal(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for part in s.split('_') {
        let mut chars = part.chars();
        if let Some(first) = chars.next() {
            out.extend(first.to_uppercase());
            out.push_str(chars.as_str());
        }
    }
    out
}

/// Order-sensitive hash of the active selection (broadcast trigger).
fn selection_hash(app: &App) -> u64 {
    use std::hash::{Hash, Hasher};
    let mut h = std::collections::hash_map::DefaultHasher::new();
    app.state.active_doc.hash(&mut h);
    for obj in &app.active_doc().selection.objs {
        obj.hash(&mut h);
    }
    h.finish()
}
