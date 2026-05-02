from __future__ import annotations
import numpy as np
from typing import TYPE_CHECKING

from ccreator.core.simulation_result import SimulationResult, ComparisonResult

if TYPE_CHECKING:
    pass


def compare(r1: SimulationResult, r2: SimulationResult) -> ComparisonResult:
    from ccreator.compare.metrics import compare_results
    m = compare_results(r1, r2)
    return ComparisonResult(r1=r1, r2=r2, _metrics=m)


def _plot_single(result: SimulationResult, **kwargs):
    import matplotlib.pyplot as plt

    if result.kind == 'ac':
        fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(10, 6))
        name = type(result.circuit).__name__

        mag_db = result.y.get('magnitude_db')
        phase_deg = result.y.get('phase_deg')

        if mag_db is not None:
            ax1.semilogx(result.x, mag_db)
            ax1.set_xlabel('Frequency (Hz)')
            ax1.set_ylabel('Magnitude (dB)')
            ax1.set_title(f'{name} — AC Response')
            ax1.grid(True)

        if phase_deg is not None:
            ax2.semilogx(result.x, phase_deg)
            ax2.set_xlabel('Frequency (Hz)')
            ax2.set_ylabel('Phase (deg)')
            ax2.grid(True)

        plt.tight_layout()
        plt.show()

    elif result.kind == 'tran':
        fig, ax = plt.subplots(figsize=(10, 4))
        name = type(result.circuit).__name__
        for key, y in result.y.items():
            ax.plot(result.x * 1e3, y, label=key)
        ax.set_xlabel('Time (ms)')
        ax.set_ylabel('Amplitude')
        ax.set_title(f'{name} — Transient Response')
        ax.legend()
        ax.grid(True)
        plt.tight_layout()
        plt.show()


def _report_single(result: SimulationResult):
    name = type(result.circuit).__name__ if hasattr(result.circuit, '__class__') else str(result.circuit)
    print(f'\n=== {name} ({result.kind.upper()}) ===')
    m = result.metrics()
    print(m)
    if result.kind == 'ac':
        mag_db = result.y.get('magnitude_db')
        if mag_db is not None:
            print(f'  DC gain:     {mag_db[0]:.2f} dB')
            print(f'  Min gain:    {mag_db.min():.2f} dB')
            print(f'  Frequencies: {result.x[0]:.1f} — {result.x[-1]:.1f} Hz')
    print()


def _plot_comparison(comp: ComparisonResult, **kwargs):
    import matplotlib.pyplot as plt

    r1, r2 = comp.r1, comp.r2

    if r1.kind == 'ac' and r2.kind == 'ac':
        name1 = type(r1.circuit).__name__
        name2 = type(r2.circuit).__name__

        fig, axes = plt.subplots(3, 1, figsize=(10, 9))

        mag1 = r1.y.get('magnitude_db')
        mag2 = r2.y.get('magnitude_db')
        phase1 = r1.y.get('phase_deg')
        phase2 = r2.y.get('phase_deg')

        if mag1 is not None:
            axes[0].semilogx(r1.x, mag1, label=name1)
        if mag2 is not None:
            axes[0].semilogx(r2.x, mag2, label=name2, linestyle='--')
        axes[0].set_ylabel('Magnitude (dB)')
        axes[0].legend()
        axes[0].grid(True)
        axes[0].set_title('AC Response Comparison')

        if phase1 is not None:
            axes[1].semilogx(r1.x, phase1, label=name1)
        if phase2 is not None:
            axes[1].semilogx(r2.x, phase2, label=name2, linestyle='--')
        axes[1].set_ylabel('Phase (deg)')
        axes[1].legend()
        axes[1].grid(True)

        error = comp._metrics.get('error_db')
        freqs = comp._metrics.get('freqs')
        if error is not None and freqs is not None:
            axes[2].semilogx(freqs, error)
            axes[2].set_xlabel('Frequency (Hz)')
            axes[2].set_ylabel('Error (dB)')
            axes[2].set_title('Magnitude Error')
            axes[2].grid(True)

        plt.tight_layout()
        plt.show()


def _report_comparison(comp: ComparisonResult):
    name1 = type(comp.r1.circuit).__name__
    name2 = type(comp.r2.circuit).__name__
    print(f'\n=== Comparison: {name1} vs {name2} ===')
    m = comp._metrics
    if 'max_error_db' in m:
        print(f'  max_error_dB:  {m["max_error_db"]:.4f} dB')
        print(f'  mean_error_dB: {m["mean_error_db"]:.4f} dB')
    if 'f3db_r1' in m:
        print(f'  f3dB ({name1}): {m["f3db_r1"]:.2f} Hz' if m['f3db_r1'] else f'  f3dB ({name1}): N/A')
    if 'f3db_r2' in m:
        print(f'  f3dB ({name2}): {m["f3db_r2"]:.2f} Hz' if m['f3db_r2'] else f'  f3dB ({name2}): N/A')
    if 'functional_eq' in m:
        print(f'  functional_eq: {m["functional_eq"]}')
        print(f'  mismatches:    {m["mismatches"]} / {m["total"]}')
    print()
