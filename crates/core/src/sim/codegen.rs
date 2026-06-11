//! Code generation from [`CircuitIR`]: PySpice Python scripts and plain
//! SPICE netlists.

use std::fmt::Write;

use super::ir::*;

// ── PySpice emitter ──

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

// ── SPICE netlist emitter ──

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

    // Testbench
    if let Some(tb) = &ir.testbench {
        let _ = writeln!(buf);
        emit_spice_analyses(&mut buf, tb);
    }

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
            waveform,
        }
        | Component::CurrentSource {
            name,
            np,
            nm,
            value,
            waveform,
        } => {
            let prefix = if matches!(comp, Component::VoltageSource { .. }) {
                'V'
            } else {
                'I'
            };
            let _ = write!(buf, "{prefix}{name} {np} {nm} {}", spice_val(value));
            if let Some(wf) = waveform {
                let _ = write!(buf, " {}", spice_waveform(wf));
            }
            let _ = writeln!(buf);
        }
        Component::BehavioralVoltage {
            name,
            np,
            nm,
            expression,
        }
        | Component::BehavioralCurrent {
            name,
            np,
            nm,
            expression,
        } => {
            let qty = if matches!(comp, Component::BehavioralVoltage { .. }) {
                'V'
            } else {
                'I'
            };
            let _ = writeln!(buf, "B{name} {np} {nm} {qty}={{{expression}}}");
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
        Component::Xspice {
            name,
            connections,
            model,
        } => {
            let conns = connections.join(" ");
            let _ = writeln!(buf, "A{name} {conns} {model}");
        }
        Component::RawSpice { line } => {
            let _ = writeln!(buf, "{line}");
        }
    }
}

/// Emit testbench directives: options, temperature, stimulus, analyses,
/// saves, measures, initial conditions, node sets, and step parameters.
fn emit_spice_analyses(buf: &mut String, tb: &Testbench) {
    for (k, v) in &tb.options.portable {
        let _ = writeln!(buf, ".option {k}={v}");
    }
    if let Some(temp) = tb.temperature {
        let _ = writeln!(buf, ".temp {temp}");
    }
    if !tb.initial_conditions.is_empty() {
        let ics: Vec<String> = tb
            .initial_conditions
            .iter()
            .map(|(node, val)| format!("V({node})={val}"))
            .collect();
        let _ = writeln!(buf, ".ic {}", ics.join(" "));
    }
    for (node, val) in &tb.node_sets {
        let _ = writeln!(buf, ".nodeset V({node})={val}");
    }
    for comp in &tb.stimulus {
        emit_spice_component(buf, comp);
    }
    for analysis in &tb.analyses {
        emit_spice_analysis(buf, analysis);
    }
    for s in &tb.saves {
        let _ = writeln!(buf, ".save {s}");
    }
    for m in &tb.measures {
        let _ = writeln!(buf, ".meas {m}");
    }
    for sp in &tb.step_params {
        let sweep = sp.sweep_type.as_deref().unwrap_or("lin");
        let _ = writeln!(
            buf,
            ".step {sweep} {} {} {} {}",
            sp.param, sp.start, sp.stop, sp.step
        );
    }
    for line in &tb.extra_lines {
        let _ = writeln!(buf, "{line}");
    }
}

/// Emit a single analysis directive.
fn emit_spice_analysis(buf: &mut String, analysis: &Analysis) {
    match analysis {
        Analysis::Op => {
            let _ = writeln!(buf, ".op");
        }
        Analysis::Dc { sweeps } => {
            let _ = write!(buf, ".dc");
            for sweep in sweeps {
                let _ = write!(
                    buf,
                    " {} {} {} {}",
                    sweep.source, sweep.start, sweep.stop, sweep.step
                );
            }
            let _ = writeln!(buf);
        }
        Analysis::Ac {
            variation,
            points,
            start,
            stop,
        } => {
            let _ = writeln!(buf, ".ac {variation} {points} {start} {stop}");
        }
        Analysis::Transient {
            step,
            stop,
            start,
            max_step,
            uic,
        } => {
            let _ = write!(buf, ".tran {step} {stop}");
            if let Some(s) = start {
                let _ = write!(buf, " {s}");
            }
            if let Some(ms) = max_step {
                if start.is_none() {
                    let _ = write!(buf, " 0");
                }
                let _ = write!(buf, " {ms}");
            }
            if *uic {
                let _ = write!(buf, " UIC");
            }
            let _ = writeln!(buf);
        }
        Analysis::Noise {
            output,
            reference,
            source,
            variation,
            points,
            start,
            stop,
            points_per_summary,
        } => {
            let _ = write!(
                buf,
                ".noise V({output},{reference}) {source} {variation} {points} {start} {stop}"
            );
            if let Some(pps) = points_per_summary {
                let _ = write!(buf, " {pps}");
            }
            let _ = writeln!(buf);
        }
        Analysis::Tf { output, source } => {
            let _ = writeln!(buf, ".tf {output} {source}");
        }
        Analysis::Sensitivity { output, ac } => {
            let _ = write!(buf, ".sens {output}");
            if let Some(ac_params) = ac {
                let _ = write!(
                    buf,
                    " AC {} {} {} {}",
                    ac_params.variation, ac_params.points, ac_params.start, ac_params.stop
                );
            }
            let _ = writeln!(buf);
        }
        Analysis::PoleZero {
            node1,
            node2,
            node3,
            node4,
            tf_type,
            pz_type,
        } => {
            let _ = writeln!(
                buf,
                ".pz {node1} {node2} {node3} {node4} {tf_type} {pz_type}"
            );
        }
        Analysis::Distortion {
            variation,
            points,
            start,
            stop,
            f2overf1,
        } => {
            let _ = write!(buf, ".disto {variation} {points} {start} {stop}");
            if let Some(ratio) = f2overf1 {
                let _ = write!(buf, " {ratio}");
            }
            let _ = writeln!(buf);
        }
        Analysis::Fourier {
            fundamental,
            outputs,
            num_harmonics,
        } => {
            let _ = write!(buf, ".four {fundamental}");
            if let Some(nh) = num_harmonics {
                let _ = write!(buf, " {nh}");
            }
            for o in outputs {
                let _ = write!(buf, " {o}");
            }
            let _ = writeln!(buf);
        }
        // Vendor-specific and non-standard analyses get a comment
        _ => {
            let _ = writeln!(buf, "* unsupported analysis: {analysis:?}");
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

/// Format an `IrWaveform` as a SPICE waveform specification.
fn spice_waveform(wf: &IrWaveform) -> String {
    match wf {
        IrWaveform::Sin {
            offset,
            amplitude,
            frequency,
            delay,
            damping,
            phase,
        } => {
            format!("SIN({offset} {amplitude} {frequency} {delay} {damping} {phase})")
        }
        IrWaveform::Pulse {
            initial,
            pulsed,
            delay,
            rise_time,
            fall_time,
            pulse_width,
            period,
        } => {
            format!(
                "PULSE({initial} {pulsed} {delay} {rise_time} {fall_time} {pulse_width} {period})"
            )
        }
        IrWaveform::Pwl { values } => {
            let pairs: Vec<String> = values.iter().map(|(t, v)| format!("{t} {v}")).collect();
            format!("PWL({})", pairs.join(" "))
        }
        IrWaveform::Exp {
            initial,
            pulsed,
            rise_delay,
            rise_tau,
            fall_delay,
            fall_tau,
        } => {
            format!("EXP({initial} {pulsed} {rise_delay} {rise_tau} {fall_delay} {fall_tau})")
        }
        IrWaveform::Sffm {
            offset,
            amplitude,
            carrier_freq,
            modulation_index,
            signal_freq,
        } => {
            format!("SFFM({offset} {amplitude} {carrier_freq} {modulation_index} {signal_freq})")
        }
        IrWaveform::Am {
            amplitude,
            offset,
            modulating_freq,
            carrier_freq,
            delay,
        } => {
            format!("AM({amplitude} {offset} {modulating_freq} {carrier_freq} {delay})")
        }
    }
}

/// Append key=value parameter pairs to the current line.
fn emit_spice_params(buf: &mut String, params: &[(String, String)]) {
    for (k, v) in params {
        let _ = write!(buf, " {k}={v}");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn divider_ir() -> CircuitIR {
        let mut top = Subcircuit::new("voltage_divider");
        top.components.push(Component::Resistor {
            name: "R1".into(),
            n1: "in".into(),
            n2: "out".into(),
            value: IrValue::numeric(10_000.0),
            params: vec![],
        });
        top.components.push(Component::Resistor {
            name: "R2".into(),
            n1: "out".into(),
            n2: "0".into(),
            value: IrValue::numeric(10_000.0),
            params: vec![],
        });
        top.components.push(Component::VoltageSource {
            name: "V1".into(),
            np: "in".into(),
            nm: "0".into(),
            value: IrValue::numeric(5.0),
            waveform: None,
        });
        let mut ir = CircuitIR::with_top(top);
        ir.testbench = Some(Testbench {
            dut: "voltage_divider".into(),
            analyses: vec![Analysis::Op],
            ..Testbench::default()
        });
        ir
    }

    #[test]
    fn pyspice_veriloga_and_precompiled_osdi() {
        let mut ir = CircuitIR::new("va");
        // .va source: compiled at sim time via veriloga(); its derived
        // .osdi entry must not double-load.
        ir.top.veriloga_sources.push("models/res.va".into());
        ir.top.osdi_loads.push("models/res.osdi".into());
        // Pre-compiled module: plain osdi() load.
        ir.top.osdi_loads.push("prebuilt/diode.osdi".into());

        let py = emit_pyspice(&ir);
        assert!(py.contains(r#"ckt.veriloga("models/res.va")"#), "pyspice was:\n{py}");
        assert!(py.contains(r#"ckt.osdi("prebuilt/diode.osdi")"#), "pyspice was:\n{py}");
        assert!(!py.contains(r#"osdi("models/res.osdi")"#), "pyspice was:\n{py}");

        // Plain-SPICE export keeps both .osdi cards (no openvaf at export).
        let sp = emit_spice(&ir);
        assert!(sp.contains(".osdi models/res.osdi\n"), "spice was:\n{sp}");
        assert!(sp.contains(".osdi prebuilt/diode.osdi\n"), "spice was:\n{sp}");
    }

    #[test]
    fn pyspice_divider() {
        let py = emit_pyspice(&divider_ir());
        assert!(py.contains("from pyspice_rs import Circuit, Subcircuit"));
        assert!(py.contains(r#"ckt = Circuit("voltage_divider")"#));
        assert!(py.contains(r#"ckt.R(name="R1", positive="in", negative="out", value=10000)"#));
        assert!(py.contains(r#"ckt.V(name="V1", positive="in", negative="0", value=5)"#));
        assert!(py.contains("sim = ckt.simulator()"));
        assert!(py.contains("sim.operating_point()"));
    }

    /// End-to-end smoke for the sim runner's netlist path: python
    /// (pyspice_rs) renders the netlist, an analysis directive is spliced
    /// in before `.end`, ngspice runs it in batch mode, and the rawfile
    /// parses. Skips silently when the toolchain (bundled pyspice /
    /// ngspice) is absent — run inside `nix develop`.
    #[test]
    fn netlist_script_end_to_end() {
        use std::process::Command;

        let Some(pypath) = crate::sim::pyspice::python_path() else {
            return;
        };
        if Command::new("ngspice").arg("--version").output().is_err() {
            return;
        }

        let mut ir = divider_ir();
        ir.testbench = None; // the runner splices directives itself

        let dir = std::env::temp_dir().join("schemify_sim_test");
        std::fs::create_dir_all(&dir).unwrap();
        let script = dir.join("netlist_gen.py");
        std::fs::write(&script, emit_netlist_script(&ir)).unwrap();
        let out = Command::new(crate::sim::pyspice::python_bin())
            .arg(&script)
            .env("PYTHONPATH", &pypath)
            .output()
            .unwrap();
        assert!(
            out.status.success(),
            "python failed: {}",
            String::from_utf8_lossy(&out.stderr)
        );

        // Splice analysis directives the way run_simulation does.
        let mut deck = String::from_utf8(out.stdout).unwrap().trim_end().to_string();
        assert!(deck.contains(".title voltage_divider"), "netlist:\n{deck}");
        if let Some(s) = deck.strip_suffix(".end") {
            deck.truncate(s.trim_end().len());
        }
        deck.push_str("\n\n.op\n.end\n");

        let cir = dir.join("circuit.cir");
        let raw = dir.join("circuit.raw");
        let _ = std::fs::remove_file(&raw);
        std::fs::write(&cir, &deck).unwrap();
        let out = Command::new("ngspice")
            .arg("-b")
            .arg("-r")
            .arg(&raw)
            .arg(&cir)
            .output()
            .unwrap();
        assert!(
            out.status.success(),
            "ngspice failed:\n{}{}",
            String::from_utf8_lossy(&out.stdout),
            String::from_utf8_lossy(&out.stderr)
        );

        let plots = schemify_wave::parse_raw(&std::fs::read(&raw).unwrap()).unwrap();
        assert!(!plots.is_empty(), "rawfile parsed to zero plots");
    }

    #[test]
    fn pyspice_capacitor_and_current_source() {
        let mut top = Subcircuit::new("rc");
        top.components.push(Component::Capacitor {
            name: "C1".into(),
            n1: "a".into(),
            n2: "0".into(),
            value: IrValue::numeric(1e-9),
            params: vec![],
        });
        top.components.push(Component::CurrentSource {
            name: "I1".into(),
            np: "a".into(),
            nm: "0".into(),
            value: IrValue::numeric(0.001),
            waveform: None,
        });
        let py = emit_pyspice(&CircuitIR::with_top(top));
        assert!(py.contains(r#"ckt.C(name="C1", positive="a", negative="0", value=0.000000001)"#));
        assert!(py.contains(r#"ckt.I(name="I1", positive="a", negative="0", value=0.001)"#));
    }

    #[test]
    fn pyspice_mosfet_keyword_param_falls_back_to_raw() {
        let mut top = Subcircuit::new("m");
        top.components.push(Component::Mosfet {
            name: "1".into(),
            nd: "d".into(),
            ng: "g".into(),
            ns: "s".into(),
            nb: "b".into(),
            model: "nmos".into(),
            params: vec![("as".into(), "1p".into())],
        });
        let py = emit_pyspice(&CircuitIR::with_top(top));
        assert!(py.contains(r#"raw_spice("M1 d g s b nmos as="#));
    }

    #[test]
    fn pyspice_subcircuit_and_instance() {
        let mut top = Subcircuit::new("top");
        top.instances.push(Instance {
            name: "X1".into(),
            subcircuit: "div-2".into(),
            port_mapping: vec!["in".into(), "out".into()],
            parameters: vec![],
        });
        let mut ir = CircuitIR::with_top(top);
        ir.subcircuit_defs.push(Subcircuit {
            name: "div-2".into(),
            ports: vec![
                Port {
                    name: "a".into(),
                    direction: PortDirection::InOut,
                },
                Port {
                    name: "b".into(),
                    direction: PortDirection::InOut,
                },
            ],
            ..Subcircuit::default()
        });
        let py = emit_pyspice(&ir);
        // pyid sanitizes '-' to '_'
        assert!(py.contains(r#"sub_div_2 = Subcircuit("div-2", ["a", "b"])"#));
        assert!(py.contains("ckt.subcircuit(sub_div_2)"));
        assert!(py.contains(r#"ckt.X("X1", "div-2", "in", "out")"#));
    }

    #[test]
    fn spice_divider() {
        let sp = emit_spice(&divider_ir());
        assert!(sp.starts_with("* voltage_divider\n"));
        assert!(sp.contains("RR1 in out 10000\n"));
        assert!(sp.contains("VV1 in 0 5\n"));
        assert!(sp.contains(".op\n"));
        assert!(sp.ends_with(".end\n"));
    }

    #[test]
    fn spice_waveforms_and_analyses() {
        let mut top = Subcircuit::new("tb");
        top.components.push(Component::VoltageSource {
            name: "in".into(),
            np: "a".into(),
            nm: "0".into(),
            value: IrValue::numeric(0.0),
            waveform: Some(IrWaveform::Pulse {
                initial: 0.0,
                pulsed: 3.3,
                delay: 0.0,
                rise_time: 1e-9,
                fall_time: 1e-9,
                pulse_width: 5e-6,
                period: 1e-5,
            }),
        });
        let mut ir = CircuitIR::with_top(top);
        ir.testbench = Some(Testbench {
            dut: "tb".into(),
            analyses: vec![Analysis::Transient {
                step: 1e-9,
                stop: 1e-5,
                start: None,
                max_step: None,
                uic: true,
            }],
            saves: vec!["V(a)".into()],
            ..Testbench::default()
        });
        let sp = emit_spice(&ir);
        assert!(sp.contains("Vin a 0 0 PULSE(0 3.3 0 0.000000001 0.000000001 0.000005 0.00001)"));
        assert!(sp.contains(".tran 0.000000001 0.00001 UIC\n"));
        assert!(sp.contains(".save V(a)\n"));
    }

    #[test]
    fn spice_subckt_block() {
        let mut ir = CircuitIR::new("top");
        ir.subcircuit_defs.push(Subcircuit {
            name: "div".into(),
            ports: vec![
                Port {
                    name: "a".into(),
                    direction: PortDirection::InOut,
                },
                Port {
                    name: "b".into(),
                    direction: PortDirection::InOut,
                },
            ],
            parameters: vec![ParamDef {
                name: "rval".into(),
                default: Some("10k".into()),
            }],
            ..Subcircuit::default()
        });
        let sp = emit_spice(&ir);
        assert!(sp.contains(".subckt div a b rval=10k\n"));
        assert!(sp.contains(".ends div\n"));
    }

    #[test]
    fn spice_behavioral_and_fets() {
        let mut top = Subcircuit::new("misc");
        top.components.push(Component::BehavioralVoltage {
            name: "1".into(),
            np: "a".into(),
            nm: "0".into(),
            expression: "V(x)*2".into(),
        });
        top.components.push(Component::BehavioralCurrent {
            name: "2".into(),
            np: "a".into(),
            nm: "0".into(),
            expression: "I(V1)".into(),
        });
        top.components.push(Component::Jfet {
            name: "1".into(),
            nd: "d".into(),
            ng: "g".into(),
            ns: "s".into(),
            model: "jm".into(),
            params: vec![],
        });
        top.components.push(Component::Mesfet {
            name: "2".into(),
            nd: "d".into(),
            ng: "g".into(),
            ns: "s".into(),
            model: "zm".into(),
            params: vec![],
        });
        let sp = emit_spice(&CircuitIR::with_top(top));
        assert!(sp.contains("B1 a 0 V={V(x)*2}\n"));
        assert!(sp.contains("B2 a 0 I={I(V1)}\n"));
        assert!(sp.contains("J1 d g s jm\n"));
        assert!(sp.contains("Z2 d g s zm\n"));
    }
}
