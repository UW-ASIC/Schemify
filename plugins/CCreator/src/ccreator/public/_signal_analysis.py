"""Reusable DSP / signal analysis utilities for testbench metric extraction."""
from __future__ import annotations

import numpy as np


# ---------------------------------------------------------------------------
# FFT-based spectral analysis
# ---------------------------------------------------------------------------

def compute_fft(t: np.ndarray, y: np.ndarray,
                window: str = 'hann') -> tuple[np.ndarray, np.ndarray]:
    """Return (freqs_hz, magnitude_dbfs) from a time-domain waveform.

    Uses one-sided FFT. Window choices: 'hann', 'blackmanharris', 'rect'.
    """
    N = len(y)
    dt = np.mean(np.diff(t))
    fs = 1.0 / dt

    if window == 'hann':
        w = np.hanning(N)
    elif window == 'blackmanharris':
        w = np.blackman(N)
    else:
        w = np.ones(N)

    coherent_gain = np.sum(w) / N
    yw = y * w
    Y = np.fft.rfft(yw)
    mag = np.abs(Y) * 2.0 / (N * coherent_gain)
    mag[0] /= 2.0  # DC bin no doubling
    mag_dbfs = 20.0 * np.log10(mag + 1e-300)
    freqs = np.fft.rfftfreq(N, d=dt)
    return freqs, mag_dbfs


def find_fundamental(freqs: np.ndarray, mag_dbfs: np.ndarray,
                     fmin: float = 0.0) -> tuple[float, float]:
    """Find fundamental frequency and its power. Skip DC bin."""
    mask = freqs > fmin if fmin > 0 else np.arange(len(freqs)) > 0
    idx = np.argmax(mag_dbfs[mask])
    actual_idx = np.where(mask)[0][idx]
    return float(freqs[actual_idx]), float(mag_dbfs[actual_idx])


def find_harmonics(freqs: np.ndarray, mag_dbfs: np.ndarray,
                   f0: float, n_harmonics: int = 10,
                   bin_width: int = 3) -> list[tuple[float, float]]:
    """Return list of (freq, power_dbfs) for harmonics 2..n_harmonics of f0."""
    harmonics = []
    for n in range(2, n_harmonics + 2):
        target = n * f0
        if target >= freqs[-1]:
            break
        idx = np.argmin(np.abs(freqs - target))
        lo = max(0, idx - bin_width)
        hi = min(len(mag_dbfs), idx + bin_width + 1)
        peak_idx = lo + np.argmax(mag_dbfs[lo:hi])
        harmonics.append((float(freqs[peak_idx]), float(mag_dbfs[peak_idx])))
    return harmonics


def compute_thd(freqs: np.ndarray, mag_dbfs: np.ndarray,
                f0: float, n_harmonics: int = 10) -> float:
    """Total Harmonic Distortion in dB (ratio of harmonic power to fundamental)."""
    _, fund_db = find_fundamental(freqs, mag_dbfs)
    fund_lin = 10 ** (fund_db / 20.0)
    harms = find_harmonics(freqs, mag_dbfs, f0, n_harmonics)
    if not harms:
        return -np.inf
    harm_power = sum(10 ** (h_db / 10.0) for _, h_db in harms)
    fund_power = 10 ** (fund_db / 10.0)
    if fund_power == 0:
        return 0.0
    return float(10.0 * np.log10(harm_power / fund_power))


def compute_sfdr(freqs: np.ndarray, mag_dbfs: np.ndarray,
                 f0: float, n_harmonics: int = 20) -> float:
    """Spurious-Free Dynamic Range in dBc (fundamental minus largest spur)."""
    _, fund_db = find_fundamental(freqs, mag_dbfs)
    harms = find_harmonics(freqs, mag_dbfs, f0, n_harmonics)
    if not harms:
        return float('inf')
    worst_spur_db = max(h_db for _, h_db in harms)
    return float(fund_db - worst_spur_db)


def compute_snr(freqs: np.ndarray, mag_dbfs: np.ndarray,
                f0: float, n_harmonics: int = 10,
                fs: float | None = None, exclude_dc: bool = True) -> float:
    """Signal-to-Noise Ratio in dB. Noise = total power minus signal and harmonics."""
    mag_lin = 10 ** (mag_dbfs / 20.0)
    total_power = np.sum(mag_lin ** 2)

    # Signal power (fundamental bin +/- 1)
    fund_idx = np.argmin(np.abs(freqs - f0))
    signal_indices = set(range(max(0, fund_idx - 1), min(len(freqs), fund_idx + 2)))

    # Harmonic power
    harm_indices = set()
    for n in range(2, n_harmonics + 2):
        target = n * f0
        if target >= freqs[-1]:
            break
        idx = np.argmin(np.abs(freqs - target))
        harm_indices.update(range(max(0, idx - 1), min(len(freqs), idx + 2)))

    exclude = signal_indices | harm_indices
    if exclude_dc:
        exclude.add(0)

    noise_power = sum(mag_lin[i] ** 2 for i in range(len(mag_lin)) if i not in exclude)
    signal_power = sum(mag_lin[i] ** 2 for i in signal_indices)

    if noise_power == 0:
        return float('inf')
    return float(10.0 * np.log10(signal_power / noise_power))


def compute_sndr(freqs: np.ndarray, mag_dbfs: np.ndarray,
                 f0: float, fs: float | None = None) -> float:
    """Signal-to-Noise-and-Distortion Ratio in dB."""
    mag_lin = 10 ** (mag_dbfs / 20.0)
    fund_idx = np.argmin(np.abs(freqs - f0))
    signal_indices = set(range(max(0, fund_idx - 1), min(len(freqs), fund_idx + 2)))
    signal_power = sum(mag_lin[i] ** 2 for i in signal_indices)
    total_power = np.sum(mag_lin[1:] ** 2)  # exclude DC
    nad_power = total_power - signal_power
    if nad_power <= 0:
        return float('inf')
    return float(10.0 * np.log10(signal_power / nad_power))


def compute_enob(sndr_db: float) -> float:
    """Effective Number of Bits from SNDR: ENOB = (SNDR - 1.76) / 6.02."""
    return (sndr_db - 1.76) / 6.02


# ---------------------------------------------------------------------------
# Zero-crossing / timing analysis
# ---------------------------------------------------------------------------

def find_zero_crossings(t: np.ndarray, y: np.ndarray,
                        threshold: float = 0.0,
                        edge: str = 'rising') -> np.ndarray:
    """Return interpolated times where y crosses threshold.

    edge: 'rising', 'falling', or 'both'.
    """
    shifted = y - threshold
    sign_changes = np.diff(np.sign(shifted))
    times = []
    for i in np.where(sign_changes != 0)[0]:
        if edge == 'rising' and sign_changes[i] <= 0:
            continue
        if edge == 'falling' and sign_changes[i] >= 0:
            continue
        # Linear interpolation
        y0, y1 = shifted[i], shifted[i + 1]
        if y1 == y0:
            times.append(t[i])
        else:
            frac = -y0 / (y1 - y0)
            times.append(t[i] + frac * (t[i + 1] - t[i]))
    return np.array(times)


def measure_frequency(t: np.ndarray, y: np.ndarray,
                      threshold: float | None = None) -> float:
    """Measure frequency from zero crossings. Auto-threshold at midpoint."""
    if threshold is None:
        threshold = (np.max(y) + np.min(y)) / 2.0
    crossings = find_zero_crossings(t, y, threshold, edge='rising')
    if len(crossings) < 2:
        return 0.0
    periods = np.diff(crossings)
    return float(1.0 / np.mean(periods))


def measure_periods(t: np.ndarray, y: np.ndarray,
                    threshold: float | None = None) -> np.ndarray:
    """Return array of individual period durations from rising edge crossings."""
    if threshold is None:
        threshold = (np.max(y) + np.min(y)) / 2.0
    crossings = find_zero_crossings(t, y, threshold, edge='rising')
    if len(crossings) < 2:
        return np.array([])
    return np.diff(crossings)


def measure_period_jitter(periods: np.ndarray) -> dict:
    """Compute period jitter metrics from array of period durations.

    Returns dict with keys: rms, peak_to_peak, cycle_to_cycle_rms.
    """
    if len(periods) < 2:
        return {'rms': 0.0, 'peak_to_peak': 0.0, 'cycle_to_cycle_rms': 0.0}
    mean_period = np.mean(periods)
    jitter = periods - mean_period
    c2c = np.diff(periods)
    return {
        'rms': float(np.std(periods)),
        'peak_to_peak': float(np.max(periods) - np.min(periods)),
        'cycle_to_cycle_rms': float(np.std(c2c)) if len(c2c) > 0 else 0.0,
    }


def measure_duty_cycle(t: np.ndarray, y: np.ndarray,
                       threshold: float | None = None) -> float:
    """Measure duty cycle (0-1) of a periodic signal."""
    if threshold is None:
        threshold = (np.max(y) + np.min(y)) / 2.0
    rising = find_zero_crossings(t, y, threshold, edge='rising')
    falling = find_zero_crossings(t, y, threshold, edge='falling')
    if len(rising) < 1 or len(falling) < 1:
        return 0.5
    # Pair each rising edge with next falling edge
    high_times = []
    periods_local = []
    ri, fi = 0, 0
    while ri < len(rising) and fi < len(falling):
        r = rising[ri]
        # Find next falling after this rising
        while fi < len(falling) and falling[fi] <= r:
            fi += 1
        if fi >= len(falling):
            break
        high_time = falling[fi] - r
        # Find next rising for period
        if ri + 1 < len(rising):
            period = rising[ri + 1] - r
            high_times.append(high_time)
            periods_local.append(period)
        ri += 1
    if not periods_local:
        return 0.5
    return float(np.mean(np.array(high_times) / np.array(periods_local)))


# ---------------------------------------------------------------------------
# Settling / step response analysis
# ---------------------------------------------------------------------------

def measure_settling_time(t: np.ndarray, y: np.ndarray,
                          final_value: float | None = None,
                          tolerance: float = 0.01) -> float:
    """Time for y to settle within tolerance band around final_value."""
    if final_value is None:
        final_value = y[-1]
    band = np.abs(tolerance * final_value) if final_value != 0 else tolerance
    within = np.abs(y - final_value) <= band
    # Find last time signal exits the band
    if np.all(within):
        return 0.0
    exits = np.where(~within)[0]
    if len(exits) == 0:
        return 0.0
    last_exit = exits[-1]
    if last_exit + 1 >= len(t):
        return float(t[-1] - t[0])
    return float(t[last_exit + 1] - t[0])


def measure_slew_rate(t: np.ndarray, y: np.ndarray) -> float:
    """Maximum absolute dy/dt in V/s."""
    dy = np.diff(y)
    dt = np.diff(t)
    rates = np.abs(dy / dt)
    return float(np.max(rates))


def measure_overshoot(t: np.ndarray, y: np.ndarray,
                      final_value: float | None = None) -> float:
    """Overshoot as fraction of step size. Returns 0 if no overshoot."""
    if final_value is None:
        final_value = y[-1]
    initial = y[0]
    step = final_value - initial
    if step == 0:
        return 0.0
    if step > 0:
        peak = np.max(y)
        return max(0.0, float((peak - final_value) / step))
    else:
        trough = np.min(y)
        return max(0.0, float((final_value - trough) / abs(step)))


def measure_rise_time(t: np.ndarray, y: np.ndarray,
                      lo_frac: float = 0.1, hi_frac: float = 0.9) -> float:
    """10%-90% rise time (or custom fractions)."""
    ymin, ymax = np.min(y), np.max(y)
    span = ymax - ymin
    if span == 0:
        return 0.0
    lo_val = ymin + lo_frac * span
    hi_val = ymin + hi_frac * span
    lo_crossings = find_zero_crossings(t, y, lo_val, edge='rising')
    hi_crossings = find_zero_crossings(t, y, hi_val, edge='rising')
    if len(lo_crossings) == 0 or len(hi_crossings) == 0:
        return 0.0
    return float(hi_crossings[0] - lo_crossings[0])


def measure_fall_time(t: np.ndarray, y: np.ndarray,
                      lo_frac: float = 0.1, hi_frac: float = 0.9) -> float:
    """90%-10% fall time (or custom fractions)."""
    ymin, ymax = np.min(y), np.max(y)
    span = ymax - ymin
    if span == 0:
        return 0.0
    lo_val = ymin + lo_frac * span
    hi_val = ymin + hi_frac * span
    hi_crossings = find_zero_crossings(t, y, hi_val, edge='falling')
    lo_crossings = find_zero_crossings(t, y, lo_val, edge='falling')
    if len(hi_crossings) == 0 or len(lo_crossings) == 0:
        return 0.0
    return float(lo_crossings[0] - hi_crossings[0])


# ---------------------------------------------------------------------------
# DC transfer curve / linearity (ADC / DAC)
# ---------------------------------------------------------------------------

def compute_dnl(code_widths: np.ndarray) -> np.ndarray:
    """Differential Nonlinearity in LSB from array of code bin widths.

    code_widths[i] = width of code bin i in input units.
    Ideal width = mean(code_widths).
    DNL[i] = (code_widths[i] / ideal_width) - 1
    """
    ideal = np.mean(code_widths)
    if ideal == 0:
        return np.zeros_like(code_widths)
    return code_widths / ideal - 1.0


def compute_inl(dnl: np.ndarray) -> np.ndarray:
    """Integral Nonlinearity in LSB (cumulative sum of DNL)."""
    return np.cumsum(dnl)


def measure_offset_error(v_in: np.ndarray, codes: np.ndarray,
                         expected_first_transition: float) -> float:
    """Offset error in LSB. Difference between actual and ideal first code transition."""
    transitions = np.where(np.diff(codes) != 0)[0]
    if len(transitions) == 0:
        return 0.0
    actual_first = v_in[transitions[0]]
    ideal_step = (v_in[-1] - v_in[0]) / (np.max(codes) - np.min(codes))
    if ideal_step == 0:
        return 0.0
    return float((actual_first - expected_first_transition) / ideal_step)


def measure_gain_error(v_in: np.ndarray, codes: np.ndarray,
                       ideal_gain: float) -> float:
    """Gain error as fraction of ideal gain. Uses best-fit slope."""
    if len(v_in) < 2:
        return 0.0
    coeffs = np.polyfit(v_in, codes.astype(float), 1)
    actual_gain = coeffs[0]
    if ideal_gain == 0:
        return 0.0
    return float((actual_gain - ideal_gain) / ideal_gain)


def check_monotonicity(codes: np.ndarray) -> bool:
    """True if output codes never decrease as input increases."""
    return bool(np.all(np.diff(codes.astype(float)) >= 0))


def extract_code_widths(v_in: np.ndarray, codes: np.ndarray) -> np.ndarray:
    """From a ramp input and digitized codes, compute code bin widths."""
    unique_codes = np.unique(codes)
    widths = []
    for code in unique_codes:
        mask = codes == code
        if np.any(mask):
            v_vals = v_in[mask]
            widths.append(v_vals[-1] - v_vals[0])
    return np.array(widths)


# ---------------------------------------------------------------------------
# AC response helpers
# ---------------------------------------------------------------------------

def find_f3db(freqs: np.ndarray, mag_db: np.ndarray) -> float | None:
    """Find -3dB frequency from DC gain."""
    if len(mag_db) == 0:
        return None
    dc_gain = mag_db[0]
    target = dc_gain - 3.0
    crossings = np.where(np.diff(np.sign(mag_db - target)))[0]
    if len(crossings) == 0:
        return None
    idx = crossings[0]
    if idx + 1 >= len(freqs):
        return float(freqs[idx])
    f0, f1 = freqs[idx], freqs[idx + 1]
    m0, m1 = mag_db[idx], mag_db[idx + 1]
    if m1 == m0:
        return float(f0)
    frac = (target - m0) / (m1 - m0)
    return float(f0 + frac * (f1 - f0))


def find_peak_response(freqs: np.ndarray, mag_db: np.ndarray) -> tuple[float, float]:
    """Find frequency and gain of peak in magnitude response."""
    idx = np.argmax(mag_db)
    return float(freqs[idx]), float(mag_db[idx])


def measure_quality_factor(freqs: np.ndarray, mag_db: np.ndarray) -> float | None:
    """Q factor from bandpass response: Q = f_center / bandwidth_3dB."""
    f_peak, peak_db = find_peak_response(freqs, mag_db)
    target = peak_db - 3.0
    crossings = np.where(np.diff(np.sign(mag_db - target)))[0]
    if len(crossings) < 2:
        return None
    # Interpolate both crossing points
    edges = []
    for c in [crossings[0], crossings[-1]]:
        if c + 1 >= len(freqs):
            edges.append(freqs[c])
        else:
            f0, f1 = freqs[c], freqs[c + 1]
            m0, m1 = mag_db[c], mag_db[c + 1]
            if m1 == m0:
                edges.append(f0)
            else:
                frac = (target - m0) / (m1 - m0)
                edges.append(f0 + frac * (f1 - f0))
    if len(edges) < 2 or edges[1] == edges[0]:
        return None
    bw = edges[1] - edges[0]
    return float(f_peak / bw)


def measure_phase_margin(freqs: np.ndarray, mag_db: np.ndarray,
                         phase_deg: np.ndarray) -> float | None:
    """Phase margin: phase at 0dB gain crossover + 180 degrees."""
    crossings = np.where(np.diff(np.sign(mag_db)))[0]
    if len(crossings) == 0:
        return None
    idx = crossings[0]
    if idx + 1 >= len(phase_deg):
        phase_at_ugf = phase_deg[idx]
    else:
        m0, m1 = mag_db[idx], mag_db[idx + 1]
        if m1 == m0:
            frac = 0.0
        else:
            frac = -m0 / (m1 - m0)
        phase_at_ugf = phase_deg[idx] + frac * (phase_deg[idx + 1] - phase_deg[idx])
    return float(phase_at_ugf + 180.0)


def measure_gain_margin(freqs: np.ndarray, mag_db: np.ndarray,
                        phase_deg: np.ndarray) -> float | None:
    """Gain margin: negative of gain at -180 degree phase crossing."""
    target = -180.0
    crossings = np.where(np.diff(np.sign(phase_deg - target)))[0]
    if len(crossings) == 0:
        return None
    idx = crossings[0]
    if idx + 1 >= len(mag_db):
        return float(-mag_db[idx])
    p0, p1 = phase_deg[idx], phase_deg[idx + 1]
    if p1 == p0:
        frac = 0.0
    else:
        frac = (target - p0) / (p1 - p0)
    gain_at_crossing = mag_db[idx] + frac * (mag_db[idx + 1] - mag_db[idx])
    return float(-gain_at_crossing)


def measure_psrr_at_freq(freqs: np.ndarray, mag_db: np.ndarray,
                         target_freq: float) -> float:
    """PSRR in dB at a specific frequency (assumes mag_db is supply-to-output TF)."""
    idx = np.argmin(np.abs(freqs - target_freq))
    return float(-mag_db[idx])


def measure_ugf(freqs: np.ndarray, mag_db: np.ndarray) -> float | None:
    """Unity gain frequency (0dB crossing)."""
    crossings = np.where(np.diff(np.sign(mag_db)))[0]
    if len(crossings) == 0:
        return None
    idx = crossings[0]
    if idx + 1 >= len(freqs):
        return float(freqs[idx])
    m0, m1 = mag_db[idx], mag_db[idx + 1]
    if m1 == m0:
        return float(freqs[idx])
    frac = -m0 / (m1 - m0)
    return float(freqs[idx] + frac * (freqs[idx + 1] - freqs[idx]))


# ---------------------------------------------------------------------------
# Switch / resistance measurement
# ---------------------------------------------------------------------------

def measure_ron(v_signal: np.ndarray, i_signal: np.ndarray) -> float:
    """On-resistance from V/I data (linear fit slope)."""
    if len(v_signal) < 2:
        return 0.0
    mask = np.abs(i_signal) > 1e-15  # avoid divide by zero
    if not np.any(mask):
        return float('inf')
    coeffs = np.polyfit(i_signal[mask], v_signal[mask], 1)
    return float(abs(coeffs[0]))


def measure_ron_flatness(v_signal: np.ndarray, i_signal: np.ndarray) -> dict:
    """Ron variation across signal range. Returns min, max, mean, spread_pct."""
    mask = np.abs(i_signal) > 1e-15
    if not np.any(mask):
        return {'min': 0, 'max': 0, 'mean': 0, 'spread_pct': 0}
    ron_local = np.abs(v_signal[mask] / i_signal[mask])
    return {
        'min': float(np.min(ron_local)),
        'max': float(np.max(ron_local)),
        'mean': float(np.mean(ron_local)),
        'spread_pct': float((np.max(ron_local) - np.min(ron_local)) /
                            np.mean(ron_local) * 100) if np.mean(ron_local) > 0 else 0,
    }


def measure_charge_injection(t: np.ndarray, v_out: np.ndarray,
                             t_switch: float, c_load: float) -> float:
    """Charge injection in Coulombs from output voltage glitch at switch event.

    Q_inj = C_load * delta_V
    """
    idx = np.argmin(np.abs(t - t_switch))
    # Look for peak deviation in a window after switch event
    window = min(len(v_out) - 1, idx + max(10, len(v_out) // 50))
    v_before = v_out[max(0, idx - 1)]
    v_window = v_out[idx:window + 1]
    delta_v = np.max(np.abs(v_window - v_before))
    return float(c_load * delta_v)


def measure_off_isolation(freqs: np.ndarray, mag_db: np.ndarray,
                          target_freq: float | None = None) -> float:
    """Off-state isolation in dB (negative of input-to-output transfer function).

    If target_freq given, returns isolation at that freq. Else returns worst-case.
    """
    if target_freq is not None:
        idx = np.argmin(np.abs(freqs - target_freq))
        return float(-mag_db[idx])
    return float(-np.max(mag_db))


# ---------------------------------------------------------------------------
# Glitch / transient quality
# ---------------------------------------------------------------------------

def measure_glitch_energy(t: np.ndarray, v_out: np.ndarray,
                          t_event: float, r_load: float = 50.0,
                          window_s: float | None = None) -> float:
    """Glitch energy in Volt-seconds (area of glitch pulse).

    Looks in a window after t_event for deviation from settled value.
    """
    idx_start = np.argmin(np.abs(t - t_event))
    if window_s is None:
        window_s = (t[-1] - t[0]) * 0.01  # 1% of total time
    idx_end = np.argmin(np.abs(t - (t_event + window_s)))
    idx_end = max(idx_end, idx_start + 2)

    v_settled = v_out[min(idx_end, len(v_out) - 1)]
    segment = v_out[idx_start:idx_end]
    t_seg = t[idx_start:idx_end]
    if len(t_seg) < 2:
        return 0.0
    deviation = np.abs(segment - v_settled)
    return float(np.trapezoid(deviation, t_seg))


# ---------------------------------------------------------------------------
# Phase noise estimation (from transient data)
# ---------------------------------------------------------------------------

def estimate_phase_noise(t: np.ndarray, y: np.ndarray,
                         offsets_hz: list[float] | None = None) -> dict:
    """Estimate phase noise from transient waveform at given offset frequencies.

    Returns dict mapping offset_hz -> phase_noise_dBc_Hz.
    Uses FFT of instantaneous phase.
    """
    if offsets_hz is None:
        offsets_hz = [1e3, 10e3, 100e3, 1e6]

    threshold = (np.max(y) + np.min(y)) / 2.0
    crossings = find_zero_crossings(t, y, threshold, edge='rising')
    if len(crossings) < 4:
        return {f: None for f in offsets_hz}

    # Instantaneous frequency from period measurements
    periods = np.diff(crossings)
    f_inst = 1.0 / periods
    f_mean = np.mean(f_inst)

    # Phase deviation: phi(t) = 2*pi * integral(f_inst - f_mean)
    dt_periods = np.diff(crossings[:-1]) if len(crossings) > 2 else periods
    # Uniformly resample for FFT
    t_mid = (crossings[:-1] + crossings[1:]) / 2.0
    if len(t_mid) < 4:
        return {f: None for f in offsets_hz}

    phase_dev = 2.0 * np.pi * np.cumsum((f_inst - f_mean) * periods)

    # FFT of phase deviation
    N = len(phase_dev)
    fs_phase = 1.0 / np.mean(np.diff(t_mid))
    freqs_phase = np.fft.rfftfreq(N, d=1.0 / fs_phase)
    Y = np.fft.rfft(phase_dev * np.hanning(N))
    # Single-sideband phase noise spectral density
    Sphi = 2.0 * np.abs(Y) ** 2 / (N * fs_phase)

    result = {}
    for offset in offsets_hz:
        idx = np.argmin(np.abs(freqs_phase - offset))
        if idx < len(Sphi) and Sphi[idx] > 0:
            result[offset] = float(10.0 * np.log10(Sphi[idx] + 1e-300))
        else:
            result[offset] = None
    return result
