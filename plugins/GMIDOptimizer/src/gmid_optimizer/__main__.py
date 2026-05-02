"""CLI entry point for GMIDOptimizer.

Usage: python -m gmid_optimizer --config problem.toml
"""

from __future__ import annotations

import argparse
import json
import logging
import sys
from pathlib import Path

from gmid_optimizer.problem import (
    Problem,
    Resistor,
    SpecKind,
    Specification,
    Testbench,
    Transistor,
)
from gmid_optimizer.optimizer import GMIDOptimizer

logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")
log = logging.getLogger(__name__)


def load_problem_from_json(path: Path) -> dict:
    """Load problem definition from JSON config file."""
    with open(path) as f:
        return json.load(f)


def build_problem(cfg: dict) -> tuple[Problem, str, float]:
    """Build Problem from config dict."""
    kind_map = {
        "minimize": SpecKind.MINIMIZE,
        "maximize": SpecKind.MAXIMIZE,
        ">=": SpecKind.GREATER_EQUAL,
        "<=": SpecKind.LESS_EQUAL,
        "==": SpecKind.EQUAL,
        "range": SpecKind.RANGE,
    }

    transistors = [
        Transistor(
            instance=t["instance"],
            model=t["model"],
            kind=t.get("kind", "nmos"),
            L=t["L"],
            gmid_min=t.get("gmid_min", 3.0),
            gmid_max=t.get("gmid_max", 25.0),
            nf_min=t.get("nf_min", 1),
            nf_max=t.get("nf_max", 20),
        )
        for t in cfg.get("transistors", [])
    ]

    resistors = [
        Resistor(
            instance=r["instance"],
            R_min=r.get("R_min", 100),
            R_max=r.get("R_max", 100e3),
            step=r.get("step"),
        )
        for r in cfg.get("resistors", [])
    ]

    specs = [
        Specification(
            name=s["name"],
            kind=kind_map.get(s["kind"], SpecKind.MAXIMIZE),
            target=s.get("target", 0.0),
            target_upper=s.get("target_upper"),
            weight=s.get("weight", 1.0),
        )
        for s in cfg.get("specs", [])
    ]

    testbenches = [
        Testbench(
            path=tb["path"],
            name=tb.get("name", tb["path"]),
            specs=specs,
            timeout_s=tb.get("timeout_s", 60.0),
        )
        for tb in cfg.get("testbenches", [])
    ]

    return (
        Problem(
            transistors=transistors,
            resistors=resistors,
            testbenches=testbenches,
        ),
        cfg.get("model_lib", ""),
        cfg.get("vdd", 1.8),
    )


def main():
    parser = argparse.ArgumentParser(description="Gm/Id Circuit Optimizer")
    parser.add_argument("--config", required=True, help="Path to JSON config file")
    parser.add_argument("--max-iter", type=int, default=50)
    parser.add_argument("--initial-samples", type=int, default=20)
    parser.add_argument("--cache-dir", default=".gmid_cache")
    parser.add_argument("--seed", type=int, default=42)
    args = parser.parse_args()

    cfg = load_problem_from_json(Path(args.config))
    problem, model_lib, vdd = build_problem(cfg)

    log.info(f"Design variables: {problem.design_variable_count}")
    log.info(f"Objectives: {problem.objective_count}")
    log.info(f"Constraints: {problem.constraint_count}")
    log.info(f"Transistors: {len(problem.transistors)} (L fixed)")

    optimizer = GMIDOptimizer(
        problem=problem,
        model_lib_path=model_lib,
        vdd=vdd,
        cache_dir=Path(args.cache_dir),
        max_iter=args.max_iter,
        initial_samples=args.initial_samples,
        seed=args.seed,
    )

    def progress(iteration, obs):
        status = "OK" if obs.is_feasible else "INFEASIBLE"
        log.info(f"  [{status}] measurements: {obs.measurements}")

    result = optimizer.run(callback=progress)

    log.info(f"\nOptimization complete: {result.iterations} iterations")
    log.info(f"Feasible solutions found: {result.feasible_count}")

    if result.best_params:
        log.info("\nBest design:")
        for inst, params in result.best_params.items():
            log.info(f"  {inst}:")
            for k, v in params.items():
                if isinstance(v, float):
                    log.info(f"    {k} = {v:.4e}")
                else:
                    log.info(f"    {k} = {v}")
    else:
        log.warning("No feasible solution found")
        sys.exit(1)


if __name__ == "__main__":
    main()
