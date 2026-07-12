//! Plain SPICE netlist emitter from [`CircuitIR`].

use std::fmt::Write;

use crate::ir::*;

/// Emit a standard SPICE netlist from the circuit IR.
pub fn emit_spice(ir: &CircuitIR) -> String {
    let mut buf = String::new();

    // Title line
    let _ = writeln!(buf, "* {}", ir.top.name);
    let _ = writeln!(buf);

    // Subcircuit definitions
    for sc in &ir.subcircuit_defs {
        emit_spice_subcircuit(&mut buf, sc);
        let _ = writeln!(buf);
    }

    // Top-level body
    emit_spice_body(&mut buf, &ir.top);

    let _ = writeln!(buf, ".end");
    buf
}

/// Emit a `.subckt` block for a subcircuit definition.
fn emit_spice_subcircuit(buf: &mut String, sc: &Subcircuit) {
    let port_names: Vec<&str> = sc.ports.iter().map(|p| p.name.as_str()).collect();

    let _ = write!(buf, ".subckt {} {}", sc.name, port_names.join(" "));

    // Inline parameter defaults on the .subckt line
    for p in &sc.parameters {
        let default = p.default.as_deref().unwrap_or("0");
        let _ = write!(buf, " {}={}", p.name, default);
    }
    let _ = writeln!(buf);

    emit_spice_body(buf, sc);

    let _ = writeln!(buf, ".ends {}", sc.name);
}

/// Emit the body of a subcircuit or top-level circuit: includes, libs,
/// models, raw lines, components, and instances.
fn emit_spice_body(buf: &mut String, sc: &Subcircuit) {
    // Compiled Verilog-A modules (ngspice >= 42 `.osdi` card).
    for osdi in &sc.osdi_loads {
        let _ = writeln!(buf, ".osdi {osdi}");
    }
    for inc in &sc.includes {
        let _ = writeln!(buf, ".include {inc}");
    }
    for (path, section) in &sc.libs {
        let _ = writeln!(buf, ".lib {path} {section}");
    }
    for p in &sc.parameters {
        let default = p.default.as_deref().unwrap_or("0");
        let _ = writeln!(buf, ".param {} = {}", p.name, default);
    }
    for m in &sc.models {
        let params = m
            .parameters
            .iter()
            .map(|(k, v)| format!("{k}={v}"))
            .collect::<Vec<_>>()
            .join(" ");
        if params.is_empty() {
            let _ = writeln!(buf, ".model {} {}", m.name, m.kind);
        } else {
            let _ = writeln!(buf, ".model {} {} ({params})", m.name, m.kind);
        }
    }
    for line in &sc.raw_spice {
        let _ = writeln!(buf, "{line}");
    }
    for comp in &sc.components {
        emit_spice_component(buf, comp);
    }
    for inst in &sc.instances {
        let nodes = inst.port_mapping.join(" ");
        let _ = write!(buf, "X{} {} {}", inst.name, nodes, inst.subcircuit);
        for (k, v) in &inst.parameters {
            let _ = write!(buf, " {k}={v}");
        }
        let _ = writeln!(buf);
    }
}

/// Emit a single component line in SPICE syntax.
fn emit_spice_component(buf: &mut String, comp: &Component) {
    match comp {
        Component::VerilogA {
            name,
            nodes,
            model,
            params,
        } => {
            let _ = write!(buf, "N{name} {} {model}", nodes.join(" "));
            for (k, v) in params {
                let _ = write!(buf, " {k}={v}");
            }
            let _ = writeln!(buf);
        }
        Component::Resistor {
            name,
            n1,
            n2,
            value,
            params,
        }
        | Component::Capacitor {
            name,
            n1,
            n2,
            value,
            params,
        }
        | Component::Inductor {
            name,
            n1,
            n2,
            value,
            params,
        } => {
            let prefix = match comp {
                Component::Resistor { .. } => 'R',
                Component::Capacitor { .. } => 'C',
                _ => 'L',
            };
            let _ = write!(buf, "{prefix}{name} {n1} {n2} {}", spice_val(value));
            emit_spice_params(buf, params);
            let _ = writeln!(buf);
        }
        Component::MutualInductor {
            name,
            inductor1,
            inductor2,
            coupling,
        } => {
            let _ = writeln!(buf, "K{name} {inductor1} {inductor2} {coupling}");
        }
        Component::VoltageSource {
            name,
            np,
            nm,
            value,
        }
        | Component::CurrentSource {
            name,
            np,
            nm,
            value,
        } => {
            let prefix = if matches!(comp, Component::VoltageSource { .. }) {
                'V'
            } else {
                'I'
            };
            let _ = writeln!(buf, "{prefix}{name} {np} {nm} {}", spice_val(value));
        }
        Component::BehavioralVoltage {
            name,
            np,
            nm,
            expression,
        } => {
            let _ = writeln!(buf, "B{name} {np} {nm} V={{{expression}}}");
        }
        Component::Mosfet {
            name,
            nd,
            ng,
            ns,
            nb,
            model,
            params,
        } => {
            let _ = write!(buf, "M{name} {nd} {ng} {ns} {nb} {model}");
            emit_spice_params(buf, params);
            let _ = writeln!(buf);
        }
        Component::Diode {
            name,
            np,
            nm,
            model,
            params,
        } => {
            let _ = write!(buf, "D{name} {np} {nm} {model}");
            emit_spice_params(buf, params);
            let _ = writeln!(buf);
        }
        Component::Bjt {
            name,
            nc,
            nb,
            ne,
            model,
            params,
        } => {
            let _ = write!(buf, "Q{name} {nc} {nb} {ne} {model}");
            emit_spice_params(buf, params);
            let _ = writeln!(buf);
        }
        Component::Jfet {
            name,
            nd,
            ng,
            ns,
            model,
            params,
        }
        | Component::Mesfet {
            name,
            nd,
            ng,
            ns,
            model,
            params,
        } => {
            let prefix = if matches!(comp, Component::Jfet { .. }) {
                'J'
            } else {
                'Z'
            };
            let _ = write!(buf, "{prefix}{name} {nd} {ng} {ns} {model}");
            emit_spice_params(buf, params);
            let _ = writeln!(buf);
        }
        Component::Vcvs {
            name,
            np,
            nm,
            ncp,
            ncm,
            gain,
        } => {
            let _ = writeln!(buf, "E{name} {np} {nm} {ncp} {ncm} {gain}");
        }
        Component::Vccs {
            name,
            np,
            nm,
            ncp,
            ncm,
            transconductance,
        } => {
            let _ = writeln!(buf, "G{name} {np} {nm} {ncp} {ncm} {transconductance}");
        }
        Component::Ccvs {
            name,
            np,
            nm,
            vsense,
            transresistance,
        } => {
            let _ = writeln!(buf, "H{name} {np} {nm} {vsense} {transresistance}");
        }
        Component::Cccs {
            name,
            np,
            nm,
            vsense,
            gain,
        } => {
            let _ = writeln!(buf, "F{name} {np} {nm} {vsense} {gain}");
        }
        Component::VSwitch {
            name,
            np,
            nm,
            ncp,
            ncm,
            model,
        } => {
            let _ = writeln!(buf, "S{name} {np} {nm} {ncp} {ncm} {model}");
        }
        Component::ISwitch {
            name,
            np,
            nm,
            vcontrol,
            model,
        } => {
            let _ = writeln!(buf, "W{name} {np} {nm} {vcontrol} {model}");
        }
        Component::TLine {
            name,
            inp,
            inm,
            outp,
            outm,
            z0,
            td,
        } => {
            let _ = writeln!(buf, "T{name} {inp} {inm} {outp} {outm} Z0={z0} TD={td}");
        }
        Component::RawSpice { line } => {
            let _ = writeln!(buf, "{line}");
        }
    }
}

/// Format an `IrValue` for SPICE output.
fn spice_val(v: &IrValue) -> String {
    match v {
        IrValue::Numeric { value } => format!("{value}"),
        IrValue::Expression { expr } => format!("{{{expr}}}"),
        IrValue::Raw { text } => text.clone(),
    }
}

/// Append key=value parameter pairs to the current line.
fn emit_spice_params(buf: &mut String, params: &[(String, String)]) {
    for (k, v) in params {
        let _ = write!(buf, " {k}={v}");
    }
}

