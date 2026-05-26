//! Parameter resolution and substitution for SPICE `.param` directives.
//!
//! Separated from parsing so that param resolution can be tested and invoked
//! independently of the SPICE line parser.

use std::collections::HashMap;

use crate::s2s::ir::{Circuit, Instance};
use super::expr::{eval_expr, parse_spice_number};

/// Resolve raw `.param` string values to f64 via fixed-point iteration.
///
/// Handles dependency ordering: iterates until no new params resolve,
/// up to `params.len() + 1` iterations (sufficient for any DAG).
pub fn resolve_params(params: &HashMap<String, String>) -> HashMap<String, f64> {
    let mut resolved = HashMap::new();
    let max_iterations = params.len() + 1;
    for _ in 0..max_iterations {
        let mut changed = false;
        for (key, val_str) in params {
            if resolved.contains_key(key) {
                continue;
            }
            if let Some(num) = parse_spice_number(val_str) {
                resolved.insert(key.clone(), num);
                changed = true;
                continue;
            }
            if let Ok(num) = eval_expr(val_str, &resolved) {
                resolved.insert(key.clone(), num);
                changed = true;
            }
        }
        if !changed {
            break;
        }
    }
    resolved
}

/// Substitute resolved param values into all instance parameters in a circuit.
pub fn substitute_params(circuit: &mut Circuit, resolved: &HashMap<String, f64>) {
    substitute_in_instances(&mut circuit.top.instances, resolved);
    for sub in circuit.subcircuits.values_mut() {
        substitute_in_instances(&mut sub.instances, resolved);
    }
}

fn substitute_in_instances(instances: &mut [Instance], resolved: &HashMap<String, f64>) {
    for inst in instances.iter_mut() {
        let keys: Vec<String> = inst.params.keys().cloned().collect();
        for key in keys {
            let val_str = inst.params[&key].clone();
            let lower = val_str.to_ascii_lowercase();
            if let Some(&num) = resolved.get(&lower) {
                inst.params.insert(key, format!("{}", num));
            } else if parse_spice_number(&val_str).is_none() {
                if let Ok(num) = eval_expr(&val_str, resolved) {
                    inst.params.insert(key, format!("{}", num));
                }
            }
        }
    }
}
