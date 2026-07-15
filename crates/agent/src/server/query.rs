//! Read-only App → JSON projections for the MCP query surface, plus the
//! small param/naming helpers the router shares.

use std::collections::BTreeMap;
use std::fmt::Write as FmtWrite;
use std::path::PathBuf;

use anyhow::{anyhow, Result};
use serde_json::{json, Value};

use schemify_editor::handler::{self, App, Origin, ViewMode};
use schemify_editor::schemify::{Color, DeviceKind};

// ════════════════════════════════════════════════════════════
// Queries
// ════════════════════════════════════════════════════════════

pub(crate) fn session_state(app: &App) -> Value {
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

pub(crate) fn query_instances(app: &App) -> Value {
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

pub(crate) fn query_nets(app: &mut App) -> Value {
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
pub(crate) fn query_view(app: &mut App) -> Value {
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
    let conns = &connectivity.instance_connections;

    let is_device = |name: &str, k: DeviceKind| !k.is_non_electrical() && !name.starts_with('.');

    let mut buf = String::new();
    let device_count = inst_info.iter().filter(|(n, _, k)| is_device(n, *k)).count();
    let _ = writeln!(
        buf,
        "{sch_name} | {device_count} devices, {wire_count} wires, {} nets",
        net_names.len()
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
                        let net = c
                            .net_idx
                            .and_then(|ni| net_names.get(ni as usize))
                            .map(String::as_str)
                            .unwrap_or("?");
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
    for (i, (iname, _, ikind)) in inst_info.iter().enumerate() {
        if !is_device(iname, *ikind) {
            continue;
        }
        let Some(cs) = conns.get(i) else { continue };
        for c in cs {
            let Some(nname) = c
                .net_idx
                .and_then(|ni| net_names.get(ni as usize))
            else {
                continue;
            };
            let entry = net_device_pins.entry(nname.as_str()).or_default();
            let tag = format!("{iname}.{}", c.pin_name);
            if !entry.contains(&tag) {
                entry.push(tag);
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
            c.net_idx
                .and_then(|ni| net_names.get(ni as usize))
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
    // Nets terminated by a label/supply symbol (lab_pin, gnd, vdd) are
    // intentional single-device nets (ports, rails) — not stubs.
    let terminated: std::collections::HashSet<&str> = inst_info
        .iter()
        .enumerate()
        .filter(|(_, (iname, _, ikind))| !is_device(iname, *ikind))
        .filter_map(|(i, _)| conns.get(i))
        .flatten()
        .filter_map(|c| c.net_idx.and_then(|ni| net_names.get(ni as usize)))
        .map(String::as_str)
        .collect();
    for (nname, eps) in &net_device_pins {
        if eps.len() == 1
            && !nname.is_empty()
            && *nname != "?"
            && !terminated.contains(nname)
        {
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

pub(crate) fn pin_connection_hint(
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

pub(crate) fn save_path(app: &App, params: &Value) -> Result<PathBuf> {
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

pub(crate) use schemify_editor::marshal::{f64_or_si, f64_vec, num, opt_f64, opt_f64_vec, opt_num, req_bool, req_str, target_str};

/// Plugin id for marketplace methods: `id` preferred, `name` accepted
/// for backwards compatibility.
pub(crate) fn req_plugin_id(params: &Value) -> Result<String> {
    req_str(params, "id")
        .or_else(|_| req_str(params, "name"))
        .map_err(|_| anyhow!("missing string parameter 'id'"))
}

pub(crate) fn origin_name(origin: &Origin) -> &'static str {
    match origin {
        Origin::Unsaved => "unsaved",
        Origin::Buffer(_) => "buffer",
        Origin::File(_) => "file",
        Origin::Memory => "memory",
    }
}

pub(crate) fn view_mode_name(mode: ViewMode) -> &'static str {
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

pub(crate) fn wave_of(app: &App) -> Result<&schemify_editor::wave::WaveState> {
    app.state
        .wave
        .as_deref()
        .ok_or_else(|| anyhow!("no waveform loaded (use wave/open first)"))
}

pub(crate) fn kind_str(k: schemify_wave::VarKind) -> &'static str {
    use schemify_wave::VarKind::*;
    match k {
        Time => "time",
        Frequency => "frequency",
        Voltage => "voltage",
        Current => "current",
        Other => "other",
    }
}

pub(crate) fn color_hex(c: Color) -> String {
    format!("#{:02x}{:02x}{:02x}", c.r, c.g, c.b)
}

/// All loaded files → analysis blocks → variables. The AI's signal browser.
pub(crate) fn query_signals(app: &App) -> Result<Value> {
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
pub(crate) fn query_traces(app: &App) -> Result<Value> {
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
                    schemify_editor::wave::LineStyle::Solid => "solid",
                    schemify_editor::wave::LineStyle::Dash => "dash",
                    schemify_editor::wave::LineStyle::Dot => "dot",
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
pub(crate) fn query_cursors(app: &App) -> Result<Value> {
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
pub(crate) fn query_wave_data(app: &App, params: &Value) -> Result<Value> {
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

pub(crate) fn find_optimizer(app: &App, id: u32) -> Result<&handler::OptimizerInstance> {
    app.state
        .optimizers
        .iter()
        .find(|o| o.id == id)
        .ok_or_else(|| anyhow!("unknown optimizer id {id}"))
}

/// All optimizer instances, one summary row each.
pub(crate) fn query_optimizers(app: &App) -> Value {
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
pub(crate) fn query_optimizer_state(app: &App, params: &Value) -> Result<Value> {
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
pub(crate) fn optimizer_suggest(app: &App, params: &Value) -> Result<Value> {
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