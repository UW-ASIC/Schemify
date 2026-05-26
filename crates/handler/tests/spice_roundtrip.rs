//! SPICE exact roundtrip test.
//!
//! Flow: input .spice → import_spice() → Schematic → to_circuit_ir()
//!       → JSON bridge → PySpice Spice3CodeGen::emit_netlist() → output .spice
//!       → parse both → compare component-by-component (exact match).

use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::PathBuf;

use lasso::Rodeo;

use pyspice::codegen::spice3::{Spice3CodeGen, Spice3Dialect};
use pyspice::codegen::CodeGen;
use schemify_handler::netlist::to_circuit_ir;
use schemify_handler::spice_import::import_spice;

fn fixture(name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures")
        .join(name)
}

/// Bridge schemify-sim CircuitIR → pyspice CircuitIR via JSON.
fn bridge_ir(sim_ir: &schemify_sim::ir::CircuitIR) -> pyspice::ir::CircuitIR {
    let json = serde_json::to_string(sim_ir).expect("serialize sim IR");
    serde_json::from_str(&json).expect("deserialize to pyspice IR")
}

/// Run the full roundtrip: .spice → Schematic → CircuitIR → SPICE text.
fn roundtrip_to_spice(source: &str) -> String {
    let mut interner = Rodeo::default();
    let sch = import_spice(source, &mut interner)
        .unwrap_or_else(|e| panic!("import_spice failed: {e}"));
    let sim_ir = to_circuit_ir(&sch, &interner);
    let py_ir = bridge_ir(&sim_ir);
    let cg = Spice3CodeGen {
        dialect: Spice3Dialect::Ngspice,
    };
    cg.emit_netlist(&py_ir)
        .unwrap_or_else(|e| panic!("emit_netlist failed: {e}"))
}

// ---------------------------------------------------------------------------
// Normalized SPICE comparison
// ---------------------------------------------------------------------------

/// Parsed component: (prefix_char, name, sorted_tokens_after_name).
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
struct ParsedComponent {
    prefix: char,
    name: String,
    nets: Vec<String>,
    model_or_value: String,
    params: BTreeMap<String, String>,
}

/// Parse a SPICE netlist into a set of normalized components.
fn parse_spice_components(spice: &str) -> BTreeSet<ParsedComponent> {
    let mut components = BTreeSet::new();

    for line in spice.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('*') || line.starts_with('.') {
            continue;
        }

        let tokens: Vec<&str> = line.split_whitespace().collect();
        if tokens.is_empty() {
            continue;
        }

        let inst = tokens[0].to_lowercase();
        let prefix = inst.chars().next().unwrap_or(' ');

        let (net_count, has_model) = match prefix {
            'm' => (4, true),
            'r' | 'c' | 'l' => (2, false),
            'v' | 'i' => (2, false),
            'q' => (3, true),
            'j' => (3, true),
            'z' => (3, true),
            'd' => (2, true),
            'e' | 'g' => (4, false), // controlled sources: 4 nets + gain
            'f' | 'h' => (2, false), // current-controlled: 2 nets + vsense + gain
            'k' => (0, false),       // mutual inductor
            't' => (4, false),       // transmission line
            'x' => {
                // Subcircuit instance: x<name> <nets...> <subckt_name>
                // Variable net count — skip for now
                continue;
            }
            _ => continue,
        };

        if tokens.len() < 1 + net_count {
            continue;
        }

        let nets: Vec<String> = tokens[1..1 + net_count]
            .iter()
            .map(|t| t.to_lowercase())
            .collect();

        let remaining = &tokens[1 + net_count..];
        let model_or_value = if has_model && !remaining.is_empty() {
            remaining[0].to_lowercase()
        } else if !has_model && !remaining.is_empty() {
            normalize_value(remaining[0])
        } else {
            String::new()
        };

        let param_start = if model_or_value.is_empty() { 0 } else { 1 };
        let mut params = BTreeMap::new();
        for tok in remaining.iter().skip(param_start) {
            let tok_lower = tok.to_lowercase();
            if let Some(eq) = tok_lower.find('=') {
                let k = tok_lower[..eq].to_string();
                let v = normalize_value(&tok_lower[eq + 1..]);
                params.insert(k, v);
            }
        }

        components.insert(ParsedComponent {
            prefix,
            name: inst,
            nets,
            model_or_value,
            params,
        });
    }

    components
}

/// Normalize a SPICE value string for comparison.
/// Converts SI suffixes to numeric, rounds to avoid float drift.
fn normalize_value(s: &str) -> String {
    let s_lower = s.to_lowercase();

    // Try direct parse
    if let Ok(v) = s_lower.parse::<f64>() {
        return format_normalized(v);
    }

    // SI suffix
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
            Some(m) => (&s_lower[..s_lower.len() - 1], m),
            None => (s_lower.as_str(), 1.0),
        }
    } else {
        (s_lower.as_str(), 1.0)
    };

    if let Ok(v) = num_part.parse::<f64>() {
        return format_normalized(v * multiplier);
    }

    // Not numeric — return as-is
    s_lower
}

fn format_normalized(v: f64) -> String {
    if v == 0.0 {
        return "0".to_string();
    }
    // Use enough precision to distinguish values, but normalize representation
    let s = format!("{:.6e}", v);
    // Trim trailing zeros in mantissa
    s.trim_end_matches('0').trim_end_matches('.').to_string()
}

fn compare_components(
    input: &BTreeSet<ParsedComponent>,
    output: &BTreeSet<ParsedComponent>,
) -> Vec<String> {
    let mut errors = Vec::new();

    let input_by_name: BTreeMap<&str, &ParsedComponent> =
        input.iter().map(|c| (c.name.as_str(), c)).collect();
    let output_by_name: BTreeMap<&str, &ParsedComponent> =
        output.iter().map(|c| (c.name.as_str(), c)).collect();

    for (name, inp) in &input_by_name {
        match output_by_name.get(name) {
            None => errors.push(format!("MISSING in output: {}", name)),
            Some(out) => {
                if inp.nets != out.nets {
                    errors.push(format!(
                        "{}: nets differ — input {:?} vs output {:?}",
                        name, inp.nets, out.nets
                    ));
                }
                if inp.model_or_value != out.model_or_value {
                    errors.push(format!(
                        "{}: value/model differs — input '{}' vs output '{}'",
                        name, inp.model_or_value, out.model_or_value
                    ));
                }
                // Compare params that exist in input
                for (k, v) in &inp.params {
                    match out.params.get(k) {
                        None => errors.push(format!(
                            "{}: param '{}={}' missing in output",
                            name, k, v
                        )),
                        Some(ov) if ov != v => errors.push(format!(
                            "{}: param '{}' differs — input '{}' vs output '{}'",
                            name, k, v, ov
                        )),
                        _ => {}
                    }
                }
            }
        }
    }

    for name in output_by_name.keys() {
        if !input_by_name.contains_key(name) {
            errors.push(format!("EXTRA in output: {}", name));
        }
    }

    errors
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[test]
fn debug_import_structure() {
    let source = fs::read_to_string(fixture("simple_amp.spice")).unwrap();
    let mut interner = Rodeo::default();
    let sch = import_spice(&source, &mut interner).unwrap();

    eprintln!("=== Instances ({}) ===", sch.instances.len());
    for i in 0..sch.instances.len() {
        let name = interner.resolve(&sch.instances.name[i]);
        let kind = sch.instances.kind[i];
        let x = sch.instances.x[i];
        let y = sch.instances.y[i];
        eprintln!("  [{}] name={:?} kind={:?} pos=({},{})", i, name, kind, x, y);
    }

    eprintln!("\n=== Wires ({}) ===", sch.wires.len());
    for i in 0..sch.wires.len() {
        let net = interner.resolve(&sch.wires.net_name[i]);
        eprintln!("  [{}] ({},{}) -> ({},{}) net={:?}", i,
            sch.wires.x0[i], sch.wires.y0[i],
            sch.wires.x1[i], sch.wires.y1[i], net);
    }

    let conn = schemify_handler::connectivity::resolve(&sch, &interner);
    eprintln!("\n=== Connectivity ===");
    eprintln!("  nets: {}", conn.nets.len());
    eprintln!("  net_names: {:?}", conn.net_names);
    for (i, pins) in conn.instance_connections.iter().enumerate() {
        if i < sch.instances.len() {
            let name = interner.resolve(&sch.instances.name[i]);
            let kind = sch.instances.kind[i];
            eprintln!("  inst[{}] {} ({:?}): {:?}", i, name, kind, pins);
        }
    }
}

#[test]
fn test_simple_amp_spice_roundtrip() {
    let source = fs::read_to_string(fixture("simple_amp.spice")).unwrap();
    let output = roundtrip_to_spice(&source);

    eprintln!("=== Input ===\n{}", source);
    eprintln!("=== Output ===\n{}", output);

    let input_comps = parse_spice_components(&source);
    let output_comps = parse_spice_components(&output);

    let errors = compare_components(&input_comps, &output_comps);
    assert!(
        errors.is_empty(),
        "simple_amp roundtrip mismatches:\n{}",
        errors.join("\n"),
    );
}

#[test]
fn test_diff_pair_spice_roundtrip() {
    let source = fs::read_to_string(fixture("diff_pair.spice")).unwrap();
    let output = roundtrip_to_spice(&source);

    eprintln!("=== Input ===\n{}", source);
    eprintln!("=== Output ===\n{}", output);

    let input_comps = parse_spice_components(&source);
    let output_comps = parse_spice_components(&output);

    let errors = compare_components(&input_comps, &output_comps);
    assert!(
        errors.is_empty(),
        "diff_pair roundtrip mismatches:\n{}",
        errors.join("\n"),
    );
}

// ---------------------------------------------------------------------------
// Batch PySpice roundtrip tests
// ---------------------------------------------------------------------------

/// Run roundtrip on a fixture, check: all components survive, no `?` nets.
fn assert_roundtrip_no_unresolved(name: &str) {
    let path = fixture(name);
    let source = fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("{name}: read failed: {e}"));
    let output = roundtrip_to_spice(&source);

    // No unresolved pins in output
    assert!(
        !output.contains(" ? ") && !output.contains(" ?\n"),
        "{name}: output contains unresolved '?' net\n=== Output ===\n{output}",
    );

    let input_comps = parse_spice_components(&source);
    let output_comps = parse_spice_components(&output);

    let errors = compare_components(&input_comps, &output_comps);
    assert!(
        errors.is_empty(),
        "{name} roundtrip mismatches:\n{}\n=== Output ===\n{output}",
        errors.join("\n"),
    );
}

// -- basic --
#[test] fn roundtrip_basic_voltage_divider() { assert_roundtrip_no_unresolved("basic__voltage_divider.spice"); }
#[test] fn roundtrip_basic_rc_lowpass() { assert_roundtrip_no_unresolved("basic__rc_lowpass.spice"); }
#[test] fn roundtrip_basic_rc_integrator() { assert_roundtrip_no_unresolved("basic__rc_integrator.spice"); }
#[test] fn roundtrip_basic_rl_highpass() { assert_roundtrip_no_unresolved("basic__rl_highpass.spice"); }
#[test] fn roundtrip_basic_rlc_bandpass() { assert_roundtrip_no_unresolved("basic__rlc_bandpass.spice"); }
#[test] fn roundtrip_basic_wheatstone_bridge() { assert_roundtrip_no_unresolved("basic__wheatstone_bridge.spice"); }

// -- bjt --
#[test] fn roundtrip_bjt_common_emitter() { assert_roundtrip_no_unresolved("bjt__common_emitter.spice"); }
#[test] fn roundtrip_bjt_emitter_follower() { assert_roundtrip_no_unresolved("bjt__emitter_follower.spice"); }
#[test] fn roundtrip_bjt_current_mirror() { assert_roundtrip_no_unresolved("bjt__bjt_current_mirror.spice"); }
#[test] fn roundtrip_bjt_diff_pair() { assert_roundtrip_no_unresolved("bjt__bjt_diff_pair.spice"); }
#[test] fn roundtrip_bjt_cascode_amplifier() { assert_roundtrip_no_unresolved("bjt__cascode_amplifier.spice"); }

// -- digital --
#[test] fn roundtrip_digital_nand_gate() { assert_roundtrip_no_unresolved("digital__nand_gate.spice"); }
#[test] fn roundtrip_digital_nor_gate() { assert_roundtrip_no_unresolved("digital__nor_gate.spice"); }
#[test] fn roundtrip_digital_ring_oscillator() { assert_roundtrip_no_unresolved("digital__ring_oscillator.spice"); }
#[test] fn roundtrip_digital_sr_latch() { assert_roundtrip_no_unresolved("digital__sr_latch.spice"); }
#[test] fn roundtrip_digital_transmission_gate() { assert_roundtrip_no_unresolved("digital__transmission_gate.spice"); }

// -- mosfet --
#[test] fn roundtrip_mosfet_cmos_inverter() { assert_roundtrip_no_unresolved("mosfet__cmos_inverter.spice"); }
#[test] fn roundtrip_mosfet_common_source() { assert_roundtrip_no_unresolved("mosfet__common_source.spice"); }
#[test] fn roundtrip_mosfet_common_source_active_load() { assert_roundtrip_no_unresolved("mosfet__common_source_active_load.spice"); }
#[test] fn roundtrip_mosfet_source_follower() { assert_roundtrip_no_unresolved("mosfet__source_follower.spice"); }
#[test] fn roundtrip_mosfet_current_mirror() { assert_roundtrip_no_unresolved("mosfet__mosfet_current_mirror.spice"); }
#[test] fn roundtrip_mosfet_cascode_current_mirror() { assert_roundtrip_no_unresolved("mosfet__cascode_current_mirror.spice"); }
#[test] fn roundtrip_mosfet_wilson_mirror() { assert_roundtrip_no_unresolved("mosfet__wilson_mirror.spice"); }
#[test] fn roundtrip_mosfet_diff_pair() { assert_roundtrip_no_unresolved("mosfet__mosfet_diff_pair.spice"); }
#[test] fn roundtrip_mosfet_folded_cascode_ota() { assert_roundtrip_no_unresolved("mosfet__folded_cascode_ota.spice"); }
#[test] fn roundtrip_mosfet_telescopic_ota() { assert_roundtrip_no_unresolved("mosfet__telescopic_ota.spice"); }
#[test] fn roundtrip_mosfet_two_stage_opamp() { assert_roundtrip_no_unresolved("mosfet__two_stage_opamp.spice"); }

// -- opamp --
#[test] fn roundtrip_opamp_inverting_amplifier() { assert_roundtrip_no_unresolved("opamp__inverting_amplifier.spice"); }
#[test] fn roundtrip_opamp_noninverting_amplifier() { assert_roundtrip_no_unresolved("opamp__noninverting_amplifier.spice"); }
#[test] fn roundtrip_opamp_summing_amplifier() { assert_roundtrip_no_unresolved("opamp__summing_amplifier.spice"); }
#[test] fn roundtrip_opamp_differentiator() { assert_roundtrip_no_unresolved("opamp__differentiator.spice"); }
#[test] fn roundtrip_opamp_integrator() { assert_roundtrip_no_unresolved("opamp__integrator.spice"); }
#[test] fn roundtrip_opamp_instrumentation_amp() { assert_roundtrip_no_unresolved("opamp__instrumentation_amp.spice"); }

// -- mixed signal --
#[test] fn roundtrip_mixed_comparator() { assert_roundtrip_no_unresolved("mixed_signal__comparator.spice"); }
#[test] fn roundtrip_mixed_sample_and_hold() { assert_roundtrip_no_unresolved("mixed_signal__sample_and_hold.spice"); }
#[test] fn roundtrip_mixed_r2r_dac() { assert_roundtrip_no_unresolved("mixed_signal__r2r_dac.spice"); }
#[test] fn roundtrip_mixed_vco() { assert_roundtrip_no_unresolved("mixed_signal__vco.spice"); }
#[test] fn roundtrip_mixed_phase_detector() { assert_roundtrip_no_unresolved("mixed_signal__phase_detector.spice"); }
#[test] fn roundtrip_mixed_charge_pump_pll() { assert_roundtrip_no_unresolved("mixed_signal__charge_pump_pll.spice"); }

// -- power --
#[test] fn roundtrip_power_bandgap_reference() { assert_roundtrip_no_unresolved("power__bandgap_reference.spice"); }
#[test] fn roundtrip_power_ldo_regulator() { assert_roundtrip_no_unresolved("power__ldo_regulator.spice"); }
#[test] fn roundtrip_power_buck_converter() { assert_roundtrip_no_unresolved("power__buck_converter.spice"); }
#[test] fn roundtrip_power_charge_pump() { assert_roundtrip_no_unresolved("power__charge_pump.spice"); }
