//! Schematic → CircuitIR conversion.
//!
//! Resolves connectivity from wires/instances, then builds a `CircuitIR`
//! suitable for passing to pyspice_rs (via JSON) for netlist emission.

use lasso::Rodeo;

use schemify_core::schematic::Schematic;
use schemify_core::types::DeviceKind;
use schemify_sim::ir::*;

use crate::connectivity;

/// Convert a Schematic into a CircuitIR.
///
/// Resolves connectivity (union-find over wires + instance pins),
/// maps each electrical instance to a CircuitIR `Component`,
/// and collects model definitions.
pub fn to_circuit_ir(sch: &Schematic, interner: &Rodeo) -> CircuitIR {
    let conn = connectivity::resolve(sch, interner);

    let mut components = Vec::new();
    let mut instances = Vec::new();

    for i in 0..sch.instances.len() {
        let kind = sch.instances.kind[i];

        // Skip non-electrical instances
        if !is_electrical(kind) {
            continue;
        }

        let raw_name = interner.resolve(&sch.instances.name[i]);
        // PySpice codegen prepends the SPICE prefix (R, M, V, etc.),
        // so strip it from the instance name to avoid doubling.
        let name = strip_spice_prefix(raw_name, kind);
        let pins = &conn.instance_connections[i];

        // Collect properties
        let ps = sch.instances.prop_start[i] as usize;
        let pc = sch.instances.prop_count[i] as usize;
        let props = &sch.properties[ps..ps + pc];

        let get_prop = |key: &str| -> Option<String> {
            props
                .iter()
                .find(|p| interner.resolve(&p.key) == key)
                .map(|p| interner.resolve(&p.value).to_owned())
        };

        let params: Vec<(String, String)> = props
            .iter()
            .filter(|p| {
                let k = interner.resolve(&p.key);
                !matches!(k, "value" | "model")
            })
            .map(|p| {
                (
                    interner.resolve(&p.key).to_owned(),
                    interner.resolve(&p.value).to_owned(),
                )
            })
            .collect();

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

        let value_or_default = |default: &str| -> IrValue {
            match get_prop("value") {
                Some(v) => parse_value(&v),
                None => IrValue::Raw {
                    text: default.to_owned(),
                },
            }
        };

        let model_name = || -> String {
            get_prop("model").unwrap_or_else(|| match kind {
                DeviceKind::Nmos3 | DeviceKind::Nmos4 | DeviceKind::Nmos4Depl
                | DeviceKind::NmosSub | DeviceKind::Nmoshv4 | DeviceKind::Rnmos4 => {
                    "nmos".to_owned()
                }
                DeviceKind::Pmos3 | DeviceKind::Pmos4 | DeviceKind::PmosSub
                | DeviceKind::Pmoshv4 => "pmos".to_owned(),
                DeviceKind::Npn => "npn".to_owned(),
                DeviceKind::Pnp => "pnp".to_owned(),
                DeviceKind::Njfet => "njfet".to_owned(),
                DeviceKind::Pjfet => "pjfet".to_owned(),
                _ => "unknown".to_owned(),
            })
        };

        match kind {
            // 2-terminal passives
            DeviceKind::Resistor | DeviceKind::VarResistor => {
                components.push(Component::Resistor {
                    name,
                    n1: net(0),
                    n2: net(1),
                    value: value_or_default("1k"),
                    params,
                });
            }
            DeviceKind::Resistor3 => {
                // 3-terminal resistor: pins 0,1 are terminals, pin 2 is wiper
                components.push(Component::Resistor {
                    name,
                    n1: net(0),
                    n2: net(1),
                    value: value_or_default("1k"),
                    params,
                });
            }
            DeviceKind::Capacitor => {
                components.push(Component::Capacitor {
                    name,
                    n1: net(0),
                    n2: net(1),
                    value: value_or_default("1p"),
                    params,
                });
            }
            DeviceKind::Inductor => {
                components.push(Component::Inductor {
                    name,
                    n1: net(0),
                    n2: net(1),
                    value: value_or_default("1n"),
                    params,
                });
            }

            // Diodes
            DeviceKind::Diode | DeviceKind::Zener => {
                components.push(Component::Diode {
                    name,
                    np: net(0),
                    nm: net(1),
                    model: model_name(),
                    params,
                });
            }

            // MOSFETs (4-terminal)
            DeviceKind::Nmos4 | DeviceKind::Pmos4 | DeviceKind::Nmos4Depl
            | DeviceKind::NmosSub | DeviceKind::PmosSub | DeviceKind::Nmoshv4
            | DeviceKind::Pmoshv4 | DeviceKind::Rnmos4 => {
                components.push(Component::Mosfet {
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
                components.push(Component::Mosfet {
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
                components.push(Component::Bjt {
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
                components.push(Component::Jfet {
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
                components.push(Component::Mesfet {
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
                components.push(Component::VoltageSource {
                    name,
                    np: net(0),
                    nm: net(1),
                    value: value_or_default("0"),
                    waveform: None,
                });
            }
            DeviceKind::Isource => {
                components.push(Component::CurrentSource {
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
                components.push(Component::Vcvs {
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
                components.push(Component::Vccs {
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
                components.push(Component::Ccvs {
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
                components.push(Component::Cccs {
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
                components.push(Component::BehavioralVoltage {
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
                components.push(Component::TLine {
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
                components.push(Component::VSwitch {
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
                components.push(Component::ISwitch {
                    name,
                    np: net(0),
                    nm: net(1),
                    vcontrol,
                    model,
                });
            }

            // Subcircuit instance
            DeviceKind::Subckt | DeviceKind::DigitalInstance => {
                let symbol = interner.resolve(&sch.instances.symbol[i]);
                let port_mapping: Vec<String> =
                    (0..pins.len()).map(|p| net(p)).collect();
                let parameters: Vec<(String, String)> = params;
                instances.push(Instance {
                    name,
                    subcircuit: symbol.to_owned(),
                    port_mapping,
                    parameters,
                });
            }

            // Coupling
            DeviceKind::Coupling => {
                let k: f64 = get_prop("value")
                    .and_then(|v| v.parse().ok())
                    .unwrap_or(1.0);
                let l1 = get_prop("inductor1").unwrap_or_default();
                let l2 = get_prop("inductor2").unwrap_or_default();
                components.push(Component::MutualInductor {
                    name,
                    inductor1: l1,
                    inductor2: l2,
                    coupling: k,
                });
            }

            // Ammeter = zero-volt source
            DeviceKind::Ammeter => {
                components.push(Component::VoltageSource {
                    name,
                    np: net(0),
                    nm: net(1),
                    value: IrValue::Numeric { value: 0.0 },
                    waveform: None,
                });
            }

            // Everything else (non-electrical, handled above) or unsupported
            _ => {}
        }
    }

    // Model definitions
    let models: Vec<ModelDef> = sch
        .model_defs
        .iter()
        .map(|m| {
            // Parse ".model name TYPE(params)" → structured ModelDef
            let parts: Vec<&str> = m.body.splitn(3, ' ').collect();
            let (model_kind, model_params) = if parts.len() >= 3 {
                let kind_and_params = parts[2];
                if let Some(paren) = kind_and_params.find('(') {
                    let kind = kind_and_params[..paren].to_owned();
                    let param_str = kind_and_params[paren + 1..]
                        .trim_end_matches(')');
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

            ModelDef {
                name: m.name.clone(),
                kind: model_kind,
                parameters: model_params,
            }
        })
        .collect();

    let top = Subcircuit {
        name: sch.name.clone(),
        ports: vec![],
        parameters: vec![],
        components,
        instances,
        models,
        raw_spice: vec![],
        includes: vec![],
        libs: vec![],
        osdi_loads: vec![],
        verilog_blocks: vec![],
    };

    CircuitIR {
        top,
        testbench: None,
        subcircuit_defs: vec![],
        model_libraries: vec![],
    }
}

/// Strip the SPICE prefix letter from an instance name if it matches the device kind.
/// E.g., "M1" for a MOSFET → "1", "R1" for a Resistor → "1".
/// PySpice's codegen prepends the prefix, so we must not double it.
fn strip_spice_prefix(name: &str, kind: DeviceKind) -> String {
    let expected_prefix = match kind {
        DeviceKind::Resistor | DeviceKind::VarResistor | DeviceKind::Resistor3 => 'r',
        DeviceKind::Capacitor => 'c',
        DeviceKind::Inductor => 'l',
        DeviceKind::Diode | DeviceKind::Zener => 'd',
        DeviceKind::Nmos3 | DeviceKind::Nmos4 | DeviceKind::Nmos4Depl
        | DeviceKind::NmosSub | DeviceKind::Nmoshv4 | DeviceKind::Rnmos4
        | DeviceKind::Pmos3 | DeviceKind::Pmos4 | DeviceKind::PmosSub
        | DeviceKind::Pmoshv4 => 'm',
        DeviceKind::Npn | DeviceKind::Pnp => 'q',
        DeviceKind::Njfet | DeviceKind::Pjfet => 'j',
        DeviceKind::Mesfet => 'z',
        DeviceKind::Vsource | DeviceKind::Ammeter => 'v',
        DeviceKind::Isource => 'i',
        DeviceKind::Vcvs => 'e',
        DeviceKind::Vccs => 'g',
        DeviceKind::Ccvs => 'h',
        DeviceKind::Cccs => 'f',
        DeviceKind::Behavioral => 'b',
        DeviceKind::Tline | DeviceKind::TlineLossy => 't',
        DeviceKind::Vswitch | DeviceKind::Iswitch => 's',
        DeviceKind::Coupling => 'k',
        DeviceKind::Subckt | DeviceKind::DigitalInstance => 'x',
        _ => return name.to_owned(),
    };
    if let Some(first) = name.chars().next() {
        if first.to_ascii_lowercase() == expected_prefix {
            return name[first.len_utf8()..].to_owned();
        }
    }
    name.to_owned()
}

fn is_electrical(kind: DeviceKind) -> bool {
    !matches!(
        kind,
        DeviceKind::Unknown
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
            | DeviceKind::Generic
            | DeviceKind::Param
            | DeviceKind::Probe
            | DeviceKind::ProbeDiff
            | DeviceKind::Code
            | DeviceKind::Graph
            | DeviceKind::Hdl
            | DeviceKind::Sqwsource
    )
}

fn parse_value(s: &str) -> IrValue {
    if let Ok(v) = s.parse::<f64>() {
        return IrValue::Numeric { value: v };
    }
    // Try SI suffix: 1k, 10u, 100n, etc.
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
            return IrValue::Numeric {
                value: v * multiplier,
            };
        }
    }

    // Expression or raw
    if s.contains('{') || s.contains('+') || s.contains('*') || s.contains('/') {
        IrValue::Expression {
            expr: s.to_owned(),
        }
    } else {
        IrValue::Raw {
            text: s.to_owned(),
        }
    }
}
