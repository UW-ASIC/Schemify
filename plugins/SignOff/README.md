## Gold-Standard Pre-Tapeout Verification Methodology for Analog and Mixed-Signal ICs

# Gold-Standard Pre-Tapeout Verification Methodology for Analog/Mixed-Signal Integrated Circuits

_A comprehensive reference document for analog designers targeting SkyWater sky130 and any modern process node_

## Executive Summary

There is no single simulation, tool, or test that delivers "100% confidence" that silicon will match simulation — that confidence is only earned by stacking many independent, partially-overlapping verification activities such that the probability of any unmodeled effect surviving all of them is negligible. The methodology below is organized as that stack. It is structured into seventeen verification domains followed by a master sign-off checklist. The guiding principles throughout are:

1. **Defense in depth** — every important specification is exercised by at least two independent methods (e.g., AC + transient noise; corner sweep + Monte Carlo; STB + transient stability).
2. **Stress beyond datasheet** — verify at conditions worse than the product datasheet ("guardband") because models are most accurate at typical bias and least accurate at the tails.
3. **Verify the verification** — sanity-check the testbench itself with hand calculations, ideal-component substitutions, and known-answer regressions.
4. **Make silicon observable** — bring critical internal nodes to pads or to on-chip ADCs, and provide trim/calibration knobs for everything that depends on absolute device parameters (Vt, R, C, β).
5. **Be skeptical of the PDK** — especially in sky130, where moderate/weak-inversion models, RF library accuracy, and aging/EM data are incomplete or absent. Verify what the foundry will not.

The remainder of this document is intended to be read as a reference and used as a tapeout sign-off ledger.

---

## 1. PVT and Corner Analysis Methodology

## 1. PVT and Corner Analysis Methodology

### 1.1 Corner taxonomy

The minimum corner set for a CMOS analog block is the 2×2×3 grid of {process} × {temperature} × {supply}, but a "gold-standard" sign-off uses many more layers:

- **Digital/transistor process corners (BSIM model files)** — TT (typical), FF, SS, FS (NMOS fast/PMOS slow), SF (NMOS slow/PMOS fast). FS/SF are critical for any circuit whose performance depends on Vtn–Vtp matching (CMOS bandgaps, level shifters, rail-to-rail input stages, differential pairs with bulk-driven mismatch). In sky130 the files live in `libs.tech/ngspice/corners/` as `tt`, `ss`, `ff`, `sf`, `fs`, `leak`, and `wafer`; in commercial PDKs you typically additionally find low-leak (LL), high-leak (HL), and lot-skew corners.
- **Passive corners** — resistor (rr_lo / rr_hi, often ±20% on poly resistors at 130 nm and ±15% at 28 nm and below), MIM/MOS capacitor (cc_lo / cc_hi, ±10–15%), and varactor corners. Cross these with active corners — _the worst RC time constant is rarely at TT_. Sky130 supplies `rc_lo`, `rc_hi`, `cmim_lo`, `cmim_hi`, `cvpp_lo`, `cvpp_hi` etc. via `sky130.lib.spice`. Always enumerate every passive technology you use; missing one is a common silicon-failure cause.
- **Extended/special corners** — slow-slow at cold/low-Vdd ("SS-cold-low") is worst-case for digital speed and analog GBW; FF-hot-high is worst for leakage, EM, self-heating, and reliability; SS-hot-high is worst for BJT-based bandgap startup and saturation margin; FF-cold-low is worst for slew/overshoot in feedback loops. Always run all four "extreme" combinations explicitly.
- **MOS flavor cross-skew** — when both LVT and HVT (or 1.8 V and 5 V) devices appear, foundries usually allow them to skew independently. Sky130 has nfet/pfet_01v8 plus \_lvt/\_hvt variants; you must run a "VT-skew" corner where LVT goes fast while HVT goes slow (and vice versa) for any circuit that mixes them in a matched topology.
- **Statistical/sigma corners** — extracted via Worst-Case Distance (WCD) or scaled-sigma sampling so that the corner is a single SPICE point representing a target sigma (e.g., 4.5σ for a 6.7 ppm failure rate). These are produced by Solido HSMC, Cadence Spectre FMC, or Synopsis PrimeSim HSPICE; in open-source they must be approximated by hand from large MC runs.

### 1.2 Temperature and supply range

- **Commercial range**: 0–70 °C; **industrial**: −40–85 °C; **extended industrial**: −40–105 °C; **automotive Grade 1**: −40–125 °C; **Grade 0/AEC-Q100**: −40–150 °C; **military**: −55–125 °C. _Always simulate at least the corners 10 °C outside the spec range_ (e.g., −50/+135 °C for industrial) because die-junction temperature exceeds ambient by 20–40 °C in many packages.
- **Supply**: nominal ±5% (consumer), ±10% (most ICs), ±20% (automotive/IoT). Tape-out sign-off should always include nominal ±10% even if datasheet is ±5%, plus a separate "brown-out" simulation at 70–80% of nominal (DC and ramp) for circuits that must survive low-voltage events.
- For multi-supply chips, sweep each supply independently _and_ together — co-variation matters for level shifters, ESD diodes, and substrate-coupled circuits.

### 1.3 How many corners to actually run

A naive full factorial of {7 process × 5 temp × 3 supply × 4 RC × 2 VT-skew × N load} is hundreds to thousands of points. Practical compromise:

- **Block-level functional sweep**: ~9–15 _fast_ corners (TT/SS/FF + FS/SF, three temperatures, two supplies, RC nominal) for daily regression.
- **Sign-off sweep**: full cross of {SS, TT, FF, SF, FS} × {Tmin, T25, Tmax} × {Vmin, Vnom, Vmax} × {RC_min, RC_nom, RC_max} for _every spec line_ — typically 100–300 points per circuit. Automate with ADE-XL / `corners.cfg` / a Python harness over ngspice or Xyce.
- **Top-level chip**: corners are too expensive at full chip; rely on block-level corner coverage plus a smaller representative top-level cross (typically 5 process × 3 temp × 3 supply = 45 points).

### 1.4 When corner analysis fails

Corner analysis is a _worst-case_ assumption: that all parameters skew together. It misses:

- **Mismatch-driven failures** (corners model global variation, not local). A diff pair at TT can have unacceptable offset.
- **Non-monotonic dependencies** — some specs (e.g., bandgap TC, oscillator startup margin) have a worst case at an _intermediate_ corner, not at any extreme.
- **Tail risk** — corners typically represent 3σ; you need MC/HSMC for 4–6σ.
- **Layout-dependent effects** — corners do not capture STI stress, well proximity, or LDE; you must run post-layout in addition.
- **Aging-shifted operating point** — corners are at t=0; aged corners must be obtained from MOSRA/RelXpert/Eldo-UDRM.
- **Correlation between blocks** — a top-level circuit can fail when two sub-blocks both lie at the same corner edge, even though each was independently signed off "with margin."

**Practical rule**: never tape out unless every spec passes every corner with ≥15% margin (or ≥3 stdev of the MC noise), and unless the _delta from nominal to worst corner_ has been hand-checked for physical plausibility — if a spec moves by 5× across corners, the design is fragile and the testbench likely missed a node.

## 2. Monte Carlo Methodology

## 2. Monte Carlo Methodology

### 2.1 Three flavors of MC

1. **Global/process MC** — all transistors on the die share a common skew sample (lot-to-lot, wafer-to-wafer). Each MC iteration randomizes the process parameters once. This MC gives the _distribution of the mean_ and is approximately replaceable by corner analysis.
2. **Local/mismatch MC** — every device gets an independent random ΔVt, Δβ, and Δgate-leak drawn from the Pelgrom model. This is the _only_ method for offset, INL/DNL, comparator decision, and PSRR-due-to-mismatch analysis.
3. **Combined ("process + mismatch") MC** — both knobs randomized simultaneously. This is what you run for production sign-off because it correlates global skew with local mismatch (e.g., mismatch grows at SS-cold for many parameters).

In sky130 you control this via the `MC_MM_SWITCH` and `MC_PR_SWITCH` parameters in the corner `.lib` files; setting both to 1 enables combined mode. In Spectre, use the `montecarlo` analysis with `variations=all`. In HSPICE, use `.option MONTE=…` with `AGAUSS`/`UNIF` per-device parameters.

### 2.2 Sample-size targets

For a Gaussian spec, the _confidence interval_ on a percentile estimate at N samples is:

| Target yield (σ) | Failure rate | Brute-force MC samples (rule of thumb) |
| ---------------- | ------------ | -------------------------------------- |
| 3 σ              | 1350 ppm     | 200 – 1000                             |
| 3.5 σ            | 230 ppm      | 1k – 5k                                |
| 4 σ              | 32 ppm       | 10k                                    |
| 4.5 σ            | 3.4 ppm      | 100k                                   |
| 5 σ              | 0.29 ppm     | 1 M                                    |
| 6 σ              | 2 ppb        | 1 B (infeasible without HSMC)          |

Always _also_ report sample mean, standard deviation, skew, kurtosis, and a normal-probability (QQ) plot. A QQ plot that bends in the tail (very common for SAR comparator offset, SRAM bit-cell read-current, flip-flop setup time) **invalidates Gaussian extrapolation** — you must use HSMC instead of multiplying σ.

### 2.3 High-sigma methods

When 1k–10k brute-force samples are insufficient (memory bit-cells, sense amps, standard cells, ADC comparators, level shifters, latches in a PLL), use one of:

- **Worst-Case Distance (WCD)** — linearize the failure boundary in parameter space and find the closest point under a Gaussian density. Fast, but linear-only; underestimates yield when the failure region is curved (most real circuits). Implemented in Solido WCA and Cadence Spectre FMC.
- **Importance Sampling (IS)** — shift the sampling distribution toward the failure region and reweight. Excellent in low dimensions; suffers from the _dimensionality effect_ in high-dim BSIM parameter spaces.
- **Scaled-Sigma Sampling (SSS / sigma-amplification)** — run MC at amplified σ (e.g., 2×, 3×, 4×) and extrapolate yield back to nominal σ via a parametric fit. Robust against dimensionality but Gaussian-only.
- **High-Sigma Monte Carlo (HSMC, Solido)** — machine-learning-classifier-guided sampling toward the failure boundary; converges in 1k–10k simulations for 6σ tasks where brute MC needs 1 B.
- **Subset simulation / MCMC** — partitions the failure event into nested intermediate events.

For sign-off, **use at least two methods** and verify their tails agree within 0.5σ. Cadence Spectre FMC reports a 10× reduction in simulations to find 4σ tails on a 14 nm FinFET ADC (900 vs 10 000); plan for similar 10–100× speedups vs brute-force MC in your budget.

### 2.4 Choosing the spec/yield

| Sub-block class                      | Target sigma                                                 |
| ------------------------------------ | ------------------------------------------------------------ |
| Top-level analog (PLL lock, ADC SNR) | 3 σ (1300 ppm)                                               |
| Bandgap output trim range            | 3.5 – 4 σ                                                    |
| Comparator offset / decision         | 4.5 – 5 σ in an N-comparator flash; 6 σ in SRAM-class arrays |
| Standard-cell setup/hold             | 5 – 6 σ (millions of instances)                              |
| Bit-cell read/write                  | 6 σ +                                                        |

### 2.5 When Monte Carlo misses real silicon variation

- **Spatial gradients** — Pelgrom's coefficient model is local; foundry MC files typically do not contain a die-scale gradient. Layout common-centroid or interdigitate, and _verify_ by recomputing offset with hand-imposed gradients (1 mV/mm Vt gradient is a typical worst case).
- **Systematic mismatch from layout** — orientation, dummies, STI-stress asymmetry. These are _not_ in the MC model.
- **Across-wafer correlation** — modules near the wafer edge see different process; not modeled in standard MC.
- **Process drift over time / different lots** — designers often forget that MC simulates a _single fabrication snapshot_. Real production has lot-to-lot drift that exceeds the MC σ.
- **Sky130-specific**: the BSIM4 mismatch parameters in sky130_fd_pr were re-derived from limited NIST/CoolCAD wafer measurements; they are _known to be optimistic_ in subthreshold (see Murmann's Ngspice-on-Colab analysis). For weak/moderate inversion design, add a hand-rolled 20–50% safety factor on σ(ΔVt).

**Sign-off rule**: report yield (fraction of MC samples that pass every spec, the worst-case-yield ANDed over outputs) — not per-output yield. A 5σ yield on each of 20 specs is only ~99% combined yield if the failures are uncorrelated.

## 3. Post-Layout Verification: DRC, LVS, ERC, Antenna, Density, and Parasitic Extraction

## 3. Post-Layout Verification: DRC, LVS, ERC, Antenna, Density, and Extraction

### 3.1 The mandatory clean checks

- **DRC (Design Rule Checking)** — Calibre nmDRC, ICValidator, Pegasus, Magic (`drc check`), or KLayout (with sky130 `drc/sky130A_mr.drc`). Run in _signoff_ mode, not interactive; require zero violations or a formal waiver document with foundry concurrence. On sky130 use the KLayout deck for sign-off — Magic's interactive DRC is good for in-flight checks but historically misses some advanced rules (SRAM exceptions; see SkyWater known-issues #2 and #10).
- **LVS (Layout vs Schematic)** — netlist match including device parameters (W, L, M, NF), with port matching, no black-boxed cells. Use Calibre LVS or netgen (`netgen -batch lvs`). Sub-circuits like ESD diodes, sealring, deep-N-well taps, antenna-protection diodes must all LVS — _every_ layout device must come back to a schematic device. A common pre-tapeout pitfall: parasitic diodes between deep-N-well and substrate that exist in layout but not schematic.
- **ERC (Electrical Rule Checking)** — floating gates, floating wells, missing substrate ties, well-tap spacing, supply-shorted nets, IO/core supply confusion, gate-to-tap-tie violations. Run both schematic ERC (in Virtuoso/Xschem) and physical ERC. Magic's `extract all; ext2sim` after layout extraction will flag isolated nets.
- **Antenna checks** — accumulated metal area on a gate before connection to diffusion can charge-induced-damage the oxide during plasma etch. Calibre antenna rule deck or KLayout antenna check. Cure with antenna diodes or "jogging" the route to a higher metal. Often missed on analog where designers focus on schematic-driven layout.
- **Density / fill** — every metal and poly layer has min/max density rules (typically 20–80% per window). Insert metal fill (Magic `cif paint` patterns, KLayout fill, ICC2/Innovus tile fill). Verify density meets _both_ min and max in every density window for every metal. For matched analog (capacitor arrays, current mirrors), use **shielded dummy fill** that does not couple to sensitive nets — pulled to AC ground or to the same net as the underlying structure.
- **Latch-up rules** — well-tap spacing typically 15–25 µm; ESD/I-O cells need extra guard rings. Foundry deck enforces this if installed; check sky130 has both regular DRC and "long" LU-spacing rules.
- **Sealring** — outer chip seal must be DRC-/LVS-clean as its own cell.

### 3.2 Parasitic extraction (PEX) modes

| Mode                      | Includes                   | When to use                                                  |
| ------------------------- | -------------------------- | ------------------------------------------------------------ |
| **C-only (decoupled)**    | grounded caps, no R        | Fast prelim post-layout sim; OK for low-frequency digital    |
| **C+CC (coupled)**        | grounded + coupling caps   | Required whenever cross-talk matters (matched lines, clocks) |
| **R+C**                   | net R + grounded C         | First-cut post-layout for slow analog                        |
| **R+C+CC ("RCc", "RCC")** | full RC network + coupling | **Mandatory for any analog/RF/mixed-signal sign-off**        |
| **+ Inductance (RLCk)**   | + self & mutual inductance | RF >5 GHz, large inductors, supply current loops             |

Industry tools: **Synopsis StarRC** (deeply integrated with Synopsis flow, default for digital-on-top), **Cadence Quantus QRC** (default in Virtuoso, ML-accelerated), **Siemens Calibre xACT/xRC and xACT 3D** (gold standard for sign-off; xACT 3D contains an integrated Laplace field solver). All three are foundry-certified down to 3 nm. Open-source: **Magic** has rule-based extraction with `ext2spice -p extract.cfg`; for sky130 it ships density tables and per-layer coupling parameters but is **roughly 5–15% accurate on coupling caps and ~25% on long-thin resistors** — adequate for non-matched analog, marginal for 10-bit-and-above data converters. **OpenRCX** (part of OpenROAD) is digital-oriented. There is no production-grade open-source field solver — for sky130 SAR DAC sign-off, Magic + a hand-built Python field-solver wrapper (FastCap2, FasterCap, Palace) is the only option.

**Accuracy modes**: Calibre xACT/xRC offers modes 200 (fast, sparse grid), 600 (denser grid, slower), and MEMS (highest accuracy, retains tiny coupling). Use 600 + selective field-solve on critical nets (e.g., the DAC array of a SAR ADC; an ADC's reference distribution) for sign-off. StarRC `Rapid3D` and Quantus `QRC-3D` both provide field-solver modes.

**Reduction settings**: aggressive reduction (PEX REDUCE TICER, PEX REDUCE CC) speeds simulation but loses accuracy. For analog sign-off use moderate reduction (`PEX REDUCE ANALOG YES` in Calibre); for the most sensitive nodes (sample caps, reference distribution, LO buffers) use _no reduction_.

### 3.3 Why pre-layout and post-layout differ

Pre- vs post-layout deltas come from:

- **Wiring R** — multi-kΩ poly-resistor traces; long thin metal-1 in dense areas. Splits poles and adds Johnson noise.
- **Wiring C** — adds dominant pole capacitance to high-impedance nodes; reduces GBW by 1.3–3× typically on a 2-stage OTA without effort to keep nets short.
- **Coupling C / cross-talk** — clock-to-input or supply-to-bias kick. Sometimes turns a stable PSRR into instability.
- **Device parameters** — extracted W/L can differ from schematic due to fingering, multipliers, layout-dependent effects (next section).
- **Sub-circuits inserted by extraction** — substrate diodes for FETs, body resistors, parasitic BJTs at deep-N-well boundaries.
- **Reduced supply mesh** — schematic models VDD/VSS as ideal; post-layout has IR drop and dynamic noise.

**Action items**: budget 20–30% performance margin pre-layout for analog (more for high-Z nodes like a continuous-time integrator output). After post-layout simulation:

1. _Always_ re-run full PVT and a reduced MC on the extracted view.
2. Compare every spec pre vs post: explain any >5% delta physically before sign-off.
3. If post-layout GBW is materially lower than pre, the layout is wrong — fix; do not band-aid with compensation.

## 4. Electromigration and IR-Drop Analysis

## 4. Electromigration and IR-Drop Analysis

### 4.1 Static IR-drop

- **Goal**: verify VDD–VSS at every device terminal stays within ~3% of nominal under DC average current (a common automotive bar is ≤30 mV on a 1 V supply, ≤50 mV on 1.8 V).
- **Tool**: Synopsis Totem (foundry-certified to 1.6 nm), Cadence Voltus-XFi (transistor-level, integrated with Spectre X), Siemens mPower (both analog and digital, full-chip scale), Ansys/Synopsis RedHawk-SC for digital top-level. Open-source: there is no production-grade EM/IR signoff tool; Magic+OpenROAD's PDN analyzer is the closest, and you must hand-build current maps for big analog blocks.
- **Method**: average-current DC SPICE on the extracted RC network; identify hot spots; widen straps, add vias, place decap.

### 4.2 Dynamic IR-drop

- **Goal**: instantaneous VDD droop under simultaneously-switching peak current (clock edge, ADC sample, comparator decision). Typical bar ≤5% of supply.
- **Method**: transient SPICE with package model + on-chip decap + extracted PDN, stimulated with worst-case switching vector. For analog blocks, include the switching of adjacent digital — the _adjacent block's_ dynamic load on the shared supply is often what kills analog performance.
- **Mitigation**: dense decap (MOS cap, MIM cap, fringe cap), thick top-metal supply, dedicated AVDD pad with multiple bond-wires, on-die LDOs feeding sensitive blocks.

### 4.3 Electromigration

- **Rules**: per-layer current-density limit J_max (A/µm of width) for average DC (Iavg), RMS (Irms — Joule heating), and peak (Ipeak — bidirectional pulse). At 130 nm Iavg ≈ 1 mA/µm for M1, scaling down with each node (~0.3 mA/µm at 7 nm). Sky130's `tech.lef` lists these per layer; the foundry spec sheets (NDA at sky130, public at most foundries) include temperature-dependent EM lifetime targets (10-year median for 105 °C is typical).
- **Black's equation**: MTTF ∝ 1/(J^n · exp(−Ea/kT)) with n≈2, Ea ≈ 0.7–1.0 eV. A 10 °C increase in metal temperature roughly halves lifetime.
- **Signal EM**: high-activity nets (clocks, fast-switching outputs) need to be checked for _bidirectional_ (peak) and _unidirectional_ (DC) EM separately. RMS limit handles Joule heating in narrow lines.
- **Via EM** — via arrays should have ≥30% safety margin because vias are the most failure-prone interconnect feature. Use 2+ vias per current-carrying junction always.

### 4.4 Power-grid verification

- **Connectivity / topology**: every transistor must reach every supply through low-R path; check with Voltus-XFi power-grid views, or hand-compute worst-case path R using extracted netlist.
- **Decoupling**: target 1–5% of switching charge as on-die decap (rule of thumb 10 pF per mA of switching current). Place decap in dead-space at every standard-cell row end and around large analog blocks.
- **Hierarchical PG signoff**: each IP returns a current/voltage profile (chip-level macromodel) to the top; Totem and RedHawk-SC generate these.

### 4.5 Sky130 specifics

The sky130 PDK does **not** ship a foundry-certified EM/IR tool flow. Practical method:

1. Build a coarse DC supply model from the extracted netlist using ngspice (1000s of resistors, fast).
2. Compute J for every metal segment by hand (or with a Python KLayout script) at the highest expected current and compare to the rule-of-thumb 1 mA/µm.
3. Always _over-design_ sky130 chips' power straps because there is no signoff EM tool — 2× width vs. minimum allowed is a reasonable margin.
4. For tiny tapeouts / chipIgnite, EM is generally not a concern; for high-current analog (LDOs >100 mA, drivers, RF PAs) you should hand-verify.

## 5. Reliability and Aging Simulation (HCI / NBTI / PBTI / TDDB)

## 5. Reliability and Aging Simulation

### 5.1 The four dominant aging mechanisms

- **HCI (Hot Carrier Injection)** — energetic carriers near drain inject into the oxide, raising Vt and degrading mobility. Worst in NMOS in saturation with high Vds; AC stress (switching) dominates over DC for most digital, but DC-biased analog (always-on current mirrors, bias generators, oscillator buffers) is most exposed.
- **NBTI (Negative Bias Temperature Instability)** — PMOS with negative Vgs at elevated temperature shifts Vt positive (less drive). Partially recoverable when stress is removed. Dominant in digital PMOS, in PMOS-input opamps, and in PMOS current mirrors held with constant Vgs.
- **PBTI (Positive Bias Temperature Instability)** — analogous for NMOS in high-k metal-gate stacks (28 nm and below). Significant in FinFET.
- **TDDB (Time-Dependent Dielectric Breakdown)** — gate-oxide rupture under prolonged high field. Both NBTI/PBTI shifts and TDDB lifetime are checked against gate-bias budgets (Vg_max for 10-year MTTF).

Also relevant: **stress migration** in interconnect, **soft errors** for memories (not applicable to most analog), and **junction leakage drift**.

### 5.2 Aging-simulation flows

| Tool                                         | Vendor                                   | Model                                             |
| -------------------------------------------- | ---------------------------------------- | ------------------------------------------------- |
| MOSRA (Levels 1–3)                           | Synopsis HSPICE / PrimeSim               | Built-in BSIM-aging model file (foundry-provided) |
| RelXpert / Eldo-UDRM                         | Cadence (Spectre RelXpert), Siemens Eldo | Foundry "AgeMOS" / URI plug-in                    |
| TMI (TSMC), SPRT (Samsung), foundry-specific | Foundry                                  | NDA models tied to a specific node                |

Open-source: **none mature**. Sky130 ships **no aging models**; ngspice has experimental hooks via `.option` but no production HCI/BTI flow. The mitigation in open-source land is conservative biasing (gate-source voltage budgeted ≤90% of nominal supply over life, drain-source headroom ≥200 mV) and DC bias avoidance — keep critical PMOS off when not in use.

### 5.3 Methodology

1. **Fresh simulation** — run full PVT/MC at t=0.
2. **Compute stress vector** — long-transient simulation (representative workload, often a steady-state period) → extract per-device stress integrals (∫Ids·Vds dt for HCI, ∫|Vgs|·exp(-Ea/kT) dt for NBTI).
3. **Apply aging** — MOSRA/RelXpert produce shifted model parameters for 1, 5, 10 years at a use-condition temperature (typically 105 °C for consumer, 125 °C for automotive).
4. **Re-simulate** — every spec at t=EOL across PVT. The _EOL corner_ is its own corner.
5. **Check guard-bands**: report Δ(spec) / spec_initial; flag any >10% degradation; require headroom against the spec to be ≥1.5× the predicted Δ.

### 5.4 What aging analysis misses

- **AC partial-recovery** for BTI is modeled but uncertainty is ±2× on extrapolated 10-yr Vt shift.
- **Voltage acceleration** (β factor in Black's law) for HCI varies 3–10× across publications.
- **Self-heating-aging coupling** in FinFET is poorly modeled at production-PDK level.
- **Hot-carrier on switching pads** sensitive analog devices — handled by separate I/O reliability rules ("Vg_max", "Vds_max" for transient overshoot), which the foundry will check at sign-off if you supply the test bench.

**Sign-off rule**: have a documented HCI/NBTI/TDDB analysis for every bias generator, oscillator core, comparator latch, and any DC-biased PMOS in the design — not just "the chip will be aging-checked at the SoC level."

## 6. ESD and Latch-up Verification

## 6. ESD and Latch-up Verification

### 6.1 The three ESD models

- **HBM (Human Body Model)** — 100 pF charged through 1.5 kΩ. ANSI/ESDA/JEDEC JS-001 (replaces MIL-STD-883). Typical targets: 2 kV consumer, 4–8 kV ruggedized. Peak current ≈ 1.33 A at 2 kV; rise time ~10 ns; pulse width ~150 ns. The HBM clamp must trigger before the protected oxide breaks down.
- **CDM (Charged Device Model)** — package self-discharges through a single pin, ~10–50 Ω, ~1 GHz BW. JEDEC JS-002. Pulse rise time <400 ps; peak current 5–15 A at 500 V. **CDM is the dominant in-fab failure mode in modern ICs** — automated handling has all but eliminated HBM events but charged packages still snap-discharge through bond-wires.
- **MM (Machine Model)** — historically a 200 pF / 0 Ω discharge. JEDEC dropped MM as redundant with HBM; modern qualifications usually skip it.

Typical qualification: 3 units at 2 kV HBM (positive and negative, 3 zaps each) plus 3 units at 500 V (or 250 V "C4-bumped") CDM.

### 6.2 ESD design and verification

- **Sizing**: clamp width ≈ 1 A per 50–100 µm of finger for "big FET" 2-stage clamps; for snapback NMOS clamps, follow foundry's ESD design manual exactly — sky130 has `sky130_fd_io__esd_pfet_g5v0d10v5`, `esd_nfet_*`, and the `sky130_fd_io__sio*` cells with characterized 2 kV HBM rating.
- **Pad-to-pad simulation (HBM)** — inject the 2-kV HBM source between every pin pair; verify (a) clamp triggers (<5 ns), (b) clamp voltage stays below oxide BV (typically 6–7 V for 1.8 V devices, 10 V for 5 V devices in sky130), (c) clamp current density satisfies metal EM during the ~150 ns pulse, (d) no internal node exceeds gate-oxide breakdown.
- **CDM simulation** — model the package as a charged C with the pulled-down pin connected through a ~1 nH+0.5 Ω path. Spot every IO and supply pin; verify gate oxides on internal devices connected to that pin don't see >oxide V_BV.
- **Pad ring continuity** — the ESD bus (power clamp ring) must be continuous and low-R. A typical "I/O ring break" silicon failure happens when designers manually re-arrange pads and accidentally cut the clamp bus.
- **Tools**: PathFinder (Ansys), Calibre PERC (Mentor) for static ESD topology checks; QuantumESD (Magwel) for full SPICE-on-extracted CDM. In open source, you can run hand-built HBM/CDM testbenches in ngspice on the extracted I/O ring.

### 6.3 Latch-up

- **Rule of thumb**: well-tap spacing ≤25 µm in core, ≤15 µm at I/O and near supply switches.
- **Verification**: JEDEC JESD78E test — inject ±100 mA at every I/O for 1 s while measuring supply current; ±1.5× Vdd overvoltage on supply rails. Pre-silicon, this is checked structurally (guard ring spacing, well-tap density) by Calibre PERC or vendor decks.
- **Sub-block analog risk**: any analog node that can be driven above Vdd or below Vss (e.g., RF receivers seeing antenna bounce, sample-and-hold inputs with kickback, level shifters on cold-start) needs _local_ guard rings (n+ in N-well, p+ in P-substrate, butted to supplies).
- **Substrate noise**: digital injection into the substrate can be 10–100 mV at low-Z analog wells. Mitigation: deep N-well isolation (sky130 has `nfet_01v8 + DNW`), heavy guard rings, separate analog substrate tap pad (VSSA).

### 6.4 Sky130 / open-source ESD reality

The sky130 I/O cells (`sky130_fd_io__gpiov2`, `sky130_fd_io__sio`, etc.) come with foundry-characterized ESD ratings (~2 kV HBM, ~500 V CDM for the standard pad). Use them. Do _not_ route analog signals directly from an unprotected pad. For analog-only pads on the Caravan analog harness, the documented strategy is to put the high-voltage clamp under the pad — see eFabless/Caravan analog wrapper guidance. Custom ESD design at sky130 outside the foundry I/O cells is risky without measured silicon data.

## 7. Noise Analysis

## 7. Noise Analysis

### 7.1 Sources to model

- **Thermal/channel noise** — 4kTγgm in MOS; modeled in BSIM4 via `tnoiMod`. γ ≈ 2/3 in long-channel; rises to 1–2 in short-channel and is a known modeling weakness in sky130 (the BSIM-noise parameters were re-fit on limited wafer data).
- **Flicker (1/f) noise** — Kf/(Cox·W·L·f^Af); dominant below ~1 MHz for MOS. PMOS typically has 3–10× lower Kf than NMOS in sky130, so PMOS-input opamps are preferred for low-noise.
- **Shot noise** — 2qI in BJT, diodes, and at junctions in subthreshold MOS.
- **Burst (popcorn) noise** — discrete trap states; not modeled in standard PDKs but present in measured silicon; mitigation = oversize critical input devices.
- **Resistor thermal noise** — 4kTR; also `Kf` for poly resistors (sometimes 1/f in res_high_po).
- **Substrate/supply-coupled noise** — _not in any device model_; you must simulate it explicitly.

### 7.2 Analysis types

- **`.noise` (small-signal AC noise)** — gold standard for linear time-invariant circuits. Reports total integrated output-referred noise and per-device contributions. _Always_ read the noise-contribution summary — the answer is "which 5 devices dominate noise?" not "what is total noise?"
- **PNOISE (periodic noise / cyclostationary)** — required for any circuit with periodic operating point: oscillators, mixers, switched-cap filters, samplers, choppers, PLLs. Cadence SpectreRF / Keysight ADS / Synopsis CustomSim. Output options: `pm` for phase noise (dBc/Hz), `pmjitter` for period jitter, `sources` to identify dominant noise contributors. Open-source: ngspice has a basic PSS+PNOISE through the `pss`/`pnoise` analyses (less mature than commercial); Xyce has limited PNOISE.
- **Transient noise (Tnoise)** — injects noise sources as random current/voltage sources in time domain. Required for: SAR-ADC noise (signal-dependent, non-LTI), Δ-Σ modulator noise, large-signal ring-oscillator phase noise, jitter, and any non-LTI circuit. Set transient timestep ≤ 1/(10·fnoise_max). Setting `noise_fmin` and `noise_fmax` controls the band. Cadence Spectre/AFS XT, HSPICE, and ngspice all support transient noise. Calibrate against `.noise` for the LTI portion.
- **Stochastic / accumulated jitter** — for PLLs and SerDes, transient noise over many cycles, then post-process for period jitter and integrated phase noise.

### 7.3 Methodology by circuit class

- **Opamps / OTAs**: AC `.noise` at every gain configuration, integrated input-referred from 0.1 Hz to 10× GBW. Always check the noise corner (1/f-to-thermal crossover) is comfortably below the signal band.
- **Oscillators**: PSS + PNOISE → phase noise plot from 1 Hz to fc/2 offset. Verify Leeson model match: ~−20 dB/dec close-in and ~−30 dB/dec for 1/f^3 region.
- **PLLs**: simulate each block (PFD, CP, divider, VCO, ref) separately, extract per-block noise spectrum, combine in a behavioral model (Verilog-A or Python). Closed-loop output phase noise = Σ |H_i(jω)|^2 · S_i(ω). See Kundert's "Predicting Phase Noise and Jitter of PLL-Based Frequency Synthesizers" (Designer's Guide) for the canonical methodology. Cross-check with full-circuit transient noise over ≥1000 reference cycles.
- **Mixers / SC**: PNOISE in time-varying mode; report SSB noise figure for RF mixers, kT/C noise for SC filters/ADCs.
- **RF receivers**: noise figure via `.noise` + S-parameters; NFmin and Γopt from device noise parameters. Verify at every band, every gain step.

### 7.4 Targets and pitfalls

- An OTA spec like "10 nV/√Hz @ 1 kHz" must be simulated _and_ the contribution analyzed. If the input pair contributes <80%, the layout/parasitic-extracted version may be worse than schematic.
- For SC circuits, `kT/C` noise is fundamental — verify total Cs/Cf is large enough by hand and re-confirm in transient noise.
- **Sky130 noise modeling caution**: sky130 1/f and thermal noise parameters are derived from limited measurement and tend to under-predict noise in short-channel devices and weak inversion. Apply a 1.5–2× safety factor on simulated input-referred noise for sub-µV-range circuits.

## 8. Stability and AC Analysis

## 8. Stability and AC Analysis

### 8.1 Loop-gain methods

- **Open-loop AC** — break the loop, drive a test source, measure. Simple but disturbs DC bias and assumes unidirectional signal flow.
- **Middlebrook's two-injection method** — voltage and current injection at the loop break, combined to compute return ratio while preserving the DC operating point. Requires "low-impedance into high-impedance" injection point.
- **Tian's method** — generalization that handles bidirectional signal flow without restriction on injection-point impedance. Implemented as Cadence Spectre's `stb` analysis and as the `LoopGain2.asc` example in LTspice (Frank Wiedmann's port). **This is the production default**; the `iprobe` (analogLib) is placed in the loop. For differential, use a `diffstbprobe` so the differential- and common-mode loops are reported separately.
- **Middlebrook's General Feedback Theorem (GFT)** — distinguishes loop gain, loop forward path, and bypass path; correctly predicts closed-loop peaking even when loop gain looks fine. Useful for circuits with significant feed-forward.

### 8.2 What to measure

For every feedback path:

- **DC loop gain** (≥40 dB minimum for an opamp; ≥80 dB for precision LDOs/bandgaps).
- **Unity-gain frequency** (f0, where |T|=1).
- **Phase margin (PM)** — minimum 45° for "production quality"; 60° is the engineering target; 70°+ for circuits driving large capacitive loads or with poorly characterized loads. Below 45° = ringing; below 30° = silicon will likely oscillate.
- **Gain margin (GM)** — typically ≥10 dB.
- **Output impedance** vs frequency, especially for LDOs (peaks indicate Q at the load-pole — verify Q<0.5 for monotonic transient).

### 8.3 Stability across PVT and load

Stability is **not a single number**. Sweep:

- Process: all five corners. SS-cold often has lowest GBW and may also have lowest PM (lower gm crashes the LHP zero).
- Temperature: both extremes.
- Supply: low end (slow) and high end (high gm, can lower PM through gm/Cc relocation).
- Load capacitance: 0 → 10× nominal in log steps. The "no-load" case is often the worst-case PM for Miller-compensated opamps and for capless LDOs.
- Load current (LDO): 0 mA, 1 µA, 1 mA, full current. LDOs have load-dependent loops and the worst PM may be at light load (e.g., 1.85° at 10 µA per published 0.18 µm LDO results).
- For switching circuits (DC-DC, charge pump), do **large-signal stability**: simulate a startup, a worst-case load step, and a worst-case supply step; verify monotonic recovery, no sub-harmonic oscillation, no limit cycles.

### 8.4 Multi-loop and conditional stability

- Circuits with nested loops (Miller + nulling-zero, LDO with cascode pole, BG with two amplifier loops) require breaking each loop independently — `stb` only handles one loop at a time.
- _Conditional stability_ (region of Bode plot where |T|>1 and phase >180°) is silicon-killing. Verify the loop is _unconditionally_ stable, including under all start-up transients.
- For multi-loop, Nyquist plot of the return-ratio matrix (Rosenbrock's method) is the rigorous check.

### 8.5 Pitfalls

- Forgetting that `stb` reports return ratio, not gain — they differ in sign convention. Read the manual.
- Placing the probe inside a _minor_ loop and missing the dominant loop.
- Using AC simulation when the bias point itself is unstable — always confirm a clean DC operating point first.
- Trusting a 60° pre-layout PM and seeing 30° post-layout — wire C on high-Z compensation node migrated the pole. Always re-do stability after parasitic extraction _and_ at every PVT corner.

## 9. Transient Simulation Thoroughness

## 9. Transient Simulation Thoroughness

### 9.1 What to include

- **Power-on / supply ramp** — supplies must ramp from 0 to nominal at the worst-case slowest ramp the system spec allows (typically 1 µs to 100 ms). Verify (a) no latch-up condition, (b) no internal node exceeds rated voltage, (c) clean start of biasing chain, (d) digital comes up in a known reset state, (e) PLL/oscillator achieves lock.
- **Power-down sequence** — verify graceful shutdown; no glitches, no reverse current through ESD diodes.
- **Brown-out** — supply dips to 70% then recovers; verify state machine and analog all recover correctly.
- **Cold-start / startup margin** — every bandgap, every oscillator, every self-biased current source has a _zero-current equilibrium_; verify the startup circuit kicks the loop out at every corner, including the slowest (SS-cold-low). Run 100+ MC iterations of the startup transient — _failure to start at 1 ppm_ is a real silicon failure mode that does not appear in a single simulation.
- **Worst-case input patterns** — for converters/comparators, dynamic input near transition, simultaneous code transitions, alternating max/min codes.
- **Settling** — must reach the target accuracy (e.g., 0.5 LSB for an N-bit ADC: 2^−(N+1) of full scale) within the allocated time at every corner. Watch for _slew/non-linear settling_ — when the signal swing exceeds gm/Cload·t_slew, settling is exponential of the slew-limited time, not the linear time-constant.
- **Long-duration runs** — for circuits with slow loops (auto-zero, chopper, BG stabilization), run at least 10× the slowest time constant.
- **Glitch analysis** — look for narrow pulses on critical nets (clocks, control signals); verify no spurious switching events from digital-coupled disturbance.
- **Worst-case temperature transient** — for circuits with on-die heaters / digital that warms a corner of the die during operation, simulate the analog block's response to a ramp temperature.

### 9.2 Settings to get right

- Use `method=gear2` or `trap` (Spectre) / `level=1 method=trap` (HSPICE) / `.options method=trap` (ngspice) for high-accuracy analog. The default `traponly` BDF in some simulators damps real ringing.
- `reltol = 1e-5` to `1e-6` for sign-off; relax for daily.
- `vabstol = 1e-7`, `iabstol = 1e-12` (or stricter for sub-µA bias).
- `maxstep` must be ≤ 1/(20×fmax) of any signal of interest.
- Always re-simulate critical results with tighter tol; if results change, the simulation is convergence-noise-limited, not real.

### 9.3 Long-transient productivity

- Use FastSPICE / AFS-XT / Spectre X / PrimeSim XA for >1 ms transient on >100k transistor blocks. They use multi-rate integration and table-model approximations. Trade speed for ~1–3 dB accuracy loss on noise.
- In open source, ngspice with KLU solver and Verilog-A behavioral models for non-critical blocks gives the same effect.

### 9.4 Glitch/event coverage

Maintain a coverage list:

- All clock-domain crossings exercised.
- Reset/release sequences (synchronous & asynchronous) covered.
- All trim-DAC codes simulated for at least min/typ/max.
- All standby/active mode transitions exercised.
- Every analog mux state checked.

## 10. Mismatch and Matching Analysis

## 10. Mismatch and Matching Analysis

### 10.1 Pelgrom model

For two nominally identical devices: σ²(ΔVt) = AVT²/(W·L) + SVT²·D², σ²(Δβ/β) = Aβ²/(W·L) + Sβ²·D², where D is the separation distance. For sky130_fd_pr_nfet_01v8 typical AVT ≈ 5–6 mV·µm; pfet_01v8 ≈ 8–10 mV·µm. For advanced FinFET, AVT ≈ 1.5–3 mV·µm (per fin) but devices are quantized — only integer numbers of fins, with mismatch ≈ AVT/√N_fin · AVT_norm.

### 10.2 Matching design rules

- **Pelgrom-driven sizing**: for an ADC comparator with σ(Voff) ≤ Vlsb/4 at 4σ, solve W·L ≥ (4·AVT/(Vlsb/4))² → quadratic-in-bits scaling.
- **Common centroid**: 2-D centroid match for both x and y; _interdigitated_ gets centroid match in 1-D only and can have ratio error from a 2-D gradient. For ratio-critical (DAC capacitor arrays), use 2-D common centroid with edge dummies.
- **Dummy devices**: every matched edge device sees STI stress differently; 1–2 dummy fingers on each side of a matched array.
- **Orientation**: matched devices must have identical orientation (same channel direction). For very high precision (DAC INL <0.1 LSB at 12 bits), use 2-direction interleaving to cancel directional gradient (e.g., NMOS stress is anisotropic in channel direction).
- **Routing symmetry**: route resistor/capacitor matched lines with identical length, identical metal stack, identical number of vias.
- **Well-tap symmetry**: same well-tap configuration per device (some PDKs allow shared taps for closer devices, which can produce different VT through different substrate bias).

### 10.3 Verification

- **Layout inspection** — visually verify centroid match, dummy presence, identical orientation, symmetric routing. Many design groups require an analog layout review _before_ PEX.
- **Mismatch MC** — at least 1000 samples; report σ, 4σ tail, normality test (Shapiro-Wilk or D'Agostino). A failed normality test => use HSMC or hand-driven WCD.
- **Post-layout mismatch** — re-run mismatch MC after PEX. Wiring asymmetry can dominate device mismatch at sub-1-mV offsets.
- **DEM (Dynamic Element Matching)** checks — for circuits using DEM (Δ-Σ DACs, current-steering DACs), verify the scrambling algorithm produces white spectrum at the matching-error frequency (not a tone). Behavioral simulation in Python or Verilog-A is most efficient; verify at the full transistor level afterward.
- **Offset distribution plot** — histogram of input-referred offset across MC. Report mean, σ, max(|x|), 99.9th percentile, 4σ extrapolation.

### 10.4 Layout-dependent mismatch in advanced nodes

FinFET introduces additional effects (well-proximity WPE, LOD, NDE, PSE) not modeled in standard MC. These are handled by extracting per-device "neighbor" parameters via the LDE-aware extraction (Calibre xRC with LDE flow, StarRC with LDE annotation). For sky130 these effects exist but are small (130 nm) — for 28 nm and below they dominate mismatch and _every_ matched analog cell must be LDE-extracted and re-simulated.

## 11. Sub-block-Specific Verification Methodologies

## 11. Sub-block-Specific Verification Methodologies

For every sub-block below, the _common verification stack_ is: schematic-functional → PVT → MC (combined process+mismatch) → post-layout → PVT-on-post-layout → reduced-MC-on-post-layout → aging-on-post-layout. The block-specific items below add to that stack.

### 11.1 Bandgap references (BGR)

- **DC**: nominal Vref vs supply (`Vref(Vdd)`), report line regulation; vs temperature −40 to +125 °C; report TC in ppm/°C with min/max/quadratic fit; vs trim code.
- **PSRR**: AC source on supply, AC at output; report from 0.1 Hz to ≥10 MHz across loads. Bandgaps often show good DC PSRR (>−80 dB) but poor MHz-range PSRR (−20 to −40 dB) due to internal opamp BW. Verify against application's supply ripple environment.
- **Startup**: transient supply ramp at 1 µs, 100 µs, 10 ms rise times. Run 100+ MC samples to find no-startup cases. Trigger the dedicated startup circuit and verify it disconnects after main loop is up. Re-verify at SS-cold.
- **Curvature**: TC plot — verify curvature is the expected concave (1st-order) or S-shape (2nd-order corrected). Trim range: must cover ±4σ of process spread at room temperature.
- **Noise**: integrated 0.1 Hz–10 Hz noise (matters for the noise-floor of a precision ADC); report µV-rms.
- **MC**: nominal Vref ±3σ should be within trim range, ideally <1% of Vref.
- **Sky130 caveat**: BJT-based BGRs use parasitic vertical PNP under deep-N-well; sky130 BJT models are characterized but I_S spread is wide (±20%) — trim range must accommodate.

### 11.2 LDOs / linear regulators

- **DC**: Vout vs Vin (line regulation, µV/V; aim ≤1 mV/V), Vout vs Iload (load regulation, µV/mA; aim ≤50 µV/mA at 50 mA), dropout voltage at full load across temperature.
- **AC**: open-loop gain Bode, PM/GM across {0, 1 µA, 100 µA, 10 mA, max} load × {min, nom, max Cload, min/max ESR}. Phase margin must be ≥45° across **all** combinations. LDO loops have load-dependent dominant poles; light-load (≈10 µA) is often the worst case for PM, but full-load may be the worst for transient overshoot.
- **PSRR**: vs frequency, vs load, vs Vin–Vout headroom. Target ≥60 dB DC, ≥40 dB at 1 kHz, ≥20 dB at 1 MHz for noise-sensitive analog supplies.
- **Load transient**: step Iload 10% → 90% in 1 ns / 100 ns / 1 µs; report droop and settling. Typical target ≤50 mV droop at 100 ns / 90% step.
- **Line transient**: step Vin within rated range; verify no instability.
- **Stability under capless / cap-only load**: many LDOs are characterized only with a specific Cload+ESR; verify at boundaries.

### 11.3 PLLs

- **Lock time** at every reference frequency × every divide ratio × every PVT, both warm-start and cold-start (VCO at top and bottom of range). Report worst lock time.
- **Lock range** (frequency tuning range with margin).
- **Phase noise / jitter** — closed-loop spot phase noise at 1 kHz, 10 kHz, 100 kHz, 1 MHz offsets; integrated RMS jitter over the spec band. Use Kundert's behavioral model fed by per-block PSS+PNOISE results for closed-loop; cross-check with transient noise on full circuit for ≥1000 ref cycles.
- **Reference spurs** (at fREF and harmonics) — must be below −60 to −80 dBc depending on application. Driven by charge-pump mismatch and supply coupling.
- **Fractional spurs** (frac-N synthesizers) — verify SDM-driven noise shaping does not produce in-band tones.
- **Supply pushing** (Hz/V on VCO supply) — translate to phase noise via the supply-noise spectrum.

### 11.4 ADCs

Architecture-dependent (referring to Murmann's ADC Survey for class-leading numbers):

- **SAR**: DAC linearity dominates; comparator noise + offset secondary. Test by code histogram (10 M sample at slow ramp or coherent sine input). Report DNL (must be >−1 LSB for monotonicity), INL (typ ≤1 LSB for medium-resolution), missing codes (any "0-count" bin), SNDR/ENOB (FFT of coherent sine input, ≥4 periods, with primary tone in a prime-index FFT bin), SFDR. Verify cap mismatch contribution by MC over the DAC array.
- **Flash**: comparator offset and metastability dominate. INL/DNL via histogram; bubble-error rate via worst-case input near transitions; encoder-error rate via wiring delay analysis.
- **Pipeline**: residue-amp gain error → INL; inter-stage settling → ENOB. Verify each stage's residue using its specific output-vs-input transfer curve; check digital-correction redundancy is sufficient. Run ramp + coherent-sine FFT.
- **Δ-Σ**: SNDR vs OSR and signal level; tone-free decimated output for slow-changing input. Verify quantizer is stable for all input ranges (no overload). DNL/INL are typically irrelevant for Δ-Σ except for multi-bit quantizers (DAC linearity in the feedback path bounds SNR). Verify NTF zeros at desired band.
- **General**: simulate full ENOB across PVT × ≥200 MC samples; if simulation cannot reach >10,000 samples for histogram, supplement with behavioral model fed with extracted nonlinearity coefficients.

### 11.5 DACs

- **Static**: code-sweep, measure Vout(code); report DNL, INL (endpoint and best-fit), monotonicity. Cap-DAC: include MC of capacitor mismatch (gradient + Pelgrom). Current-steering DAC: thermometer-vs-binary partitioning verification.
- **Dynamic**: settling time and glitch energy at every major-carry transition (binary mid-scale is worst). Glitch energy = ∫|Vout(t)−ideal|dt over settling window.
- **SFDR / IM3**: FFT of coherent sine output for narrowband DACs; two-tone test for wideband.
- **Output impedance** for current-steering — affects load-dependent INL.

### 11.6 Comparators

- **Offset**: MC mismatch run; report σ_Voff and 4–6σ tail (HSMC if used in flash arrays with many comparators).
- **Kickback**: simulate input voltage during latching with a finite source impedance (R_src). Report kickback charge ∫i_in dt per decision; verify input source can recover before next sample.
- **Metastability**: simulate decision time for Vin near the threshold (Vin = Vtrip + δ for δ = 1 µV, 10 µV, 100 µV); fit exponential τ_meta. Bit-error rate = exp(−t_resolve/τ_meta). For ADCs needing BER<1e-12, t_resolve ≥ 28·τ_meta.
- **Hysteresis** (if intentional): verify hysteresis band across PVT and MC; for unintentional hysteresis check it's <σ_Voff/4.
- **Speed**: clock-to-output across decision difficulty.

### 11.7 OTAs / Op-amps

- **Open-loop gain (Av0)**: ≥40 dB minimum for general use; ≥80 dB for precision (charge integrators, voltage references, precision LDOs); ≥100 dB for instrumentation.
- **GBW**: verify at every load. The "open-load" GBW often differs from "spec load" by 2–3×.
- **Slew rate**: full-scale step on closed-loop test; report SR+ and SR− separately; verify ≥3× nominal-signal·2π·BW so settling is linear, not slew-limited.
- **CMRR**: AC analysis with common-mode source; >60 dB typical, >100 dB precision; _test at the actual common-mode range corner_.
- **PSRR+ and PSRR−**: each supply separately; report DC and at AC frequencies of interest.
- **Output swing**: linear range across PVT, MC and load — usually the spec-limiting parameter.
- **Input common-mode range / offset**: voltages where input pair is in saturation; CMRR drops near edges.

### 11.8 Oscillators

- **Startup**: cold + supply ramp; verify oscillation builds across all corners. Sensitive to bias-current MC.
- **Phase noise**: PSS+PNOISE; close-in (1 kHz–100 kHz) for stability/long-term, far-out (10 MHz+) for sampling-clock jitter.
- **Pulling**: small ΔIbias or ΔVdd test → ΔFosc; check that nominal supply ripple does not pull the oscillator outside lock.
- **Injection locking**: if a strong near-fosc signal is present, simulate pulling/locking range.
- **Harmonic content** for crystal/MEMS-driven oscillators.
- **Amplitude stability** (limiting mechanism); verify AGC if used.

### 11.9 Voltage references and biasing chains

- **Startup**: cold-start, slow ramp, MC. Document the startup mechanism. Confirm a _guaranteed_ kick out of the zero-current equilibrium.
- **PTAT / CTAT components verified** at each measurement node.
- **Trim**: verify range, monotonicity, step size; check trim does not break startup.
- **PSRR / noise** as for BGR.

### 11.10 Switched-capacitor circuits

- **Charge injection**: simulate switch-off transient on a high-Z node; reported in units of millivolts of node disturbance. Mitigate with dummy switches and complementary clocks.
- **Clock feedthrough**: simulate clock edges coupling to held nodes via Cgd; verify at maximum clock slew rate.
- **kT/C noise**: SC noise PNOISE; verify floor below the signal-band requirement.
- **Settling**: full transient with realistic clock; verify each phase settles to N+1 bits before phase change.
- **Substrate kick**: verify large clock buffers do not couple into sample capacitors via substrate (deep-N-well isolation, well-strapping).

### 11.11 RF front-ends

- **S-parameters**: small-signal `.sp` at every gain mode and band; verify input/output match, gain.
- **Noise figure**: `.noise` with port S-parameter inputs.
- **Linearity**: IIP3 via two-tone PSS; P1dB via large-signal sweep.
- **Stability**: K-factor / μ-factor across bias and frequency; verify K>1 throughout the band and outside it (parasitic oscillations).
- **Pulling / spur coupling** from on-chip oscillators.
- **Sky130 RF caveat**: the `sky130_fd_pr_rf` library is marked "reference only" — use `sky130_fd_pr_rf2`. RF accuracy above 5 GHz is limited and you should overdesign or include test-structures for measurement.

## 12. Package and PCB Co-simulation

## 12. Package and PCB Co-simulation

### 12.1 Bondwire and package parasitics

- **Bondwire** typical: 1 nH/mm, 50–80 mΩ/mm. A 2 mm bondwire = 2 nH and ~150 mΩ. _Two bondwires_ on the same pad in parallel = ~1 nH (with shared mutual inductance reducing the benefit to ~70%).
- **Down-bond / power-pin clustering**: each VDD pin shares inductance with its near-neighbor; for high-current digital supplies, this couples on-die ringing onto VSS via mutual inductance.
- **Always**: model every supply pin and every fast signal pin with an explicit RL or distributed S-parameter package model. Cadence Sigrity, Ansys SIwave, or open-source `Palace`/`gmsh+OpenEMS` can extract package models.
- **Worst-case**: assume bondwire L 2× the typical to bracket worst-case ringing.

### 12.2 Package models

- IBIS / IBIS-AMI: pin-to-pin RLC matrices for system-level simulation; obtain from the package vendor or build from physical model.
- S-parameter touchstone (.sNp) for high-speed package (Wirebond + BGA + lead-frame); include in transient via convolution (Spectre `nport`, ngspice `.sp` or Verilog-A behavioral).

### 12.3 PCB

- **Power-supply network**: model decap (ceramic + electrolytic) plus PCB trace inductance. For RF, ensure no ground-loop resonances inside the chip's noise spec band.
- **Reference and clock distribution**: model trace as transmission line with measured ε_r; verify return loss.
- **External components**: include vendor SPICE models for the actual reference parts you intend to use (e.g., the 26-MHz TCXO for the PLL ref).

### 12.4 Where co-simulation pays off

- LDO/regulator stability with the customer's actual board (1 nF ceramic + 22 µF tantalum has very different Z(f) than 1 µF ceramic alone).
- Oscillator startup with realistic crystal model and Cload.
- ADC reference with realistic decap (the reference is loaded with capacitive currents at sample rate).
- RF matching with real package + PCB launch.

### 12.5 Test sockets and ATE

Don't forget to include the test fixture: socket + handler contact resistance can be 50–500 mΩ; for low-Vdo LDOs the socket alone can fail your line-regulation test.

## 13. Mixed-Signal Verification

## 13. Mixed-Signal Verification

### 13.1 Modeling-language ladder

From most-detailed/slowest to least-detailed/fastest:

1. **Full transistor SPICE** — gold-standard accuracy; ms of simulated time per day for full chips.
2. **Verilog-AMS / Verilog-A (electrical)** — continuous-time behavioral; analog convergence applies. Good for OTAs, comparators, oscillators with realistic AC noise modeled.
3. **Verilog-AMS `wreal` / SystemVerilog `real` nettype** — discrete-event real-number models (RNM). 100–500× faster than electrical Verilog-AMS, sufficient for connectivity and functional checks; _cannot_ model loading effects, current, or impedance interactions out of the box.
4. **SystemVerilog UDN (User-Defined Nettype, e.g., `EEnet`)** — multiple resolved values (V, I, R) on a single net; allows loading/current modeling in DMS. Cadence ships `EEnet` package.
5. **Pure digital (logic 0/1, X)** — connectivity-only.

### 13.2 Methodology

- **Block specification → model first**: write the Verilog-AMS/RNM model from the architectural spec **before** transistor design. Run system-level regression against this model to expose unrealistic specs.
- **Co-simulation flow**: Cadence Spectre AMS Designer / Xcelium Mixed-Signal App; Synopsis VCS-AMS / CustomSim; Siemens Symphony. Open-source: Verilator + ngspice cosim is possible but immature; `cocotb` + spice via subprocess is a common open-source workaround.
- **Connect modules**: define how `electrical`/`real`/`logic` boundaries resolve; verify they correctly model loading at the digital-analog boundary (output drivers, level shifters).
- **Verification metrics**: code coverage of the digital RTL, functional coverage of the spec items, _plus_ SVAs (SystemVerilog Assertions) embedded in the AMS models for monitoring analog invariants (e.g., "Vref must stay within ±2% of 1.2 V during normal operation").
- **Equivalence check**: every RNM model must be checked against the transistor netlist at the block boundary at least at: nominal DC, nominal AC, one PVT extreme, one MC sample.
- **Top-level signoff**: run the full system regression at RNM speed; for _each_ high-risk scenario (cold boot, brown-out, mode change) drop in the transistor model of the critical block and re-run.

### 13.3 Digital-analog interface specifics

- Level shifters must function at every voltage combination (including the brief startup window where one supply is up but not the other).
- Power-domain crossings need isolation cells.
- Async crossings must use synchronizer flip-flops with measured MTBF.
- Glitches on digital control to analog must be suppressed (debouncing, retiming).

### 13.4 Sky130 mixed-signal practice

The Caravel / Caravan harness already provides a mixed-signal template: PicoRV32 management core, wishbone bus, GPIO with analog mux. For analog-heavy designs, use Caravan (analog wrapper) which provides bare analog pads with under-pad clamps. Build a SystemVerilog RNM model of every analog block in your user project; verify functionality at the chip top-level using the Caravel testbench harness with iverilog or Verilator before transistor signoff.

## 14. PDK-Specific Considerations for sky130 (and Open vs Commercial Tools)

## 14. PDK-Specific Considerations for sky130 (and Open Tools vs Commercial)

### 14.1 sky130 model accuracy and gotchas

- **Subthreshold / weak-inversion accuracy is poor**. The BSIM4 binned models exhibit a non-physical kink in gm/Id around Vgs ≈ Vt that is visible in `Ngspice-on-Colab` SKY130_VGS_sweep notebooks. For low-power analog operating at Vov < 100 mV, this can cause 10–30% gm misprediction. Mitigation: design with Vov ≥ 100–150 mV, or apply hand-fudged g_m model. As of 2026 there are no public plans to refit subthreshold; Murmann, Wright, and others have characterized the issue extensively.
- **RF library**: `sky130_fd_pr_rf` is reference-only — use `sky130_fd_pr_rf2`. Models above 5 GHz have wide uncertainty.
- **Aging**: no MOSRA/RelXpert/Eldo aging models shipped. Plan a conservative HCI/NBTI design margin.
- **High-voltage devices** (5 V, 10.5 V, 16 V, 20 V NMOS/PMOS) have foundry-validated models, but use them per the _Spice Models doc (002-21997)_ obtainable from SkyWater on request.
- **Resistors**: `res_high_po` and `res_xhigh_po` are the precision options; generic diffusion resistors are listed as "not recommended for analog." 5 fixed widths plus W/L parameterized. Capacitance under the resistor is in the model.
- **Capacitors**: MIM (M3-cap_top) for precision; VPP fingered metal stacks for density-/cost-sensitive applications.
- **Standard cells**: HD library for digital is mature; HV-level shifters in `sky130_fd_sc_hvl`.
- **SRAM**: `sky130_fd_sp_sram` is not a Magic-DRC-clean library yet; use OpenRAM-generated macros instead.
- **I/O cells**: `sky130_fd_io__gpiov2`, `sky130_fd_io__sio` — read the user guide carefully; analog-mux behavior in different power modes is subtle (firmware must drive `inp_dis=1` when `analog_en=1`).

### 14.2 Open-source vs commercial tool gaps

| Capability           | Commercial                                         | Open-source equivalent                                | Gap                                                              |
| -------------------- | -------------------------------------------------- | ----------------------------------------------------- | ---------------------------------------------------------------- |
| SPICE                | Spectre / Spectre X, HSPICE / PrimeSim, Eldo / AFS | ngspice (KLU), Xyce                                   | OK to ~100k devices; FastSPICE-level scale missing               |
| RF/PSS/PNOISE        | SpectreRF, HSPICE-RF, AFS-RF                       | ngspice has basic PSS/PNOISE                          | Less mature; verify carefully                                    |
| Aging                | MOSRA, RelXpert, UDRM                              | none                                                  | No aging signoff in open-source                                  |
| Layout               | Virtuoso, Custom Compiler, L-Edit                  | Magic, KLayout                                        | Adequate for sky130; lacks constraint-driven analog placement    |
| Schematic            | Virtuoso Schematic Editor                          | Xschem, Xcircuit                                      | Functional; integration polish behind                            |
| DRC/LVS              | Calibre, IC Validator, Pegasus                     | Magic (DRC, ext), netgen (LVS), KLayout (signoff DRC) | sky130 signoff via KLayout deck is foundry-supported             |
| Extraction           | StarRC, Quantus QRC, Calibre xRC/xACT 3D           | Magic ext, OpenRCX                                    | Coupling-cap accuracy ~5–15% (Magic); no production field solver |
| EM/IR                | Totem, Voltus-XFi, mPower, RedHawk-SC              | none mature                                           | Build by hand from SPICE                                         |
| ESD                  | PathFinder, Calibre PERC                           | hand testbenches                                      | No automated topology check                                      |
| Mixed-signal         | AMS Designer, VCS-AMS, Symphony                    | iverilog + ngspice subprocess, cocotb                 | Workable for small chips                                         |
| Datasheet generation | Custom                                             | CACHE, CICsim                                          | Functional                                                       |

### 14.3 Sky130 tapeout practical tips

- Run **local mpw-precheck** early (the Efabless precheck Docker container).
- KLayout DRC ruleset can differ from Magic's; both must pass for sign-off. Magic for in-flight, KLayout for signoff. Use the KLayout sky130A `drc/` deck.
- For LVS, place the netlist in **both** `xschem/` and `netgen/` to pass precheck.
- Magic changes cell internals on GDS read — preserve original cells with `property GDS_FILE` (see Caravan-tapeout lessons-learned). For drop-in IP, freeze the GDS reference.
- The `sky130A_setup.tcl` for netgen needs `permute` directives for parallel-symmetric pins (e.g., diode A/C) to avoid LVS pin-swap false-fails.
- Use **`ciel`** (formerly `volare`) for reproducible PDK installation; freeze the exact hash for tapeout.
- For analog harness, use **Caravan** (analog wrapper, bare pads under-clamp) rather than Caravel (digital-oriented).
- Open-source flows are good for _educational/test-chip_ tapeouts but you should **expect first-silicon yield <100%** and pre-plan a second turn. Tapeout test-structures aggressively (process-monitor ring osc, parametric NMOS/PMOS, R/C/L test bars, ESD probe pads).
- Sky130 process maturity: a 180/130 nm hybrid originally Cypress, in commercial volume production for ~20+ years — it's a reliable process; problems are usually in the _PDK_, not the wafer.

## 15. Differences Across Process Nodes

## 15. Differences Across Process Nodes

### 15.1 Mature bulk-CMOS nodes (180 nm, 130 nm, 65 nm)

- **Long-channel-like behavior**: gm/Id curves are smooth; weak inversion is usable for low-power.
- **Lower 1/f noise** per area but lower density; reach noise specs with brute area.
- **Vdd 1.8–5.0 V** options enable robust analog (e.g., sky130's 5 V/10 V/16 V/20 V devices).
- **Mismatch coefficients** are larger (AVT ~5–8 mV·µm) but device sizes are large enough to compensate.
- **Reliability** is mature; HCI/NBTI margins are well-known and foundry margins generous.
- **Layout effects**: STI stress small; WPE present but small; LDE rules manageable.
- **Verification effort**: corners + MC + parasitic extraction is largely sufficient. Self-heating negligible. Density rules are loose. Single-patterning lithography.

### 15.2 Sub-65 nm planar (45 nm, 40 nm, 28 nm)

- **Short-channel effects** dominate; rds drops, gm·rds < 30 typical.
- **High-k metal gate** introduces PBTI as a first-order effect (28 nm and below).
- **LDE / WPE / STI stress** become first-order; **every** analog block must be LDE-extraction-aware. Calibre xRC's LDE flow or StarRC `LDE` extraction is mandatory.
- **Mismatch** decreases (AVT ~2–3 mV·µm) but density requirements increase variation; matched layouts must be very careful.
- **Density rules** tight; chess-board dummies common.
- **Multiple-patterning** (LELE) at 28 nm and below — _coloring_ of metal layers becomes a layout constraint; LVS includes coloring check.
- **Aging signoff** mandatory.
- **Verification effort**: full corner + HSMC + aging + LDE-aware extraction + EM/IR.

### 15.3 FinFET nodes (16 nm, 14 nm, 10 nm, 7 nm, 5 nm, 3 nm)

- **Fin quantization**: device width is discrete (number of fins). Mismatch scales as 1/√N_fin.
- **Self-heating**: confined geometry traps heat; junction temperature 20–60 K above ambient in active devices. Bulk FinFET STI depth (>100 nm) and SOI BOX thickness control Rth. PA-class power densities can degrade gm/gd by 30–40% from SH alone, and dramatically accelerate aging.
- **Quantum capacitance** and parasitic gate-fin-edge effects make traditional BSIM4 insufficient → BSIM-CMG (common-multi-gate) models. Be aware that the model's "self-heating node" (a thermal node `tnode`) must be enabled (`shmod=1`) for accurate analog simulation. Most foundry corner files default to OFF for digital-flow speed.
- **Layout-dependent effects**: WPE, NDE, OD-OD spacing, gate length end effect (GLE), CESL stress — all first-order. ALL matched analog **must** be LDE-extracted.
- **Multiple patterning** (LELE, LELELE, SADP, SAQP). Coloring constraints. Some metals are unidirectional (only horizontal _or_ only vertical).
- **Self-heating-aging coupling**: a hot device ages faster, hotter, _etc._. MOSRA/RelXpert must include self-heating; standard signoff includes EOL@SH.
- **EM**: J_max much lower (≤0.3 mA/µm at 7 nm); cobalt/ruthenium contacts replace tungsten; via EM is the dominant failure.
- **BTI** (both NBTI and PBTI) is fast and partially recoverable; aging models must include AC partial-recovery.
- **Vdd**: 0.7–0.9 V nominal core, with much narrower margin.
- **Random Dopant Fluctuation** is reduced (fully-depleted fin) but **line-edge roughness**, fin-thickness variation, and metal-grain WF variation dominate.

### 15.4 GAA / nanosheet (3 nm and below)

- **Stacked-nanosheet quantization** is even finer; mismatch ↓ further but layout LDE ↑.
- **Bonded backside power delivery (BPD)** at 2 nm and below changes EM/IR analysis — the analog block sits between front-side signal routing and back-side power.
- **EUV-only patterning** at the most-aggressive layers; stochastic edge effects appear as new variation sources.

### 15.5 Effect-by-node summary table

| Effect                          | 180 nm      | 65 nm         | 28 nm         | 14 nm FF    | 5 nm FF     | 3 nm GAA   |
| ------------------------------- | ----------- | ------------- | ------------- | ----------- | ----------- | ---------- |
| Random Vt mismatch (AVT, mV·µm) | 6           | 3             | 2             | 1.5/fin     | 1.0/fin     | <1.0/fin   |
| Self-heating                    | n/a         | small         | noticeable    | important   | dominant    | dominant   |
| WPE / LDE / STI                 | small       | yes           | yes           | mandatory   | mandatory   | mandatory  |
| Aging signoff                   | optional    | optional      | required      | required    | required    | required   |
| Multi-patterning                | no          | no            | LELE          | LELE/LELELE | SAQP+EUV    | EUV stoch. |
| EM J_max (M1)                   | ~1 mA/µm    | 0.7           | 0.5           | 0.4         | 0.3         | 0.25       |
| Vdd                             | 1.8/3.3/5 V | 1.0/1.2/2.5 V | 0.9/1.0/1.8 V | 0.75/0.9 V  | 0.65/0.75 V | 0.6/0.7 V  |

## 16. Design Review and Sign-off Red Flags

## 16. Design Review and Sign-off Red Flags

### 16.1 Waveform red flags

When reviewing transient waveforms before tapeout, the following patterns are warning signs:

- **Slow rise/fall on a node that should switch fast** — usually a wiring-RC issue or wrong device sizing.
- **Ringing / overshoot on a bias node** — instability or insufficient bias-line decap.
- **Drift on a "DC" node during long transient** — slow leakage or thermal drift; verify long-duration settling.
- **Asymmetric step response (faster going up than down)** — slew imbalance; will cause distortion.
- **Multiple zero-crossings at a comparator decision** — metastability or kickback ringing.
- **Sub-harmonic content on an oscillator output** — limit cycle / mode jump.
- **Glitches synchronous with a clock edge on an analog node** — clock feedthrough or substrate kick.
- **Output that "stalls" then recovers** — startup failure narrowly averted; failure-prone.
- **Slow settling that beats the spec by only 5–10%** — at silicon corners it will fail.
- **PSRR plot peaking** — internal resonance, will manifest as supply-tone in silicon.
- **Loop-gain phase margin under 45° at any PVT/load** — will oscillate at some unit in production.
- **DNL/INL exceeding ±0.5 LSB on histograms** — risk of missing codes.
- **MC histogram with heavy tails (non-Gaussian)** — yield extrapolation is unreliable; run HSMC.

### 16.2 Schematic / layout red flags

- Unconnected substrate pins on isolated devices.
- Body of a switch transistor not tied to source (charge sharing).
- Unbalanced gate-loading on a differential pair.
- Critical bias mirror with N=1 (no averaging of mismatch).
- Long high-Z node without ESD/floating-net protection.
- Capacitor common-centroid array with dummies missing on one side.
- Power straps narrower than 2× the minimum-EM width.
- A single via on a high-current connection (should be ≥2).
- A floating well that _could_ couple to a noisy node.
- An I/O pad without ESD primary clamp.

### 16.3 Common silicon-failure post-mortems

Reviewing MPW shuttle / academic / industry post-mortems, the recurring failure modes are:

1. **Bandgap fails to start** at cold-low-Vdd in a fraction of dice → insufficient startup margin or MC sample size was 100 (should be ≥1000 across PVT for startup).
2. **PLL fails to lock** at frequency extreme → divider/charge-pump bias under-margin at corner; cure with wider VCO range and CP bias trim.
3. **LDO oscillates** with customer's actual board → light-load PM was not verified at no-load.
4. **ADC has missing codes** at one end of scale → DAC cap mismatch + amp gain corner combine; cure with calibration.
5. **Comparator hangs / decision time long** in a fraction of decisions → metastability time was budgeted from typical, not 4σ.
6. **Reference moves with neighboring digital activity** → no deep-N-well isolation, substrate coupling.
7. **Chip resets randomly during high digital activity** → dynamic IR drop exceeded brown-out threshold.
8. **EM-induced shift** of a critical resistor after burn-in → undersized poly resistor at marginal current density.
9. **ESD failure** on a single pin → clamp bus broken at a layout edit late in tapeout.
10. **Crystal oscillator does not start** with the customer's crystal → Cload and ESR were not characterized against the customer's part.
11. **Sky130-specific**: subthreshold-biased OTA delivers 30% lower gm than simulated → known PDK weak-inversion modeling defect.
12. **Sky130-specific**: a DRC waiver missed because Magic DRC and KLayout DRC differed → tapeout sign-off must use KLayout deck.

### 16.4 Sign-off discipline

- **Two-person review** of every block before tapeout — designer + an independent senior reviewer with checklist.
- **Specification traceability matrix**: every spec line links to (a) the simulation that proves it, (b) the PVT corner that is worst-case, (c) the MC yield, (d) post-layout result, (e) margin.
- **Test plan in hand** before tapeout: every spec must have a test method on the planned ATE / lab setup.
- **DFT for analog**: every critical internal node should be observable (analog scan, IDDQ checkpoints, internal voltage outputs through analog mux).
- **Trim**: every absolute-parameter spec must be trimmable. Don't tape out a design that needs the bandgap to be ±0.5% without a trim.
- **Test structures on the same die / shuttle**: process control monitors (W-shaped resistor ladders, ring-oscillator-based PVT monitors, capacitor matched arrays, BJT diode pair, on-die temperature sensor).
- **Two-engineer signoff on every netlist version**: a hash of the as-taped-out netlist and GDS must be recorded.

## 17. When Simulation Diverges from Silicon — Mitigations and Bench Correlation

## 17. When Simulation Diverges from Silicon

### 17.1 Classes of effects that simulation often misses

- **Substrate coupling** — digital switching injects ~1–100 mA pulses into the substrate; couples to analog wells, bias generators, sample caps. _Not in any standard SPICE simulation_ unless an extracted substrate network is built. Mitigation: deep-N-well guard rings, separate substrate taps, separate analog pads, on-die substrate-sense test point.
- **Supply coupling / SSO bounce** — bondwire inductance + simultaneous switching causes 50–500 mV transient on VSS that schematics ignore (schematic VSS is ideal ground). Mitigation: include explicit bondwire L in transient testbenches; budget dynamic IR.
- **EMI ingress** — RF coupling to long bondwires, package pins, board traces. Especially for sub-µV nodes. Mitigation: filter every external interface, shield long high-Z nets.
- **On-die temperature gradients** — a hot LDO 1 mm away creates ~5 K gradient at the analog block; mismatch in a "matched" pair on opposite sides of the chip can be 0.5–1 mV. Mitigation: floorplan heat sources away from precision analog; on-die thermal sensors.
- **Self-heating** — already discussed for FinFET; for high-current analog (LDO pass FETs, drivers) self-heating shifts Vt and gm; the simulator may have SH disabled by default.
- **Model inaccuracy at extreme bias** — BSIM4 is fit best at typical Vds=Vdd/2, Vgs around 2-Vt. At Vds<50 mV (linear region) or at Vov<100 mV (subthreshold) accuracy degrades. Sky130 is particularly poor in subthreshold (Section 14).
- **Body / well noise** — well bias dynamic — through capacitive coupling from neighbors — modulates Vt. Rarely modeled. Mitigation: heavy well-strapping.
- **Quantum / process tail effects** — gate leakage, GIDL, RDF — only partially modeled.
- **Long-time-constant drift** — dielectric absorption in MIM caps, slow thermal time constants, hysteresis from trapped charge. Bench characterization required.
- **Package-induced strain** — molding-compound stress shifts BJT VBE and resistor values by 0.1–1%. Calibrate at known package.
- **PCB-driven feedback** — customer board can complete an unintended feedback loop (e.g., supply→reference→supply).
- **Test-equipment artifacts** — probe loading, scope BW limits, ATE socket parasitics can look like silicon failure but are test-setup issues.

### 17.2 Mitigation strategies — designing for unknown unknowns

1. **Overdesign margin** — engineering rule of thumb: target spec ±50%; design center at +25–50% above min spec. Worst-case simulation worst-case PVT MC should still pass with 10–20% extra margin.
2. **Trim and calibration** — every absolute-parameter spec must be trimmable. Foreground (factory) trim handles process; background calibration handles drift/aging.
3. **DFT (design for test)**: analog scan / analog mux to bring 4–8 critical internal nodes to a pad; pad-driven force/sense for current biases; on-die monitors (ring-oscillator-based PVT probe, BJT diode pair for temperature, resistor matched pair for sheet-R control).
4. **Test structures on the same die / scribe-line PCMs**: process-monitor structures for every device type, sized for direct DC probing on the wafer.
5. **Built-in self-test (BIST)** for digital, analog BIST or loopback for converters.
6. **Conservative aging margin** — at least 2× the expected EOL Δ.
7. **Graceful degradation** — design loops so that small mis-tracking shows as graceful spec degradation, not failure.
8. **Bring up plan** — engineering test plan with a defined order: power up, bias check, oscillator startup, PLL lock, ADC SNR, ..., each stage gating the next. If a chip fails, you should be able to localize the failure to within one block.

### 17.3 Bench-correlation loop

After first silicon, the correlation between bench and simulation feeds back into the verification methodology:

- For every measured-spec to simulated-spec delta >10%, identify root cause: model error, parasitic error, layout effect, or test-setup error.
- File model-improvement requests with the foundry.
- Update internal verification templates with new corner cases.
- Re-run pre-tapeout sign-off scripts on the next design iteration; any regression suite must catch the same defect.

This bench-correlation loop is the _only_ mechanism that incrementally closes the simulation-silicon gap. In open-source/sky130 world, this loop is the responsibility of the community — file PRs to the SkyWater model repo with measured data; this is what improved RF2 over RF and is starting to address subthreshold modeling.

# Master Pre-Tapeout Sign-off Checklist

The body of this report (Sections 1–17, recorded as sequential sections) constitutes the methodology. The following master checklist is the _sign-off ledger_ — every line must be marked PASS, WAIVED-with-justification, or FAIL-do-not-tape-out before authorizing GDS streamout. It is technology-agnostic; sky130-specific items are tagged `[sky130]`.

## A. Specification & Requirements

- [ ] Every spec line in the datasheet has a documented verification method
- [ ] Specification traceability matrix is complete (spec ↔ testbench ↔ result ↔ worst corner ↔ margin)
- [ ] Test plan exists for every spec on the planned ATE / bench
- [ ] Trim / calibration plan documented for every absolute-parameter spec
- [ ] DFT plan: ≥4 critical internal analog nodes brought out via pad or analog mux
- [ ] Built-in process / temperature / supply monitor on die
- [ ] Block-level and full-chip review by an independent senior reviewer signed

## B. Schematic Functional Verification

- [ ] DC operating point clean for every block (no devices in unintended region)
- [ ] AC small-signal: gain, BW, PM, GM, CMRR, PSRR, output impedance, input impedance reported
- [ ] Transient: startup (multiple ramp rates), power-on/off, brown-out, mode transitions
- [ ] Noise: `.noise` integrated, contributors identified; PNOISE for periodic circuits; transient noise for SAR/Δ-Σ
- [ ] Stability: Tian (`stb`) and/or Middlebrook on every loop, every PVT × every load condition; PM ≥ 45° everywhere
- [ ] Large-signal stability for switched circuits

## C. PVT Corner Coverage

- [ ] All process corners: TT, FF, SS, FS, SF, plus passive corners (rr_lo/hi, cc_lo/hi) `[sky130: include rc_lo/hi, cmim_lo/hi, cvpp_lo/hi]`
- [ ] VT-skew corners run where LVT + HVT or 1.8 V + 5 V devices are mixed `[sky130]`
- [ ] Temperature: at least Tmin−10, Tmin, T25, Tmax, Tmax+10 °C
- [ ] Supply: nominal ±10% (or as spec demands), plus a brown-out at 70% nominal
- [ ] Full cross of {process × temp × supply × passive × VT-skew} signoff sweep (~100–300 points)
- [ ] Every spec passes every corner with ≥15% margin or ≥3 stdev of MC

## D. Monte Carlo

- [ ] Combined process+mismatch MC on every block; 1000–10000 samples for ≤4σ specs
- [ ] HSMC (Solido / Spectre FMC / scaled-sigma) for any spec requiring ≥4.5σ yield, OR documented Gaussian extrapolation justification
- [ ] QQ plot inspected for non-Gaussian tail behavior
- [ ] Yield reported as AND-of-all-specs, not per-spec
- [ ] Trim range bracket ±3–4σ of nominal MC distribution
- [ ] Sky130 weak-inversion: 1.5–2× safety factor applied on simulated σ for sub-µV-class circuits `[sky130]`

## E. Post-Layout

- [ ] DRC clean in signoff deck (KLayout sky130A_mr for sky130, Calibre/IC-Validator for commercial) `[sky130: must match precheck deck]`
- [ ] LVS clean with parameter check; netgen for sky130 with proper pin-permute setup
- [ ] ERC: no floating gates, wells, missing taps, supply shorts
- [ ] Antenna check clean
- [ ] Density check (every metal/poly layer) min and max in every window
- [ ] Sealring + Latch-up well-tap spacing checked
- [ ] PEX in **R+C+CC (RCc)** mode for all analog/RF; full field-solver for high-precision matched arrays (SAR DAC, reference distribution)
- [ ] Pre- vs post-layout deltas reviewed; any spec change >5% explained physically
- [ ] All PVT and reduced MC re-run on extracted view
- [ ] Stability re-verified on extracted view

## F. EM / IR

- [ ] Static IR drop ≤3% of supply at every device terminal
- [ ] Dynamic IR drop ≤5% under worst-case switching
- [ ] EM Iavg, Irms, Ipeak limits met per layer (with ≥30% margin for vias)
- [ ] Power-grid connectivity verified
- [ ] On-die decap meets 10 pF/mA target
- [ ] `[sky130]` Hand-built EM check on high-current analog (LDOs, drivers), strap width ≥ 2× minimum

## G. Reliability / Aging

- [ ] HCI / NBTI / PBTI 10-year (or per-app) EOL spec passes at FF-hot-high corner
- [ ] TDDB / Vg_max / Vds_max gate-bias budget verified — no transient over-voltage exceeds limits at any node
- [ ] Aging-shifted PVT re-run for critical specs
- [ ] `[sky130]` Conservative bias budget (Vgs ≤ 90% nominal, Vds headroom ≥ 200 mV) applied since aging models are absent

## H. ESD / Latch-up

- [ ] HBM ≥ 2 kV pad-to-pad simulated; clamp triggers, gate-oxide BV not exceeded
- [ ] CDM ≥ 500 V (or 250 V for flip-chip) simulated per pin
- [ ] Clamp bus continuous, no I/O ring break
- [ ] Latch-up rules (well-tap spacing) met; JESD78E topology check passed
- [ ] Substrate noise mitigated (deep-N-well, separate VSSA pad, guard rings)
- [ ] `[sky130]` Use foundry I/O cells (sky130_fd_io\_\_\*); do not roll custom ESD

## I. Sub-block-Specific Sign-off

- [ ] Bandgap: TC, PSRR(f), startup MC ≥1000 samples, noise, trim range
- [ ] LDO: PSRR(f, Iload), line/load reg, full PM sweep over {load, Cload, ESR}, load-step droop
- [ ] PLL: lock time/range, phase noise spec (per-block + closed-loop behavioral cross-checked with transient noise), spurs <−60 dBc
- [ ] ADC: ENOB, DNL, INL, missing codes via histogram; PVT × MC; metastability for SAR/flash
- [ ] DAC: DNL, INL, settling, glitch energy, SFDR
- [ ] Comparator: σ(Voff) at 4–6σ tail, kickback charge, metastability τ
- [ ] OTA: Av0, GBW, SR±, CMRR, PSRR±, output swing, input CMR across PVT/MC
- [ ] Oscillator: startup MC, phase noise (close-in & far-out), pulling
- [ ] References / biasing: startup MC, trim, noise
- [ ] SC: charge injection, clock feedthrough, kT/C, settling at full clock
- [ ] RF: S-params, NF, IIP3, P1dB, stability (K>1) across band

## J. Package / PCB / Mixed-Signal

- [ ] Bondwire + package model included in supply / clock / RF transient sims
- [ ] Customer-board-realistic LDO load (caps + ESR) used in stability sims
- [ ] Crystal oscillator simulated with vendor crystal model + Cload spread
- [ ] Mixed-signal RNM model exists for every analog block; equivalence-checked against transistor at boundary
- [ ] Level shifters function during multi-supply startup window
- [ ] Async domain crossings have synchronizers with measured MTBF

## K. Final Tapeout-Day Checks

- [ ] GDS hash + netlist hash recorded with two-engineer signoff
- [ ] All DRC waivers documented, foundry-approved
- [ ] `[sky130]` mpw-precheck passes locally; KLayout signoff DRC clean; netlist in both `xschem/` and `netgen/`; `ciel`/`volare` PDK hash frozen
- [ ] Test plan reviewed; ATE/lab equipment availability confirmed
- [ ] Pad list, package pin-out, bond diagram, top-level pinout cross-verified against datasheet
- [ ] Engineering bring-up plan documented (sequence: supply ramp → bias → osc → PLL → ADC → ...)
- [ ] Two engineers independently re-confirm the GDS to be streamed matches the verified version

---

## Closing Notes

This document is a synthesis of contemporary industrial practice (Cadence, Synopsis, Siemens application notes; foundry sign-off methodologies down to 3 nm), classical analog references (Razavi _Design of Analog CMOS Integrated Circuits_, Sansen _Analog Design Essentials_, Allen–Holberg _CMOS Analog Circuit Design_, Maloberti _Analog Design for CMOS VLSI Systems_, Hastings _The Art of Analog Layout_, Pelgrom's mismatch model), open-source community knowledge (Tim Edwards / Efabless tooling, Murmann's ADC survey and Ngspice-on-Colab analyses, Kundert's Designer's Guide on PLL noise and stability, Tian _et al._ on small-signal stability, Wiedmann's loop-gain analyses, Caravan tapeout retrospectives), and lessons from MPW shuttle post-mortems on sky130.

No single chapter is sufficient on its own. The combination — and the discipline of formal sign-off against the checklist — is what brings simulated and silicon behavior into close enough agreement that first silicon meets specification. For open-source flows on sky130 the bench-correlation loop after each tapeout is the dominant means of closing remaining gaps; treat every tapeout as a model-and-flow improvement opportunity, and over-design margin generously in the absence of foundry-grade aging, EM/IR, and ESD signoff tooling.

The user is encouraged to maintain this checklist as a living document, augmenting it with team-specific test structures, MC-sample-size policies, and node-specific layout-effect rules as silicon experience accumulates.
