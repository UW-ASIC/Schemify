//! Schemify domain model — device taxonomy, schematic document (SoA via
//! `soa_derive`), embedded `.chn_prim` primitive table, the `.chn`
//! reader/writer, and wire/label/bus connectivity resolution.
//!
//! Pure data + transforms: no App state, no I/O beyond format parsing,
//! no UI. Everything downstream (editor, sim, net2schem, gui, mcp)
//! builds on this crate.

pub mod chn;
pub mod connectivity;
pub mod device;
pub mod model;
pub mod prims;

// Flat re-exports: `schemify_schematic::X` for every domain type.
pub use chn::*;
pub use connectivity::*;
pub use device::*;
pub use model::*;
pub use prims::*;

/// Interned string handle. Resolve via the owning `Rodeo`.
pub type Sym = lasso::Spur;
