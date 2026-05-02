# PDKSwitcherino Plugin

Cross-PDK circuit remapping with gm/Id-preserving transistor resizing.

## Commands

```
plugin pdkswitch                     — open panel, remap with current selections
plugin pdkswitch <target>            — remap to target PDK (auto-detect source)
plugin pdkswitch <source> <target>   — remap from source to target PDK
```

## Supported PDKs

| Key | Display Name | VDD | L_min |
|-----|-------------|-----|-------|
| `sky130A` | SkyWater 130nm | 1.8V | 0.15um |
| `ihp-sg13g2` | IHP 130nm SiGe BiCMOS | 1.2V | 0.13um |
| `gf180mcuA` | GlobalFoundries 180nm | 3.3V | 0.28um |

## Model Mapping

### sky130A
- `sky130_fd_pr__nfet_01v8` (nfet)
- `sky130_fd_pr__pfet_01v8` (pfet)
- `sky130_fd_pr__nfet_01v8_lvt` (nfet_lvt)
- `sky130_fd_pr__pfet_01v8_lvt` (pfet_lvt)
- `sky130_fd_pr__nfet_01v8_hvt` (nfet_hvt)
- `sky130_fd_pr__pfet_01v8_hvt` (pfet_hvt)

### ihp-sg13g2
- `sg13_lv_nmos` (nfet)
- `sg13_lv_pmos` (pfet)
- `sg13_hv_nmos` (nfet_hv)
- `sg13_hv_pmos` (pfet_hv)

### gf180mcuA
- `nfet_03v3` (nfet)
- `pfet_03v3` (pfet)
- `nfet_05v0` (nfet_hv)
- `pfet_05v0` (pfet_hv)

## Remap Modes

| Mode | Description |
|------|-------------|
| Linear scaling | Default. Scales W/L by VDD and L_min ratios |
| gm/Id LUT | Higher accuracy. Requires `pdk_switcherino` library with LUT data |

## Flow

1. Auto-detect source PDK from model names in schematic
2. Select target PDK
3. Preview: model mapping table, before/after W/L/nf for each MOSFET
4. **BLOCK** if any model has no mapping (hard error, cannot apply)
5. Apply: updates model, W, L, nf properties via `set_instance_prop()`

## Safety

- Unmapped models block the apply step entirely
- Preview always shown before applying
- Schematic changes invalidate the preview (must re-remap)

## Volare Integration

If `volare` is installed (`pip install volare`), the plugin detects installed PDKs
and shows their status in the panel.

## Example

```
plugin pdkswitch sky130A gf180mcuA
```

This remaps all MOSFETs from SkyWater 130nm to GlobalFoundries 180nm,
adjusting W/L for the different VDD (1.8V -> 3.3V) and minimum lengths.

## Workflow for LLM

1. Create or open a schematic with MOSFETs using a specific PDK's model names
2. Run: `plugin pdkswitch sky130A ihp-sg13g2`
3. The plugin auto-detects, previews, and (if no errors) applies the remap
4. Save the file after remapping
