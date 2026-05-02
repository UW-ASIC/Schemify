"""Bayesian optimization backend using BoTorch/GPyTorch.

Replaces the Zig backend with proper GP surrogate + acquisition functions.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Optional

import numpy as np
import torch
from botorch.acquisition import (
    ExpectedImprovement,
    LogExpectedImprovement,
    qExpectedImprovement,
)
from botorch.acquisition.analytic import ProbabilityOfImprovement
from botorch.fit import fit_gpytorch_mll
from botorch.models import SingleTaskGP
from botorch.models.transforms.outcome import Standardize
from botorch.optim import optimize_acqf
from botorch.utils.transforms import normalize, unnormalize
from gpytorch.mlls import ExactMarginalLogLikelihood
from scipy.stats.qmc import LatinHypercube


@dataclass
class Observation:
    """Single observation from running a simulation."""
    parameters: np.ndarray  # design variables
    objectives: np.ndarray  # objective values
    constraints: np.ndarray  # constraint values (negative = satisfied)
    valid: bool = True
    elapsed_ms: int = 0
    iteration: int = 0
    measurements: dict[str, float] = field(default_factory=dict)

    @property
    def is_feasible(self) -> bool:
        if not self.valid:
            return False
        return bool(np.all(self.constraints <= 0))


class BayesianBackend:
    """Bayesian optimization with GP surrogate and EI acquisition."""

    def __init__(
        self,
        n_params: int,
        bounds_min: np.ndarray,
        bounds_max: np.ndarray,
        initial_samples: int = 20,
        batch_size: int = 1,
        seed: int = 42,
    ):
        self.n_params = n_params
        self.bounds = torch.tensor(
            np.stack([bounds_min, bounds_max]),
            dtype=torch.float64,
        )
        self.initial_samples = initial_samples
        self.batch_size = batch_size
        self.seed = seed

        # Observation storage
        self.X: list[np.ndarray] = []
        self.Y_obj: list[np.ndarray] = []
        self.Y_con: list[np.ndarray] = []
        self.valid: list[bool] = []
        self.iteration = 0

        self._model: Optional[SingleTaskGP] = None
        self._best_feasible_idx: Optional[int] = None

    def suggest(self, n: int = 1) -> np.ndarray:
        """Suggest next candidate point(s) to evaluate.

        Returns array of shape (n, n_params) in original scale.
        """
        if self.iteration < self.initial_samples:
            return self._lhs_samples(n)
        return self._optimize_acquisition(n)

    def add_observation(
        self,
        params: np.ndarray,
        objectives: np.ndarray,
        constraints: np.ndarray,
        valid: bool = True,
    ) -> None:
        self.X.append(params.copy())
        self.Y_obj.append(objectives.copy())
        self.Y_con.append(constraints.copy())
        self.valid.append(valid)

        if valid and np.all(constraints <= 0):
            idx = len(self.X) - 1
            if self._best_feasible_idx is None:
                self._best_feasible_idx = idx
            elif objectives[0] < self.Y_obj[self._best_feasible_idx][0]:
                self._best_feasible_idx = idx

        self.iteration += 1

    def best(self) -> Optional[dict]:
        if self._best_feasible_idx is None:
            return None
        idx = self._best_feasible_idx
        return {
            "params": self.X[idx],
            "objectives": self.Y_obj[idx],
        }

    def _lhs_samples(self, n: int) -> np.ndarray:
        """Generate Latin Hypercube samples in original space."""
        sampler = LatinHypercube(d=self.n_params, seed=self.seed + self.iteration)
        unit_samples = sampler.random(n)
        lb = self.bounds[0].numpy()
        ub = self.bounds[1].numpy()
        return lb + unit_samples * (ub - lb)

    def _optimize_acquisition(self, n: int) -> np.ndarray:
        """Fit GP and optimize acquisition function."""
        # Build training data (only valid observations)
        valid_mask = [v for v in self.valid]
        X_train = torch.tensor(
            np.stack([x for x, v in zip(self.X, valid_mask) if v]),
            dtype=torch.float64,
        )
        Y_train = torch.tensor(
            np.stack([y for y, v in zip(self.Y_obj, valid_mask) if v]),
            dtype=torch.float64,
        )

        if len(X_train) < 2:
            return self._lhs_samples(n)

        # Normalize inputs to [0, 1]
        X_normalized = normalize(X_train, self.bounds)

        # Fit GP
        model = SingleTaskGP(
            X_normalized, Y_train,
            outcome_transform=Standardize(m=Y_train.shape[-1]),
        )
        mll = ExactMarginalLogLikelihood(model.likelihood, model)
        fit_gpytorch_mll(mll)
        self._model = model

        # Best feasible value for EI
        if self._best_feasible_idx is not None:
            best_f = torch.tensor(
                [self.Y_obj[self._best_feasible_idx][0]],
                dtype=torch.float64,
            )
        else:
            best_f = Y_train.min()

        # Optimize acquisition
        acq = LogExpectedImprovement(model=model, best_f=best_f)

        unit_bounds = torch.stack([
            torch.zeros(self.n_params, dtype=torch.float64),
            torch.ones(self.n_params, dtype=torch.float64),
        ])

        candidates, _ = optimize_acqf(
            acq_function=acq,
            bounds=unit_bounds,
            q=n,
            num_restarts=10,
            raw_samples=256,
        )

        # Unnormalize back to original space
        result = unnormalize(candidates, self.bounds)
        return result.detach().numpy()

    @property
    def observations(self) -> list[Observation]:
        obs = []
        for i, (x, y_obj, y_con, v) in enumerate(
            zip(self.X, self.Y_obj, self.Y_con, self.valid)
        ):
            obs.append(Observation(
                parameters=x, objectives=y_obj,
                constraints=y_con, valid=v, iteration=i,
            ))
        return obs
