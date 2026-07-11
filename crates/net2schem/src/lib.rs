//! SPICE netlist → schematic pipeline (s2s).
//!
//! Parse + placement run in the `cktimg` library (see `cktimg`); routing
//! (`route`) stays here so wires land on Schemify's own symbol geometry.
//! `emit` holds the schematic adapter, pin geometry, and validation; the
//! hypergraph IR lives in `ir`.

pub mod cktimg;
pub mod emit;
pub mod ir;
pub mod route;

// `shared` folded into `ir`; old path kept alive.
pub use ir as shared;

use crate::ir::Circuit;

/// Parse a SPICE netlist and produce a laid-out circuit.
///
/// Parse + placement run in cktimg; routing runs here so wires match
/// Schemify's symbol geometry. cktimg flattens `.subckt`s, so `subcircuits`
/// is always empty; lines cktimg could not represent land in
/// `Circuit::diagnostics`.
///
/// The returned `Circuit` has placement coordinates, wires, and labels filled
/// in; pass it to `emit` for schematic conversion.
pub fn netlist_to_circuit(source: &str) -> anyhow::Result<Circuit> {
    cktimg::netlist_to_circuit(source)
}
