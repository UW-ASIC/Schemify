# PDK Switching

`circuit.switch_pdk()` remaps a realistic analog circuit from one open-source PDK to another. It preserves circuit behavior by matching gm/Id operating points and — when characterization data is available — intrinsic gain (Av = gm/gds).

## Quick Start

```python
from ccreator import realistic, Port

@realistic.analog
class DiffPair:
    ports = [Port('inp', 'input', 'analog'), Port('inn', 'input', 'analog'),
             Port('out_p', 'output', 'analog'), Port('out_n', 'output', 'analog'),
             Port('vdd', 'inout', 'voltage'), Port('vss', 'inout', 'voltage')]

    def build(self, n):
        n.MOSFET('M1', 'out_p', 'inp', 'tail', 'vss', 'sky130_fd_pr__nfet_01v8', W='5u', L='0.5u')
        n.MOSFET('M2', 'out_n', 'inn', 'tail', 'vss', 'sky130_fd_pr__nfet_01v8', W='5u', L='0.5u')
        n.MOSFET('M3', 'out_p', 'out_p', 'vdd', 'vdd', 'sky130_fd_pr__pfet_01v8', W='10u', L='0.5u')
        n.MOSFET('M4', 'out_n', 'out_p', 'vdd', 'vdd', 'sky130_fd_pr__pfet_01v8', W='10u', L='0.5u')
        n.MOSFET('M5', 'tail', 'vbias', 'vss', 'vss', 'sky130_fd_pr__nfet_01v8', W='20u', L='1u')

pair = DiffPair()

# Remap to GF180MCU — returns a SPICE netlist string
gf180_spice = pair.switch_pdk('gf180mcuA')
print(gf180_spice)
```

The returned string contains the remapped `.subckt` with GF180MCU model names and rescaled W/L.

## API

```python
circuit.switch_pdk(
    target: str,             # Target PDK name
    source: str | None = None,  # Source PDK name (auto-detected if None)
    use_lut: bool = True,    # Attempt gm/Id LUT-based remap
) -> str                     # Remapped SPICE netlist string
```

### Parameters

| Parameter | Description |
|-----------|-------------|
| `target` | PDK name to remap to. Must be a registered PDK: `"sky130A"`, `"gf180mcuA"`, `"ihp-sg13g2"`. |
| `source` | PDK name to remap from. If `None`, auto-detected by scanning model names in the netlist against the PDK registry. |
| `use_lut` | If `True`, attempts to build gm/Id lookup tables via ngspice characterization sweeps. If characterization fails (no ngspice, no PDK installed), falls back to linear scaling. |

### Auto-Detection

When `source=None`, CCreator scans the SPICE netlist for known model names:

| Model pattern | Detected PDK |
|---|---|
| `sky130_fd_pr__nfet_*`, `sky130_fd_pr__pfet_*` | `sky130A` |
| `sg13_lv_nmos`, `sg13_lv_pmos`, `sg13_hv_*` | `ihp-sg13g2` |
| `nfet_03v3`, `pfet_03v3`, `nfet_05v0`, `pfet_05v0` | `gf180mcuA` |

If no match is found, a `CircuitDefinitionError` is raised asking you to pass `source=` explicitly.

## Supported PDKs

| PDK | Name | VDD | L_min | Models |
|-----|------|-----|-------|--------|
| SkyWater 130nm | `sky130A` | 1.8 V | 0.15 um | `sky130_fd_pr__nfet_01v8`, `__pfet_01v8`, `__*_lvt`, `__*_hvt` |
| IHP SG13G2 | `ihp-sg13g2` | 1.2 V | 0.13 um | `sg13_lv_nmos`, `sg13_lv_pmos`, `sg13_hv_*` |
| GF 180nm MCU | `gf180mcuA` | 3.3 V | 0.28 um | `nfet_03v3`, `pfet_03v3`, `nfet_05v0`, `pfet_05v0` |

### Registering a Custom PDK

```python
from ccreator.pdk_switcherino import PDK, register_pdk

my_pdk = PDK(
    name='my_pdk',
    display='My Custom PDK',
    vdd=1.2,
    l_min=0.18e-6,
    nfet='my_nfet',
    pfet='my_pfet',
    model_lib='libs.ref/sky130_fd_pr/spice/sky130_fd_pr__tt.pm3.spice',
    corner='tt',
    corners=['tt', 'ff', 'ss'],
    discrete_lengths=[0.18, 0.25, 0.5, 1.0, 2.0],  # in um
    device_map={
        'generic_nfet': 'my_nfet',
        'generic_pfet': 'my_pfet',
    },
)
register_pdk(my_pdk)
```

## Remapping Methodology

CCreator uses three remapping modes, tried in priority order:

### Mode 1: Av-Preserving Multi-L (Best Quality)

**Goal:** Preserve both the gm/Id operating point and the intrinsic gain Av = gm/gds.

**How it works:**

1. **Characterize** the source device at its current L — extract gm/Id, Jd (current density), and Av from a Vgs sweep at 3 Vds points.
2. **Characterize** the target device at multiple L values (the PDK's `discrete_lengths`).
3. For each source MOSFET:
   - Compute the source operating point: `Jd_src = Id / (W_src * 1e-6)`, then `gmid_src = lookup(Jd_src)`.
   - Look up the source gain: `Av_src = lookup_av(gmid_src)`.
   - **Find the target L** that produces the same Av at the same gm/Id: scan the target multi-L family for `argmin |Av_tgt(L, gmid) - Av_src|`.
   - **Size W** to maintain the same drain current: `W_tgt = Id_src / Jd_tgt(gmid_src)`.

**Result:** The remapped circuit preserves gain, bandwidth characteristics, and current levels across PDKs. In testing, this reduces gain spread from ~13 dB (linear scaling) to ~4 dB across sky130 / IHP / GF180.

**Requires:** ngspice + installed PDK models for both source and target.

### Mode 2: Single-L gm/Id Remap

**Goal:** Preserve gm/Id operating point with proportional L scaling.

1. Scale L proportionally: `L_tgt = L_src * (L_min_tgt / L_min_src)`.
2. Snap to nearest discrete L in the target PDK.
3. Look up Jd at the source gm/Id for the target device at the snapped L.
4. Size W: `W_tgt = Id_src / Jd_tgt`.

**Result:** Preserves current density and transconductance efficiency. Does not preserve gain (gds changes with L).

**Requires:** ngspice + installed PDK models.

### Mode 3: Linear Fallback

**Goal:** Quick approximation when no simulation tools are available.

```
W_tgt = W_src * (VDD_src / VDD_tgt) * (L_min_tgt / L_min_src)
L_tgt = L_src * (L_min_tgt / L_min_src)
```

**Result:** Rough scaling. Useful for initial exploration, not for final design.

**Requires:** Nothing beyond PDK metadata (VDD, L_min).

## Model Mapping

Each PDK defines a `device_map` that maps generic device names to PDK-specific models. When switching PDKs, the switcher looks up the source model in the source PDK's map, finds the corresponding generic name, then resolves it in the target PDK's map.

Direct mappings are also maintained for common models:

| sky130 | GF180MCU | IHP SG13G2 |
|--------|----------|------------|
| `sky130_fd_pr__nfet_01v8` | `nfet_03v3` | `sg13_lv_nmos` |
| `sky130_fd_pr__pfet_01v8` | `pfet_03v3` | `sg13_lv_pmos` |
| `sky130_fd_pr__nfet_01v8_lvt` | `nfet_03v3` | `sg13_lv_nmos` |
| `sky130_fd_pr__nfet_01v8_hvt` | `nfet_05v0` | `sg13_hv_nmos` |

## Characterization Details

Characterization runs a DC sweep of Vgs at three Vds points (Vdd/2 +/- 50mV):

```
Vgs: 0 → VDD, step = 10mV
Vds: VDD/2 - 0.05, VDD/2, VDD/2 + 0.05
```

From the sweep data:

- **gm** = dId/dVgs (finite difference)
- **gds** = dId/dVds (from the 3 Vds points)
- **gm/Id** = gm / Id
- **Jd** = Id / W (current density, A/um)
- **Av** = gm / gds (intrinsic gain)

Subthreshold noise is filtered: `Id_floor = max(Id_mid.max() * 1e-5, 1e-9)`.

Results are cached as `.npz` files in `~/.cache/pdk_switcherino/lut/`.

### Interpolation

| Lookup | Method | Reason |
|--------|--------|--------|
| gm/Id -> Jd | Cubic spline | Smooth, well-behaved data |
| gm/Id -> Vgs | Cubic spline | Smooth, well-behaved data |
| gm/Id -> Av | **Linear** | Av data is noisy at extreme gm/Id; cubic spline oscillates |
| Jd -> gm/Id | Cubic spline | Inverse lookup |

## Direct Subpackage Usage

You can use the PDK switcher directly without the circuit wrapper:

```python
from ccreator.pdk_switcherino import PDKSwitcher, get_pdk, auto_root, get_lut
from ccreator.pdk_switcherino.characterize import DeviceLUTFamily

src = auto_root(get_pdk('sky130A'))
tgt = auto_root(get_pdk('gf180mcuA'))

switcher = PDKSwitcher(src, tgt)

# Load single-L LUTs
src_nfet = get_lut(src, src.nfet, 'nmos', src.l_min * 1e6)
src_pfet = get_lut(src, src.pfet, 'pmos', src.l_min * 1e6)
tgt_nfet = get_lut(tgt, tgt.nfet, 'nmos', tgt.l_min * 1e6)
tgt_pfet = get_lut(tgt, tgt.pfet, 'pmos', tgt.l_min * 1e6)

switcher.load_luts(src_nfet, src_pfet, tgt_nfet, tgt_pfet)

# Remap a single device
result = switcher.remap_device(
    model='sky130_fd_pr__nfet_01v8',
    w=5e-6, l=0.5e-6, nf=1,
    bias_current=50e-6,
)
print(f"New model: {result.model}, W={result.w:.2e}, L={result.l:.2e}")

# Or remap an entire SPICE netlist
remapped = switcher.remap_netlist(spice_string, bias_currents={'M1': 25e-6, 'M2': 25e-6})
```

## Volare Integration

CCreator auto-detects installed PDKs via environment variables and the Volare PDK manager:

```python
from ccreator.pdk_switcherino import installed_pdks, pdk_root

print(installed_pdks())   # ['sky130A', 'gf180mcuA']
print(pdk_root('sky130A'))  # PosixPath('/home/user/.volare/sky130A')
```

Environment variables checked: `SKY130_PDK_ROOT`, `GF180_PDK_ROOT`, `IHP_PDK_ROOT`. Falls back to `~/.volare/`.
