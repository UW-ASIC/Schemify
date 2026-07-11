//! Editor use-case layer: `App` state, the `Command` vocabulary and its
//! dispatch, undo history, project config, JSON command marshaling, and
//! waveform-viewer session state.
//!
//! Headless frontends (mcp, cli) and the gui all drive mutations through
//! `App::dispatch(Command)`.

pub mod config;
pub mod handler;
pub mod marshal;
pub mod waveform;

// Compatibility shims for pre-split paths; canonical homes are the
// schematic and sim crates. Removed once all consumers import directly.
pub mod schemify;
pub use schemify_sim as sim;
pub use waveform as wave;
