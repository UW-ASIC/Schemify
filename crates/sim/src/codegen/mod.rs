//! Code generation from [`CircuitIR`]: PySpice Python scripts and plain
//! SPICE netlists.

mod pyspice;
mod spice;

pub use pyspice::*;
pub use spice::*;

#[cfg(test)]
mod tests {
    use super::*;

    use crate::ir::*;

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
        });
        CircuitIR::with_top(top)
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
    }

    /// End-to-end smoke for the sim runner's netlist path: python
    /// (pyspice_rs) renders the netlist, an analysis directive is spliced
    /// in before `.end`, ngspice runs it in batch mode, and the rawfile
    /// parses. Skips silently when the toolchain (bundled pyspice /
    /// ngspice) is absent — run inside `nix develop`.
    #[test]
    fn netlist_script_end_to_end() {
        use std::process::Command;

        let Some(pypath) = crate::pyspice::python_path() else {
            return;
        };
        if Command::new("ngspice").arg("--version").output().is_err() {
            return;
        }

        let ir = divider_ir();

        let dir = std::env::temp_dir().join("schemify_sim_test");
        std::fs::create_dir_all(&dir).unwrap();
        let script = dir.join("netlist_gen.py");
        std::fs::write(&script, emit_netlist_script(&ir)).unwrap();
        let out = Command::new(crate::pyspice::python_bin())
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
        assert!(sp.ends_with(".end\n"));
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
        assert!(sp.contains("J1 d g s jm\n"));
        assert!(sp.contains("Z2 d g s zm\n"));
    }
}
