//! PySpice emitter: Python scripts that build the circuit via `pyspice_rs`.

use std::fmt::Write;

use crate::ir::*;

pub fn emit_pyspice(ir: &CircuitIR) -> String {
    let mut buf = String::new();
    let _ = writeln!(buf, "from pyspice_rs import Circuit, Subcircuit");
    let _ = writeln!(buf);

    for sc in &ir.subcircuit_defs {
        emit_subcircuit(&mut buf, sc, "sub");
        let _ = writeln!(buf);
    }

    let var = "ckt";
    let _ = writeln!(buf, "{var} = Circuit({:?})", ir.top.name);
    emit_body(&mut buf, &ir.top, var);

    for sc in &ir.subcircuit_defs {
        let _ = writeln!(buf, "{var}.subcircuit(sub_{})", pyid(&sc.name));
    }

    if let Some(tb) = &ir.testbench {
        let _ = writeln!(buf);
        emit_testbench(&mut buf, tb, var);
    }

    buf
}

fn emit_subcircuit(buf: &mut String, sc: &Subcircuit, prefix: &str) {
    let var = format!("{prefix}_{}", pyid(&sc.name));
    let _ = write!(buf, "{var} = Subcircuit({:?}, [", sc.name);
    for (i, p) in sc.ports.iter().enumerate() {
        if i > 0 {
            let _ = write!(buf, ", ");
        }
        let _ = write!(buf, "{:?}", p.name);
    }
    let _ = writeln!(buf, "])");
    emit_body(buf, sc, &var);
}

fn emit_body(buf: &mut String, sc: &Subcircuit, var: &str) {
    // Verilog-A sources: pyspice_rs's veriloga() compiles via openvaf
    // (mtime-cached) and records the resulting .osdi load itself.
    // Its path detection is `.va`-only; `.vams` falls through to the
    // pre-compiled osdi() load below.
    for src in &sc.veriloga_sources {
        if src.ends_with(".va") {
            let _ = writeln!(buf, "{var}.veriloga({src:?})");
        }
    }
    for osdi in &sc.osdi_loads {
        // Skip loads already covered by a veriloga() call above (the IR
        // records both so the plain-SPICE emitter keeps its .osdi card).
        let compiled_above = sc.veriloga_sources.iter().any(|src| {
            src.ends_with(".va")
                && std::path::Path::new(src).with_extension("osdi").to_string_lossy()
                    == osdi.as_str()
        });
        if !compiled_above {
            let _ = writeln!(buf, "{var}.osdi({osdi:?})");
        }
    }
    for inc in &sc.includes {
        let _ = writeln!(buf, "{var}.include({inc:?})");
    }
    for (path, section) in &sc.libs {
        let _ = writeln!(buf, "{var}.lib({path:?}, {section:?})");
    }
    for p in &sc.parameters {
        let default = p.default.as_deref().unwrap_or("0");
        let _ = writeln!(buf, "{var}.parameter({:?}, {:?})", p.name, default);
    }
    for m in &sc.models {
        let _ = write!(buf, "{var}.model({:?}, {:?}", m.name, m.kind);
        for (k, v) in &m.parameters {
            let _ = write!(buf, ", {k}={v}");
        }
        let _ = writeln!(buf, ")");
    }
    for line in &sc.raw_spice {
        let _ = writeln!(buf, "{var}.raw_spice({line:?})");
    }

    for comp in &sc.components {
        let _ = write!(buf, "{var}.");
        match comp {
            // PySpice has no OSDI instance binding: emit the N-card as raw
            // SPICE ({:?} so quotes/backslashes stay valid Python).
            Component::VerilogA {
                name,
                nodes,
                model,
                params,
            } => {
                let param_str: String =
                    params.iter().map(|(k, v)| format!(" {k}={v}")).collect();
                let card = format!("N{name} {} {model}{param_str}", nodes.join(" "));
                let _ = writeln!(buf, "raw_spice({card:?})");
            }
            Component::Resistor {
                name,
                n1,
                n2,
                value,
                params,
            } => {
                let _ = write!(
                    buf,
                    "R(name={:?}, positive={:?}, negative={:?}, value={}",
                    name,
                    n1,
                    n2,
                    pyval(value)
                );
                emit_params(buf, params);
                let _ = writeln!(buf, ")");
            }
            Component::Capacitor {
                name,
                n1,
                n2,
                value,
                ..
            }
            | Component::Inductor {
                name,
                n1,
                n2,
                value,
                ..
            } => {
                let letter = if matches!(comp, Component::Capacitor { .. }) {
                    'C'
                } else {
                    'L'
                };
                let _ = writeln!(
                    buf,
                    "{letter}(name={:?}, positive={:?}, negative={:?}, value={})",
                    name,
                    n1,
                    n2,
                    pyval(value)
                );
            }
            Component::VoltageSource {
                name,
                np,
                nm,
                value,
                ..
            }
            | Component::CurrentSource {
                name,
                np,
                nm,
                value,
                ..
            } => {
                let letter = if matches!(comp, Component::VoltageSource { .. }) {
                    'V'
                } else {
                    'I'
                };
                if has_waveform(value) {
                    let _ = writeln!(
                        buf,
                        "raw_spice(\"{letter}{name} {np} {nm} {}\")",
                        raw_value_str(value)
                    );
                } else {
                    let _ = writeln!(
                        buf,
                        "{letter}(name={:?}, positive={:?}, negative={:?}, value={})",
                        name,
                        np,
                        nm,
                        pyval(value)
                    );
                }
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
                // If any param name is a Python keyword (e.g. "as"), emit as
                // raw SPICE to avoid a syntax error in the generated code.
                if params.iter().any(|(k, _)| is_python_keyword(k)) {
                    let param_str: String = params
                        .iter()
                        .map(|(k, v)| format!(" {}={}", k, spice_param_to_python(v)))
                        .collect();
                    let _ = writeln!(
                        buf,
                        "raw_spice(\"M{name} {nd} {ng} {ns} {nb} {model}{param_str}\")"
                    );
                } else {
                    let _ = write!(
                        buf,
                        "MOSFET(name={:?}, drain={:?}, gate={:?}, source={:?}, bulk={:?}, model={:?}",
                        name, nd, ng, ns, nb, model
                    );
                    emit_params(buf, params);
                    let _ = writeln!(buf, ")");
                }
            }
            Component::Diode {
                name,
                np,
                nm,
                model,
                ..
            } => {
                let _ = writeln!(
                    buf,
                    "D(name={:?}, anode={:?}, cathode={:?}, model={:?})",
                    name, np, nm, model
                );
            }
            Component::Bjt {
                name,
                nc,
                nb,
                ne,
                model,
                ..
            } => {
                let _ = writeln!(
                    buf,
                    "Q(name={:?}, collector={:?}, base={:?}, emitter={:?}, model={:?})",
                    name, nc, nb, ne, model
                );
            }
            Component::Jfet {
                name,
                nd,
                ng,
                ns,
                model,
                ..
            } => {
                let _ = writeln!(
                    buf,
                    "J(name={:?}, drain={:?}, gate={:?}, source={:?}, model={:?})",
                    name, nd, ng, ns, model
                );
            }
            Component::Vcvs {
                name,
                np,
                nm,
                ncp,
                ncm,
                gain,
            } => {
                let _ = writeln!(
                    buf,
                    "E(name={:?}, positive={:?}, negative={:?}, control_positive={:?}, control_negative={:?}, voltage_gain={})",
                    name, np, nm, ncp, ncm, gain
                );
            }
            Component::Vccs {
                name,
                np,
                nm,
                ncp,
                ncm,
                transconductance,
            } => {
                let _ = writeln!(
                    buf,
                    "G(name={:?}, positive={:?}, negative={:?}, control_positive={:?}, control_negative={:?}, transconductance={})",
                    name, np, nm, ncp, ncm, transconductance
                );
            }
            Component::Ccvs {
                name,
                np,
                nm,
                vsense,
                transresistance,
            } => {
                let _ = writeln!(
                    buf,
                    "H(name={:?}, positive={:?}, negative={:?}, vsense={:?}, transresistance={})",
                    name, np, nm, vsense, transresistance
                );
            }
            Component::Cccs {
                name,
                np,
                nm,
                vsense,
                gain,
            } => {
                let _ = writeln!(
                    buf,
                    "F(name={:?}, positive={:?}, negative={:?}, vsense={:?}, current_gain={})",
                    name, np, nm, vsense, gain
                );
            }
            _ => {
                let _ = writeln!(buf, "# unsupported: {comp:?}");
            }
        }
    }

    for inst in &sc.instances {
        let nodes = inst
            .port_mapping
            .iter()
            .map(|n| format!("{n:?}"))
            .collect::<Vec<_>>()
            .join(", ");
        let _ = writeln!(
            buf,
            "{var}.X({:?}, {:?}, {})",
            inst.name, inst.subcircuit, nodes
        );
    }
}

fn emit_testbench(buf: &mut String, tb: &Testbench, var: &str) {
    let _ = writeln!(buf, "sim = {var}.simulator()");

    for analysis in &tb.analyses {
        match analysis {
            Analysis::Transient {
                step, stop, start, ..
            } => {
                let s = start.unwrap_or(0.0);
                let _ = writeln!(buf, "sim.transient({step}, {stop}, {s})");
            }
            Analysis::Dc { sweeps } => {
                for sweep in sweeps {
                    let _ = writeln!(
                        buf,
                        "sim.dc({:?}, {}, {}, {})",
                        sweep.source, sweep.start, sweep.stop, sweep.step
                    );
                }
            }
            Analysis::Ac {
                variation,
                points,
                start,
                stop,
            } => {
                let _ = writeln!(buf, "sim.ac({variation:?}, {points}, {start}, {stop})");
            }
            Analysis::Op => {
                let _ = writeln!(buf, "sim.operating_point()");
            }
            _ => {
                let _ = writeln!(buf, "# unsupported analysis: {analysis:?}");
            }
        }
    }
}

fn emit_params(buf: &mut String, params: &[(String, String)]) {
    for (k, v) in params {
        let pv = spice_param_to_python(v);
        let _ = write!(buf, ", {k}={pv}");
    }
}

fn spice_param_to_python(s: &str) -> String {
    if let Ok(v) = s.parse::<f64>() {
        return format!("{v}");
    }
    let lower = s.to_ascii_lowercase();
    let (num_part, mult) = if let Some(n) = lower.strip_suffix("meg") {
        (n, 1e6)
    } else if lower.len() > 1 {
        let last = lower.as_bytes()[lower.len() - 1];
        match last {
            b't' => (&s[..s.len() - 1], 1e12),
            b'g' => (&s[..s.len() - 1], 1e9),
            b'k' => (&s[..s.len() - 1], 1e3),
            b'm' => (&s[..s.len() - 1], 1e-3),
            b'u' => (&s[..s.len() - 1], 1e-6),
            b'n' => (&s[..s.len() - 1], 1e-9),
            b'p' => (&s[..s.len() - 1], 1e-12),
            b'f' => (&s[..s.len() - 1], 1e-15),
            b'a' => (&s[..s.len() - 1], 1e-18),
            _ => return format!("{s:?}"),
        }
    } else {
        return format!("{s:?}");
    };
    if let Ok(v) = num_part.parse::<f64>() {
        format!("{}", v * mult)
    } else {
        format!("{s:?}")
    }
}

fn pyval(v: &IrValue) -> String {
    match v {
        IrValue::Numeric { value } => {
            if *value == 0.0 {
                "0".to_string()
            } else {
                format!("{value}")
            }
        }
        IrValue::Expression { expr } => format!("{expr:?}"),
        IrValue::Raw { text } => format!("{text:?}"),
    }
}

fn has_waveform(v: &IrValue) -> bool {
    match v {
        IrValue::Raw { text } => {
            let t = text.to_ascii_lowercase();
            t.contains("pulse(")
                || t.contains("sin(")
                || t.contains("pwl(")
                || t.contains("exp(")
                || t.contains("sffm(")
                || (t.contains(' ') && t.contains("ac"))
        }
        _ => false,
    }
}

fn raw_value_str(v: &IrValue) -> &str {
    match v {
        IrValue::Raw { text } => text,
        IrValue::Expression { expr } => expr,
        IrValue::Numeric { .. } => "0",
    }
}

fn is_python_keyword(s: &str) -> bool {
    matches!(
        s,
        "False"
            | "None"
            | "True"
            | "and"
            | "as"
            | "assert"
            | "async"
            | "await"
            | "break"
            | "class"
            | "continue"
            | "def"
            | "del"
            | "elif"
            | "else"
            | "except"
            | "finally"
            | "for"
            | "from"
            | "global"
            | "if"
            | "import"
            | "in"
            | "is"
            | "lambda"
            | "nonlocal"
            | "not"
            | "or"
            | "pass"
            | "raise"
            | "return"
            | "try"
            | "while"
            | "with"
            | "yield"
    )
}

fn pyid(name: &str) -> String {
    name.chars()
        .map(|c| if c.is_alphanumeric() { c } else { '_' })
        .collect()
}

/// Emit a Python script that builds the circuit via `pyspice_rs` and prints
/// the rendered netlist to stdout. The sim runner captures it, appends the
/// schematic's analysis directives, and hands the result to the selected
/// SPICE backend. pyspice_rs owns PDK/model resolution and dialect quirks,
/// so the netlist comes from Python rather than `emit_spice`.
pub fn emit_netlist_script(ir: &CircuitIR) -> String {
    let mut buf = emit_pyspice(ir);
    let _ = writeln!(buf);
    let _ = writeln!(buf, "import sys");
    let _ = writeln!(buf, "sys.stdout.write(str(ckt))");
    buf
}
