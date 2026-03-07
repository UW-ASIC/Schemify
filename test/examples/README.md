# Test Example Fixtures

This directory contains fixture data used by `test/core/test_e2e_examples.zig`.

## Active fixture sources

- `xschem_core_examples/`
  - Upstream: `https://github.com/StefanSchippers/xschem`
  - Source path: `xschem_library/examples`
  - Included subset: only `.sch` files that have a same-name `.sym`.
- `xschem_sky130/`
  - Upstream: `https://github.com/StefanSchippers/xschem_sky130`
  - Used as-is for additional real-world xschem-origin fixtures.

## Why `sky130_schematics` is no longer used for parity tests

The parity suite now compares Schemify output directly against xschem CLI output on
xschem-origin fixture sets. The previous `sky130_schematics` flow used a separate
custom netlisting script path and is no longer part of the mixed-source parity test.

## Refreshing `xschem_core_examples`

Run from project root:

```sh
rm -rf /tmp/xschem_examples_tmp
git clone --depth 1 --filter=blob:none --sparse https://github.com/StefanSchippers/xschem.git /tmp/xschem_examples_tmp
git -C /tmp/xschem_examples_tmp sparse-checkout set xschem_library/examples
rm -rf test/examples/xschem_core_examples
mkdir -p test/examples/xschem_core_examples
python3 - <<'PY'
import shutil
from pathlib import Path

src = Path('/tmp/xschem_examples_tmp/xschem_library/examples')
dst = Path('test/examples/xschem_core_examples')

for sch in sorted(src.glob('*.sch')):
    sym = sch.with_suffix('.sym')
    if not sym.exists():
        continue
    shutil.copy2(sch, dst / sch.name)
    shutil.copy2(sym, dst / sym.name)
PY

# Regenerate comptime fixture manifest used by tests
python3 - <<'PY'
from pathlib import Path

root = Path('.')
roots = [root / 'test/examples/xschem_sky130', root / 'test/examples/xschem_core_examples']
cases = []
for r in roots:
    for sch in sorted(r.rglob('*.sch')):
        sym = sch.with_suffix('.sym')
        if sym.exists():
            cases.append((sch.as_posix(), sym.as_posix()))

out = root / 'test/core/fixture_manifest.zig'
with out.open('w', encoding='utf-8') as f:
    f.write('pub const Case = struct {\\n')
    f.write('    sch_path: []const u8,\\n')
    f.write('    sym_path: []const u8,\\n')
    f.write('};\\n\\n')
    f.write('pub const cases = [_]Case{\\n')
    for sch, sym in cases:
        f.write(f'    .{{ .sch_path = \"{sch}\", .sym_path = \"{sym}\" }},\\n')
    f.write('};\\n')
PY
```
