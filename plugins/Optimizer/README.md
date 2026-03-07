# Circuit Parameter Optimizer — Architecture Document

## Problem Statement

You have:

- A SPICE testbench that simulates a circuit
- Component parameters to tune (transistor W/L, resistor values, bias currents, etc.)
- Target specifications (gain ≥ 40dB, phase margin ≥ 60°, area minimized, etc.)

You want:

- The parameter values that meet all specs with minimal simulations
- Each simulation is expensive (seconds to minutes)

---

## The Optimization Problem (Mathematically)

```
minimize    f(x)                          ← objective (e.g., area, power)
subject to  c_i(x) ≤ 0,  i = 1, ..., C    ← constraints (specs to meet)
where       x ∈ [L, U] ⊂ ℝ^d             ← parameters within bounds
```

**Critical insight**: You cannot compute gradients of f or c_i. They are black-box functions evaluated by SPICE. This rules out gradient descent, Newton's method, etc.

---

## Why Bayesian Optimization?

Bayesian Optimization (BO) is designed exactly for this:

- Black-box functions (no gradients)
- Expensive evaluations (want minimal samples)
- Bounded search space

**Core idea**: Build a statistical model (surrogate) of f and c_i from observations. Use the model's predictions AND uncertainty to decide where to sample next.

---

## System Components

### Component 1: Observation Database

**Purpose**: Store all (parameters → simulation results) pairs.

**What it holds**:

- Parameter vectors (normalized to [0,1] for numerical stability)
- Objective values (the thing you're minimizing/maximizing)
- Constraint values (negative = satisfied, positive = violated)
- Metadata (simulation time, simulator version, timestamp)

**Design consideration**: This is append-only during optimization. Structure it for fast iteration over all observations (the surrogate model needs to read everything on each update).

---

### Component 2: Testbench Interface

**Purpose**: Convert parameter values → simulation results.

**Responsibilities**:

1. Take a parameter vector
2. Generate a valid netlist (substitute values into template)
3. Invoke the simulator
4. Parse output files to extract measurements
5. Return structured results

**Inputs to define**:

- Testbench template with placeholder syntax (e.g., `{{M1_W}}`, `$param(Ibias)`)
- Mapping: parameter name → placeholder location(s) in template
- Mapping: measurement name → location in simulator output

**Simulator support to consider**:

- ngspice (open source, .raw and .measure output)
- HSPICE (industry standard, .lis output)
- Spectre (Cadence, various formats)
- Xyce (Sandia, open source)

Each has different output formats. You need parsers for each.

---

### Component 3: Surrogate Model

**Purpose**: Approximate f(x) and c_i(x) from observations so you can predict at unobserved points.

**The standard choice**: Gaussian Process (GP)

A GP gives you:

- μ(x) = predicted mean at point x
- σ²(x) = predicted variance (uncertainty) at point x

**Why GP over neural networks or random forests?**

- GPs provide calibrated uncertainty estimates (critical for exploration)
- GPs work well with small datasets (you have few observations)
- GPs have theoretical guarantees on convergence

**Key decisions**:

1. **One GP per output vs. Multi-output GP**
   - One GP per output: simpler, outputs assumed independent
   - Multi-output GP: models correlations between outputs (gain and bandwidth are often correlated)
   - Multi-output is better but more complex

2. **Kernel choice**
   - Matérn 5/2 is the standard for physical systems (twice differentiable)
   - Use Automatic Relevance Determination (ARD): separate length scale per input dimension

3. **Hyperparameter fitting**
   - Maximize marginal likelihood (standard approach)
   - Requires numerical optimization (L-BFGS typically)

**Libraries that implement this**:

- GPyTorch (PyTorch-based, GPU support, most flexible)
- GPy (older, stable, Sheffield ML group)
- scikit-learn GaussianProcessRegressor (simple, limited)
- George (fast, C++ backend)

---

### Component 4: Acquisition Function

**Purpose**: Score candidate points to decide which to simulate next.

**The trade-off**: Exploitation (sample where predicted objective is good) vs. Exploration (sample where uncertainty is high).

**Standard acquisition functions**:

| Function                        | Formula                  | Behavior      |
| ------------------------------- | ------------------------ | ------------- |
| Expected Improvement (EI)       | E[max(f_best - f(x), 0)] | Balanced      |
| Probability of Improvement (PI) | P(f(x) < f_best)         | Exploitative  |
| Lower Confidence Bound (LCB)    | μ(x) - β·σ(x)            | Tunable via β |

**For constrained problems, you need constraint-aware acquisition**:

Standard approach: Multiply acquisition by probability of feasibility

```
α_constrained(x) = α(x) × ∏_i P(c_i(x) ≤ 0)
```

**TRACE approach (from the paper you read)**:

Two-level dominance:

1. Level 1: Rank points by feasibility using fcv1 and fcv2
2. Level 2: Among equally-feasible points, rank by LCB/PI/EI

This provably focuses search on the feasible region first.

**Libraries that implement acquisition functions**:

- BoTorch (most comprehensive, includes constrained variants)
- GPyOpt (Sheffield, good for basics)
- Dragonfly (CMU, includes multi-fidelity)

---

### Component 5: Acquisition Optimizer

**Purpose**: Find the point(s) that maximize the acquisition function.

**This is itself an optimization problem**, but:

- The acquisition function is cheap to evaluate (just GP predictions)
- You can use gradients (acquisition functions are differentiable w.r.t. x)

**Standard approach**:

1. Generate many random starting points
2. Run L-BFGS-B from each starting point
3. Return the best result

**Why L-BFGS-B?**

- Handles box constraints (your parameter bounds)
- Uses gradients efficiently
- Quasi-Newton, so faster than gradient descent

**Batch acquisition** (selecting multiple points at once):

- Useful if you can run simulations in parallel
- More complex: need to account for the fact that selected points haven't been observed yet
- qEI, qLCB variants exist for this

---

### Component 6: Convergence Monitor

**Purpose**: Decide when to stop.

**Criteria to consider**:

- Budget exhausted (max iterations reached)
- Objective improvement below threshold for N iterations
- All constraints satisfied and objective stable
- Predicted improvement negligible everywhere

**Practical note**: Often you just run until budget is exhausted, then pick the best feasible point observed.

---

## Data Flow

```
┌─────────────────────────────────────────────────────────────────┐
│                                                                 │
│  ┌──────────────┐    parameters    ┌──────────────────────┐    │
│  │              │ ───────────────► │                      │    │
│  │  Acquisition │                  │  Testbench Interface │    │
│  │  Optimizer   │ ◄─────────────── │                      │    │
│  │              │   measurements   └──────────┬───────────┘    │
│  └──────┬───────┘                             │                │
│         │                                     │                │
│         │ x*                                  │ (x, y)         │
│         │                                     │                │
│         ▼                                     ▼                │
│  ┌──────────────┐                  ┌──────────────────────┐    │
│  │  Acquisition │ ◄─────────────── │                      │    │
│  │  Function    │    μ(x), σ(x)    │  Observation         │    │
│  └──────┬───────┘                  │  Database            │    │
│         │                          │                      │    │
│         │ α(x)                     └──────────┬───────────┘    │
│         │                                     │                │
│         ▼                                     │ training data  │
│  ┌──────────────┐                             │                │
│  │   Surrogate  │ ◄───────────────────────────┘                │
│  │   Model (GP) │                                              │
│  └──────────────┘                                              │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## The Algorithm (Step by Step)

### Initialization Phase

1. Define parameter bounds [L_j, U_j] for each parameter j
2. Define specifications (objective to minimize, constraints to satisfy)
3. Generate initial samples using Latin Hypercube Sampling (LHS)
   - LHS gives better coverage than random sampling
   - Typical: 5-10 samples per dimension, minimum ~20
4. Run simulations for all initial samples
5. Store results in observation database

### Main Loop

```
while not converged:
    1. Fit surrogate models to current observations
       - One GP for objective
       - One GP per constraint (or multi-output GP for all)
       - Optimize GP hyperparameters (length scales, noise, etc.)

    2. Define acquisition function
       - Use GP predictions for μ(x), σ(x)
       - Incorporate constraint predictions

    3. Optimize acquisition function
       - Multi-start L-BFGS-B over parameter space
       - Get candidate point(s) x*

    4. Evaluate candidate(s)
       - Run SPICE simulation at x*
       - Parse results

    5. Update database
       - Append new observation(s)

    6. Check convergence
       - Budget exhausted?
       - Objective converged?
```

### Finalization

1. Find best feasible observation in database
2. Optionally: Run verification simulation at best point
3. Report optimal parameters and achieved specifications

---

## Key Design Decisions

### Decision 1: Multi-Output Modeling

**Option A**: Independent GPs (one per output)

- Simpler implementation
- Faster fitting
- Ignores correlations between outputs

**Option B**: Multi-output GP (joint model)

- Exploits correlations (if gain is high, bandwidth is often low)
- Better predictions with fewer samples
- More complex, slower

**Recommendation**: Start with Option A. Move to Option B if sample efficiency is critical.

---

### Decision 2: Handling Constraints

**Option A**: Probability of Feasibility weighting

```
α_constrained(x) = α(x) × P(feasible)
```

- Simple
- Can waste samples in infeasible regions early on

**Option B**: TRACE two-level dominance

- Level 1 forces search toward feasible region
- Level 2 optimizes within feasible region
- Better for tight constraints
- More complex acquisition optimization

**Recommendation**: Use TRACE if your constraints are tight (most of the space is infeasible). Use probability weighting otherwise.

---

### Decision 3: Batch vs Sequential

**Sequential**: One simulation at a time

- Simpler
- Each sample uses all available information
- Slower wall-clock time

**Batch**: Multiple simulations in parallel

- Faster wall-clock time
- Need "fantasizing" or ensemble methods to handle pending evaluations
- qEI, qLCB, or MACE ensemble

**Recommendation**: Use batch if you have parallel simulation capability. Batch sizes of 2-4 are typical.

---

### Decision 4: Multi-Fidelity

If you can run simulations at different accuracy levels:

- Coarse: faster but less accurate (e.g., simplified models, fewer points)
- Fine: slower but accurate (full simulation)

Multi-fidelity BO uses cheap simulations to guide expensive ones.

**When to use**: When coarse simulations are ≥5x faster and reasonably correlated with fine results.

**Libraries**: BoTorch has SingleTaskMultiFidelityGP, Dragonfly supports this natively.

---

### Decision 5: Where to Put Intelligence

**Option A**: Zig does everything

- Implement GP, acquisition, optimization in Zig
- No external dependencies
- Significant implementation effort (Cholesky, L-BFGS, etc.)

**Option B**: Zig orchestrates, Python optimizes

- Zig handles testbench, simulation, parsing
- Python handles GP fitting and acquisition (via IPC)
- Leverages mature libraries
- Adds complexity of IPC

**Option C**: Python does everything

- Simplest implementation
- Zig not needed
- May be slower for simulation orchestration

**Recommendation**: Option B gives best of both worlds. Zig is fast for I/O-heavy simulation management. Python has mature optimization libraries.

---

## Suggested Libraries by Component

| Component      | Library         | Language | Notes                                         |
| -------------- | --------------- | -------- | --------------------------------------------- |
| GP Surrogate   | GPyTorch        | Python   | Most flexible, GPU support                    |
| GP Surrogate   | BoTorch         | Python   | Higher-level, built on GPyTorch               |
| GP Surrogate   | GPy             | Python   | Older, stable                                 |
| Acquisition    | BoTorch         | Python   | Comprehensive, includes batch and constrained |
| Acquisition    | GPyOpt          | Python   | Simpler, good for basics                      |
| Multi-fidelity | Dragonfly       | Python   | Built-in support                              |
| L-BFGS-B       | scipy.optimize  | Python   | Standard                                      |
| LHS Sampling   | scipy.stats.qmc | Python   | Latin Hypercube and Sobol                     |
| SPICE parsing  | PySpice         | Python   | ngspice interface                             |
| SPICE parsing  | Custom          | Any      | Often needed for specific formats             |

---

## Numbers to Expect

Based on circuit optimization literature:

| Metric                                  | Typical Range                     |
| --------------------------------------- | --------------------------------- |
| Initial samples                         | 10-70 (depends on dimensionality) |
| Total budget                            | 100-500 simulations               |
| Constraint satisfaction rate (naive BO) | ~1-10% of samples                 |
| Constraint satisfaction rate (TRACE)    | ~20-40% of samples                |
| Improvement over random search          | 3-10x fewer simulations           |

---

## Failure Modes to Handle

1. **All initial samples infeasible**
   - Need exploration toward feasible region
   - TRACE handles this well

2. **GP hyperparameters poorly fit**
   - Can cause over/under-exploration
   - Use priors on hyperparameters
   - Consider fully Bayesian treatment (MCMC over hyperparameters)

3. **Simulator failures**
   - Non-convergence, numerical issues
   - Treat as constraint violation or missing data
   - Don't let one failure stop optimization

4. **Flat objective in feasible region**
   - Acquisition function becomes dominated by exploration
   - Any feasible point is acceptable
   - Consider early stopping

5. **Highly multimodal objective**
   - GP may miss local optima
   - Use more random restarts in acquisition optimization
   - Consider ensemble of GPs

---

## Summary

**Minimum viable implementation**:

1. Testbench interface (generate netlist, run sim, parse output)
2. Observation database (store all results)
3. GP surrogate (one per output)
4. EI acquisition with probability of feasibility
5. Multi-start L-BFGS-B for acquisition optimization
6. Main loop connecting everything

**Enhanced implementation**:

- Multi-output GP for correlated specs
- TRACE acquisition for tight constraints
- Batch acquisition for parallel sims
- Multi-fidelity for variable accuracy sims

**The bottleneck is always the simulator**. Everything else is cheap in comparison. Invest in reducing simulation time (simpler testbenches, coarse-to-fine, caching) before optimizing the optimizer.
