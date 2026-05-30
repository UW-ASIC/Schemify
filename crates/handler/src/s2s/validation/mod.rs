//! Structural validator for schematic output correctness.
//!
//! Run validation checks on subcircuits and circuits before writing files
//! to catch issues like duplicate instance names, off-grid coordinates,
//! non-orthogonal wires, etc.

use std::collections::HashSet;

use crate::s2s::ir::{Circuit, Subcircuit};

/// A validation error or warning found during checking.
#[derive(Debug, Clone)]
pub struct ValidationError {
    pub severity: Severity,
    pub message: String,
}

/// Severity level for validation errors.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Severity {
    Error,
    Warning,
}

/// Validate a subcircuit for XSchem output correctness.
pub fn validate_subcircuit(subckt: &Subcircuit) -> Vec<ValidationError> {
    let mut errors = Vec::new();

    check_unique_names(subckt, &mut errors);
    check_grid_alignment(subckt, &mut errors);
    check_rotation_values(subckt, &mut errors);
    check_wire_orthogonality(subckt, &mut errors);
    check_no_duplicate_wires(subckt, &mut errors);
    check_net_label_consistency(subckt, &mut errors);

    errors
}

/// Validate full circuit (all subcircuits + top).
pub fn validate_circuit(circuit: &Circuit) -> Vec<ValidationError> {
    let mut errors = validate_subcircuit(&circuit.top);
    for (name, sub) in &circuit.subcircuits {
        let sub_errors = validate_subcircuit(sub);
        for mut e in sub_errors {
            e.message = format!("subcircuit '{}': {}", name, e.message);
            errors.push(e);
        }
    }
    errors
}

/// Every instance name must be unique within a subcircuit.
fn check_unique_names(subckt: &Subcircuit, errors: &mut Vec<ValidationError>) {
    let mut seen = HashSet::new();
    for inst in &subckt.instances {
        if !seen.insert(&inst.name) {
            errors.push(ValidationError {
                severity: Severity::Error,
                message: format!("duplicate instance name '{}'", inst.name),
            });
        }
    }
}

/// All coordinates must be multiples of 10 (XSchem grid alignment).
fn check_grid_alignment(subckt: &Subcircuit, errors: &mut Vec<ValidationError>) {
    for inst in &subckt.instances {
        if inst.x % 10 != 0 || inst.y % 10 != 0 {
            errors.push(ValidationError {
                severity: Severity::Error,
                message: format!(
                    "instance '{}' off-grid at ({}, {})",
                    inst.name, inst.x, inst.y
                ),
            });
        }
    }
    for (i, wire) in subckt.wires.iter().enumerate() {
        if wire.x1 % 10 != 0 || wire.y1 % 10 != 0 || wire.x2 % 10 != 0 || wire.y2 % 10 != 0 {
            errors.push(ValidationError {
                severity: Severity::Error,
                message: format!(
                    "wire {} off-grid at ({}, {})-({}, {})",
                    i, wire.x1, wire.y1, wire.x2, wire.y2
                ),
            });
        }
    }
    for (i, label) in subckt.labels.iter().enumerate() {
        if label.x % 10 != 0 || label.y % 10 != 0 {
            errors.push(ValidationError {
                severity: Severity::Error,
                message: format!("label {} off-grid at ({}, {})", i, label.x, label.y),
            });
        }
    }
}

/// Rotation must be in {0, 1, 2, 3}.
fn check_rotation_values(subckt: &Subcircuit, errors: &mut Vec<ValidationError>) {
    for inst in &subckt.instances {
        if inst.rotation > 3 {
            errors.push(ValidationError {
                severity: Severity::Error,
                message: format!(
                    "instance '{}' has invalid rotation {}",
                    inst.name, inst.rotation
                ),
            });
        }
    }
    for (i, label) in subckt.labels.iter().enumerate() {
        if label.rotation > 3 {
            errors.push(ValidationError {
                severity: Severity::Error,
                message: format!("label {} has invalid rotation {}", i, label.rotation),
            });
        }
    }
}

/// Every wire must be horizontal (y1==y2) or vertical (x1==x2).
fn check_wire_orthogonality(subckt: &Subcircuit, errors: &mut Vec<ValidationError>) {
    for (i, wire) in subckt.wires.iter().enumerate() {
        if wire.x1 != wire.x2 && wire.y1 != wire.y2 {
            errors.push(ValidationError {
                severity: Severity::Error,
                message: format!(
                    "wire {} is diagonal: ({}, {})-({}, {})",
                    i, wire.x1, wire.y1, wire.x2, wire.y2
                ),
            });
        }
    }
}

/// No two wires with identical endpoints on the same net.
fn check_no_duplicate_wires(subckt: &Subcircuit, errors: &mut Vec<ValidationError>) {
    let mut seen = HashSet::new();
    for (i, wire) in subckt.wires.iter().enumerate() {
        // Normalize: always store smaller endpoint first so (A,B) == (B,A).
        let key = if (wire.x1, wire.y1) <= (wire.x2, wire.y2) {
            (wire.net_idx, wire.x1, wire.y1, wire.x2, wire.y2)
        } else {
            (wire.net_idx, wire.x2, wire.y2, wire.x1, wire.y1)
        };
        if !seen.insert(key) {
            errors.push(ValidationError {
                severity: Severity::Warning,
                message: format!(
                    "duplicate wire {} at ({}, {})-({}, {})",
                    i, wire.x1, wire.y1, wire.x2, wire.y2
                ),
            });
        }
    }
}

/// Every label's net_idx must be a valid index into the subcircuit's nets.
fn check_net_label_consistency(subckt: &Subcircuit, errors: &mut Vec<ValidationError>) {
    let net_count = subckt.nets.len();
    for (i, label) in subckt.labels.iter().enumerate() {
        if (label.net_idx as usize) >= net_count {
            errors.push(ValidationError {
                severity: Severity::Error,
                message: format!(
                    "label {} references net_idx {} but only {} nets exist",
                    i, label.net_idx, net_count
                ),
            });
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
#[cfg(test)]
mod tests {
    use super::*;
    use crate::s2s::ir::{Instance, Label, Net, Pin, PinDir, Primitive, Subcircuit, Wire};
    use std::collections::HashMap;

    /// Build a valid subcircuit (all checks pass).
    fn valid_subckt() -> Subcircuit {
        let mut subckt = Subcircuit::new("test");
        subckt.nets.push(Net::new("vdd"));
        subckt.nets.push(Net::new("gnd"));
        subckt.instances.push(Instance {
            name: "M1".to_string(),
            primitive: Primitive::Nmos,
            symbol: String::new(),
            pins: vec![
                Pin {
                    name: "D".to_string(),
                    dir: PinDir::Inout,
                    net_idx: Some(0),
                },
                Pin {
                    name: "G".to_string(),
                    dir: PinDir::Input,
                    net_idx: Some(1),
                },
                Pin {
                    name: "S".to_string(),
                    dir: PinDir::Inout,
                    net_idx: Some(1),
                },
                Pin {
                    name: "B".to_string(),
                    dir: PinDir::Bulk,
                    net_idx: Some(1),
                },
            ],
            params: HashMap::new(),
            x: 100,
            y: 200,
            rotation: 0,
            flip: false,
        });
        subckt.wires.push(Wire {
            net_idx: 0,
            x1: 100,
            y1: 200,
            x2: 200,
            y2: 200,
        });
        subckt.labels.push(Label {
            net_idx: 0,
            x: 100,
            y: 200,
            rotation: 0,
        });
        subckt
    }

    #[test]
    fn valid_subcircuit_no_errors() {
        let subckt = valid_subckt();
        let errors = validate_subcircuit(&subckt);
        assert!(errors.is_empty(), "expected no errors, got: {:?}", errors);
    }

    #[test]
    fn duplicate_instance_name_detected() {
        let mut subckt = valid_subckt();
        // Add a second instance with the same name "M1".
        subckt.instances.push(Instance {
            name: "M1".to_string(),
            primitive: Primitive::Pmos,
            symbol: String::new(),
            pins: vec![],
            params: HashMap::new(),
            x: 200,
            y: 200,
            rotation: 0,
            flip: false,
        });
        let errors = validate_subcircuit(&subckt);
        assert!(
            errors.iter().any(|e| e.severity == Severity::Error
                && e.message.contains("duplicate instance name 'M1'")),
            "expected duplicate name error, got: {:?}",
            errors
        );
    }

    #[test]
    fn off_grid_instance_detected() {
        let mut subckt = valid_subckt();
        subckt.instances[0].x = 105; // not a multiple of 10
        let errors = validate_subcircuit(&subckt);
        assert!(
            errors
                .iter()
                .any(|e| e.severity == Severity::Error && e.message.contains("off-grid")),
            "expected off-grid error, got: {:?}",
            errors
        );
    }

    #[test]
    fn off_grid_wire_detected() {
        let mut subckt = valid_subckt();
        subckt.wires[0].x1 = 103;
        let errors = validate_subcircuit(&subckt);
        assert!(
            errors
                .iter()
                .any(|e| e.severity == Severity::Error && e.message.contains("wire 0 off-grid")),
            "expected off-grid wire error, got: {:?}",
            errors
        );
    }

    #[test]
    fn off_grid_label_detected() {
        let mut subckt = valid_subckt();
        subckt.labels[0].x = 15;
        let errors = validate_subcircuit(&subckt);
        assert!(
            errors
                .iter()
                .any(|e| e.severity == Severity::Error && e.message.contains("label 0 off-grid")),
            "expected off-grid label error, got: {:?}",
            errors
        );
    }

    #[test]
    fn non_orthogonal_wire_detected() {
        let mut subckt = valid_subckt();
        subckt.wires[0] = Wire {
            net_idx: 0,
            x1: 100,
            y1: 200,
            x2: 200,
            y2: 300, // diagonal!
        };
        let errors = validate_subcircuit(&subckt);
        assert!(
            errors
                .iter()
                .any(|e| e.severity == Severity::Error && e.message.contains("diagonal")),
            "expected diagonal wire error, got: {:?}",
            errors
        );
    }

    #[test]
    fn duplicate_wire_detected() {
        let mut subckt = valid_subckt();
        // Add duplicate of existing wire.
        subckt.wires.push(Wire {
            net_idx: 0,
            x1: 100,
            y1: 200,
            x2: 200,
            y2: 200,
        });
        let errors = validate_subcircuit(&subckt);
        assert!(
            errors
                .iter()
                .any(|e| e.severity == Severity::Warning && e.message.contains("duplicate wire")),
            "expected duplicate wire warning, got: {:?}",
            errors
        );
    }

    #[test]
    fn duplicate_wire_reversed_endpoints_detected() {
        let mut subckt = valid_subckt();
        // Add the same wire but with reversed endpoints.
        subckt.wires.push(Wire {
            net_idx: 0,
            x1: 200,
            y1: 200,
            x2: 100,
            y2: 200,
        });
        let errors = validate_subcircuit(&subckt);
        assert!(
            errors
                .iter()
                .any(|e| e.severity == Severity::Warning && e.message.contains("duplicate wire")),
            "expected duplicate wire warning for reversed endpoints, got: {:?}",
            errors
        );
    }

    #[test]
    fn invalid_rotation_instance_detected() {
        let mut subckt = valid_subckt();
        subckt.instances[0].rotation = 5;
        let errors = validate_subcircuit(&subckt);
        assert!(
            errors
                .iter()
                .any(|e| e.severity == Severity::Error && e.message.contains("invalid rotation")),
            "expected invalid rotation error, got: {:?}",
            errors
        );
    }

    #[test]
    fn invalid_rotation_label_detected() {
        let mut subckt = valid_subckt();
        subckt.labels[0].rotation = 7;
        let errors = validate_subcircuit(&subckt);
        assert!(
            errors
                .iter()
                .any(|e| e.severity == Severity::Error && e.message.contains("invalid rotation")),
            "expected invalid rotation error for label, got: {:?}",
            errors
        );
    }

    #[test]
    fn invalid_label_net_idx_detected() {
        let mut subckt = valid_subckt();
        subckt.labels[0].net_idx = 99; // out of bounds
        let errors = validate_subcircuit(&subckt);
        assert!(
            errors
                .iter()
                .any(|e| e.severity == Severity::Error
                    && e.message.contains("references net_idx 99")),
            "expected invalid net_idx error, got: {:?}",
            errors
        );
    }

    #[test]
    fn validate_circuit_prefixes_subcircuit_name() {
        let mut circuit = Circuit::new("top");
        circuit.top.nets.push(Net::new("vdd"));
        let mut bad_sub = Subcircuit::new("inv");
        bad_sub.instances.push(Instance {
            name: "X1".to_string(),
            primitive: Primitive::Nmos,
            symbol: String::new(),
            pins: vec![],
            params: HashMap::new(),
            x: 105, // off-grid
            y: 200,
            rotation: 0,
            flip: false,
        });
        circuit.subcircuits.insert("inv".to_string(), bad_sub);

        let errors = validate_circuit(&circuit);
        assert!(
            errors
                .iter()
                .any(|e| e.message.contains("subcircuit 'inv':")),
            "expected error message to be prefixed with subcircuit name, got: {:?}",
            errors
        );
    }

    #[test]
    fn valid_subcircuit_with_only_warnings_has_no_errors() {
        // A completely valid subcircuit should produce zero errors/warnings.
        let subckt = valid_subckt();
        let errors = validate_subcircuit(&subckt);
        let has_fatal = errors.iter().any(|e| e.severity == Severity::Error);
        assert!(!has_fatal, "expected no fatal errors, got: {:?}", errors);
    }

    #[test]
    fn empty_subcircuit_no_errors() {
        let subckt = Subcircuit::new("empty");
        let errors = validate_subcircuit(&subckt);
        assert!(errors.is_empty(), "empty subcircuit should have no errors");
    }
}
