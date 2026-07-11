//! `.chn` file format — text round-trip for schematic documents.
//!
//! [`parse`]: reader, degrades gracefully (malformed fields warn + default).
//! [`write`]: serializer, line format round-trip compatible with old files.

mod parse;
mod write;

pub use parse::*;
pub use write::*;
