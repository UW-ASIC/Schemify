//! Schematic -> CircuitIR conversion: the ONE exhaustive DeviceKind match
//! that emits netlist components. Adding a device kind = add its arm here
//! (plus the spec row in `schemify::device`).

use std::path::Path;

use lasso::Rodeo;

use crate::pdk::{LoadedPdk, PdkCell};
use schemify_schematic::resolve_connectivity;
use schemify_schematic::{DeviceKind, Schematic};
use crate as ir;

/// PDK cell for a device kind: the manifest keys cells by primitive name
/// ("nmos4", "res", ...), so map by parsing the key back to a kind.
fn pdk_cell_for_kind(pdk: &LoadedPdk, kind: DeviceKind) -> Option<&PdkCell> {
    pdk.cells
        .iter()
        .find(|(k, _)| DeviceKind::from_name(k) == kind)
        .map(|(_, c)| c)
}

/// Convert a Schematic into a CircuitIR.
///
/// Resolves connectivity (union-find over wires + instance pins), maps each
/// electrical instance to a `Component`, and collects model definitions.
///
/// With a loaded PDK, mapped device kinds get the PDK model name and default
/// parameters; subcircuit devices (prefix 'X') are emitted as X-cards, and
/// the PDK's .lib (with the schematic's corner) and includes are injected
/// into the top subcircuit.
pub fn to_circuit_ir(sch: &Schematic, interner: &Rodeo, pdk: Option<&LoadedPdk>) -> ir::CircuitIR {
    let conn = resolve_connectivity(sch, interner);

    let mut components: Vec<ir::Component> = Vec::new();
    let mut instances: Vec<ir::Instance> = Vec::new();
    let mut osdi_loads: Vec<String> = Vec::new();
    let mut veriloga_sources: Vec<String> = Vec::new();
    let mut va_models: Vec<String> = Vec::new();

    for i in 0..sch.instances.len() {
        let kind = sch.instances.kind[i];
        if !kind.is_electrical() {
            continue;
        }

        let raw_name = interner.resolve(&sch.instances.name[i]);
        // The codegen prepends the SPICE prefix (R, M, V, ...), so strip it
        // from the instance name to avoid doubling.
        let name = strip_spice_prefix(raw_name, kind);
        let pins = &conn.instance_connections[i];
        let props = sch.instance_props(i);

        let get_prop = |key: &str| -> Option<String> {
            props
                .iter()
                .find(|p| interner.resolve(&p.key) == key)
                .map(|p| interner.resolve(&p.value).to_owned())
        };

        let mut params: Vec<(String, String)> = props
            .iter()
            .filter(|p| !matches!(interner.resolve(&p.key), "value" | "model"))
            .map(|p| {
                (
                    interner.resolve(&p.key).to_owned(),
                    interner.resolve(&p.value).to_owned(),
                )
            })
            .collect();

        let pdk_cell = pdk.and_then(|p| pdk_cell_for_kind(p, kind));

        // PDK default params fill in whatever the instance doesn't set.
        if let Some(cell) = pdk_cell {
            for (k, v) in &cell.default_params {
                if !params.iter().any(|(pk, _)| pk.eq_ignore_ascii_case(k)) {
                    params.push((k.clone(), v.clone()));
                }
            }
        }

        let net = |pin_idx: usize| -> String {
            pins.get(pin_idx)
                .and_then(|pc| {
                    if pc.net_idx == usize::MAX {
                        None
                    } else {
                        conn.net_names.get(pc.net_idx)
                    }
                })
                .cloned()
                .unwrap_or_else(|| "?".to_owned())
        };

        let value_or_default = |default: &str| -> ir::IrValue {
            // Parse the default too: "1k" must reach codegen as Numeric(1000)
            // — pyspice_rs's native methods take Float | Unit, not strings.
            match get_prop("value") {
                Some(v) => parse_value(&v),
                None => parse_value(default),
            }
        };

        let model_name = || -> String {
            get_prop("model")
                .or_else(|| pdk_cell.map(|c| c.model.clone()))
                .unwrap_or_else(|| kind.default_model().to_owned())
        };

        // PDK devices are typically subcircuits: emit an X-card directly
        // (M/R/C-cards would reference the wrong primitive type) and skip
        // the per-kind component mapping.
        if let Some(cell) = pdk_cell {
            if cell.prefix == 'X' {
                let nets: Vec<String> = if cell.pin_order.is_empty() {
                    (0..pins.len()).map(&net).collect()
                } else {
                    // Map manifest pin order onto schematic pins by name.
                    cell.pin_order
                        .iter()
                        .map(|want| {
                            pins.iter()
                                .position(|pc| pc.pin_name.eq_ignore_ascii_case(want))
                                .map(&net)
                                .unwrap_or_else(|| "?".to_owned())
                        })
                        .collect()
                };
                let model = get_prop("model").unwrap_or_else(|| cell.model.clone());
                let mut line = format!("X{name} {} {model}", nets.join(" "));
                for (k, v) in &params {
                    line.push(' ');
                    line.push_str(k);
                    line.push('=');
                    line.push_str(v);
                }
                components.push(ir::Component::RawSpice { line });
                continue;
            }
        }

        match kind {
            // 2-terminal passives
            DeviceKind::Resistor | DeviceKind::VarResistor | DeviceKind::Resistor3 => {
                // Resistor3: pins 0,1 are the terminals, pin 2 is the wiper.
                components.push(ir::Component::Resistor {
                    name,
                    n1: net(0),
                    n2: net(1),
                    value: value_or_default("1k"),
                    params,
                });
            }
            DeviceKind::Capacitor => {
                components.push(ir::Component::Capacitor {
                    name,
                    n1: net(0),
                    n2: net(1),
                    value: value_or_default("1p"),
                    params,
                });
            }
            DeviceKind::Inductor => {
                components.push(ir::Component::Inductor {
                    name,
                    n1: net(0),
                    n2: net(1),
                    value: value_or_default("1n"),
                    params,
                });
            }

            // Diodes
            DeviceKind::Diode | DeviceKind::Zener => {
                components.push(ir::Component::Diode {
                    name,
                    np: net(0),
                    nm: net(1),
                    model: model_name(),
                    params,
                });
            }

            // MOSFETs (4-terminal)
            DeviceKind::Nmos4
            | DeviceKind::Pmos4
            | DeviceKind::Nmos4Depl
            | DeviceKind::NmosSub
            | DeviceKind::PmosSub
            | DeviceKind::Nmoshv4
            | DeviceKind::Pmoshv4
            | DeviceKind::Rnmos4 => {
                components.push(ir::Component::Mosfet {
                    name,
                    nd: net(0),
                    ng: net(1),
                    ns: net(2),
                    nb: net(3),
                    model: model_name(),
                    params,
                });
            }

            // MOSFETs (3-terminal — bulk tied to source)
            DeviceKind::Nmos3 | DeviceKind::Pmos3 => {
                let source = net(2);
                components.push(ir::Component::Mosfet {
                    name,
                    nd: net(0),
                    ng: net(1),
                    ns: source.clone(),
                    nb: source,
                    model: model_name(),
                    params,
                });
            }

            // BJTs
            DeviceKind::Npn | DeviceKind::Pnp => {
                components.push(ir::Component::Bjt {
                    name,
                    nc: net(0),
                    nb: net(1),
                    ne: net(2),
                    model: model_name(),
                    params,
                });
            }

            // JFETs
            DeviceKind::Njfet | DeviceKind::Pjfet => {
                components.push(ir::Component::Jfet {
                    name,
                    nd: net(0),
                    ng: net(1),
                    ns: net(2),
                    model: model_name(),
                    params,
                });
            }

            // MESFET
            DeviceKind::Mesfet => {
                components.push(ir::Component::Mesfet {
                    name,
                    nd: net(0),
                    ng: net(1),
                    ns: net(2),
                    model: model_name(),
                    params,
                });
            }

            // Sources
            DeviceKind::Vsource => {
                components.push(ir::Component::VoltageSource {
                    name,
                    np: net(0),
                    nm: net(1),
                    value: value_or_default("0"),
                    waveform: None,
                });
            }
            DeviceKind::Isource => {
                components.push(ir::Component::CurrentSource {
                    name,
                    np: net(0),
                    nm: net(1),
                    value: value_or_default("0"),
                    waveform: None,
                });
            }

            // Controlled sources
            DeviceKind::Vcvs => {
                let gain: f64 = get_prop("value")
                    .and_then(|v| v.parse().ok())
                    .unwrap_or(1.0);
                components.push(ir::Component::Vcvs {
                    name,
                    np: net(0),
                    nm: net(1),
                    ncp: net(2),
                    ncm: net(3),
                    gain,
                });
            }
            DeviceKind::Vccs => {
                let gm: f64 = get_prop("value")
                    .and_then(|v| v.parse().ok())
                    .unwrap_or(1e-3);
                components.push(ir::Component::Vccs {
                    name,
                    np: net(0),
                    nm: net(1),
                    ncp: net(2),
                    ncm: net(3),
                    transconductance: gm,
                });
            }
            DeviceKind::Ccvs => {
                let tr: f64 = get_prop("value")
                    .and_then(|v| v.parse().ok())
                    .unwrap_or(1.0);
                let vsense = get_prop("vsense").unwrap_or_default();
                components.push(ir::Component::Ccvs {
                    name,
                    np: net(0),
                    nm: net(1),
                    vsense,
                    transresistance: tr,
                });
            }
            DeviceKind::Cccs => {
                let gain: f64 = get_prop("value")
                    .and_then(|v| v.parse().ok())
                    .unwrap_or(1.0);
                let vsense = get_prop("vsense").unwrap_or_default();
                components.push(ir::Component::Cccs {
                    name,
                    np: net(0),
                    nm: net(1),
                    vsense,
                    gain,
                });
            }

            // Behavioral source
            DeviceKind::Behavioral => {
                let expr = get_prop("value").unwrap_or_default();
                components.push(ir::Component::BehavioralVoltage {
                    name,
                    np: net(0),
                    nm: net(1),
                    expression: expr,
                });
            }

            // Transmission line
            DeviceKind::Tline | DeviceKind::TlineLossy => {
                let z0: f64 = get_prop("Z0")
                    .or_else(|| get_prop("z0"))
                    .and_then(|v| v.parse().ok())
                    .unwrap_or(50.0);
                let td: f64 = get_prop("TD")
                    .or_else(|| get_prop("td"))
                    .and_then(|v| v.parse().ok())
                    .unwrap_or(1e-9);
                components.push(ir::Component::TLine {
                    name,
                    inp: net(0),
                    inm: net(1),
                    outp: net(2),
                    outm: net(3),
                    z0,
                    td,
                });
            }

            // Switches
            DeviceKind::Vswitch => {
                let model = get_prop("model").unwrap_or_else(|| "sw".to_owned());
                components.push(ir::Component::VSwitch {
                    name,
                    np: net(0),
                    nm: net(1),
                    ncp: net(2),
                    ncm: net(3),
                    model,
                });
            }
            DeviceKind::Iswitch => {
                let model = get_prop("model").unwrap_or_else(|| "csw".to_owned());
                let vcontrol = get_prop("vsense").unwrap_or_default();
                components.push(ir::Component::ISwitch {
                    name,
                    np: net(0),
                    nm: net(1),
                    vcontrol,
                    model,
                });
            }

            // Verilog-A module (OSDI): N-card referencing the compiled
            // module; the .osdi load is recorded once per distinct source.
            DeviceKind::Hdl => {
                let source = get_prop("source_file").unwrap_or_default();
                let model = get_prop("model_name")
                    .filter(|m| !m.is_empty())
                    .or_else(|| {
                        Path::new(&source)
                            .file_stem()
                            .map(|s| s.to_string_lossy().into_owned())
                    })
                    .filter(|m| !m.is_empty())
                    .unwrap_or_else(|| "va_module".to_owned());
                if !source.is_empty() {
                    // openvaf's conventional output is a sibling .osdi.
                    let is_va_source = source.ends_with(".va") || source.ends_with(".vams");
                    let osdi = if is_va_source {
                        Path::new(&source)
                            .with_extension("osdi")
                            .to_string_lossy()
                            .into_owned()
                    } else {
                        source.clone()
                    };
                    if !osdi_loads.contains(&osdi) {
                        osdi_loads.push(osdi);
                    }
                    // Keep the source path as a codegen hint: the PySpice
                    // emitter compiles it via `veriloga()` (openvaf) instead
                    // of loading the .osdi directly.
                    if is_va_source && !veriloga_sources.contains(&source) {
                        veriloga_sources.push(source.clone());
                    }
                }
                if !va_models.contains(&model) {
                    va_models.push(model.clone());
                }
                params.retain(|(k, _)| {
                    !matches!(k.as_str(), "source_file" | "model_name" | "category")
                });
                components.push(ir::Component::VerilogA {
                    name,
                    nodes: (0..pins.len()).map(&net).collect(),
                    model,
                    params,
                });
            }

            // Subcircuit instance
            DeviceKind::Subckt | DeviceKind::DigitalInstance => {
                let symbol = interner.resolve(&sch.instances.symbol[i]);
                instances.push(ir::Instance {
                    name,
                    subcircuit: symbol.to_owned(),
                    port_mapping: (0..pins.len()).map(&net).collect(),
                    parameters: params,
                });
            }

            // Coupling
            DeviceKind::Coupling => {
                let k: f64 = get_prop("value")
                    .and_then(|v| v.parse().ok())
                    .unwrap_or(1.0);
                let l1 = get_prop("inductor1").unwrap_or_default();
                let l2 = get_prop("inductor2").unwrap_or_default();
                components.push(ir::Component::MutualInductor {
                    name,
                    inductor1: l1,
                    inductor2: l2,
                    coupling: k,
                });
            }

            // Ammeter = zero-volt source
            DeviceKind::Ammeter => {
                components.push(ir::Component::VoltageSource {
                    name,
                    np: net(0),
                    nm: net(1),
                    value: ir::IrValue::Numeric { value: 0.0 },
                    waveform: None,
                });
            }

            // Non-netlisted kinds: unreachable — filtered by is_electrical()
            // at the top of the loop. Listed explicitly (no wildcard) so a
            // NEW DeviceKind fails to compile until it gets an emit arm or
            // is consciously added here.
            DeviceKind::Unknown
            | DeviceKind::Sqwsource
            | DeviceKind::Param
            | DeviceKind::Probe
            | DeviceKind::ProbeDiff
            | DeviceKind::Code
            | DeviceKind::Graph
            | DeviceKind::Gnd
            | DeviceKind::Vdd
            | DeviceKind::LabPin
            | DeviceKind::InputPin
            | DeviceKind::OutputPin
            | DeviceKind::InoutPin
            | DeviceKind::Annotation
            | DeviceKind::Noconn
            | DeviceKind::Title
            | DeviceKind::Launcher
            | DeviceKind::RgbLed
            | DeviceKind::Generic => {}
        }
    }

    // Model definitions: parse ".model name TYPE(params)" into structured defs.
    let mut models: Vec<ir::ModelDef> = Vec::with_capacity(sch.model_defs.len());
    for m in &sch.model_defs {
        let parts: Vec<&str> = m.body.splitn(3, ' ').collect();
        let (model_kind, model_params) = if parts.len() >= 3 {
            let kind_and_params = parts[2];
            if let Some(paren) = kind_and_params.find('(') {
                let kind = kind_and_params[..paren].to_owned();
                let param_str = kind_and_params[paren + 1..].trim_end_matches(')');
                let params: Vec<(String, String)> = param_str
                    .split_whitespace()
                    .filter_map(|kv| {
                        let eq = kv.find('=')?;
                        Some((kv[..eq].to_owned(), kv[eq + 1..].to_owned()))
                    })
                    .collect();
                (kind, params)
            } else {
                (kind_and_params.to_owned(), vec![])
            }
        } else {
            (String::new(), vec![])
        };
        models.push(ir::ModelDef {
            name: m.name.clone(),
            kind: model_kind,
            parameters: model_params,
        });
    }

    // Verilog-A instances need a model card binding the OSDI module
    // (`.model <name> <module>`); auto-emit one per module unless the
    // user already defined a card with that name.
    for va in va_models {
        if !models.iter().any(|m| m.name == va) {
            models.push(ir::ModelDef {
                name: va.clone(),
                kind: va,
                parameters: vec![],
            });
        }
    }

    // PDK model library: corner-sectioned .lib plus plain includes.
    let mut includes = vec![];
    let mut libs = vec![];
    let mut model_libraries = vec![];
    if let Some(p) = pdk {
        let corner = if sch.sim_corner.is_empty() {
            p.default_corner.clone()
        } else {
            sch.sim_corner.clone()
        };
        if let Some(lib) = &p.lib_path {
            let path = lib.to_string_lossy().into_owned();
            libs.push((path.clone(), corner.clone()));
            model_libraries.push(ir::ModelLibrary {
                name: p.name.clone(),
                path,
                corner: Some(corner),
                backend_paths: Default::default(),
            });
        }
        for inc in &p.includes {
            includes.push(inc.to_string_lossy().into_owned());
        }
    }

    let top = ir::Subcircuit {
        name: sch.name.clone(),
        components,
        instances,
        models,
        includes,
        libs,
        osdi_loads,
        veriloga_sources,
        ..Default::default()
    };

    ir::CircuitIR {
        top,
        testbench: None,
        subcircuit_defs: vec![],
        model_libraries,
    }
}

/// Convert a top-level Schematic plus child schematics into a CircuitIR.
/// Each child becomes a subcircuit definition; the child's `pins` field
/// supplies the port list.
pub fn to_circuit_ir_with_children(
    top: &Schematic,
    children: &[Schematic],
    interner: &Rodeo,
    pdk: Option<&LoadedPdk>,
) -> ir::CircuitIR {
    let mut circuit = to_circuit_ir(top, interner, pdk);
    circuit.subcircuit_defs.reserve(children.len());

    for child in children {
        let child_ir = to_circuit_ir(child, interner, pdk);
        let ports: Vec<ir::Port> = child
            .pins
            .iter()
            .map(|p| ir::Port {
                name: interner.resolve(&p.name).to_owned(),
                direction: ir::PortDirection::InOut,
            })
            .collect();

        // OSDI loads are global, not per-.subckt: hoist into the top.
        for osdi in child_ir.top.osdi_loads {
            if !circuit.top.osdi_loads.contains(&osdi) {
                circuit.top.osdi_loads.push(osdi);
            }
        }
        for src in child_ir.top.veriloga_sources {
            if !circuit.top.veriloga_sources.contains(&src) {
                circuit.top.veriloga_sources.push(src);
            }
        }

        circuit.subcircuit_defs.push(ir::Subcircuit {
            name: child.name.clone(),
            ports,
            components: child_ir.top.components,
            instances: child_ir.top.instances,
            models: child_ir.top.models,
            ..Default::default()
        });
    }

    circuit
}

/// Strip the SPICE prefix letter from an instance name if it matches the
/// device kind ("M1" for a MOSFET -> "1"). The codegen prepends the prefix,
/// so it must not be doubled.
fn strip_spice_prefix(name: &str, kind: DeviceKind) -> String {
    let prefix = kind.prefix();
    if prefix == 0 {
        return name.to_owned();
    }
    if let Some(first) = name.chars().next() {
        if first.to_ascii_uppercase() == prefix.to_ascii_uppercase() as char {
            return name[first.len_utf8()..].to_owned();
        }
    }
    name.to_owned()
}

/// Parse a SPICE value literal: plain number, SI suffix (1k, 10u, 1meg, ...),
/// expression, or raw text.
fn parse_value(s: &str) -> ir::IrValue {
    if let Ok(v) = s.parse::<f64>() {
        return ir::IrValue::Numeric { value: v };
    }
    let s_lower = s.to_ascii_lowercase();
    let (num_part, multiplier) = if let Some(n) = s_lower.strip_suffix("meg") {
        (n, 1e6)
    } else if let Some(n) = s_lower.strip_suffix("mil") {
        (n, 25.4e-6)
    } else if s_lower.len() > 1 {
        let last = s_lower.as_bytes()[s_lower.len() - 1];
        let mult = match last {
            b't' => Some(1e12),
            b'g' => Some(1e9),
            b'k' => Some(1e3),
            b'm' => Some(1e-3),
            b'u' => Some(1e-6),
            b'n' => Some(1e-9),
            b'p' => Some(1e-12),
            b'f' => Some(1e-15),
            b'a' => Some(1e-18),
            _ => None,
        };
        match mult {
            Some(m) => (&s[..s.len() - 1], m),
            None => (s, 1.0),
        }
    } else {
        (s, 1.0)
    };

    if multiplier != 1.0 {
        if let Ok(v) = num_part.parse::<f64>() {
            return ir::IrValue::Numeric {
                value: v * multiplier,
            };
        }
    }

    if s.contains('{') || s.contains('+') || s.contains('*') || s.contains('/') {
        ir::IrValue::Expression { expr: s.to_owned() }
    } else {
        ir::IrValue::Raw { text: s.to_owned() }
    }
}

// ════════════════════════════════════════════════════════════
// Tests
// ════════════════════════════════════════════════════════════

