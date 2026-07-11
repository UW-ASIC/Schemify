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

