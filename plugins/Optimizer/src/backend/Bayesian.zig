//! Re-export shim — Bayesian backend lives in backend.zig.
pub const BayesianBackend = @import("backend.zig").Bayesian;
