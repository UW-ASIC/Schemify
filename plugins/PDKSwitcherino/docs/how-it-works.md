# PDKSwitcherino — How It Works

PDKSwitcherino remaps analog circuit designs between Process Design Kits (PDKs) using the **gm/Id design methodology**. Instead of naively scaling transistor dimensions by technology ratios, it preserves each transistor's **operating point** — ensuring the remapped circuit behaves equivalently on the target process.

## The Problem

Switching an analog design between PDKs (e.g. SkyWater 130nm → GlobalFoundries 180nm) is not as simple as scaling W and L:

- **Different VDD** — a design at 1.8V doesn't directly map to 3.3V
- **Different L_min** — minimum channel lengths differ (0.15um vs 0.28um)
- **Different device physics** — threshold voltages, mobility, oxide thickness all change
- **Gain depends on L** — intrinsic gain Av = gm/gds changes with channel length

Linear scaling (W_new = W_old × L_min_ratio) ignores all of this. The result is a circuit that's biased in a completely different operating region.

## The gm/Id Methodology

The **gm/Id ratio** (transconductance efficiency) is a technology-independent measure of a MOSFET's inversion level:

| gm/Id (V⁻¹) | Region |
|---|---|
| 3–8 | Strong inversion |
| 8–15 | Moderate inversion |
| 15–25 | Weak inversion |

A transistor with gm/Id = 12 on sky130 is in the same relative operating region as one with gm/Id = 12 on GF180 — even though VDD, Vth, and device physics are completely different.

### Key insight

If we preserve gm/Id across PDKs, the transistor stays in the same inversion level. Combined with preserving drain current (Id), this uniquely determines the target W.

## Characterization

Before remapping, each device is **characterized** via DC sweeps:

1. Sweep Vgs at three Vds bias points (Vds_mid ± delta)
2. Extract gm = dId/dVgs and gds = dId/dVds
3. Compute: gm/Id, current density Jd = Id/W, intrinsic gain Av = gm/gds

This produces a **DeviceLUT** — a lookup table for a single (device, L) pair that maps between gm/Id, Jd, Vgs, and Av via interpolation.

```
DeviceLUT(device="sky130_fd_pr__nfet_01v8", L_um=0.5)
  gm/Id range: [2.1, 22.4] V⁻¹
  Lookups: gmid → Jd, gmid → Vgs, gmid → Av, Jd → gmid
```

## Remap Flow

Given a source transistor (model, W, L, Id):

### Step 1: Extract operating point from source

```
Jd_source = Id / (W × nf)           # current density (A/um)
gm/Id     = LUT_source.lookup(Jd)   # inversion level
Av_source = LUT_source.lookup_av(gm/Id)  # intrinsic gain
```

### Step 2: Find target dimensions

**Mode 1 — Av-preserving (multi-L families):**

Characterize the target device at multiple L values to build a `DeviceLUTFamily`. For each L, we know Av(gm/Id). Pick the L where Av best matches the source:

```
best_L = family.find_L_for_av(gm/Id, Av_source)
W_target = LUT_target[best_L].compute_w(gm/Id, Id)
```

This preserves both the inversion level AND the intrinsic gain — critical for amplifier stages where gain depends on device output resistance.

**Mode 2 — Single-L gm/Id:**

Scale L by the L_min ratio, then size W to preserve drain current at the same gm/Id:

```
L_target = L_source × (L_min_target / L_min_source)
W_target = LUT_target.compute_w(gm/Id, Id)
```

This preserves gm/Id but NOT intrinsic gain (since L is determined by a simple ratio, not gain matching).

### Step 3: Apply constraints

- Snap L to the target PDK's discrete length grid
- Split into multiple fingers if W exceeds max finger width
- Map model names (e.g. `sky130_fd_pr__nfet_01v8` → `nfet_03v3`)

## Why Bias Current Matters

The bias current is **required** because it determines the exact operating point. Without it, there's no way to know where on the gm/Id curve the transistor sits:

- A W=4um NFET at Id=10uA operates at a very different gm/Id than the same device at Id=100uA
- The same W and L can be in weak, moderate, or strong inversion depending on bias

For a 5-transistor OTA, the currents are determined by the topology:
- Diff pair (M1, M2): Ibias/2 each
- Active load (M3, M4): Ibias/2 each
- Tail source (M5): Ibias

## Multi-L Av Preservation

Intrinsic gain Av = gm/gds is strongly L-dependent:
- Longer L → lower gds (higher output resistance) → higher Av
- This relationship is monotonic: Av always increases with L

When switching from sky130 (L_min=0.15um) to GF180 (L_min=0.28um), a naive L_min ratio scaling gives L_target = L × 1.87. But this may overshoot or undershoot the gain.

The `DeviceLUTFamily` characterizes at all discrete L values:

```
GF180 NFET family:
  L=0.28um: Av=8.2 at gm/Id=10
  L=0.30um: Av=9.1
  L=0.35um: Av=12.3
  L=0.50um: Av=25.8
  L=1.00um: Av=89.4
  L=2.00um: Av=201.7
```

If the source has Av=30 at gm/Id=10, the algorithm picks L=0.50um (closest match) rather than L=0.93um (what L_min ratio would give). The result is a real, manufacturable L value with a known, characterized Av.

## Supported PDKs

| PDK | VDD | L_min | NFET | PFET |
|---|---|---|---|---|
| SkyWater 130nm | 1.8V | 0.15um | sky130_fd_pr__nfet_01v8 | sky130_fd_pr__pfet_01v8 |
| IHP SG13G2 | 1.2V | 0.13um | sg13_lv_nmos | sg13_lv_pmos |
| GF 180nm MCU | 3.3V | 0.28um | nfet_03v3 | pfet_03v3 |

## Example

Remap a 5T OTA from sky130 to GF180 (Av-preserving mode):

```
PDK Switch: SkyWater 130nm → GlobalFoundries 180nm MCU (gm/Id multi-L Av-preserving)
  VDD: 1.8V → 3.3V
  L_min: 0.15um → 0.28um

  XM1 (diff pair NFET): gm/Id=13.2 V⁻¹
    W: 4u → 2.8u   L: 0.5u → 0.5u   (Av: 28→26)
  XM3 (load PFET): gm/Id=11.8 V⁻¹
    W: 8u → 5.1u   L: 0.5u → 1.0u   (Av: 35→33)
  XM5 (tail NFET): gm/Id=8.4 V⁻¹
    W: 4u → 1.9u   L: 1.0u → 2.0u   (Av: 85→91)
```

Notice:
- W decreased (GF180's wider devices carry more current per um)
- L was chosen per-device to match intrinsic gain, not by a global ratio
- gm/Id preserved → same inversion level → equivalent small-signal behavior

## References

- B. Murmann, "Systematic Design of Analog CMOS Circuits Using Pre-Computed Lookup Tables," IEEE TCAS-I, 2011
- P. Jespers & B. Murmann, *Systematic Design of Analog CMOS Circuits*, Cambridge University Press, 2017
