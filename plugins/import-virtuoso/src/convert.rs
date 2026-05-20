//! Conversion from parsed CDL/Spectre circuits to `ImportResult`.
//!
//! Both CDL and Spectre parse into the shared `CdlCircuit` IR, then convert
//! to `ImportResult` using common placement and wiring logic.

use std::collections::HashMap;

use crate::cdl::CdlCircuit;
use crate::pdk_map;
use crate::result::*;

// -- Grid placement constants -------------------------------------------------

const GRID_STEP: i32 = 160;
const COLUMN_WIDTH: i32 = 400;
const START_X: i32 = 200;
const START_Y: i32 = 200;

// -- Public API ---------------------------------------------------------------

/// Import a CDL netlist string into an `ImportResult`.
///
/// Converts the first subcircuit found (or top-level instances if none).
pub fn import_cdl(input: &str) -> Result<ImportResult, String> {
    let circuit = crate::cdl::parse_cdl(input)?;
    circuit_to_import_result(&circuit)
}

/// Import a Spectre netlist string into an `ImportResult`.
///
/// Converts the first subcircuit found (or top-level instances if none).
pub fn import_spectre(input: &str) -> Result<ImportResult, String> {
    let circuit = crate::spectre::parse_spectre(input)?;
    circuit_to_import_result(&circuit)
}

// -- Conversion ---------------------------------------------------------------

/// Convert a `CdlCircuit` to an `ImportResult`.
///
/// If the circuit has subcircuits, converts the first one; otherwise uses
/// the top-level instances.
fn circuit_to_import_result(circuit: &CdlCircuit) -> Result<ImportResult, String> {
    let target = if !circuit.subcircuits.is_empty() {
        &circuit.subcircuits[0]
    } else {
        circuit
    };

    let mut result = ImportResult::new(target.name.clone());

    // Create port pins
    for (i, port_name) in target.ports.iter().enumerate() {
        result.pins.push(PinResult {
            name: port_name.clone(),
            x: START_X - COLUMN_WIDTH,
            y: START_Y + (i as i32) * GRID_STEP,
            direction: "inout".to_string(),
            width: 1,
        });
    }

    // Build a net-to-points map for wire generation
    let mut net_points: HashMap<String, Vec<(i32, i32)>> = HashMap::new();

    // Place instances on a grid (column layout)
    let mut row = 0i32;
    let mut col = 0i32;
    let max_rows = 10;

    for cdl_inst in &target.instances {
        let x = START_X + col * COLUMN_WIDTH;
        let y = START_Y + row * GRID_STEP;

        let kind = prefix_to_kind(cdl_inst.prefix, &cdl_inst.model_or_subckt);
        let symbol_name = kind_to_symbol_name(kind);

        // Build instance properties
        let mut props = Vec::new();

        // Add model as property
        if !cdl_inst.model_or_subckt.is_empty() {
            props.push(PropertyResult {
                key: "model".to_string(),
                value: cdl_inst.model_or_subckt.clone(),
            });
        }

        // Add instance parameters
        for (k, v) in &cdl_inst.params {
            props.push(PropertyResult {
                key: k.clone(),
                value: v.clone(),
            });
        }

        result.instances.push(InstanceResult {
            name: cdl_inst.name.clone(),
            symbol: symbol_name.to_string(),
            kind: kind.to_string(),
            x,
            y,
            rotation: 0,
            flip: false,
            properties: props,
        });

        // Track node connection points for wiring
        for (pin_idx, node_name) in cdl_inst.nodes.iter().enumerate() {
            let pin_offset_y = pin_idx as i32 * 40;
            let px = x;
            let py = y + pin_offset_y;
            net_points
                .entry(node_name.clone())
                .or_default()
                .push((px, py));
        }

        // Advance grid position
        row += 1;
        if row >= max_rows {
            row = 0;
            col += 1;
        }
    }

    // Generate wires between nodes that share the same net name
    for (net_name, points) in &net_points {
        if points.len() < 2 {
            continue;
        }

        // Connect consecutive points with wires
        for pair in points.windows(2) {
            let (x0, y0) = pair[0];
            let (x1, y1) = pair[1];

            result.wires.push(WireResult {
                x0,
                y0,
                x1,
                y1,
                net_name: net_name.clone(),
                bus: false,
            });
        }
    }

    Ok(result)
}

/// Map a SPICE prefix character + model name to a device kind string.
fn prefix_to_kind(prefix: char, model: &str) -> &'static str {
    // First try PDK-aware mapping
    let pdk_kind = pdk_map::map_model_to_kind(model);
    if pdk_kind != "unknown" {
        return pdk_kind;
    }

    // Fall back to prefix-based mapping
    let model_lower = model.to_ascii_lowercase();
    match prefix {
        'M' => {
            if model_lower.contains("pmos")
                || model_lower.contains("pfet")
                || model_lower == "pch"
            {
                "pmos4"
            } else {
                "nmos4"
            }
        }
        'R' => "resistor",
        'C' => "capacitor",
        'L' => "inductor",
        'D' => "diode",
        'Q' => {
            if model_lower.contains("pnp") {
                "pnp"
            } else {
                "npn"
            }
        }
        'J' => {
            if model_lower.contains("pjfet") || model_lower == "pjf" {
                "pjfet"
            } else {
                "njfet"
            }
        }
        'V' => "vsource",
        'I' => "isource",
        'E' => "vcvs",
        'G' => "vccs",
        'H' => "ccvs",
        'F' => "cccs",
        'T' => "tline",
        'K' => "coupling",
        'X' => "subckt",
        'Z' => "mesfet",
        _ => "subckt",
    }
}

/// Map a kind string to a symbol name.
fn kind_to_symbol_name(kind: &str) -> &'static str {
    match kind {
        "resistor" | "resistor3" | "var_resistor" => "resistor",
        "capacitor" => "capacitor",
        "inductor" => "inductor",
        "diode" | "zener" => "diode",
        "nmos3" | "nmos4" | "nmos4_depl" | "nmos_sub" | "nmoshv4" | "rnmos4" => "nmos",
        "pmos3" | "pmos4" | "pmos_sub" | "pmoshv4" => "pmos",
        "npn" => "npn",
        "pnp" => "pnp",
        "njfet" => "njfet",
        "pjfet" => "pjfet",
        "mesfet" => "mesfet",
        "vsource" => "vsource",
        "isource" => "isource",
        "vcvs" => "vcvs",
        "vccs" => "vccs",
        "ccvs" => "ccvs",
        "cccs" => "cccs",
        "coupling" => "coupling",
        "tline" => "tline",
        "subckt" => "subckt",
        _ => "vsource",
    }
}

// -- Tests --------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cdl_circuit_to_import_result() {
        let input = r#"
.SUBCKT opamp INP INN OUT VDD VSS
M1 net1 INP net3 VSS nmos W=1u L=180n
M2 net1 INN net4 VSS nmos W=1u L=180n
R1 VDD net1 10k
.ENDS opamp
"#;
        let result = import_cdl(input).unwrap();

        assert_eq!(result.name, "opamp");
        assert_eq!(result.instances.len(), 3);
        assert_eq!(result.pins.len(), 5); // 5 ports

        // Check device kinds
        assert_eq!(result.instances[0].kind, "nmos4");
        assert_eq!(result.instances[1].kind, "nmos4");
        assert_eq!(result.instances[2].kind, "resistor");
    }

    #[test]
    fn spectre_circuit_to_import_result() {
        let input = r#"
subckt opamp (INP INN OUT VDD VSS)
m1 (net1 INP net3 VSS) nmos w=1u l=180n
r1 (VDD net1) resistor r=10k
ends opamp
"#;
        let result = import_spectre(input).unwrap();

        assert_eq!(result.name, "opamp");
        assert_eq!(result.instances.len(), 2);
        assert_eq!(result.pins.len(), 5);
        assert_eq!(result.instances[0].kind, "nmos4");
        assert_eq!(result.instances[1].kind, "resistor");
    }

    #[test]
    fn prefix_mapping() {
        assert_eq!(prefix_to_kind('M', "nmos"), "nmos4");
        assert_eq!(prefix_to_kind('M', "pmos"), "pmos4");
        assert_eq!(prefix_to_kind('R', "10k"), "resistor");
        assert_eq!(prefix_to_kind('C', "1p"), "capacitor");
        assert_eq!(prefix_to_kind('Q', "npn_model"), "npn");
        assert_eq!(prefix_to_kind('Q', "pnp_model"), "pnp");
        assert_eq!(prefix_to_kind('X', "my_subckt"), "subckt");
        assert_eq!(prefix_to_kind('V', "dc"), "vsource");
        assert_eq!(prefix_to_kind('D', "diode1"), "diode");
    }

    #[test]
    fn wires_generated_for_shared_nets() {
        let input = r#"
.SUBCKT test A B
R1 A net1 1k
R2 net1 B 2k
.ENDS test
"#;
        let result = import_cdl(input).unwrap();

        // net1 appears in both R1 and R2, so a wire should be created
        assert!(!result.wires.is_empty(), "wires should be created for shared nets");

        // Check that net1 wire exists
        let has_net1 = result.wires.iter().any(|w| w.net_name == "net1");
        assert!(has_net1, "should have wire for net1");
    }

    #[test]
    fn top_level_instances_when_no_subckt() {
        let input = r#"
R1 VDD net1 1k
C1 net1 GND 1p
"#;
        let result = import_cdl(input).unwrap();

        assert_eq!(result.name, "top");
        assert_eq!(result.instances.len(), 2);
    }

    #[test]
    fn properties_stored_correctly() {
        let input = r#"
.SUBCKT test A B
M1 d g s b nmos W=1u L=180n
.ENDS test
"#;
        let result = import_cdl(input).unwrap();

        // Instance should have properties: model, W, L
        let inst = &result.instances[0];
        assert_eq!(inst.properties.len(), 3); // model + W + L

        assert_eq!(inst.properties[0].key, "model");
        assert_eq!(inst.properties[0].value, "nmos");
        assert_eq!(inst.properties[1].key, "W");
        assert_eq!(inst.properties[1].value, "1u");
        assert_eq!(inst.properties[2].key, "L");
        assert_eq!(inst.properties[2].value, "180n");
    }
}
