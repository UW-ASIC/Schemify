"""Main Gm/Id optimizer orchestrator.

Flow:
1. Load problem definition (transistors, specs, testbenches)
2. Run characterization sweeps to build Gm/Id lookup tables (cached per L)
3. Run Bayesian optimization loop:
   a. Backend suggests gm/Id values (+ other params)
   b. Look up W from gm/Id tables
   c. Run testbench simulation with concrete W, L, R values
   d. Feed results back to backend
4. Return best feasible design
"""

from __future__ import annotations

import logging
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

import numpy as np

from gmid_optimizer.backend import BayesianBackend, Observation
from gmid_optimizer.gmid import GmIdLookup
from gmid_optimizer.problem import Problem, SpecKind, Transistor
from gmid_optimizer.spice import SimResult, run_characterization, run_testbench

log = logging.getLogger(__name__)


@dataclass
class OptimizationResult:
    best_params: Optional[dict] = None
    best_objectives: Optional[np.ndarray] = None
    observations: list[Observation] = field(default_factory=list)
    lookups: dict[str, GmIdLookup] = field(default_factory=dict)
    iterations: int = 0
    feasible_count: int = 0


class GMIDOptimizer:
    """Gm/Id methodology circuit optimizer.

    Key properties:
    - L is NEVER changed during optimization (cache-friendly)
    - Design variables are gm/Id ratios per transistor
    - W is derived from lookup tables, not optimized directly
    """

    def __init__(
        self,
        problem: Problem,
        model_lib_path: str,
        vdd: float = 1.8,
        cache_dir: Optional[Path] = None,
        max_iter: int = 50,
        initial_samples: int = 20,
        seed: int = 42,
    ):
        self.problem = problem
        self.model_lib_path = model_lib_path
        self.vdd = vdd
        self.cache_dir = cache_dir or Path(".gmid_cache")
        self.max_iter = max_iter
        self.initial_samples = initial_samples
        self.seed = seed

        # Gm/Id lookup tables: keyed by "{model}_L{L}"
        self.lookups: dict[str, GmIdLookup] = {}

        # Backend (initialized during characterize())
        self._backend: Optional[BayesianBackend] = None

    def characterize(self) -> None:
        """Run characterization sweeps for all unique (model, L) pairs.

        This is done ONCE before optimization. Results are cached to disk.
        Since L is fixed, the cache is never invalidated during optimization.
        """
        seen = set()
        for t in self.problem.transistors:
            key = self._lookup_key(t)
            if key in seen:
                continue
            seen.add(key)

            log.info(f"Characterizing {t.model} L={t.L:.3e}...")
            lookup = run_characterization(
                t, self.model_lib_path,
                vdd=self.vdd, cache_dir=self.cache_dir,
            )
            self.lookups[key] = lookup
            log.info(
                f"  gm/Id range: [{lookup.gmid_range[0]:.1f}, {lookup.gmid_range[1]:.1f}] V^-1"
            )

        # Initialize backend with correct bounds
        lb, ub = self.problem.get_bounds()
        self._backend = BayesianBackend(
            n_params=len(lb),
            bounds_min=np.array(lb),
            bounds_max=np.array(ub),
            initial_samples=self.initial_samples,
            seed=self.seed,
        )

    def run(self, callback=None) -> OptimizationResult:
        """Run the full optimization loop.

        callback: optional callable(iteration, observation) for progress reporting.
        """
        if not self.lookups:
            self.characterize()

        result = OptimizationResult(lookups=self.lookups)

        for i in range(self.max_iter):
            # Get candidate from backend
            candidates = self._backend.suggest(1)
            x = candidates[0]

            # Apply design vector to problem
            self.problem.apply_design_vector(x.tolist())

            # Compute W for each transistor from gm/Id lookup
            substitutions = self._build_substitutions(x)

            # Run all testbenches
            obs = self._evaluate(x, substitutions)
            obs.iteration = i

            # Feed back to backend
            self._backend.add_observation(
                obs.parameters, obs.objectives,
                obs.constraints, obs.valid,
            )

            result.observations.append(obs)
            result.iterations = i + 1
            if obs.is_feasible:
                result.feasible_count += 1

            if callback:
                callback(i, obs)

            log.info(
                f"Iter {i+1}/{self.max_iter}: "
                f"obj={obs.objectives} feasible={obs.is_feasible} "
                f"valid={obs.valid}"
            )

        # Extract best
        best = self._backend.best()
        if best:
            result.best_params = self._decode_params(best["params"])
            result.best_objectives = best["objectives"]

        return result

    def _build_substitutions(self, x: np.ndarray) -> dict[str, dict[str, str]]:
        """Build netlist substitutions from design vector.

        For transistors: look up W from gm/Id, keep L fixed.
        For resistors/params: use values directly.
        """
        subs = {}
        idx = 0

        for t in self.problem.transistors:
            gmid = x[idx]
            key = self._lookup_key(t)
            lookup = self.lookups[key]

            # Get current density (A/um) from lookup
            jd = lookup.lookup_id_w(gmid)
            vgs = lookup.lookup_vgs(gmid)

            # W (um) = Id_target / Jd(gmid).  Default reference: 10uA.
            w_um = abs(10e-6 / jd) if abs(jd) > 1e-30 else 1.0
            w_est = w_um * 1e-6  # convert to meters for netlist

            t.W = w_est
            t.Vgs = vgs

            subs[t.instance] = {
                "W": f"{w_est:.4e}",
                "L": f"{t.L:.4e}",
            }
            if t.nf > 1:
                subs[t.instance]["nf"] = str(t.nf)

            idx += 1

        for r in self.problem.resistors:
            r_val = x[idx]
            subs[r.instance] = {"R": f"{r_val:.4e}"}
            idx += 1

        for p in self.problem.parameters:
            if p.enabled:
                subs.setdefault(p.instance, {})[p.name] = f"{x[idx]:.4e}"
                idx += 1

        return subs

    def _evaluate(
        self, x: np.ndarray, substitutions: dict[str, dict[str, str]],
    ) -> Observation:
        """Run testbenches and collect objectives/constraints."""
        all_objectives = []
        all_constraints = []
        all_measurements = {}
        all_valid = True

        for tb in self.problem.testbenches:
            result = run_testbench(
                Path(tb.path), substitutions,
                timeout_s=tb.timeout_s,
            )

            if not result.valid:
                all_valid = False
                # Pad with penalty values
                for spec in tb.specs:
                    if spec.is_objective:
                        all_objectives.append(1e10 if spec.kind == SpecKind.MINIMIZE else -1e10)
                    else:
                        all_constraints.append(1e6)  # heavily violated
                continue

            all_measurements.update(result.measurements)

            for spec in tb.specs:
                measured = result.measurements.get(spec.name, 0.0)
                if spec.is_objective:
                    val = measured if spec.kind == SpecKind.MINIMIZE else -measured
                    all_objectives.append(val)
                else:
                    all_constraints.append(spec.to_constraint(measured))

        return Observation(
            parameters=x.copy(),
            objectives=np.array(all_objectives) if all_objectives else np.array([0.0]),
            constraints=np.array(all_constraints) if all_constraints else np.array([-1.0]),
            valid=all_valid,
            measurements=all_measurements,
        )

    def _decode_params(self, x: np.ndarray) -> dict:
        """Decode design vector back to human-readable parameters."""
        params = {}
        idx = 0

        for t in self.problem.transistors:
            gmid = x[idx]
            key = self._lookup_key(t)
            lookup = self.lookups[key]
            jd = lookup.lookup_id_w(gmid)
            w_um = abs(10e-6 / jd) if abs(jd) > 1e-30 else 1.0
            params[t.instance] = {
                "gm/Id": gmid,
                "W_um": w_um,
                "L": t.L,
                "Vgs": lookup.lookup_vgs(gmid),
                "intrinsic_gain": lookup.lookup_intrinsic_gain(gmid),
            }
            idx += 1

        for r in self.problem.resistors:
            params[r.instance] = {"R": x[idx]}
            idx += 1

        for p in self.problem.parameters:
            if p.enabled:
                params.setdefault(p.instance, {})[p.name] = x[idx]
                idx += 1

        return params

    @staticmethod
    def _lookup_key(t: Transistor) -> str:
        return f"{t.model}_L{t.L:.4e}"
