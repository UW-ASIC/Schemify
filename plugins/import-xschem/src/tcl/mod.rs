//! Minimal TCL interpreter for parsing xschemrc configuration files.
//!
//! Supports the subset of TCL needed to extract library paths and settings:
//! - Variable assignment and expansion (`set`, `$var`)
//! - Command substitution (`[cmd ...]`)
//! - List operations (`lappend`)
//! - File path operations (`file dirname`, `file join`)
//! - Basic control flow (`if`, `foreach`)
//! - Arithmetic expressions (`expr`)
//! - Source inclusion (`source`)

pub mod commands;
pub mod evaluator;
pub mod expr;
pub mod tokenizer;

pub use evaluator::TclInterp;
