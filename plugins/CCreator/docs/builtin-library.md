# Built-in Circuit Library

CCreator ships with a library of pre-built behavioral and realistic circuits with matching testbenches. These serve as starting points for common analog building blocks and as references for the framework's APIs.

All are importable from `ccreator.public`:

```python
from ccreator.public import IdealADC, ADCDynamicTestbench, ResistiveADCFrontend
```

## ADC (Analog-to-Digital Converter)

### Circuits

| Class | Type | Description |
|-------|------|-------------|
| `IdealADC` | Behavioral | Nyquist-limited ADC. Parameters: `N` (bits), `fs` (sample rate), `Vref`. Gain = (2^N - 1) / Vref, bandwidth = pi * fs. |
| `ResistiveADCFrontend` | Realistic | Resistive attenuator frontend. Parameters: `R_in`, `R_fb`. Gain = R_fb / (R_in + R_fb). |
| `RCADCFrontend` | Realistic | RC anti-alias filter frontend. Parameters: `R`, `C`. f3dB = 1 / (2*pi*R*C). |

### Testbenches

| Class | Analysis | Measures |
|-------|----------|----------|
| `ADCStaticTestbench` | DC ramp | DNL, INL, offset error, gain error, monotonicity |
| `ADCDynamicTestbench` | Transient (single tone) | SNDR, SFDR, ENOB, THD, SNR via FFT |
| `ADCBandwidthTestbench` | AC sweep | f3dB, passband ripple, rolloff rate |

```python
from ccreator.public import IdealADC, ADCDynamicTestbench

adc = IdealADC(N=10, fs=100e6, Vref=1.0)
tb = ADCDynamicTestbench()
result = tb.run()
m = result.metrics()
print(f"ENOB: {m.extra.get('enob', 'N/A')}")
```

## DAC (Digital-to-Analog Converter)

### Circuits

| Class | Type | Description |
|-------|------|-------------|
| `IdealDAC` | Behavioral | Reconstruction-filtered DAC. Parameters: `N`, `fs`, `Vref`. |
| `RCReconstructionFilter` | Realistic | First-order RC reconstruction. Parameters: `R`, `C`. |
| `SecondOrderReconstructionFilter` | Realistic | Cascaded two-stage RC filter. Parameters: `R1`, `C1`, `R2`, `C2`. |

### Testbenches

| Class | Analysis | Measures |
|-------|----------|----------|
| `DACStaticTestbench` | DC code ramp | DNL, INL |
| `DACDynamicTestbench` | Transient (single tone) | SFDR, THD, SNR, slew rate, settling time |
| `DACFilterTestbench` | AC sweep | f3dB, passband ripple |

## PLL (Phase-Locked Loop)

### Circuits

| Class | Type | Description |
|-------|------|-------------|
| `IdealPLL` | Behavioral | Type-II closed-loop PLL. Parameters: `f_ref`, `N` (divider), `zeta` (damping), `wn` (natural freq). H(s) = N*(2*zeta*wn*s + wn^2) / (s^2 + 2*zeta*wn*s + wn^2). |
| `CPPLLLoopFilter` | Realistic | Second-order charge-pump loop filter. Parameters: `Icp`, `C1`, `R2`, `C2`. |
| `ThirdOrderLoopFilter` | Realistic | Third-order with extra RC pole. Parameters: `Icp`, `C1`, `R2`, `C2`, `R3`, `C3`. |

### Testbenches

| Class | Analysis | Measures |
|-------|----------|----------|
| `PLLLoopFilterTestbench` | AC | Open-loop bandwidth, phase margin, gain margin |
| `PLLLockTestbench` | Transient (step) | Lock time, settling time, overshoot |
| `PLLJitterTestbench` | Transient (1000+ cycles) | Period jitter RMS and peak-to-peak, cycle-to-cycle |
| `PLLPhaseNoiseTestbench` | Transient (2000+ cycles) | Phase noise at offset frequencies |

## Bandgap Reference

### Circuits

| Class | Type | Description |
|-------|------|-------------|
| `IdealBandgap` | Behavioral | PSRR-modeled reference. Parameters: `Vref`, `psrr_f3db`. H(s) = Vref * wc / (s + wc). |
| `ResistiveDividerRef` | Realistic | R1/R2 voltage divider. |
| `FilteredDividerRef` | Realistic | Divider with bypass capacitor. |

### Testbenches

| Class | Analysis | Measures |
|-------|----------|----------|
| `BandgapPSRRTestbench` | AC | PSRR at 1k, 10k, 100k, 1M Hz |
| `BandgapLineRegTestbench` | DC (Vdd sweep) | Line regulation (mV/V), dropout voltage |
| `BandgapLoadRegTestbench` | DC (load sweep) | Load regulation, output impedance |
| `BandgapTransientTestbench` | Transient (supply ramp) | Startup settling time, overshoot |
| `BandgapNoiseTestbench` | AC | Noise gain at various frequencies |

## Oscillator

### Circuits

| Class | Type | Description |
|-------|------|-------------|
| `IdealResonator` | Behavioral | Bandpass resonator. Parameters: `f0`, `Q`. H(s) = (s*w0/Q) / (s^2 + s*w0/Q + w0^2). |
| `LCTank` | Realistic | Series RLC resonator. Parameters: `R`, `L`, `C`. |
| `RCOscillatorStage` | Realistic | Single RC phase-shift stage. |
| `ParallelLCTank` | Realistic | Parallel LC tank (anti-resonance). |

### Testbenches

| Class | Analysis | Measures |
|-------|----------|----------|
| `OscillatorACTestbench` | AC | Resonant frequency, peak gain, Q factor, f3dB |
| `OscillatorFreqTestbench` | Transient | Frequency, amplitude, duty cycle |
| `OscillatorJitterTestbench` | Transient (1000+ cycles) | Period jitter RMS and peak-to-peak |
| `OscillatorPhaseNoiseTestbench` | Transient (2000+ cycles) | Phase noise at offset frequencies |
| `OscillatorStartupTestbench` | Transient | Startup time to 90%, envelope rise time |
| `OscillatorTHDTestbench` | Transient + FFT | THD, individual harmonic magnitudes |

## Analog Switch

### Circuits

| Class | Type | Description |
|-------|------|-------------|
| `IdealSwitch` | Behavioral | Frequency-limited switch. Parameters: `Ron`, `Cload`. Bandwidth = 1/(2*pi*Ron*Cload). |
| `ResistiveSwitch` | Realistic | On-state: Ron with parasitic caps. |
| `ResistiveSwitchOff` | Realistic | Off-state: high Ron + coupling cap. |
| `TransmissionGate` | Realistic | CMOS T-gate: parallel NMOS + PMOS paths. |

### Testbenches

| Class | Analysis | Measures |
|-------|----------|----------|
| `SwitchRonTestbench` | DC sweep | Ron, flatness vs signal voltage |
| `SwitchIsolationTestbench` | AC (off-state) | Isolation at 1k–100M Hz, off-capacitance |
| `SwitchBandwidthTestbench` | AC (on-state) | f3dB, insertion loss, passband flatness |
| `SwitchTransientTestbench` | Transient (step) | Rise/fall time, settling, overshoot |
| `SwitchDistortionTestbench` | Transient + FFT | THD, SFDR |

## Signal Analysis Utilities

The built-in testbenches use a comprehensive DSP utility module (`ccreator.public._signal_analysis`) that provides:

### Frequency Domain
- `compute_fft()`, `find_fundamental()`, `find_harmonics()`
- `compute_thd()`, `compute_sfdr()`, `compute_snr()`, `compute_sndr()`, `compute_enob()`

### Time Domain
- `find_zero_crossings()`, `measure_frequency()`, `measure_periods()`
- `measure_period_jitter()`, `measure_duty_cycle()`
- `measure_settling_time()`, `measure_overshoot()`
- `measure_rise_time()`, `measure_fall_time()`, `measure_slew_rate()`

### ADC/DAC Linearity
- `compute_dnl()`, `compute_inl()`
- `measure_offset_error()`, `measure_gain_error()`, `check_monotonicity()`

### AC Response
- `find_f3db()`, `find_peak_response()`, `measure_quality_factor()`
- `measure_phase_margin()`, `measure_gain_margin()`, `measure_ugf()`
- `measure_psrr_at_freq()`

These are all importable for use in custom testbenches:

```python
from ccreator.public._signal_analysis import compute_thd, measure_settling_time

# In a custom testbench assertion:
def assertions(self, result):
    thd = compute_thd(result.y['out'], result.x)
    assert thd < -40, f"THD too high: {thd:.1f} dB"
```
