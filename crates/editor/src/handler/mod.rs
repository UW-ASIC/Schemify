//! App state + command dispatch, split by reason-to-change.
//!
//! `app` holds the state types; `dispatch` is the single mutation entry
//! point; `undo`, `transform`, `hit_test`, `connectivity`, `io`, `netlist`
//! each own one concern. Everything is re-exported flat so pre-split
//! `handler::X` paths keep working.

pub mod app;
pub mod command;
pub mod dispatch;
pub mod hit_test;
pub mod io;
pub mod netlist;
pub mod transform;
pub mod undo;

pub use app::*;
pub use command::*;
pub use dispatch::*;

// Connectivity resolution moved to the schematic crate; keep old
// `handler::resolve_connectivity` paths alive.
pub use schemify_schematic::connectivity::*;
pub use hit_test::*;
pub use io::*;
pub use transform::*;
pub use undo::*;

// The IR emitter moved next to the sim module it feeds; keep the old
// `handler::to_circuit_ir` paths alive.
pub use crate::sim::ir_emit::{to_circuit_ir, to_circuit_ir_with_children};

#[cfg(test)]
mod tests;
