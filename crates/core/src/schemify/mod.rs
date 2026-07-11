//! Schemify data model — device taxonomy, schematic document (SoA via
//! `soa_derive`), command/tool enums, embedded `.chn_prim` primitive
//! table, and the `.chn` reader/writer.

pub mod chn;
pub mod command;
pub mod device;
pub mod model;
pub mod prims;

// Flat re-exports: every pre-split `schemify::X` path keeps working.
pub use chn::*;
pub use command::*;
pub use device::*;
pub use model::*;
pub use prims::*;

/// Interned string handle. Resolve via the owning `Rodeo`.
pub type Sym = lasso::Spur;
