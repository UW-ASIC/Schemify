//! schemify-optimizer — ask-tell parameter optimizer for circuit sizing.
//!
//! Ask-tell split: [`Optimizer::suggest`] is a pure read returning the
//! precomputed pending candidate (the MCP server calls it under a shared
//! lock); [`Optimizer::report`] mutates — it records the evaluation,
//! advances the algorithm, and precomputes the next pending candidate.
//!
//! Scoring: `score = Σ weight_i * err_i` where err is `value` for
//! [`Target::Minimize`], `-value` for [`Target::Maximize`], and
//! `|value - t|` for [`Target::Approach`]. Lower score = better.
//!
//! History is stored SoA/flat (`params_flat`, `objectives_flat`, `scores`)
//! and the whole optimizer state round-trips through JSON.

mod nelder_mead;

use serde::{Deserialize, Serialize};

use nelder_mead::NelderMead;

/// Default xorshift64* seed (golden-ratio constant); also used when a caller
/// sets seed 0, which xorshift cannot escape.
const DEFAULT_SEED: u64 = 0x9E3779B97F4A7C15;

/// One bounded search parameter. `init` is clamped to `[min, max]` at use.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Param {
    pub name: String,
    pub min: f64,
    pub max: f64,
    pub init: f64,
}

/// What "good" means for one measured objective.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Target {
    Minimize,
    Maximize,
    /// Minimize |value - target|.
    Approach(f64),
}

/// A named, weighted objective. Score contribution is `weight * err`.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Objective {
    pub name: String,
    pub target: Target,
    pub weight: f64,
}

/// Search strategy. Both are ask-tell and clamp candidates to bounds.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Algorithm {
    Random,
    NelderMead,
}

impl Algorithm {
    pub fn as_str(self) -> &'static str {
        match self {
            Algorithm::Random => "random",
            Algorithm::NelderMead => "nelder-mead",
        }
    }

    pub fn from_name(s: &str) -> Option<Self> {
        match s {
            "random" => Some(Algorithm::Random),
            "nelder-mead" => Some(Algorithm::NelderMead),
            _ => None,
        }
    }
}

/// Borrowed view of one history row.
#[derive(Clone, Copy, Debug, PartialEq, Serialize)]
pub struct Evaluation<'a> {
    pub index: u32,
    pub params: &'a [f64],
    pub objectives: &'a [f64],
    pub score: f64,
}

#[derive(thiserror::Error, Debug, PartialEq)]
pub enum OptError {
    #[error("dimension mismatch: expected {expected}, got {got}")]
    DimMismatch { expected: usize, got: usize },
    #[error("duplicate name: {0}")]
    DuplicateName(String),
    #[error("unknown name: {0}")]
    UnknownName(String),
    #[error("no parameters defined")]
    NoParams,
    #[error("invalid bounds for param {0}: min > max")]
    InvalidBounds(String),
}

/// Ask-tell optimizer over named bounded params and weighted objectives.
///
/// History is SoA: `params_flat` is n_evals x n_params row-major,
/// `objectives_flat` is n_evals x n_objectives, `scores` parallel.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Optimizer {
    name: String,
    algorithm: Algorithm,
    seed: u64,
    rng_state: u64,
    params: Vec<Param>,
    objectives: Vec<Objective>,
    params_flat: Vec<f64>,
    objectives_flat: Vec<f64>,
    scores: Vec<f64>,
    /// Precomputed candidate served by `suggest`. None iff no params.
    pending: Option<Vec<f64>>,
    /// Nelder-Mead state machine; None unless that algorithm is active.
    nm: Option<NelderMead>,
}

impl Optimizer {
    pub fn new(name: impl Into<String>) -> Self {
        Optimizer {
            name: name.into(),
            algorithm: Algorithm::Random,
            seed: DEFAULT_SEED,
            rng_state: DEFAULT_SEED,
            params: Vec::new(),
            objectives: Vec::new(),
            params_flat: Vec::new(),
            objectives_flat: Vec::new(),
            scores: Vec::new(),
            pending: None,
            nm: None,
        }
    }

    pub fn name(&self) -> &str {
        &self.name
    }

    pub fn set_name(&mut self, name: impl Into<String>) {
        self.name = name.into();
    }

    pub fn algorithm(&self) -> Algorithm {
        self.algorithm
    }

    /// Switch algorithm: resets algorithm-internal state (RNG, simplex,
    /// pending candidate) but keeps params, objectives, and history.
    pub fn set_algorithm(&mut self, a: Algorithm) {
        self.algorithm = a;
        self.reset_algorithm();
    }

    /// Set the RNG seed and rewind the RNG to it. History and the current
    /// pending candidate are untouched; only future random draws change.
    pub fn set_seed(&mut self, seed: u64) {
        self.seed = if seed == 0 { DEFAULT_SEED } else { seed };
        self.rng_state = self.seed;
    }

    pub fn params(&self) -> &[Param] {
        &self.params
    }

    pub fn objectives(&self) -> &[Objective] {
        &self.objectives
    }

    /// Add a param. Resets the run: history row width changes, so it is
    /// invalidated and cleared.
    pub fn add_param(&mut self, p: Param) -> Result<(), OptError> {
        if p.min > p.max {
            return Err(OptError::InvalidBounds(p.name));
        }
        if self.params.iter().any(|q| q.name == p.name) {
            return Err(OptError::DuplicateName(p.name));
        }
        self.params.push(p);
        self.reset();
        Ok(())
    }

    /// Remove a param by name. Resets the run (history cleared).
    pub fn remove_param(&mut self, name: &str) -> Result<(), OptError> {
        let i = self
            .params
            .iter()
            .position(|p| p.name == name)
            .ok_or_else(|| OptError::UnknownName(name.into()))?;
        self.params.remove(i);
        self.reset();
        Ok(())
    }

    /// Add an objective. Resets the run (history row width changes).
    pub fn add_objective(&mut self, o: Objective) -> Result<(), OptError> {
        if self.objectives.iter().any(|q| q.name == o.name) {
            return Err(OptError::DuplicateName(o.name));
        }
        self.objectives.push(o);
        self.reset();
        Ok(())
    }

    /// Remove an objective by name. Resets the run (history cleared).
    pub fn remove_objective(&mut self, name: &str) -> Result<(), OptError> {
        let i = self
            .objectives
            .iter()
            .position(|o| o.name == name)
            .ok_or_else(|| OptError::UnknownName(name.into()))?;
        self.objectives.remove(i);
        self.reset();
        Ok(())
    }

    /// The pending candidate to evaluate next. Pure read: no state is
    /// touched, so it is safe under a shared lock. None if no params.
    pub fn suggest(&self) -> Option<&[f64]> {
        self.pending.as_deref()
    }

    /// Record measured objective values for the pending candidate, advance
    /// the algorithm, and precompute the next pending candidate.
    /// Returns the (lower-is-better) score.
    pub fn report(&mut self, measured: &[f64]) -> Result<f64, OptError> {
        let candidate = self.pending.clone().ok_or(OptError::NoParams)?;
        if measured.len() != self.objectives.len() {
            return Err(OptError::DimMismatch {
                expected: self.objectives.len(),
                got: measured.len(),
            });
        }
        let score = score_of(&self.objectives, measured);
        self.params_flat.extend_from_slice(&candidate);
        self.objectives_flat.extend_from_slice(measured);
        self.scores.push(score);
        match self.algorithm {
            Algorithm::Random => self.pending = Some(self.sample_uniform()),
            Algorithm::NelderMead => {
                let nm = self.nm.as_mut().expect("nm state exists while pending");
                nm.tell(score);
                self.pending = Some(nm.candidate().to_vec());
            }
        }
        Ok(score)
    }

    /// Record a manual/external evaluation at explicit param values. Feeds
    /// history and best-tracking only: it does NOT advance the Nelder-Mead
    /// state machine, the RNG, or the pending candidate.
    pub fn report_at(&mut self, params: &[f64], measured: &[f64]) -> Result<f64, OptError> {
        if self.params.is_empty() {
            return Err(OptError::NoParams);
        }
        if params.len() != self.params.len() {
            return Err(OptError::DimMismatch {
                expected: self.params.len(),
                got: params.len(),
            });
        }
        if measured.len() != self.objectives.len() {
            return Err(OptError::DimMismatch {
                expected: self.objectives.len(),
                got: measured.len(),
            });
        }
        let score = score_of(&self.objectives, measured);
        self.params_flat.extend_from_slice(params);
        self.objectives_flat.extend_from_slice(measured);
        self.scores.push(score);
        Ok(score)
    }

    /// Clear history and algorithm state, rewind the RNG, and recompute the
    /// pending candidate from scratch.
    pub fn reset(&mut self) {
        self.params_flat.clear();
        self.objectives_flat.clear();
        self.scores.clear();
        self.reset_algorithm();
    }

    pub fn n_evals(&self) -> u32 {
        self.scores.len() as u32
    }

    pub fn eval(&self, i: u32) -> Option<Evaluation<'_>> {
        let i = i as usize;
        if i >= self.scores.len() {
            return None;
        }
        let np = self.params.len();
        let no = self.objectives.len();
        Some(Evaluation {
            index: i as u32,
            params: &self.params_flat[i * np..(i + 1) * np],
            objectives: &self.objectives_flat[i * no..(i + 1) * no],
            score: self.scores[i],
        })
    }

    /// Lowest-score evaluation seen so far.
    pub fn best(&self) -> Option<Evaluation<'_>> {
        let (i, _) = self
            .scores
            .iter()
            .enumerate()
            .min_by(|(_, a), (_, b)| a.total_cmp(b))?;
        self.eval(i as u32)
    }

    /// Full state as JSON: config, history (flat), pending suggestion, plus
    /// derived `best` and `n_evals`. Deserializing this back into an
    /// `Optimizer` round-trips (derived fields are ignored).
    pub fn to_json(&self) -> serde_json::Value {
        let mut v = serde_json::to_value(self).expect("optimizer state is plain data");
        v["n_evals"] = self.n_evals().into();
        v["best"] = match self.best() {
            Some(e) => serde_json::json!({
                "index": e.index,
                "params": e.params,
                "objectives": e.objectives,
                "score": e.score,
            }),
            None => serde_json::Value::Null,
        };
        v
    }

    /// Rebuild algorithm-internal state. Keeps history.
    fn reset_algorithm(&mut self) {
        self.rng_state = self.seed;
        if self.params.is_empty() {
            self.pending = None;
            self.nm = None;
            return;
        }
        match self.algorithm {
            // Both algorithms start at the (clamped) init point.
            Algorithm::Random => {
                self.nm = None;
                self.pending = Some(
                    self.params
                        .iter()
                        .map(|p| p.init.clamp(p.min, p.max))
                        .collect(),
                );
            }
            Algorithm::NelderMead => {
                let nm = NelderMead::new(&self.params);
                self.pending = Some(nm.candidate().to_vec());
                self.nm = Some(nm);
            }
        }
    }

    /// Uniform draw per param; the only place the RNG advances.
    fn sample_uniform(&mut self) -> Vec<f64> {
        let mut state = self.rng_state;
        let v = self
            .params
            .iter()
            .map(|p| p.min + next_unit(&mut state) * (p.max - p.min))
            .collect();
        self.rng_state = state;
        v
    }
}

/// Weighted-sum score; lower is better.
fn score_of(objectives: &[Objective], measured: &[f64]) -> f64 {
    objectives
        .iter()
        .zip(measured)
        .map(|(o, &v)| {
            let err = match o.target {
                Target::Minimize => v,
                Target::Maximize => -v,
                Target::Approach(t) => (v - t).abs(),
            };
            o.weight * err
        })
        .sum()
}

/// xorshift64*: tiny, deterministic, no dependency. State must be nonzero.
fn xorshift_next(state: &mut u64) -> u64 {
    let mut x = *state;
    x ^= x >> 12;
    x ^= x << 25;
    x ^= x >> 27;
    *state = x;
    x.wrapping_mul(0x2545_F491_4F6C_DD1D)
}

/// Uniform f64 in [0, 1) from the top 53 bits.
fn next_unit(state: &mut u64) -> f64 {
    (xorshift_next(state) >> 11) as f64 / (1u64 << 53) as f64
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sphere_opt() -> Optimizer {
        let mut opt = Optimizer::new("sphere");
        for name in ["x", "y", "z"] {
            opt.add_param(Param {
                name: name.into(),
                min: -5.0,
                max: 5.0,
                init: 4.0,
            })
            .unwrap();
        }
        opt.add_objective(Objective {
            name: "f".into(),
            target: Target::Minimize,
            weight: 1.0,
        })
        .unwrap();
        opt
    }

    #[test]
    fn random_improves_sphere_within_bounds() {
        let mut opt = sphere_opt();
        for _ in 0..200 {
            let x = opt.suggest().unwrap().to_vec();
            for &v in &x {
                assert!((-5.0..=5.0).contains(&v), "out of bounds: {v}");
            }
            let f: f64 = x.iter().map(|v| v * v).sum();
            opt.report(&[f]).unwrap();
        }
        assert_eq!(opt.n_evals(), 200);
        let first = opt.eval(0).unwrap().score;
        let best = opt.best().unwrap().score;
        assert!(best < first, "best {best} not better than first {first}");
        assert!(best < 5.0, "best {best} too far from optimum");
    }

    #[test]
    fn nelder_mead_converges_on_quadratic() {
        let mut opt = Optimizer::new("quad");
        opt.add_param(Param {
            name: "x".into(),
            min: -10.0,
            max: 10.0,
            init: 5.0,
        })
        .unwrap();
        opt.add_param(Param {
            name: "y".into(),
            min: -10.0,
            max: 10.0,
            init: 5.0,
        })
        .unwrap();
        opt.add_objective(Objective {
            name: "f".into(),
            target: Target::Minimize,
            weight: 1.0,
        })
        .unwrap();
        opt.set_algorithm(Algorithm::NelderMead);
        for _ in 0..300 {
            let p = opt.suggest().unwrap().to_vec();
            let f = (p[0] - 1.0).powi(2) + (p[1] + 2.0).powi(2);
            opt.report(&[f]).unwrap();
        }
        let best = opt.best().unwrap();
        assert!(
            (best.params[0] - 1.0).abs() < 0.05 && (best.params[1] + 2.0).abs() < 0.05,
            "did not converge: {:?} (score {})",
            best.params,
            best.score
        );
    }

    #[test]
    fn nelder_mead_single_param_works() {
        let mut opt = Optimizer::new("1d");
        opt.add_param(Param {
            name: "x".into(),
            min: -4.0,
            max: 4.0,
            init: 3.0,
        })
        .unwrap();
        opt.add_objective(Objective {
            name: "f".into(),
            target: Target::Minimize,
            weight: 1.0,
        })
        .unwrap();
        opt.set_algorithm(Algorithm::NelderMead);
        for _ in 0..100 {
            let p = opt.suggest().unwrap().to_vec();
            opt.report(&[(p[0] - 0.5).powi(2)]).unwrap();
        }
        let best = opt.best().unwrap();
        assert!((best.params[0] - 0.5).abs() < 0.05, "1d: {:?}", best.params);
    }

    #[test]
    fn suggest_is_pure() {
        for algo in [Algorithm::Random, Algorithm::NelderMead] {
            let mut opt = sphere_opt();
            opt.set_algorithm(algo);
            opt.report(&[48.0]).unwrap();
            let before = opt.to_json();
            let a = opt.suggest().unwrap().to_vec();
            let b = opt.suggest().unwrap().to_vec();
            assert_eq!(a, b);
            assert_eq!(before, opt.to_json());
        }
    }

    #[test]
    fn errors() {
        let mut empty = Optimizer::new("empty");
        assert!(empty.suggest().is_none());
        assert_eq!(empty.report(&[]), Err(OptError::NoParams));
        assert_eq!(empty.report_at(&[], &[]), Err(OptError::NoParams));

        let mut opt = sphere_opt();
        assert_eq!(
            opt.add_param(Param {
                name: "x".into(),
                min: 0.0,
                max: 1.0,
                init: 0.5
            }),
            Err(OptError::DuplicateName("x".into()))
        );
        assert_eq!(
            opt.add_objective(Objective {
                name: "f".into(),
                target: Target::Maximize,
                weight: 1.0
            }),
            Err(OptError::DuplicateName("f".into()))
        );
        assert_eq!(
            opt.report(&[1.0, 2.0]),
            Err(OptError::DimMismatch {
                expected: 1,
                got: 2
            })
        );
        assert_eq!(
            opt.report_at(&[0.0], &[1.0]),
            Err(OptError::DimMismatch {
                expected: 3,
                got: 1
            })
        );
        assert_eq!(
            opt.remove_param("nope"),
            Err(OptError::UnknownName("nope".into()))
        );
        assert_eq!(
            opt.add_param(Param {
                name: "w".into(),
                min: 2.0,
                max: 1.0,
                init: 1.5
            }),
            Err(OptError::InvalidBounds("w".into()))
        );
    }

    #[test]
    fn json_round_trip() {
        for algo in [Algorithm::Random, Algorithm::NelderMead] {
            let mut opt = sphere_opt();
            opt.set_algorithm(algo);
            for _ in 0..10 {
                let x = opt.suggest().unwrap().to_vec();
                let f: f64 = x.iter().map(|v| v * v).sum();
                opt.report(&[f]).unwrap();
            }
            opt.report_at(&[0.1, 0.2, 0.3], &[0.14]).unwrap();
            let json = opt.to_json();
            let back: Optimizer = serde_json::from_value(json.clone()).unwrap();
            assert_eq!(back, opt);
            assert_eq!(back.to_json(), json);
        }
    }

    #[test]
    fn seed_determinism() {
        let mut a = sphere_opt();
        let mut b = sphere_opt();
        a.set_seed(42);
        b.set_seed(42);
        for _ in 0..50 {
            let xa = a.suggest().unwrap().to_vec();
            let xb = b.suggest().unwrap().to_vec();
            assert_eq!(xa, xb);
            let f: f64 = xa.iter().map(|v| v * v).sum();
            a.report(&[f]).unwrap();
            b.report(&[f]).unwrap();
        }
    }
}
