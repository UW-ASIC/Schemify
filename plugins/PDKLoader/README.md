## EasyPDKLoader

EasyPDKLoader is a native plugin (`libEasyPDKLoader.so`) that embeds Python via
`libpython` at runtime. On plugin init it:

1. Installs Volare Python dependencies (`pip install -U volare`) best-effort.
2. Locates one or more `xschem/` trees:
   - explicit `EASYPDK_XSCHEM_DIR`, or
   - variant scan under `$PDK_ROOT/<variant>/libs.tech/xschem`
3. Converts all `.sch` fixtures under each tree into Schemify files:
   - `.chn` when a sibling `.sym` exists
   - `.chn_tb` when no sibling `.sym` exists

The conversion is performed by the bundled helper executable `easy_pdk_convert`.

### Environment controls

- `EASYPDK_XSCHEM_DIR`: explicit input `xschem` directory.
- `EASYPDK_VARIANTS`: comma-separated PDK variants (default: `sky130A,ibp180,gf180mcuD`).
- `EASYPDK_SCHEMIFY_DIR`: output root directory (default: `./schemify`, with per-variant subdirs).
- `EASYPDK_AUTO_RUN`: set to `0`/`false`/`no` to disable auto conversion.
- `PDK_ROOT`, `PDK`: fallback discovery for the input xschem path.

## Tests

Run plugin tests:

`zig build test`

Current suite focuses on variant resolution behavior for Volare-style layouts
(e.g. `sky130A`, `ibp180`, `gf180mcuD`).