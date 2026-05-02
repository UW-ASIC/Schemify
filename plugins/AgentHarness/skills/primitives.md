# Primitive Kinds

All primitives available for `place` and `insert` commands.

## MOSFET

| Kind | SPICE Prefix | Pins |
|------|-------------|------|
| `nmos4` / `nmos` | M | d (drain), g (gate), s (source), b (bulk) |
| `pmos4` / `pmos` | M | d, g, s, b |
| `nmos3` | M | d, g, s |
| `pmos3` | M | d, g, s |

Common properties: `W`, `L`, `nf`, `model`

Example:
```
place nmos4 M1 100 200
set-prop 0 W 10u
set-prop 0 L 180n
set-prop 0 model nch
```

## Passive

| Kind | SPICE Prefix | Pins |
|------|-------------|------|
| `resistor` | R | p, n |
| `capacitor` | C | p, n |
| `inductor` | L | p, n |

Property: `value` (e.g., `10k`, `1p`, `100n`)

## Diode

| Kind | SPICE Prefix | Pins |
|------|-------------|------|
| `diode` | D | anode, cathode |
| `zener` | D | anode, cathode |

## BJT

| Kind | SPICE Prefix | Pins |
|------|-------------|------|
| `npn` | Q | collector, base, emitter |
| `pnp` | Q | collector, base, emitter |

## JFET

| Kind | SPICE Prefix | Pins |
|------|-------------|------|
| `njfet` | J | d, g, s |
| `pjfet` | J | d, g, s |

## Sources

| Kind | SPICE Prefix | Pins |
|------|-------------|------|
| `vsource` | V | p, n |
| `isource` | I | p, n |

Properties: `value`, `dc`, `ac`, `type` (pulse, sin, etc.)

## Controlled Sources

| Kind | SPICE Prefix | Pins |
|------|-------------|------|
| `vcvs` | E | p, n, cp, cn |
| `vccs` | G | p, n, cp, cn |
| `ccvs` | H | p, n, cp, cn |
| `cccs` | F | p, n, cp, cn |

## Power / Ground

| Kind | Net Injected | Pins |
|------|-------------|------|
| `gnd` | `0` | gnd |
| `vdd` | `VDD` | vdd |

These are special symbols that inject a named net at their pin.

## Pin Symbols

| Kind | Description |
|------|-------------|
| `input_pin` | Schematic input port |
| `output_pin` | Schematic output port |
| `inout_pin` | Bidirectional port |
| `lab_pin` | Net label (names a wire) |

Pin property: `net_name` — the net this pin represents.

## Other

| Kind | Description |
|------|-------------|
| `probe` | Voltage probe |
| `ammeter` | Current probe |
| `tline` | Transmission line |
| `vswitch` | Voltage-controlled switch |
| `iswitch` | Current-controlled switch |
| `generic` | Generic symbol |

## SPICE Value Suffixes

| Suffix | Multiplier |
|--------|-----------|
| `T` | 10^12 |
| `G` | 10^9 |
| `MEG` / `M` | 10^6 |
| `k` / `K` | 10^3 |
| `m` | 10^-3 |
| `u` | 10^-6 |
| `n` | 10^-9 |
| `p` | 10^-12 |
| `f` | 10^-15 |

Examples: `10k` = 10000, `180n` = 180e-9, `1p` = 1e-12

## Coordinate System

- Origin at (0, 0), Y increases downward
- Default grid snap: 10 units
- Rotation: 0 (0deg), 1 (90deg), 2 (180deg), 3 (270deg)
- Flip: horizontal mirror

## Typical Spacing

- Instance spacing: 100-200 units apart
- Pin offset from body: 40 units
- Wire segments align to grid (multiples of 10)
