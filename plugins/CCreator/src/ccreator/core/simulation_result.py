from __future__ import annotations
from dataclasses import dataclass, field
from typing import TYPE_CHECKING, Literal

import numpy as np

if TYPE_CHECKING:
    from ccreator.core.circuit import BaseCircuit


@dataclass
class SimulationResult:
    kind: Literal['ac', 'dc', 'tran', 'functional', 'rtl']
    circuit: object  # BaseCircuit or BaseTestbench
    x: np.ndarray
    y: dict[str, np.ndarray]
    metadata: dict = field(default_factory=dict)

    def metrics(self, probe: str | None = None) -> 'Metrics':
        from ccreator.compare.metrics import compute_metrics
        return compute_metrics(self, probe)

    def plot(self, **kwargs):
        from ccreator.compare.comparator import _plot_single
        _plot_single(self, **kwargs)

    def report(self):
        from ccreator.compare.comparator import _report_single
        _report_single(self)


@dataclass
class ComparisonResult:
    r1: SimulationResult
    r2: SimulationResult
    _metrics: dict = field(default_factory=dict)

    def metrics(self) -> dict:
        return self._metrics

    def plot(self, **kwargs):
        from ccreator.compare.comparator import _plot_comparison
        _plot_comparison(self, **kwargs)

    def report(self):
        from ccreator.compare.comparator import _report_comparison
        _report_comparison(self)
