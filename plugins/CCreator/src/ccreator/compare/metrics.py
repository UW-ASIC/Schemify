from __future__ import annotations
import numpy as np
from dataclasses import dataclass, field
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from ccreator.core.simulation_result import SimulationResult


@dataclass
class Metrics:
    f3db: float | None = None
    max_error_db: float | None = None
    snr: float | None = None
    timing_errors: int | None = None
    functional_eq: bool | None = None
    extra: dict = field(default_factory=dict)

    def __repr__(self):
        fields = []
        if self.f3db is not None:
            fields.append(f'f3db={self.f3db:.2f}Hz')
        if self.max_error_db is not None:
            fields.append(f'max_error_db={self.max_error_db:.4f}')
        if self.functional_eq is not None:
            fields.append(f'functional_eq={self.functional_eq}')
        if self.timing_errors is not None:
            fields.append(f'timing_errors={self.timing_errors}')
        return f'Metrics({", ".join(fields)})'


def compute_metrics(result: 'SimulationResult', probe: str | None = None) -> Metrics:
    if result.kind == 'ac':
        return _ac_metrics(result, probe)
    elif result.kind in ('functional', 'rtl'):
        return _digital_metrics(result)
    return Metrics()


def _ac_metrics(result: 'SimulationResult', probe: str | None) -> Metrics:
    if probe and f'{probe}_magnitude_db' in result.y:
        mag_db = result.y[f'{probe}_magnitude_db']
    elif probe and probe in result.y:
        mag_db = 20 * np.log10(np.abs(result.y[probe]) + 1e-300)
    elif 'magnitude_db' in result.y:
        mag_db = result.y['magnitude_db']
    else:
        return Metrics()

    freqs = result.x
    f3db = _find_f3db(freqs, mag_db)
    return Metrics(f3db=f3db)


def _find_f3db(freqs: np.ndarray, mag_db: np.ndarray) -> float | None:
    if len(mag_db) == 0:
        return None
    dc_gain = mag_db[0]
    target = dc_gain - 3.0
    crossings = np.where(np.diff(np.sign(mag_db - target)))[0]
    if len(crossings) == 0:
        return None
    idx = crossings[0]
    # Linear interpolation
    if idx + 1 >= len(freqs):
        return float(freqs[idx])
    f0, f1 = freqs[idx], freqs[idx + 1]
    m0, m1 = mag_db[idx], mag_db[idx + 1]
    if m1 == m0:
        return float(f0)
    t = (target - m0) / (m1 - m0)
    return float(f0 + t * (f1 - f0))


def _digital_metrics(result: 'SimulationResult') -> Metrics:
    return Metrics()


def compare_results(r1: 'SimulationResult', r2: 'SimulationResult') -> dict:
    """Compute comparison metrics between two SimulationResults."""
    metrics = {}

    if r1.kind == 'ac' and r2.kind == 'ac':
        metrics.update(_compare_ac(r1, r2))
    elif r1.kind in ('functional', 'rtl') and r2.kind in ('functional', 'rtl'):
        metrics.update(_compare_digital(r1, r2))

    return metrics


def _compare_ac(r1: 'SimulationResult', r2: 'SimulationResult') -> dict:
    # Interpolate r2 onto r1 frequency axis
    mag1 = r1.y.get('magnitude_db')
    mag2 = r2.y.get('magnitude_db')
    if mag1 is None or mag2 is None:
        return {}

    mag2_interp = np.interp(r1.x, r2.x, mag2)
    error_db = mag1 - mag2_interp

    m1 = compute_metrics(r1)
    m2 = compute_metrics(r2)

    return {
        'max_error_db': float(np.max(np.abs(error_db))),
        'mean_error_db': float(np.mean(np.abs(error_db))),
        'f3db_r1': m1.f3db,
        'f3db_r2': m2.f3db,
        'error_db': error_db,
        'freqs': r1.x,
    }


def _compare_digital(r1: 'SimulationResult', r2: 'SimulationResult') -> dict:
    mismatches = 0
    total = 0
    for key in r1.y:
        if key in r2.y:
            v1 = r1.y[key]
            v2 = r2.y[key]
            n = min(len(v1), len(v2))
            total += n
            mismatches += int(np.sum(v1[:n] != v2[:n]))

    return {
        'mismatches': mismatches,
        'total': total,
        'functional_eq': mismatches == 0,
    }
