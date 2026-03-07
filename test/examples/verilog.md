# Fixtures With Verilog Stimulus

These fixtures contain embedded Verilog-style content in `V { ... }` blocks
(detected by keywords like `assign`, `wire`, `always`, `module`, `initial`).

## Current manifest fixtures

- `test/examples/xschem_sky130/mips_cpu/alu.sch`
- `test/examples/xschem_sky130/mips_cpu/aludec.sch`
- `test/examples/xschem_sky130/mips_cpu/datapath.sch`
- `test/examples/xschem_sky130/mips_cpu/dmem.sch`
- `test/examples/xschem_sky130/mips_cpu/imem.sch`
- `test/examples/xschem_sky130/mips_cpu/maindec.sch`
- `test/examples/xschem_sky130/mips_cpu/regfile.sch`
- `test/examples/xschem_sky130/mips_cpu/sign_extend.sch`
- `test/examples/xschem_sky130/mips_cpu/tb.sch`
- `test/examples/xschem_sky130/sky130_tests/lvtnot.sch`
- `test/examples/xschem_sky130/sky130_tests/not.sch`
- `test/examples/xschem_sky130/sky130_tests/tb_diff_amp.sch`
- `test/examples/xschem_core_examples/greycnt.sch`
- `test/examples/xschem_core_examples/xnor.sch`

## Notes

- This list is based on `test/core/fixture_manifest.zig`.
- If fixtures change, regenerate/update this list by scanning manifest `.sch` files
  for `V {` plus Verilog keywords.
