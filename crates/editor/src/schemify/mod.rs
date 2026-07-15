//! Compatibility shim: the domain model moved to `schemify-schematic`;
//! `Command`/`Tool` moved to `handler::command`. Every pre-split
//! `schemify::X` path keeps working through these re-exports.

pub use schemify_schematic::*;

pub use crate::handler::command::*;
