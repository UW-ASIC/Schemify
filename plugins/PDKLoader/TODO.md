# PDKLoader TODO

## Phase 3 — Remaining Work

### Operating Point Extraction (3b)
- [ ] Add ABI v6 message `getState("instances")` (or new host→plugin message) to let PDKLoader read MOSFET/BJT instances + properties from the active schematic
- [ ] Run per-device ngspice OP sim to extract actual bias (VGS, VDS, VSB, ID, gm, gds, Cgg, ft) — NOT hardcoded VDD/2
- [ ] For BJTs: extract IC, β, fT from OP sim
- [ ] Populate `DeviceInstance.bias_valid = true` with real data before calling `computeRemap`
- [ ] Replace mock instances in `onMigrateClicked` with real schematic data once ABI supports it

### LUT Generation (3a)
- [x] Add Cgg and ft columns to ngspice sweep netlist (`@m.xm1.m0[cgg]`, computed ft = gm/(2π·Cgg))
- [x] Add VSB sweep dimension (4-point: 0, 0.2, 0.4, 0.6V with per-VSB raw files merged)
- [x] Handle PDK model path variations (multi-corner: ff/ss/sf/fs, multi-voltage: 1v8/3v3/5v)
- [x] ngspice `wrdata` device parameter names vary per PDK — detect correct `@m.` prefix via `detectDevicePrefix()`
- [x] Backward-compatible TSV parser (5/6/8-column formats)

### Remap Algorithm (3c)
- [x] 2D interpolation in LUT (bilinear between VGS/VDS grid points) instead of nearest-neighbor
- [x] BJT remap: target PDK's IS parameter to scale emitter area (`area_dst = area_src * IS_src / IS_dst`)
- [x] L grid snapping: round L' to nearest available discrete L in target PDK via `snapToGrid()`
- [x] nf optimization: if W' > max_finger_width, increase nf to keep W_per_finger reasonable
- [x] ft sanity check: load actual Cgg from LUT to compute ft_dst = gm_dst / (2π·Cgg_dst), flag if >30% deviation
- [x] Multi-VT support: VtFlavor enum + VtAvailability per PDK + mapVtFlavor() with fallback priority
- [x] Warnings packed struct (ft_deviation, nf_adjusted, vt_fallback, bjt_area_guess)

### UI Integration (3d)
- [x] "Migrate: src → dst" button in panel — shows when source≠target and both LUTs exist
- [x] Diff table: Device | Old W/L | New W/L | Δft% | Status (up to 20 rows + truncation)
- [x] Confirm/cancel buttons (Apply Changes / Cancel)
- [x] Emit changes through pushCommand("pdk_remap", "set_prop:...") for undoable batch edit
- [x] Flag unresizable devices with [!], no_match with [x], no_bias with [?]
- [x] Passives (R/C/L) shown as "unchanged" in diff table
- [x] Summary counts: "N ok, N warning, N unchanged"
- [ ] Map device names to instance indices once ABI queryInstances returns name→index mapping

### General
- [x] Support more PDK families: sky130B, gf180mcuA/B/C, ihp-sg13g2 (forward-compat)
- [x] IHP SG13G2 PdkParams (provisional)
- [x] Handle case where ngspice is not installed (detectNgspice + install hint in panel)
- [x] Configurable PdkParams via `~/.config/Schemify/PDKLoader/<pdk>/params.toml` overrides
- [ ] Test with real sky130→gf180 conversion on a reference design
