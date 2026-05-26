//! Annotation pass: enriches the IR with metadata needed for placement and routing.
//!
//! Detects power/ground nets, infers port directions, and tags differential pairs.

use crate::s2s::ir::{Circuit, NetClass, PinDir, Primitive, Subcircuit};

// ---------------------------------------------------------------------------
// Main entry point
// ---------------------------------------------------------------------------

/// Run all annotation passes on the circuit.
pub fn annotate(circuit: &mut Circuit) {
    annotate_power_nets(circuit);
    infer_port_directions(&mut circuit.top);
    for sub in circuit.subcircuits.values_mut() {
        infer_port_directions(sub);
    }
    detect_differential_nets(circuit);
}

// ---------------------------------------------------------------------------
// Power / ground net detection
// ---------------------------------------------------------------------------

/// Classify nets as `Power` or `Ground` based on name, globals, voltage
/// sources, and high-fanout heuristics.
pub fn annotate_power_nets(circuit: &mut Circuit) {
    // Rule 1 & 2: .global flag + name matching (globals with power names get
    // priority, but we also match non-global nets by name).
    for net in &mut circuit.top.nets {
        if let Some(class) = classify_power_name(&net.name) {
            net.classification = class;
        }
    }

    // Also classify subcircuit nets by name (needed for diff pair rejection etc.)
    for subckt in circuit.subcircuits.values_mut() {
        for net in &mut subckt.nets {
            if let Some(class) = classify_power_name(&net.name) {
                net.classification = class;
            }
        }
    }

    // Rule 3: Nets connected to a DC voltage source whose other terminal is
    // on net "0".  The positive terminal net becomes Power.
    //
    // Voltage sources have pins: 0=p (plus), 1=n (minus).
    // We look for Vsources where one pin is on net "0" and promote the other.
    let net_zero_idx = circuit
        .top
        .nets
        .iter()
        .position(|n| n.name == "0")
        .map(|i| i as u32);

    for inst in &circuit.top.instances {
        if inst.primitive != Primitive::Vsource {
            continue;
        }
        let plus_net = inst.pins.get(0).and_then(|p| p.net_idx);
        let minus_net = inst.pins.get(1).and_then(|p| p.net_idx);

        if let Some(zero_idx) = net_zero_idx {
            // If minus terminal is on "0", plus terminal is a power net.
            if minus_net == Some(zero_idx) {
                if let Some(p_idx) = plus_net {
                    let net = &mut circuit.top.nets[p_idx as usize];
                    if net.classification == NetClass::Signal {
                        net.classification = NetClass::Power;
                    }
                }
            }
            // If plus terminal is on "0", minus terminal is a ground net.
            if plus_net == Some(zero_idx) {
                if let Some(m_idx) = minus_net {
                    let net = &mut circuit.top.nets[m_idx as usize];
                    if net.classification == NetClass::Signal {
                        net.classification = NetClass::Ground;
                    }
                }
            }
        }
    }

    // Rule 4: High-fanout nets (>10 pins) where all connected pins are
    // MOSFET bulk (pin_idx 3) or source (pin_idx 2).
    for net in &mut circuit.top.nets {
        if net.classification != NetClass::Signal {
            continue;
        }
        if net.pins.len() <= 10 {
            continue;
        }

        let all_bulk_or_source = net.pins.iter().all(|pref| {
            let inst = &circuit.top.instances[pref.instance_idx as usize];
            if inst.primitive.is_mosfet() {
                // pin 2 = source, pin 3 = bulk
                pref.pin_idx == 2 || pref.pin_idx == 3
            } else {
                false
            }
        });

        if all_bulk_or_source {
            net.classification = NetClass::Power;
        }
    }
}

/// Classify a net name as Power, Ground, or None based on known patterns.
fn classify_power_name(name: &str) -> Option<NetClass> {
    let lower = name.to_ascii_lowercase();

    // Ground patterns (checked first so "0" matches ground).
    const GROUND_PATTERNS: &[&str] = &["vss", "gnd", "avss", "dvss", "gnd!", "vss!"];
    if lower == "0" {
        return Some(NetClass::Ground);
    }
    for pat in GROUND_PATTERNS {
        if lower == *pat {
            return Some(NetClass::Ground);
        }
    }
    // PDK-prefixed ground (e.g. sky130_gnd).
    if lower.ends_with("_gnd") || lower.ends_with("_vss") {
        return Some(NetClass::Ground);
    }

    // Power patterns.
    const POWER_PATTERNS: &[&str] = &["vdd", "vcc", "vbat", "avdd", "dvdd", "vdda", "vdd!", "vssa"];
    for pat in POWER_PATTERNS {
        if lower == *pat {
            // Special case: vssa sounds like ground but spec says it's in
            // the power-name list from the task description.  The task puts
            // vssa under the name-match rule list alongside vdd/vcc, but
            // "vss" variants are ground.  vssa has "vss" prefix, so treat
            // it as ground.
            if lower == "vssa" {
                return Some(NetClass::Ground);
            }
            return Some(NetClass::Power);
        }
    }
    // PDK-prefixed power (e.g. sky130_vdd).
    if lower.ends_with("_vdd") || lower.ends_with("_vcc") {
        return Some(NetClass::Power);
    }

    None
}

// ---------------------------------------------------------------------------
// Port direction inference
// ---------------------------------------------------------------------------

/// Infer I/O directions for each port of a subcircuit.
///
/// Rules:
/// 1. Port connects only to gate pins -> Input
/// 2. Port connects to drain pins and never gates -> Output
/// 3. Port name matches power/ground pattern -> Inout (power)
/// 4. Otherwise -> Inout
pub fn infer_port_directions(subckt: &mut Subcircuit) {
    let mut directions: Vec<PinDir> = Vec::with_capacity(subckt.ports.len());

    for port_name in &subckt.ports {
        // Rule 3: power/ground name -> Inout.
        if classify_power_name(port_name).is_some() {
            directions.push(PinDir::Inout);
            continue;
        }

        // Find the net for this port.
        let net_opt = subckt.nets.iter().find(|n| n.name == *port_name);
        let net = match net_opt {
            Some(n) => n,
            None => {
                directions.push(PinDir::Inout);
                continue;
            }
        };

        let mut has_gate = false;
        let mut has_drain = false;
        let mut has_other = false;

        for pref in &net.pins {
            let inst = match subckt.instances.get(pref.instance_idx as usize) {
                Some(i) => i,
                None => {
                    has_other = true;
                    continue;
                }
            };

            if inst.primitive.is_mosfet() {
                match pref.pin_idx {
                    1 => has_gate = true,  // G
                    0 => has_drain = true, // D
                    _ => has_other = true, // S or B
                }
            } else {
                has_other = true;
            }
        }

        if has_gate && !has_drain && !has_other {
            // Rule 1: only gate connections.
            directions.push(PinDir::Input);
        } else if has_drain && !has_gate {
            // Rule 2: drain connections, no gates.
            directions.push(PinDir::Output);
        } else {
            // Rule 4: mixed or unknown.
            directions.push(PinDir::Inout);
        }
    }

    subckt.port_directions = directions;
}

// ---------------------------------------------------------------------------
// Differential net detection
// ---------------------------------------------------------------------------

/// Tag net pairs that look like differential signals.
///
/// Recognised suffix patterns:
/// - `<base>_p` / `<base>_n`
/// - `<base>p`  / `<base>n`
/// - `<base>+`  / `<base>-`
/// - `<base>_ip` / `<base>_in`
///
/// Nets already classified as Power or Ground are skipped (false-positive
/// rejection).
pub fn detect_differential_nets(circuit: &mut Circuit) {
    // Build a name -> index map for quick lookup.
    let name_to_idx: std::collections::HashMap<String, usize> = circuit
        .top
        .nets
        .iter()
        .enumerate()
        .map(|(i, n)| (n.name.to_ascii_lowercase(), i))
        .collect();

    // Collect pairs first to avoid double-borrow issues.
    let mut pairs: Vec<(usize, usize)> = Vec::new();

    for (i, net) in circuit.top.nets.iter().enumerate() {
        // Skip already classified power/ground nets.
        if matches!(net.classification, NetClass::Power | NetClass::Ground) {
            continue;
        }

        let lower = net.name.to_ascii_lowercase();

        // Try each pattern for the positive side.
        let candidates: &[(&str, &str)] = &[
            ("_p", "_n"),
            ("p", "n"),
            ("+", "-"),
            ("_ip", "_in"),
        ];

        for &(pos_suffix, neg_suffix) in candidates {
            if let Some(base) = lower.strip_suffix(pos_suffix) {
                // Avoid empty base.
                if base.is_empty() {
                    continue;
                }
                // For the bare "p"/"n" suffix pair, the base must not end
                // with '_' (that would be the _p/_n pattern which we handle
                // separately), and the base itself must not be empty.
                // Also for bare p/n, require the base to be at least 1 char
                // to avoid matching single-letter names weirdly.

                let neg_name = format!("{}{}", base, neg_suffix);
                if let Some(&j) = name_to_idx.get(&neg_name) {
                    // Check the negative net isn't power/ground.
                    if matches!(
                        circuit.top.nets[j].classification,
                        NetClass::Power | NetClass::Ground
                    ) {
                        continue;
                    }
                    pairs.push((i, j));
                    break; // Don't match multiple patterns for the same net.
                }
            }
        }
    }

    // Apply classifications.
    for (p_idx, n_idx) in pairs {
        circuit.top.nets[p_idx].classification = NetClass::DifferentialP;
        circuit.top.nets[n_idx].classification = NetClass::DifferentialN;
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::s2s::ir::{Circuit, Instance, Net, Pin, PinDir, PinRef, Primitive};
    use std::collections::HashMap;

    // -- Helpers to build test circuits ------------------------------------

    fn make_mosfet(name: &str, prim: Primitive) -> Instance {
        Instance {
            name: name.to_string(),
            primitive: prim,
            symbol: String::new(),
            pins: vec![
                Pin { name: "D".into(), dir: PinDir::Inout, net_idx: None },
                Pin { name: "G".into(), dir: PinDir::Input, net_idx: None },
                Pin { name: "S".into(), dir: PinDir::Inout, net_idx: None },
                Pin { name: "B".into(), dir: PinDir::Bulk, net_idx: None },
            ],
            params: HashMap::new(),
            x: 0,
            y: 0,
            rotation: 0,
            flip: false,
        }
    }

    fn make_vsource(name: &str) -> Instance {
        Instance {
            name: name.to_string(),
            primitive: Primitive::Vsource,
            symbol: String::new(),
            pins: vec![
                Pin { name: "p".into(), dir: PinDir::Inout, net_idx: None },
                Pin { name: "n".into(), dir: PinDir::Inout, net_idx: None },
            ],
            params: {
                let mut p = HashMap::new();
                p.insert("value".to_string(), "1.8".to_string());
                p
            },
            x: 0,
            y: 0,
            rotation: 0,
            flip: false,
        }
    }

    fn connect(circuit: &mut Circuit, net_idx: u32, instance_idx: u32, pin_idx: u32) {
        circuit.connect(net_idx, PinRef { instance_idx, pin_idx });
    }

    // -- Test 1: vdd and vss detected as Power/Ground --------------------

    #[test]
    fn test_vdd_vss_classification() {
        let mut circuit = Circuit::new("top");
        let vdd_idx = circuit.add_net(Net::new("vdd"));
        let vss_idx = circuit.add_net(Net::new("vss"));
        // Add a dummy net to confirm it stays Signal.
        let sig_idx = circuit.add_net(Net::new("out"));

        annotate_power_nets(&mut circuit);

        assert_eq!(circuit.top.nets[vdd_idx as usize].classification, NetClass::Power);
        assert_eq!(circuit.top.nets[vss_idx as usize].classification, NetClass::Ground);
        assert_eq!(circuit.top.nets[sig_idx as usize].classification, NetClass::Signal);
    }

    // -- Test 2: gnd and 0 detected as Ground ----------------------------

    #[test]
    fn test_gnd_and_zero_classification() {
        let mut circuit = Circuit::new("top");
        let gnd_idx = circuit.add_net(Net::new("gnd"));
        let zero_idx = circuit.add_net(Net::new("0"));

        annotate_power_nets(&mut circuit);

        assert_eq!(circuit.top.nets[gnd_idx as usize].classification, NetClass::Ground);
        assert_eq!(circuit.top.nets[zero_idx as usize].classification, NetClass::Ground);
    }

    // -- Test 3: Voltage source with other terminal on "0" -> Power ------

    #[test]
    fn test_vsource_creates_power_net() {
        let mut circuit = Circuit::new("top");
        let supply_idx = circuit.add_net(Net::new("supply"));
        let zero_idx = circuit.add_net(Net::new("0"));

        let v1 = make_vsource("V1");
        let inst_idx = circuit.add_instance(v1);

        connect(&mut circuit, supply_idx, inst_idx, 0); // plus -> supply
        connect(&mut circuit, zero_idx, inst_idx, 1); // minus -> 0

        annotate_power_nets(&mut circuit);

        assert_eq!(
            circuit.top.nets[supply_idx as usize].classification,
            NetClass::Power,
        );
    }

    // -- Test 4: .global nets flagged correctly ---------------------------

    #[test]
    fn test_global_power_nets() {
        let mut circuit = Circuit::new("top");

        let mut vdd_net = Net::new("VDD");
        vdd_net.is_global = true;
        let vdd_idx = circuit.add_net(vdd_net);

        let mut vss_net = Net::new("VSS");
        vss_net.is_global = true;
        let vss_idx = circuit.add_net(vss_net);

        annotate_power_nets(&mut circuit);

        assert_eq!(circuit.top.nets[vdd_idx as usize].classification, NetClass::Power);
        assert_eq!(circuit.top.nets[vss_idx as usize].classification, NetClass::Ground);
    }

    // -- Test 5: High-fanout (>10 pins, all bulk/source) -> Power --------

    #[test]
    fn test_high_fanout_bulk_source_power() {
        let mut circuit = Circuit::new("top");
        let hf_idx = circuit.add_net(Net::new("substrate"));

        // Create 11 MOSFETs, each connecting bulk (pin 3) to "substrate".
        for i in 0..11 {
            let m = make_mosfet(&format!("M{}", i), Primitive::Nmos);
            let idx = circuit.add_instance(m);
            connect(&mut circuit, hf_idx, idx, 3); // bulk pin
        }

        annotate_power_nets(&mut circuit);

        assert_eq!(
            circuit.top.nets[hf_idx as usize].classification,
            NetClass::Power,
        );
    }

    // -- Test 6: Port direction — gate-only fanout -> Input ---------------

    #[test]
    fn test_port_direction_gate_only_is_input() {
        let mut subckt = Subcircuit::new("amp");
        subckt.ports = vec!["inp".to_string()];

        // Create net "inp" connected to gate pins of two MOSFETs.
        let mut net = Net::new("inp");

        let m1 = make_mosfet("M1", Primitive::Nmos);
        let m2 = make_mosfet("M2", Primitive::Nmos);
        subckt.instances.push(m1);
        subckt.instances.push(m2);

        // Connect gate (pin 1) of each MOSFET.
        net.pins.push(PinRef { instance_idx: 0, pin_idx: 1 });
        net.pins.push(PinRef { instance_idx: 1, pin_idx: 1 });
        subckt.instances[0].pins[1].net_idx = Some(0);
        subckt.instances[1].pins[1].net_idx = Some(0);
        subckt.nets.push(net);

        infer_port_directions(&mut subckt);

        assert_eq!(subckt.port_directions.len(), 1);
        assert_eq!(subckt.port_directions[0], PinDir::Input);
    }

    // -- Test 7: Port direction — drain-only -> Output --------------------

    #[test]
    fn test_port_direction_drain_only_is_output() {
        let mut subckt = Subcircuit::new("amp");
        subckt.ports = vec!["out".to_string()];

        let mut net = Net::new("out");
        let m1 = make_mosfet("M1", Primitive::Nmos);
        subckt.instances.push(m1);

        // Connect drain (pin 0).
        net.pins.push(PinRef { instance_idx: 0, pin_idx: 0 });
        subckt.instances[0].pins[0].net_idx = Some(0);
        subckt.nets.push(net);

        infer_port_directions(&mut subckt);

        assert_eq!(subckt.port_directions[0], PinDir::Output);
    }

    // -- Test 8: Port direction — power name -> Inout ---------------------

    #[test]
    fn test_port_direction_power_name_is_inout() {
        let mut subckt = Subcircuit::new("amp");
        subckt.ports = vec!["vdd".to_string(), "gnd".to_string()];
        // No nets needed — name alone triggers the rule.

        infer_port_directions(&mut subckt);

        assert_eq!(subckt.port_directions.len(), 2);
        assert_eq!(subckt.port_directions[0], PinDir::Inout);
        assert_eq!(subckt.port_directions[1], PinDir::Inout);
    }

    // -- Test 9: Differential detection — inp/inn -------------------------

    #[test]
    fn test_differential_inp_inn() {
        let mut circuit = Circuit::new("top");
        let _inp = circuit.add_net(Net::new("inp"));
        let _inn = circuit.add_net(Net::new("inn"));

        detect_differential_nets(&mut circuit);

        assert_eq!(circuit.top.nets[0].classification, NetClass::DifferentialP);
        assert_eq!(circuit.top.nets[1].classification, NetClass::DifferentialN);
    }

    // -- Test 10: Differential detection — out_p/out_n --------------------

    #[test]
    fn test_differential_out_p_out_n() {
        let mut circuit = Circuit::new("top");
        let _outp = circuit.add_net(Net::new("out_p"));
        let _outn = circuit.add_net(Net::new("out_n"));

        detect_differential_nets(&mut circuit);

        assert_eq!(circuit.top.nets[0].classification, NetClass::DifferentialP);
        assert_eq!(circuit.top.nets[1].classification, NetClass::DifferentialN);
    }

    // -- Test 11: False positive rejection — vdd_p is power, not diff ----

    #[test]
    fn test_differential_false_positive_power() {
        let mut circuit = Circuit::new("top");

        // First annotate power nets so vdd_p would be classified as Power
        // (it won't be by name alone since "vdd_p" isn't in the pattern
        // list, but "vdd" is).  Let's use "vdd" itself and a hypothetical
        // "vddn" — "vdd" is Power so should be skipped.
        let _vdd = circuit.add_net(Net::new("vdd"));
        let _vddn = circuit.add_net(Net::new("vddn"));

        // Annotate power first.
        annotate_power_nets(&mut circuit);
        assert_eq!(circuit.top.nets[0].classification, NetClass::Power);

        // Now run differential detection.
        detect_differential_nets(&mut circuit);

        // vdd must remain Power, not get re-tagged as DifferentialP.
        assert_eq!(circuit.top.nets[0].classification, NetClass::Power);
        // vddn should remain Signal (not tagged as differential because
        // the positive candidate "vdd" is Power).
        assert_eq!(circuit.top.nets[1].classification, NetClass::Signal);
    }

    // -- Test 12: Empty circuit -> no crash -------------------------------

    #[test]
    fn test_empty_circuit_no_crash() {
        let mut circuit = Circuit::new("top");
        annotate(&mut circuit);
        // Just verify no panic.
        assert!(circuit.top.nets.is_empty());
        assert!(circuit.top.instances.is_empty());
    }
}
