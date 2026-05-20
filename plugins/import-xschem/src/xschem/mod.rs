//! XSchem `.sch` / `.sym` importer.
//!
//! Provides parsing, property extraction, PDK remapping, and conversion
//! into `ImportResult`.

pub mod converter;
pub mod pdk_remap;
pub mod props;
pub mod reader;
pub mod types;

pub use converter::convert;
pub use reader::parse_xschem;
pub use types::{XSchemDoc, XSchemElement};
