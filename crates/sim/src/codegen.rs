use std::fmt::Write;

use crate::ir::*;

fn format_value(v: &IrValue) -> String {
    match v {
        IrValue::Numeric { value } => format!("{value}"),
        IrValue::Expression { expr } => format!("{{{expr}}}"),
        IrValue::Raw { text } => text.clone(),
    }
}

fn emit_params(buf: &mut String, params: &[(String, String)]) {
    for (k, v) in params {
        write!(buf, " {k}={v}").unwrap();
    }
}

/// Emit a SPICE netlist from a `CircuitIR`.
///
/// Pure function: takes IR in, returns netlist text out.
pub fn emit_netlist(ir: &CircuitIR, title: &str) -> String {
    let mut buf = String::new();
    writeln!(buf, "* {title}").unwrap();
    writeln!(buf).unwrap();

    emit_subcircuit_body(&mut buf, &ir.top);

    writeln!(buf, ".end").unwrap();
    buf
}

fn emit_subcircuit_body(buf: &mut String, sub: &Subcircuit) {
    for m in &sub.models {
        write!(buf, ".model {} {}", m.name, m.kind).unwrap();
        if !m.parameters.is_empty() {
            write!(buf, " (").unwrap();
            for (k, v) in &m.parameters {
                write!(buf, " {k}={v}").unwrap();
            }
            write!(buf, " )").unwrap();
        }
        writeln!(buf).unwrap();
    }

    for comp in &sub.components {
        emit_component(buf, comp);
    }

    for inst in &sub.instances {
        write!(buf, "X{}", inst.name).unwrap();
        for p in &inst.port_mapping {
            write!(buf, " {p}").unwrap();
        }
        writeln!(buf, " {}", inst.subcircuit).unwrap();
    }

    for line in &sub.raw_spice {
        writeln!(buf, "{line}").unwrap();
    }
}

fn emit_component(buf: &mut String, comp: &Component) {
    match comp {
        Component::Resistor {
            name,
            n1,
            n2,
            value,
            params,
        } => {
            write!(buf, "R{name} {n1} {n2} {}", format_value(value)).unwrap();
            emit_params(buf, params);
            writeln!(buf).unwrap();
        }
        Component::Capacitor {
            name,
            n1,
            n2,
            value,
            params,
        } => {
            write!(buf, "C{name} {n1} {n2} {}", format_value(value)).unwrap();
            emit_params(buf, params);
            writeln!(buf).unwrap();
        }
        Component::Inductor {
            name,
            n1,
            n2,
            value,
            params,
        } => {
            write!(buf, "L{name} {n1} {n2} {}", format_value(value)).unwrap();
            emit_params(buf, params);
            writeln!(buf).unwrap();
        }
        Component::MutualInductor {
            name,
            inductor1,
            inductor2,
            coupling,
        } => {
            writeln!(buf, "K{name} L{inductor1} L{inductor2} {coupling}").unwrap();
        }
        Component::VoltageSource {
            name,
            np,
            nm,
            value,
            waveform,
        } => {
            write!(buf, "V{name} {np} {nm} {}", format_value(value)).unwrap();
            if let Some(wf) = waveform {
                write!(buf, " ").unwrap();
                emit_waveform(buf, wf);
            }
            writeln!(buf).unwrap();
        }
        Component::CurrentSource {
            name,
            np,
            nm,
            value,
            waveform,
        } => {
            write!(buf, "I{name} {np} {nm} {}", format_value(value)).unwrap();
            if let Some(wf) = waveform {
                write!(buf, " ").unwrap();
                emit_waveform(buf, wf);
            }
            writeln!(buf).unwrap();
        }
        Component::BehavioralVoltage {
            name,
            np,
            nm,
            expression,
        } => {
            writeln!(buf, "B{name} {np} {nm} V={expression}").unwrap();
        }
        Component::BehavioralCurrent {
            name,
            np,
            nm,
            expression,
        } => {
            writeln!(buf, "B{name} {np} {nm} I={expression}").unwrap();
        }
        Component::Vcvs {
            name,
            np,
            nm,
            ncp,
            ncm,
            gain,
        } => {
            writeln!(buf, "E{name} {np} {nm} {ncp} {ncm} {gain}").unwrap();
        }
        Component::Vccs {
            name,
            np,
            nm,
            ncp,
            ncm,
            transconductance,
        } => {
            writeln!(buf, "G{name} {np} {nm} {ncp} {ncm} {transconductance}").unwrap();
        }
        Component::Cccs {
            name,
            np,
            nm,
            vsense,
            gain,
        } => {
            writeln!(buf, "F{name} {np} {nm} {vsense} {gain}").unwrap();
        }
        Component::Ccvs {
            name,
            np,
            nm,
            vsense,
            transresistance,
        } => {
            writeln!(buf, "H{name} {np} {nm} {vsense} {transresistance}").unwrap();
        }
        Component::Diode {
            name,
            np,
            nm,
            model,
            params,
        } => {
            write!(buf, "D{name} {np} {nm} {model}").unwrap();
            emit_params(buf, params);
            writeln!(buf).unwrap();
        }
        Component::Bjt {
            name,
            nc,
            nb,
            ne,
            model,
            params,
        } => {
            write!(buf, "Q{name} {nc} {nb} {ne} {model}").unwrap();
            emit_params(buf, params);
            writeln!(buf).unwrap();
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
            write!(buf, "M{name} {nd} {ng} {ns} {nb} {model}").unwrap();
            emit_params(buf, params);
            writeln!(buf).unwrap();
        }
        Component::Jfet {
            name,
            nd,
            ng,
            ns,
            model,
            params,
        } => {
            write!(buf, "J{name} {nd} {ng} {ns} {model}").unwrap();
            emit_params(buf, params);
            writeln!(buf).unwrap();
        }
        Component::Mesfet {
            name,
            nd,
            ng,
            ns,
            model,
            params,
        } => {
            write!(buf, "Z{name} {nd} {ng} {ns} {model}").unwrap();
            emit_params(buf, params);
            writeln!(buf).unwrap();
        }
        Component::VSwitch {
            name,
            np,
            nm,
            ncp,
            ncm,
            model,
        } => {
            writeln!(buf, "S{name} {np} {nm} {ncp} {ncm} {model}").unwrap();
        }
        Component::ISwitch {
            name,
            np,
            nm,
            vcontrol,
            model,
        } => {
            writeln!(buf, "W{name} {np} {nm} {vcontrol} {model}").unwrap();
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
            writeln!(buf, "T{name} {inp} {inm} {outp} {outm} Z0={z0} TD={td}").unwrap();
        }
        Component::Xspice {
            name,
            connections,
            model,
        } => {
            write!(buf, "A{name}").unwrap();
            for c in connections {
                write!(buf, " {c}").unwrap();
            }
            writeln!(buf, " {model}").unwrap();
        }
        Component::RawSpice { line } => {
            writeln!(buf, "{line}").unwrap();
        }
    }
}

fn emit_waveform(buf: &mut String, wf: &IrWaveform) {
    match wf {
        IrWaveform::Sin {
            offset,
            amplitude,
            frequency,
            delay,
            damping,
            phase,
        } => {
            write!(
                buf,
                "SIN({offset} {amplitude} {frequency} {delay} {damping} {phase})"
            )
            .unwrap();
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
            write!(
                buf,
                "PULSE({initial} {pulsed} {delay} {rise_time} {fall_time} {pulse_width} {period})"
            )
            .unwrap();
        }
        IrWaveform::Pwl { values } => {
            write!(buf, "PWL(").unwrap();
            for (i, (t, v)) in values.iter().enumerate() {
                if i > 0 {
                    write!(buf, " ").unwrap();
                }
                write!(buf, "{t} {v}").unwrap();
            }
            write!(buf, ")").unwrap();
        }
        IrWaveform::Exp {
            initial,
            pulsed,
            rise_delay,
            rise_tau,
            fall_delay,
            fall_tau,
        } => {
            write!(
                buf,
                "EXP({initial} {pulsed} {rise_delay} {rise_tau} {fall_delay} {fall_tau})"
            )
            .unwrap();
        }
        IrWaveform::Sffm {
            offset,
            amplitude,
            carrier_freq,
            modulation_index,
            signal_freq,
        } => {
            write!(
                buf,
                "SFFM({offset} {amplitude} {carrier_freq} {modulation_index} {signal_freq})"
            )
            .unwrap();
        }
        IrWaveform::Am {
            amplitude,
            offset,
            modulating_freq,
            carrier_freq,
            delay,
        } => {
            write!(
                buf,
                "AM({amplitude} {offset} {modulating_freq} {carrier_freq} {delay})"
            )
            .unwrap();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn minimal_ir(components: Vec<Component>) -> CircuitIR {
        CircuitIR {
            top: Subcircuit {
                name: "test".into(),
                components,
                ..Subcircuit::default()
            },
            testbench: None,
            subcircuit_defs: Vec::new(),
            model_libraries: Vec::new(),
        }
    }

    #[test]
    fn emit_resistor() {
        let ir = minimal_ir(vec![Component::Resistor {
            name: "1".into(),
            n1: "in".into(),
            n2: "out".into(),
            value: IrValue::Numeric { value: 1000.0 },
            params: vec![],
        }]);
        let out = emit_netlist(&ir, "test");
        assert!(out.contains("R1 in out 1000"));
    }

    #[test]
    fn emit_capacitor() {
        let ir = minimal_ir(vec![Component::Capacitor {
            name: "1".into(),
            n1: "a".into(),
            n2: "0".into(),
            value: IrValue::Numeric { value: 1e-12 },
            params: vec![],
        }]);
        let out = emit_netlist(&ir, "test");
        assert!(out.contains("C1 a 0 0.000000000001"));
    }

    #[test]
    fn emit_mosfet() {
        let ir = minimal_ir(vec![Component::Mosfet {
            name: "1".into(),
            nd: "d".into(),
            ng: "g".into(),
            ns: "s".into(),
            nb: "b".into(),
            model: "nmos_3p3".into(),
            params: vec![("W".into(), "1u".into()), ("L".into(), "180n".into())],
        }]);
        let out = emit_netlist(&ir, "test");
        assert!(out.contains("M1 d g s b nmos_3p3 W=1u L=180n"));
    }

    #[test]
    fn emit_vcvs() {
        let ir = minimal_ir(vec![Component::Vcvs {
            name: "1".into(),
            np: "out".into(),
            nm: "0".into(),
            ncp: "inp".into(),
            ncm: "inm".into(),
            gain: 10.0,
        }]);
        let out = emit_netlist(&ir, "test");
        assert!(out.contains("E1 out 0 inp inm 10"));
    }

    #[test]
    fn emit_cccs() {
        let ir = minimal_ir(vec![Component::Cccs {
            name: "1".into(),
            np: "out".into(),
            nm: "0".into(),
            vsense: "Vsense".into(),
            gain: 5.0,
        }]);
        let out = emit_netlist(&ir, "test");
        assert!(out.contains("F1 out 0 Vsense 5"));
    }

    #[test]
    fn emit_tline() {
        let ir = minimal_ir(vec![Component::TLine {
            name: "1".into(),
            inp: "in_p".into(),
            inm: "in_m".into(),
            outp: "out_p".into(),
            outm: "out_m".into(),
            z0: 50.0,
            td: 1e-9,
        }]);
        let out = emit_netlist(&ir, "test");
        assert!(out.contains("T1 in_p in_m out_p out_m Z0=50 TD=0.000000001"));
    }

    #[test]
    fn emit_model_card() {
        let ir = CircuitIR {
            top: Subcircuit {
                name: "test".into(),
                models: vec![ModelDef {
                    name: "nmos_3p3".into(),
                    kind: "NMOS".into(),
                    parameters: vec![
                        ("VTH0".into(), "0.5".into()),
                        ("TOX".into(), "7.7e-9".into()),
                    ],
                }],
                ..Subcircuit::default()
            },
            testbench: None,
            subcircuit_defs: Vec::new(),
            model_libraries: Vec::new(),
        };
        let out = emit_netlist(&ir, "test");
        assert!(out.contains(".model nmos_3p3 NMOS ( VTH0=0.5 TOX=7.7e-9 )"));
    }

    #[test]
    fn emit_subcircuit_instance() {
        let ir = CircuitIR {
            top: Subcircuit {
                name: "test".into(),
                instances: vec![Instance {
                    name: "dut".into(),
                    subcircuit: "opamp".into(),
                    port_mapping: vec![
                        "inp".into(),
                        "inm".into(),
                        "out".into(),
                        "vdd".into(),
                        "vss".into(),
                    ],
                    parameters: vec![],
                }],
                ..Subcircuit::default()
            },
            testbench: None,
            subcircuit_defs: Vec::new(),
            model_libraries: Vec::new(),
        };
        let out = emit_netlist(&ir, "test");
        assert!(out.contains("Xdut inp inm out vdd vss opamp"));
    }

    #[test]
    fn emit_voltage_source_with_pulse() {
        let ir = minimal_ir(vec![Component::VoltageSource {
            name: "in".into(),
            np: "input".into(),
            nm: "0".into(),
            value: IrValue::Numeric { value: 0.0 },
            waveform: Some(IrWaveform::Pulse {
                initial: 0.0,
                pulsed: 3.3,
                delay: 0.0,
                rise_time: 1e-9,
                fall_time: 1e-9,
                pulse_width: 5e-6,
                period: 10e-6,
            }),
        }]);
        let out = emit_netlist(&ir, "test");
        assert!(out.contains("Vin input 0 0"));
        assert!(out.contains("PULSE(0 3.3 0 0.000000001 0.000000001 0.000005 0.00001)"));
    }

    #[test]
    fn emit_ends_with_dot_end() {
        let ir = minimal_ir(vec![]);
        let out = emit_netlist(&ir, "test");
        assert!(out.trim_end().ends_with(".end"));
    }

    #[test]
    fn emit_mutual_inductor() {
        let ir = minimal_ir(vec![Component::MutualInductor {
            name: "1".into(),
            inductor1: "1".into(),
            inductor2: "2".into(),
            coupling: 0.99,
        }]);
        let out = emit_netlist(&ir, "test");
        assert!(out.contains("K1 L1 L2 0.99"));
    }

    #[test]
    fn emit_behavioral_source() {
        let ir = minimal_ir(vec![
            Component::BehavioralVoltage {
                name: "1".into(),
                np: "out".into(),
                nm: "0".into(),
                expression: "V(in)*2".into(),
            },
            Component::BehavioralCurrent {
                name: "2".into(),
                np: "a".into(),
                nm: "b".into(),
                expression: "I(R1)*0.5".into(),
            },
        ]);
        let out = emit_netlist(&ir, "test");
        assert!(out.contains("B1 out 0 V=V(in)*2"));
        assert!(out.contains("B2 a b I=I(R1)*0.5"));
    }

    #[test]
    fn emit_switches() {
        let ir = minimal_ir(vec![
            Component::VSwitch {
                name: "1".into(),
                np: "out".into(),
                nm: "0".into(),
                ncp: "ctrl_p".into(),
                ncm: "ctrl_m".into(),
                model: "SW1".into(),
            },
            Component::ISwitch {
                name: "1".into(),
                np: "out".into(),
                nm: "0".into(),
                vcontrol: "Vsense".into(),
                model: "CSW1".into(),
            },
        ]);
        let out = emit_netlist(&ir, "test");
        assert!(out.contains("S1 out 0 ctrl_p ctrl_m SW1"));
        assert!(out.contains("W1 out 0 Vsense CSW1"));
    }
}
