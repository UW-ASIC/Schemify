use std::fmt::Write;

use crate::dialect::Dialect;
use crate::ir::*;

// ---------------------------------------------------------------------------
// Value formatting
// ---------------------------------------------------------------------------

/// Format a floating-point number with SI suffix.
///
/// SPICE convention: `Meg` for 1e6 (NOT `M`, which means milli).
/// Zero is always `"0"`. Negative values get a leading `-`.
pub fn format_si(v: f64) -> String {
    if v == 0.0 {
        return "0".into();
    }

    let (abs, sign) = if v < 0.0 { (-v, "-") } else { (v, "") };

    // Ordered from largest to smallest so we pick the best suffix.
    let tiers: &[(f64, &str)] = &[
        (1e12, "T"),
        (1e9,  "G"),
        (1e6,  "Meg"),
        (1e3,  "k"),
        (1.0,  ""),
        (1e-3, "m"),
        (1e-6, "u"),
        (1e-9, "n"),
        (1e-12, "p"),
        (1e-15, "f"),
    ];

    for &(threshold, suffix) in tiers {
        if abs >= threshold * (1.0 - 1e-12) {
            let scaled = abs / threshold;
            return format!("{sign}{}", format_scaled(scaled, suffix));
        }
    }

    // Below 1e-15 → atto
    let scaled = abs / 1e-18;
    format!("{sign}{}", format_scaled(scaled, "a"))
}

/// Format the scaled mantissa + suffix, trimming unnecessary trailing zeros.
fn format_scaled(scaled: f64, suffix: &str) -> String {
    // If the scaled value is very close to an integer, emit it as integer.
    let rounded = scaled.round();
    if (scaled - rounded).abs() < 1e-9 * rounded.abs().max(1.0) {
        let int_val = rounded as i64;
        return format!("{int_val}{suffix}");
    }

    // Otherwise use up to 4 significant fractional digits and trim trailing zeros.
    let s = format!("{scaled:.4}");
    let s = s.trim_end_matches('0');
    let s = s.trim_end_matches('.');
    format!("{s}{suffix}")
}

/// Emit a `Value` for the given dialect.
pub fn emit_value(val: &Value, dialect: Dialect) -> String {
    match val {
        Value::Literal(v) => format_si(*v),
        Value::SiLiteral(s) => s.clone(),
        Value::Param(name) => match dialect {
            Dialect::Spectre => name.clone(),
            Dialect::NgSpice | Dialect::Xyce | Dialect::LtSpice => name.clone(),
        },
        Value::Expr(expr) => match dialect {
            Dialect::Spectre => expr.clone(),
            Dialect::NgSpice | Dialect::Xyce | Dialect::LtSpice => format!("{{{expr}}}"),
        },
    }
}

// ---------------------------------------------------------------------------
// Param helpers
// ---------------------------------------------------------------------------

fn emit_params_inline(params: &[Param], dialect: Dialect) -> String {
    let mut s = String::new();
    for p in params {
        if !s.is_empty() {
            s.push(' ');
        }
        write!(s, "{}={}", p.key, emit_value(&p.value, dialect)).unwrap();
    }
    s
}

fn emit_params_paren(params: &[Param], dialect: Dialect) -> String {
    if params.is_empty() {
        return String::new();
    }
    let mut s = String::from("(");
    for (i, p) in params.iter().enumerate() {
        if i > 0 {
            s.push(' ');
        }
        write!(s, "{}={}", p.key, emit_value(&p.value, dialect)).unwrap();
    }
    s.push(')');
    s
}

// ---------------------------------------------------------------------------
// Component emission
// ---------------------------------------------------------------------------

/// Emit a single component line for the given dialect.
pub fn emit_component(comp: &SpiceComponent, dialect: Dialect) -> String {
    match dialect {
        Dialect::NgSpice | Dialect::LtSpice => emit_component_spice(comp, dialect, false),
        Dialect::Xyce => emit_component_spice(comp, dialect, false),
        Dialect::Spectre => emit_component_spectre(comp),
    }
}

/// Standard SPICE (ngspice/Xyce/LTspice) component emission.
fn emit_component_spice(comp: &SpiceComponent, dialect: Dialect, _uppercase: bool) -> String {
    match comp {
        SpiceComponent::Resistor { name, nodes, value } => {
            format!("{name} {} {} {}", nodes[0], nodes[1], emit_value(value, dialect))
        }
        SpiceComponent::Capacitor { name, nodes, value } => {
            format!("{name} {} {} {}", nodes[0], nodes[1], emit_value(value, dialect))
        }
        SpiceComponent::Inductor { name, nodes, value } => {
            format!("{name} {} {} {}", nodes[0], nodes[1], emit_value(value, dialect))
        }
        SpiceComponent::Diode { name, nodes, model } => {
            format!("{name} {} {} {model}", nodes[0], nodes[1])
        }
        SpiceComponent::Mosfet { name, nodes, model, params } => {
            let mut s = format!(
                "{name} {} {} {} {} {model}",
                nodes[0], nodes[1], nodes[2], nodes[3]
            );
            if !params.is_empty() {
                write!(s, " {}", emit_params_inline(params, dialect)).unwrap();
            }
            s
        }
        SpiceComponent::Bjt { name, nodes, model, params } => {
            let mut s = format!(
                "{name} {} {} {} {model}",
                nodes[0], nodes[1], nodes[2]
            );
            if !params.is_empty() {
                write!(s, " {}", emit_params_inline(params, dialect)).unwrap();
            }
            s
        }
        SpiceComponent::Jfet { name, nodes, model, params } => {
            let mut s = format!(
                "{name} {} {} {} {model}",
                nodes[0], nodes[1], nodes[2]
            );
            if !params.is_empty() {
                write!(s, " {}", emit_params_inline(params, dialect)).unwrap();
            }
            s
        }
        SpiceComponent::Vsource { name, nodes, value } => {
            format!("{name} {} {} {}", nodes[0], nodes[1], emit_value(value, dialect))
        }
        SpiceComponent::Isource { name, nodes, value } => {
            format!("{name} {} {} {}", nodes[0], nodes[1], emit_value(value, dialect))
        }
        SpiceComponent::Vcvs { name, nodes, gain } => {
            format!(
                "{name} {} {} {} {} {}",
                nodes[0], nodes[1], nodes[2], nodes[3],
                emit_value(gain, dialect)
            )
        }
        SpiceComponent::Vccs { name, nodes, gain } => {
            format!(
                "{name} {} {} {} {} {}",
                nodes[0], nodes[1], nodes[2], nodes[3],
                emit_value(gain, dialect)
            )
        }
        SpiceComponent::Ccvs { name, nodes, gain } => {
            format!(
                "{name} {} {} {} {} {}",
                nodes[0], nodes[1], nodes[2], nodes[3],
                emit_value(gain, dialect)
            )
        }
        SpiceComponent::Cccs { name, nodes, gain } => {
            format!(
                "{name} {} {} {} {} {}",
                nodes[0], nodes[1], nodes[2], nodes[3],
                emit_value(gain, dialect)
            )
        }
        SpiceComponent::Subcircuit { name, nodes, subckt_name, params } => {
            let mut s = format!("{name} {}", nodes.join(" "));
            write!(s, " {subckt_name}").unwrap();
            if !params.is_empty() {
                write!(s, " {}", emit_params_inline(params, dialect)).unwrap();
            }
            s
        }
        SpiceComponent::Raw { text } => text.clone(),
    }
}

/// Spectre component emission — completely different syntax.
fn emit_component_spectre(comp: &SpiceComponent) -> String {
    let dialect = Dialect::Spectre;
    match comp {
        SpiceComponent::Resistor { name, nodes, value } => {
            format!(
                "resistor {name} ({} {}) r={}",
                nodes[0], nodes[1], emit_value(value, dialect)
            )
        }
        SpiceComponent::Capacitor { name, nodes, value } => {
            format!(
                "capacitor {name} ({} {}) c={}",
                nodes[0], nodes[1], emit_value(value, dialect)
            )
        }
        SpiceComponent::Inductor { name, nodes, value } => {
            format!(
                "inductor {name} ({} {}) l={}",
                nodes[0], nodes[1], emit_value(value, dialect)
            )
        }
        SpiceComponent::Diode { name, nodes, model } => {
            format!(
                "diode {name} ({} {}) {model}",
                nodes[0], nodes[1]
            )
        }
        SpiceComponent::Mosfet { name, nodes, model, params } => {
            let mut s = format!(
                "nmos4 {name} ({} {} {} {}) {model}",
                nodes[0], nodes[1], nodes[2], nodes[3]
            );
            if !params.is_empty() {
                write!(s, " {}", emit_params_inline(params, dialect)).unwrap();
            }
            s
        }
        SpiceComponent::Bjt { name, nodes, model, params } => {
            let mut s = format!(
                "bjt {name} ({} {} {}) {model}",
                nodes[0], nodes[1], nodes[2]
            );
            if !params.is_empty() {
                write!(s, " {}", emit_params_inline(params, dialect)).unwrap();
            }
            s
        }
        SpiceComponent::Jfet { name, nodes, model, params } => {
            let mut s = format!(
                "jfet {name} ({} {} {}) {model}",
                nodes[0], nodes[1], nodes[2]
            );
            if !params.is_empty() {
                write!(s, " {}", emit_params_inline(params, dialect)).unwrap();
            }
            s
        }
        SpiceComponent::Vsource { name, nodes, value } => {
            format!(
                "vsource {name} ({} {}) type=dc dc={}",
                nodes[0], nodes[1], emit_value(value, dialect)
            )
        }
        SpiceComponent::Isource { name, nodes, value } => {
            format!(
                "isource {name} ({} {}) type=dc dc={}",
                nodes[0], nodes[1], emit_value(value, dialect)
            )
        }
        SpiceComponent::Vcvs { name, nodes, gain } => {
            format!(
                "vcvs {name} ({} {} {} {}) gain={}",
                nodes[0], nodes[1], nodes[2], nodes[3],
                emit_value(gain, dialect)
            )
        }
        SpiceComponent::Vccs { name, nodes, gain } => {
            format!(
                "vccs {name} ({} {} {} {}) gain={}",
                nodes[0], nodes[1], nodes[2], nodes[3],
                emit_value(gain, dialect)
            )
        }
        SpiceComponent::Ccvs { name, nodes, gain } => {
            format!(
                "ccvs {name} ({} {} {} {}) gain={}",
                nodes[0], nodes[1], nodes[2], nodes[3],
                emit_value(gain, dialect)
            )
        }
        SpiceComponent::Cccs { name, nodes, gain } => {
            format!(
                "cccs {name} ({} {} {} {}) gain={}",
                nodes[0], nodes[1], nodes[2], nodes[3],
                emit_value(gain, dialect)
            )
        }
        SpiceComponent::Subcircuit { name, nodes, subckt_name, params } => {
            let mut s = format!(
                "{subckt_name} {name} ({})",
                nodes.join(" ")
            );
            if !params.is_empty() {
                write!(s, " {}", emit_params_inline(params, dialect)).unwrap();
            }
            s
        }
        SpiceComponent::Raw { text } => text.clone(),
    }
}

// ---------------------------------------------------------------------------
// Analysis emission
// ---------------------------------------------------------------------------

fn emit_analysis(analysis: &Analysis, dialect: Dialect) -> String {
    match dialect {
        Dialect::NgSpice | Dialect::LtSpice => emit_analysis_spice(analysis, false),
        Dialect::Xyce => emit_analysis_spice(analysis, true),
        Dialect::Spectre => emit_analysis_spectre(analysis),
    }
}

fn emit_ac_variation(v: AcVariation) -> &'static str {
    match v {
        AcVariation::Dec => "dec",
        AcVariation::Oct => "oct",
        AcVariation::Lin => "lin",
    }
}

fn emit_analysis_spice(analysis: &Analysis, uppercase: bool) -> String {
    let cmd = |s: &str| -> String {
        if uppercase { format!(".{}", s.to_uppercase()) } else { format!(".{s}") }
    };

    match analysis {
        Analysis::Op => cmd("op"),
        Analysis::Dc { source, start, stop, step } => {
            format!(
                "{} {source} {} {} {}",
                cmd("dc"),
                format_si(*start),
                format_si(*stop),
                format_si(*step)
            )
        }
        Analysis::Ac { variation, points, start, stop } => {
            format!(
                "{} {} {points} {} {}",
                cmd("ac"),
                emit_ac_variation(*variation),
                format_si(*start),
                format_si(*stop)
            )
        }
        Analysis::Tran { step, stop, start } => {
            if *start == 0.0 {
                format!(
                    "{} {} {}",
                    cmd("tran"),
                    format_si(*step),
                    format_si(*stop)
                )
            } else {
                format!(
                    "{} {} {} {}",
                    cmd("tran"),
                    format_si(*step),
                    format_si(*stop),
                    format_si(*start)
                )
            }
        }
        Analysis::Noise { output, source, variation, points, start, stop } => {
            format!(
                "{} {output} {source} {} {points} {} {}",
                cmd("noise"),
                emit_ac_variation(*variation),
                format_si(*start),
                format_si(*stop)
            )
        }
    }
}

fn emit_analysis_spectre(analysis: &Analysis) -> String {
    match analysis {
        Analysis::Op => "dc".into(),
        Analysis::Dc { source, start, stop, step } => {
            format!(
                "dc src={source} start={} stop={} step={}",
                format_si(*start),
                format_si(*stop),
                format_si(*step)
            )
        }
        Analysis::Ac { variation, points, start, stop } => {
            format!(
                "ac freq={} start={} stop={} n={points}",
                emit_ac_variation(*variation),
                format_si(*start),
                format_si(*stop)
            )
        }
        Analysis::Tran { step, stop, start } => {
            if *start == 0.0 {
                format!(
                    "tran step={} stop={}",
                    format_si(*step),
                    format_si(*stop)
                )
            } else {
                format!(
                    "tran step={} stop={} start={}",
                    format_si(*step),
                    format_si(*stop),
                    format_si(*start)
                )
            }
        }
        Analysis::Noise { output, source, variation, points, start, stop } => {
            format!(
                "noise output={output} src={source} freq={} start={} stop={} n={points}",
                emit_ac_variation(*variation),
                format_si(*start),
                format_si(*stop)
            )
        }
    }
}

// ---------------------------------------------------------------------------
// Model emission
// ---------------------------------------------------------------------------

fn emit_model(model: &ModelStatement, dialect: Dialect) -> String {
    match dialect {
        Dialect::NgSpice | Dialect::LtSpice => {
            let params = emit_params_paren(&model.params, dialect);
            format!(".model {} {} {params}", model.name, model.model_type)
        }
        Dialect::Xyce => {
            let params = emit_params_paren(&model.params, dialect);
            format!(".MODEL {} {} {params}", model.name, model.model_type)
        }
        Dialect::Spectre => {
            let mut s = format!("model {} {} ", model.name, model.model_type);
            s.push_str(&emit_params_inline(&model.params, dialect));
            s
        }
    }
}

// ---------------------------------------------------------------------------
// Subcircuit definition emission
// ---------------------------------------------------------------------------

fn emit_subcircuit_def(sub: &SubcircuitDef, dialect: Dialect) -> String {
    let mut out = String::new();

    match dialect {
        Dialect::NgSpice | Dialect::LtSpice => {
            write!(out, ".subckt {} {}", sub.name, sub.ports.join(" ")).unwrap();
            if !sub.params.is_empty() {
                write!(out, " {}", emit_params_inline(&sub.params, dialect)).unwrap();
            }
            writeln!(out).unwrap();
        }
        Dialect::Xyce => {
            write!(out, ".SUBCKT {} {}", sub.name, sub.ports.join(" ")).unwrap();
            if !sub.params.is_empty() {
                write!(out, " PARAMS: {}", emit_params_inline(&sub.params, dialect)).unwrap();
            }
            writeln!(out).unwrap();
        }
        Dialect::Spectre => {
            write!(
                out,
                "subckt {} ({})",
                sub.name,
                sub.ports.join(" ")
            ).unwrap();
            if !sub.params.is_empty() {
                write!(out, " parameters {}", emit_params_inline(&sub.params, dialect)).unwrap();
            }
            writeln!(out).unwrap();
        }
    }

    // Models inside the subcircuit
    for m in &sub.models {
        writeln!(out, "  {}", emit_model(m, dialect)).unwrap();
    }

    // Components inside the subcircuit
    for c in &sub.components {
        writeln!(out, "  {}", emit_component(c, dialect)).unwrap();
    }

    // End
    match dialect {
        Dialect::NgSpice | Dialect::LtSpice => write!(out, ".ends {}", sub.name).unwrap(),
        Dialect::Xyce => write!(out, ".ENDS {}", sub.name).unwrap(),
        Dialect::Spectre => write!(out, "ends {}", sub.name).unwrap(),
    }

    out
}

// ---------------------------------------------------------------------------
// Measurement emission
// ---------------------------------------------------------------------------

fn emit_measurement(meas: &Measurement, dialect: Dialect) -> String {
    match dialect {
        Dialect::NgSpice | Dialect::LtSpice => {
            format!(".meas {} {} {}", meas.analysis, meas.name, meas.expr)
        }
        Dialect::Xyce => {
            format!(".MEASURE {} {} {}", meas.analysis, meas.name, meas.expr)
        }
        Dialect::Spectre => {
            // Spectre doesn't have a direct .meas equivalent; emit as a comment + export
            format!("// measure {} {} {}", meas.name, meas.analysis, meas.expr)
        }
    }
}

// ---------------------------------------------------------------------------
// Full netlist emission
// ---------------------------------------------------------------------------

/// Emit a complete SPICE netlist for the given dialect.
pub fn emit_netlist(netlist: &SpiceNetlist, dialect: Dialect) -> String {
    let mut out = String::new();

    // Title line
    match dialect {
        Dialect::NgSpice | Dialect::LtSpice | Dialect::Xyce => {
            writeln!(out, "* {}", netlist.title).unwrap();
        }
        Dialect::Spectre => {
            writeln!(out, "// {}", netlist.title).unwrap();
        }
    }
    writeln!(out).unwrap();

    // Includes
    if !netlist.includes.is_empty() {
        for inc in &netlist.includes {
            match dialect {
                Dialect::NgSpice | Dialect::LtSpice => writeln!(out, ".include \"{inc}\"").unwrap(),
                Dialect::Xyce => writeln!(out, ".INCLUDE \"{inc}\"").unwrap(),
                Dialect::Spectre => writeln!(out, "include \"{inc}\"").unwrap(),
            }
        }
        writeln!(out).unwrap();
    }

    // Options
    if !netlist.options.is_empty() {
        for opt in &netlist.options {
            match dialect {
                Dialect::NgSpice | Dialect::LtSpice => writeln!(out, ".option {opt}").unwrap(),
                Dialect::Xyce => writeln!(out, ".OPTIONS {opt}").unwrap(),
                Dialect::Spectre => writeln!(out, "option {opt}").unwrap(),
            }
        }
        writeln!(out).unwrap();
    }

    // Parameters
    if !netlist.params.is_empty() {
        for p in &netlist.params {
            match dialect {
                Dialect::NgSpice | Dialect::LtSpice => {
                    writeln!(out, ".param {}={}", p.key, emit_value(&p.value, dialect)).unwrap();
                }
                Dialect::Xyce => {
                    writeln!(out, ".PARAM {}={}", p.key, emit_value(&p.value, dialect)).unwrap();
                }
                Dialect::Spectre => {
                    writeln!(
                        out,
                        "parameters {}={}",
                        p.key,
                        emit_value(&p.value, dialect)
                    ).unwrap();
                }
            }
        }
        writeln!(out).unwrap();
    }

    // Models
    if !netlist.models.is_empty() {
        for m in &netlist.models {
            writeln!(out, "{}", emit_model(m, dialect)).unwrap();
        }
        writeln!(out).unwrap();
    }

    // Subcircuit definitions
    if !netlist.subcircuits.is_empty() {
        for sub in &netlist.subcircuits {
            writeln!(out, "{}", emit_subcircuit_def(sub, dialect)).unwrap();
        }
        writeln!(out).unwrap();
    }

    // Components
    if !netlist.components.is_empty() {
        for c in &netlist.components {
            writeln!(out, "{}", emit_component(c, dialect)).unwrap();
        }
        writeln!(out).unwrap();
    }

    // Analyses
    if !netlist.analyses.is_empty() {
        for a in &netlist.analyses {
            writeln!(out, "{}", emit_analysis(a, dialect)).unwrap();
        }
        writeln!(out).unwrap();
    }

    // Measurements
    if !netlist.measurements.is_empty() {
        for m in &netlist.measurements {
            writeln!(out, "{}", emit_measurement(m, dialect)).unwrap();
        }
        writeln!(out).unwrap();
    }

    // End
    match dialect {
        Dialect::NgSpice | Dialect::LtSpice => write!(out, ".end").unwrap(),
        Dialect::Xyce => write!(out, ".END").unwrap(),
        Dialect::Spectre => { /* Spectre files don't have .end */ }
    }

    out
}

// ===========================================================================
// Tests
// ===========================================================================

#[cfg(test)]
mod tests {
    use super::*;

    // -----------------------------------------------------------------------
    // SI formatting
    // -----------------------------------------------------------------------

    #[test]
    fn si_zero() {
        assert_eq!(format_si(0.0), "0");
    }

    #[test]
    fn si_integer_values() {
        assert_eq!(format_si(10_000.0), "10k");
        assert_eq!(format_si(100.0), "100");
        assert_eq!(format_si(1.0), "1");
    }

    #[test]
    fn si_standard_suffixes() {
        assert_eq!(format_si(1e-6), "1u");
        assert_eq!(format_si(1e-9), "1n");
        assert_eq!(format_si(1e-12), "1p");
        assert_eq!(format_si(1e-15), "1f");
        assert_eq!(format_si(1e3), "1k");
        assert_eq!(format_si(1e6), "1Meg");
        assert_eq!(format_si(1e9), "1G");
        assert_eq!(format_si(1e12), "1T");
    }

    #[test]
    fn si_fractional() {
        assert_eq!(format_si(4.7e3), "4.7k");
        assert_eq!(format_si(2.2e-6), "2.2u");
        assert_eq!(format_si(180e-9), "180n");
        assert_eq!(format_si(3.3), "3.3");
    }

    #[test]
    fn si_negative() {
        assert_eq!(format_si(-10_000.0), "-10k");
        assert_eq!(format_si(-1e-9), "-1n");
    }

    #[test]
    fn si_atto() {
        assert_eq!(format_si(1e-18), "1a");
        assert_eq!(format_si(5e-18), "5a");
    }

    #[test]
    fn si_milli() {
        assert_eq!(format_si(1e-3), "1m");
        assert_eq!(format_si(2.5e-3), "2.5m");
    }

    // -----------------------------------------------------------------------
    // Value emission
    // -----------------------------------------------------------------------

    #[test]
    fn value_literal() {
        assert_eq!(emit_value(&Value::Literal(10_000.0), Dialect::NgSpice), "10k");
    }

    #[test]
    fn value_si_passthrough() {
        assert_eq!(emit_value(&Value::SiLiteral("10k".into()), Dialect::NgSpice), "10k");
    }

    #[test]
    fn value_param() {
        assert_eq!(emit_value(&Value::Param("gm".into()), Dialect::NgSpice), "gm");
        assert_eq!(emit_value(&Value::Param("gm".into()), Dialect::Spectre), "gm");
    }

    #[test]
    fn value_expr_spice() {
        assert_eq!(
            emit_value(&Value::Expr("gm * 2".into()), Dialect::NgSpice),
            "{gm * 2}"
        );
        assert_eq!(
            emit_value(&Value::Expr("gm * 2".into()), Dialect::Xyce),
            "{gm * 2}"
        );
        assert_eq!(
            emit_value(&Value::Expr("gm * 2".into()), Dialect::LtSpice),
            "{gm * 2}"
        );
    }

    #[test]
    fn value_expr_spectre() {
        assert_eq!(
            emit_value(&Value::Expr("gm * 2".into()), Dialect::Spectre),
            "gm * 2"
        );
    }

    // -----------------------------------------------------------------------
    // Component emission — NgSpice
    // -----------------------------------------------------------------------

    #[test]
    fn resistor_ngspice() {
        let r = SpiceComponent::resistor("R0", "a", "b", Value::Literal(10_000.0));
        assert_eq!(emit_component(&r, Dialect::NgSpice), "R0 a b 10k");
    }

    #[test]
    fn capacitor_ngspice() {
        let c = SpiceComponent::capacitor("C1", "in", "gnd", Value::Literal(1e-6));
        assert_eq!(emit_component(&c, Dialect::NgSpice), "C1 in gnd 1u");
    }

    #[test]
    fn inductor_ngspice() {
        let l = SpiceComponent::inductor("L1", "a", "b", Value::Literal(1e-3));
        assert_eq!(emit_component(&l, Dialect::NgSpice), "L1 a b 1m");
    }

    #[test]
    fn mosfet_ngspice() {
        let m = SpiceComponent::Mosfet {
            name: "M1".into(),
            nodes: ["d".into(), "g".into(), "s".into(), "b".into()],
            model: "nmos_3p3".into(),
            params: vec![
                Param::new("W", Value::si("1u")),
                Param::new("L", Value::si("180n")),
            ],
        };
        assert_eq!(
            emit_component(&m, Dialect::NgSpice),
            "M1 d g s b nmos_3p3 W=1u L=180n"
        );
    }

    #[test]
    fn subcircuit_instance_ngspice() {
        let x = SpiceComponent::Subcircuit {
            name: "X1".into(),
            nodes: vec!["in".into(), "out".into(), "vdd".into(), "vss".into()],
            subckt_name: "opamp".into(),
            params: vec![Param::new("gain", Value::Literal(1000.0))],
        };
        assert_eq!(
            emit_component(&x, Dialect::NgSpice),
            "X1 in out vdd vss opamp gain=1k"
        );
    }

    #[test]
    fn vsource_ngspice() {
        let v = SpiceComponent::vsource("V1", "vdd", "0", Value::Literal(3.3));
        assert_eq!(emit_component(&v, Dialect::NgSpice), "V1 vdd 0 3.3");
    }

    #[test]
    fn diode_ngspice() {
        let d = SpiceComponent::Diode {
            name: "D1".into(),
            nodes: ["a".into(), "k".into()],
            model: "1N4148".into(),
        };
        assert_eq!(emit_component(&d, Dialect::NgSpice), "D1 a k 1N4148");
    }

    #[test]
    fn bjt_ngspice() {
        let q = SpiceComponent::Bjt {
            name: "Q1".into(),
            nodes: ["c".into(), "b".into(), "e".into()],
            model: "2N2222".into(),
            params: vec![],
        };
        assert_eq!(emit_component(&q, Dialect::NgSpice), "Q1 c b e 2N2222");
    }

    #[test]
    fn jfet_ngspice() {
        let j = SpiceComponent::Jfet {
            name: "J1".into(),
            nodes: ["d".into(), "g".into(), "s".into()],
            model: "2N5457".into(),
            params: vec![],
        };
        assert_eq!(emit_component(&j, Dialect::NgSpice), "J1 d g s 2N5457");
    }

    #[test]
    fn vcvs_ngspice() {
        let e = SpiceComponent::Vcvs {
            name: "E1".into(),
            nodes: ["out+".into(), "out-".into(), "in+".into(), "in-".into()],
            gain: Value::Literal(10.0),
        };
        assert_eq!(
            emit_component(&e, Dialect::NgSpice),
            "E1 out+ out- in+ in- 10"
        );
    }

    #[test]
    fn raw_component() {
        let r = SpiceComponent::Raw { text: ".lib 'models.lib' tt".into() };
        assert_eq!(emit_component(&r, Dialect::NgSpice), ".lib 'models.lib' tt");
    }

    // -----------------------------------------------------------------------
    // Component emission — Spectre
    // -----------------------------------------------------------------------

    #[test]
    fn resistor_spectre() {
        let r = SpiceComponent::resistor("r0", "a", "b", Value::Literal(10_000.0));
        assert_eq!(
            emit_component(&r, Dialect::Spectre),
            "resistor r0 (a b) r=10k"
        );
    }

    #[test]
    fn mosfet_spectre() {
        let m = SpiceComponent::Mosfet {
            name: "m1".into(),
            nodes: ["d".into(), "g".into(), "s".into(), "b".into()],
            model: "nch".into(),
            params: vec![
                Param::new("w", Value::si("1u")),
                Param::new("l", Value::si("180n")),
            ],
        };
        assert_eq!(
            emit_component(&m, Dialect::Spectre),
            "nmos4 m1 (d g s b) nch w=1u l=180n"
        );
    }

    #[test]
    fn vsource_spectre() {
        let v = SpiceComponent::vsource("v1", "vdd", "0", Value::Literal(3.3));
        assert_eq!(
            emit_component(&v, Dialect::Spectre),
            "vsource v1 (vdd 0) type=dc dc=3.3"
        );
    }

    #[test]
    fn subcircuit_instance_spectre() {
        let x = SpiceComponent::Subcircuit {
            name: "i0".into(),
            nodes: vec!["in".into(), "out".into()],
            subckt_name: "opamp".into(),
            params: vec![Param::new("gain", Value::Literal(1000.0))],
        };
        assert_eq!(
            emit_component(&x, Dialect::Spectre),
            "opamp i0 (in out) gain=1k"
        );
    }

    #[test]
    fn capacitor_spectre() {
        let c = SpiceComponent::capacitor("c0", "in", "gnd", Value::Literal(1e-12));
        assert_eq!(
            emit_component(&c, Dialect::Spectre),
            "capacitor c0 (in gnd) c=1p"
        );
    }

    #[test]
    fn inductor_spectre() {
        let l = SpiceComponent::inductor("l0", "a", "b", Value::Literal(1e-9));
        assert_eq!(
            emit_component(&l, Dialect::Spectre),
            "inductor l0 (a b) l=1n"
        );
    }

    #[test]
    fn diode_spectre() {
        let d = SpiceComponent::Diode {
            name: "d1".into(),
            nodes: ["a".into(), "k".into()],
            model: "diomod".into(),
        };
        assert_eq!(
            emit_component(&d, Dialect::Spectre),
            "diode d1 (a k) diomod"
        );
    }

    #[test]
    fn isource_spectre() {
        let i = SpiceComponent::isource("i1", "a", "b", Value::si("1m"));
        assert_eq!(
            emit_component(&i, Dialect::Spectre),
            "isource i1 (a b) type=dc dc=1m"
        );
    }

    // -----------------------------------------------------------------------
    // Analysis emission
    // -----------------------------------------------------------------------

    #[test]
    fn analysis_op_ngspice() {
        assert_eq!(
            emit_analysis(&Analysis::Op, Dialect::NgSpice),
            ".op"
        );
    }

    #[test]
    fn analysis_op_xyce() {
        assert_eq!(
            emit_analysis(&Analysis::Op, Dialect::Xyce),
            ".OP"
        );
    }

    #[test]
    fn analysis_op_spectre() {
        assert_eq!(
            emit_analysis(&Analysis::Op, Dialect::Spectre),
            "dc"
        );
    }

    #[test]
    fn analysis_dc_ngspice() {
        let a = Analysis::Dc {
            source: "V1".into(),
            start: 0.0,
            stop: 5.0,
            step: 0.1,
        };
        assert_eq!(
            emit_analysis(&a, Dialect::NgSpice),
            ".dc V1 0 5 100m"
        );
    }

    #[test]
    fn analysis_dc_xyce() {
        let a = Analysis::Dc {
            source: "V1".into(),
            start: 0.0,
            stop: 5.0,
            step: 0.1,
        };
        assert_eq!(
            emit_analysis(&a, Dialect::Xyce),
            ".DC V1 0 5 100m"
        );
    }

    #[test]
    fn analysis_dc_spectre() {
        let a = Analysis::Dc {
            source: "V1".into(),
            start: 0.0,
            stop: 5.0,
            step: 0.1,
        };
        assert_eq!(
            emit_analysis(&a, Dialect::Spectre),
            "dc src=V1 start=0 stop=5 step=100m"
        );
    }

    #[test]
    fn analysis_ac_ngspice() {
        let a = Analysis::Ac {
            variation: AcVariation::Dec,
            points: 100,
            start: 1.0,
            stop: 1e9,
        };
        assert_eq!(
            emit_analysis(&a, Dialect::NgSpice),
            ".ac dec 100 1 1G"
        );
    }

    #[test]
    fn analysis_tran_ngspice() {
        let a = Analysis::Tran { step: 1e-9, stop: 1e-3, start: 0.0 };
        assert_eq!(
            emit_analysis(&a, Dialect::NgSpice),
            ".tran 1n 1m"
        );
    }

    #[test]
    fn analysis_tran_xyce() {
        let a = Analysis::Tran { step: 1e-9, stop: 1e-3, start: 0.0 };
        assert_eq!(
            emit_analysis(&a, Dialect::Xyce),
            ".TRAN 1n 1m"
        );
    }

    #[test]
    fn analysis_tran_spectre() {
        let a = Analysis::Tran { step: 1e-9, stop: 1e-3, start: 0.0 };
        assert_eq!(
            emit_analysis(&a, Dialect::Spectre),
            "tran step=1n stop=1m"
        );
    }

    #[test]
    fn analysis_tran_with_start() {
        let a = Analysis::Tran { step: 1e-9, stop: 1e-3, start: 1e-6 };
        assert_eq!(
            emit_analysis(&a, Dialect::NgSpice),
            ".tran 1n 1m 1u"
        );
    }

    #[test]
    fn analysis_noise_ngspice() {
        let a = Analysis::Noise {
            output: "V(out)".into(),
            source: "V1".into(),
            variation: AcVariation::Dec,
            points: 10,
            start: 1.0,
            stop: 1e9,
        };
        assert_eq!(
            emit_analysis(&a, Dialect::NgSpice),
            ".noise V(out) V1 dec 10 1 1G"
        );
    }

    // -----------------------------------------------------------------------
    // Model emission
    // -----------------------------------------------------------------------

    #[test]
    fn model_ngspice() {
        let m = ModelStatement {
            name: "nmos_3p3".into(),
            model_type: "nmos".into(),
            params: vec![
                Param::new("vth0", Value::Literal(0.4)),
                Param::new("tox", Value::Literal(7e-9)),
            ],
        };
        assert_eq!(
            emit_model(&m, Dialect::NgSpice),
            ".model nmos_3p3 nmos (vth0=400m tox=7n)"
        );
    }

    #[test]
    fn model_xyce() {
        let m = ModelStatement {
            name: "nmos_3p3".into(),
            model_type: "nmos".into(),
            params: vec![
                Param::new("vth0", Value::Literal(0.4)),
            ],
        };
        assert_eq!(
            emit_model(&m, Dialect::Xyce),
            ".MODEL nmos_3p3 nmos (vth0=400m)"
        );
    }

    #[test]
    fn model_spectre() {
        let m = ModelStatement {
            name: "nmos_3p3".into(),
            model_type: "nmos".into(),
            params: vec![
                Param::new("vth0", Value::Literal(0.4)),
                Param::new("tox", Value::Literal(7e-9)),
            ],
        };
        assert_eq!(
            emit_model(&m, Dialect::Spectre),
            "model nmos_3p3 nmos vth0=400m tox=7n"
        );
    }

    // -----------------------------------------------------------------------
    // Subcircuit def emission
    // -----------------------------------------------------------------------

    #[test]
    fn subcircuit_def_ngspice() {
        let sub = SubcircuitDef {
            name: "opamp".into(),
            ports: vec!["in+".into(), "in-".into(), "out".into(), "vdd".into(), "vss".into()],
            params: vec![],
            components: vec![
                SpiceComponent::resistor("R1", "in+", "mid", Value::si("10k")),
            ],
            models: vec![],
        };
        let result = emit_subcircuit_def(&sub, Dialect::NgSpice);
        assert!(result.starts_with(".subckt opamp in+ in- out vdd vss\n"));
        assert!(result.contains("  R1 in+ mid 10k"));
        assert!(result.ends_with(".ends opamp"));
    }

    #[test]
    fn subcircuit_def_xyce() {
        let sub = SubcircuitDef {
            name: "opamp".into(),
            ports: vec!["in+".into(), "in-".into(), "out".into()],
            params: vec![Param::new("gain", Value::Literal(1000.0))],
            components: vec![],
            models: vec![],
        };
        let result = emit_subcircuit_def(&sub, Dialect::Xyce);
        assert!(result.starts_with(".SUBCKT opamp in+ in- out PARAMS: gain=1k\n"));
        assert!(result.ends_with(".ENDS opamp"));
    }

    #[test]
    fn subcircuit_def_spectre() {
        let sub = SubcircuitDef {
            name: "opamp".into(),
            ports: vec!["in".into(), "out".into()],
            params: vec![],
            components: vec![
                SpiceComponent::resistor("r0", "in", "out", Value::si("10k")),
            ],
            models: vec![],
        };
        let result = emit_subcircuit_def(&sub, Dialect::Spectre);
        assert!(result.starts_with("subckt opamp (in out)\n"));
        assert!(result.contains("  resistor r0 (in out) r=10k"));
        assert!(result.ends_with("ends opamp"));
    }

    // -----------------------------------------------------------------------
    // Measurement emission
    // -----------------------------------------------------------------------

    #[test]
    fn measurement_ngspice() {
        let m = Measurement {
            name: "vout_avg".into(),
            analysis: "TRAN".into(),
            expr: "AVG V(out)".into(),
        };
        assert_eq!(
            emit_measurement(&m, Dialect::NgSpice),
            ".meas TRAN vout_avg AVG V(out)"
        );
    }

    #[test]
    fn measurement_xyce() {
        let m = Measurement {
            name: "vout_avg".into(),
            analysis: "TRAN".into(),
            expr: "AVG V(out)".into(),
        };
        assert_eq!(
            emit_measurement(&m, Dialect::Xyce),
            ".MEASURE TRAN vout_avg AVG V(out)"
        );
    }

    #[test]
    fn measurement_spectre() {
        let m = Measurement {
            name: "vout_avg".into(),
            analysis: "TRAN".into(),
            expr: "AVG V(out)".into(),
        };
        let result = emit_measurement(&m, Dialect::Spectre);
        assert!(result.starts_with("//"));
        assert!(result.contains("vout_avg"));
    }

    // -----------------------------------------------------------------------
    // Full netlist emission
    // -----------------------------------------------------------------------

    fn sample_netlist() -> SpiceNetlist {
        SpiceNetlist {
            title: "RC Low-Pass Filter".into(),
            includes: vec!["models.lib".into()],
            params: vec![Param::new("RL", Value::Literal(10_000.0))],
            models: vec![],
            subcircuits: vec![],
            components: vec![
                SpiceComponent::vsource("V1", "in", "0", Value::Literal(1.0)),
                SpiceComponent::resistor("R1", "in", "out", Value::Param("RL".into())),
                SpiceComponent::capacitor("C1", "out", "0", Value::Literal(1e-9)),
            ],
            analyses: vec![
                Analysis::Ac {
                    variation: AcVariation::Dec,
                    points: 100,
                    start: 1.0,
                    stop: 1e9,
                },
            ],
            measurements: vec![
                Measurement {
                    name: "bw".into(),
                    analysis: "AC".into(),
                    expr: "WHEN VDB(out)=-3".into(),
                },
            ],
            options: vec!["reltol=1e-6".into()],
        }
    }

    #[test]
    fn full_netlist_ngspice() {
        let nl = sample_netlist();
        let text = emit_netlist(&nl, Dialect::NgSpice);

        assert!(text.starts_with("* RC Low-Pass Filter\n"));
        assert!(text.contains(".include \"models.lib\""));
        assert!(text.contains(".option reltol=1e-6"));
        assert!(text.contains(".param RL=10k"));
        assert!(text.contains("V1 in 0 1"));
        assert!(text.contains("R1 in out RL"));
        assert!(text.contains("C1 out 0 1n"));
        assert!(text.contains(".ac dec 100 1 1G"));
        assert!(text.contains(".meas AC bw WHEN VDB(out)=-3"));
        assert!(text.ends_with(".end"));
    }

    #[test]
    fn full_netlist_xyce() {
        let nl = sample_netlist();
        let text = emit_netlist(&nl, Dialect::Xyce);

        assert!(text.starts_with("* RC Low-Pass Filter\n"));
        assert!(text.contains(".INCLUDE \"models.lib\""));
        assert!(text.contains(".OPTIONS reltol=1e-6"));
        assert!(text.contains(".PARAM RL=10k"));
        assert!(text.contains("V1 in 0 1"));
        assert!(text.contains("R1 in out RL"));
        assert!(text.contains("C1 out 0 1n"));
        assert!(text.contains(".AC dec 100 1 1G"));
        assert!(text.contains(".MEASURE AC bw WHEN VDB(out)=-3"));
        assert!(text.ends_with(".END"));
    }

    #[test]
    fn full_netlist_ltspice() {
        let nl = sample_netlist();
        let text = emit_netlist(&nl, Dialect::LtSpice);

        // LTspice uses lowercase like ngspice
        assert!(text.contains(".include \"models.lib\""));
        assert!(text.contains(".param RL=10k"));
        assert!(text.contains(".ac dec 100 1 1G"));
        assert!(text.contains(".meas AC bw WHEN VDB(out)=-3"));
        assert!(text.ends_with(".end"));
    }

    #[test]
    fn full_netlist_spectre() {
        let nl = sample_netlist();
        let text = emit_netlist(&nl, Dialect::Spectre);

        assert!(text.starts_with("// RC Low-Pass Filter\n"));
        assert!(text.contains("include \"models.lib\""));
        assert!(text.contains("option reltol=1e-6"));
        assert!(text.contains("parameters RL=10k"));
        assert!(text.contains("vsource V1 (in 0) type=dc dc=1"));
        assert!(text.contains("resistor R1 (in out) r=RL"));
        assert!(text.contains("capacitor C1 (out 0) c=1n"));
        assert!(text.contains("ac freq=dec start=1 stop=1G n=100"));
        // Spectre doesn't end with .end
        assert!(!text.contains(".end"));
    }

    // -----------------------------------------------------------------------
    // Same circuit in all 4 dialects
    // -----------------------------------------------------------------------

    #[test]
    fn four_dialect_comparison() {
        let nl = SpiceNetlist {
            title: "Inverter".into(),
            includes: vec![],
            params: vec![],
            models: vec![
                ModelStatement {
                    name: "nch".into(),
                    model_type: "nmos".into(),
                    params: vec![Param::new("vth0", Value::Literal(0.4))],
                },
            ],
            subcircuits: vec![],
            components: vec![
                SpiceComponent::vsource("V1", "vdd", "0", Value::Literal(1.8)),
                SpiceComponent::Mosfet {
                    name: "M1".into(),
                    nodes: ["out".into(), "in".into(), "0".into(), "0".into()],
                    model: "nch".into(),
                    params: vec![
                        Param::new("W", Value::si("1u")),
                        Param::new("L", Value::si("180n")),
                    ],
                },
                SpiceComponent::resistor("R1", "vdd", "out", Value::Literal(10_000.0)),
            ],
            analyses: vec![Analysis::Dc {
                source: "V1".into(),
                start: 0.0,
                stop: 1.8,
                step: 0.01,
            }],
            measurements: vec![],
            options: vec![],
        };

        let ng = emit_netlist(&nl, Dialect::NgSpice);
        let xy = emit_netlist(&nl, Dialect::Xyce);
        let lt = emit_netlist(&nl, Dialect::LtSpice);
        let sp = emit_netlist(&nl, Dialect::Spectre);

        // NgSpice: standard dot-commands, lowercase
        assert!(ng.contains(".model nch nmos (vth0=400m)"));
        assert!(ng.contains("M1 out in 0 0 nch W=1u L=180n"));
        assert!(ng.contains(".dc V1 0 1.8 10m"));
        assert!(ng.ends_with(".end"));

        // Xyce: uppercase dot-commands
        assert!(xy.contains(".MODEL nch nmos (vth0=400m)"));
        assert!(xy.contains(".DC V1 0 1.8 10m"));
        assert!(xy.ends_with(".END"));

        // LTspice: lowercase like ngspice
        assert!(lt.contains(".model nch nmos (vth0=400m)"));
        assert!(lt.ends_with(".end"));

        // Spectre: completely different
        assert!(sp.contains("model nch nmos vth0=400m"));
        assert!(sp.contains("nmos4 M1 (out in 0 0) nch W=1u L=180n"));
        assert!(sp.contains("dc src=V1 start=0 stop=1.8 step=10m"));
        assert!(!sp.contains(".end"));
    }

    // -----------------------------------------------------------------------
    // Edge cases
    // -----------------------------------------------------------------------

    #[test]
    fn empty_netlist() {
        let nl = SpiceNetlist::new("Empty");
        let text = emit_netlist(&nl, Dialect::NgSpice);
        assert_eq!(text, "* Empty\n\n.end");
    }

    #[test]
    fn netlist_with_subcircuit_def() {
        let nl = SpiceNetlist {
            title: "With Subckt".into(),
            subcircuits: vec![SubcircuitDef {
                name: "buf".into(),
                ports: vec!["in".into(), "out".into()],
                params: vec![],
                components: vec![
                    SpiceComponent::resistor("R1", "in", "out", Value::si("100")),
                ],
                models: vec![],
            }],
            components: vec![
                SpiceComponent::Subcircuit {
                    name: "X1".into(),
                    nodes: vec!["a".into(), "b".into()],
                    subckt_name: "buf".into(),
                    params: vec![],
                },
            ],
            ..SpiceNetlist::default()
        };

        let text = emit_netlist(&nl, Dialect::NgSpice);
        assert!(text.contains(".subckt buf in out\n"));
        assert!(text.contains("  R1 in out 100\n"));
        assert!(text.contains(".ends buf\n"));
        assert!(text.contains("X1 a b buf"));
    }
}
