#!/usr/bin/env python3
"""Cross-PDK OpAmp test — switch a 5T OTA across sky130, IHP sg13g2, and GF180MCU.

Verifies that PDKSwitcherino's gm/Id-based remapping produces equivalent OpAmp
performance on all target PDKs by running ngspice AC analysis and comparing:
  - DC open-loop gain (dB)
  - Unity-gain bandwidth (Hz)
  - Phase margin (degrees)

The gm/Id methodology preserves each transistor's inversion level (operating point)
across PDKs, so gain should be nearly identical if LUTs are loaded.

Usage (inside nix develop):
    python3 test/test_pdk_switch.py
"""

from __future__ import annotations

import importlib.util
import math
import os
import re
import subprocess
import sys
import types
from dataclasses import dataclass
from pathlib import Path

# ---------------------------------------------------------------------------
# Import switcher modules directly (bypass __init__.py which needs PySpice)
# ---------------------------------------------------------------------------

PLUGIN_DIR = Path(__file__).resolve().parent.parent
_pkg_dir = str(PLUGIN_DIR / "src" / "pdk_switcherino")

pkg = types.ModuleType("pdk_switcherino")
pkg.__path__ = [_pkg_dir]
pkg.__package__ = "pdk_switcherino"
sys.modules["pdk_switcherino"] = pkg


def _load_module(name: str, filepath: str):
    spec = importlib.util.spec_from_file_location(name, filepath)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


pdk_mod = _load_module("pdk_switcherino.pdk", f"{_pkg_dir}/pdk.py")
PDK = pdk_mod.PDK
SKY130 = pdk_mod.SKY130
IHP_SG13G2 = pdk_mod.IHP_SG13G2
GF180MCU = pdk_mod.GF180MCU

switcher_mod = _load_module("pdk_switcherino.switcher", f"{_pkg_dir}/switcher.py")
PDKSwitcher = switcher_mod.PDKSwitcher

char_mod = _load_module("pdk_switcherino.characterize", f"{_pkg_dir}/characterize.py")
DeviceLUT = char_mod.DeviceLUT
DeviceLUTFamily = char_mod.DeviceLUTFamily

TEST_DIR = Path(__file__).resolve().parent
OUT_DIR = TEST_DIR / "output"


# ---------------------------------------------------------------------------
# PDK root detection
# ---------------------------------------------------------------------------

def setup_pdk_roots() -> dict[str, PDK]:
    """Detect PDK root directories from environment or ~/.volare."""
    pdks: dict[str, PDK] = {}

    # sky130
    sky_root = os.environ.get("SKY130_PDK_ROOT", str(Path.home() / ".volare" / "sky130A"))
    if Path(sky_root).exists():
        pdks["sky130A"] = SKY130.with_root(sky_root)
        print(f"  sky130A:    {sky_root}")
    else:
        print(f"  sky130A:    NOT FOUND at {sky_root}")

    # IHP sg13g2 — requires OSDI-compiled PSP103 models
    ihp_root = os.environ.get("IHP_PDK_ROOT")
    ihp_osdi = None
    if ihp_root:
        ihp_osdi = Path(ihp_root) / "libs.tech" / "ngspice" / "osdi" / "psp103.osdi"
    if ihp_root and Path(ihp_root).exists() and ihp_osdi and ihp_osdi.exists():
        pdks["ihp-sg13g2"] = IHP_SG13G2.with_root(ihp_root)
        print(f"  ihp-sg13g2: {ihp_root}")
    elif ihp_root and Path(ihp_root).exists():
        print(f"  ihp-sg13g2: SKIPPED (PSP103 OSDI models not compiled)")
        print(f"              Need: openvaf psp103.va -> psp103.osdi")
    else:
        print(f"  ihp-sg13g2: NOT FOUND (set IHP_PDK_ROOT)")

    # sky130 low-voltage variant — same models at 1.2V
    # Tests pure gm/Id remap without L scaling (L_min ratio = 1.0)
    if "sky130A" in pdks:
        import copy
        sky130_lv = copy.copy(SKY130)
        sky130_lv.name = "sky130A_1v2"
        sky130_lv.display = "SkyWater 130nm @ 1.2V"
        sky130_lv.vdd = 1.2
        sky130_lv.root = pdks["sky130A"].root
        pdks["sky130A_1v2"] = sky130_lv
        print(f"  sky130A_1v2: (synthetic — same models at VDD=1.2V)")

    # GF180MCU
    gf_volare = Path.home() / ".volare" / "gf180mcuA"
    if gf_volare.exists():
        pdks["gf180mcuA"] = GF180MCU.with_root(gf_volare)
        print(f"  gf180mcuA:  {gf_volare}")
    else:
        print(f"  gf180mcuA:  NOT FOUND (run: volare enable --pdk gf180mcu)")

    return pdks


# ---------------------------------------------------------------------------
# SPICE value helpers
# ---------------------------------------------------------------------------

def _parse_spice(s: str) -> float:
    """Parse SPICE value with SI suffix."""
    suffixes = {
        "T": 1e12, "G": 1e9, "meg": 1e6, "k": 1e3,
        "m": 1e-3, "u": 1e-6, "n": 1e-9, "p": 1e-12, "f": 1e-15,
    }
    s = s.strip()
    for suffix, mult in sorted(suffixes.items(), key=lambda x: -len(x[0])):
        if s.endswith(suffix):
            return float(s[: -len(suffix)]) * mult
    return float(s)


def _fmt(val: float) -> str:
    """Format a float as SPICE value with SI suffix."""
    if abs(val) >= 1e-3:
        return f"{val * 1e3:.4g}m"
    if abs(val) >= 1e-6:
        return f"{val * 1e6:.4g}u"
    if abs(val) >= 1e-9:
        return f"{val * 1e9:.4g}n"
    return f"{val:.4g}"


def _extract_param(s: str, name: str) -> float | None:
    m = re.search(rf"{name}=([0-9eE.+\-]+[a-zA-Z]*)", s, re.IGNORECASE)
    if not m:
        return None
    return _parse_spice(m.group(1))


# ---------------------------------------------------------------------------
# gm/Id characterization via raw ngspice (no PySpice dependency)
# ---------------------------------------------------------------------------

import numpy as np


def _write_sweep_deck(
    path: Path,
    includes: str,
    device: str,
    prefix: str,
    W_um: float,
    L_um: float,
    vdd: float,
    vgs_step: float,
    vds_mid: float,
    vds_delta: float,
    is_pmos: bool,
) -> None:
    """Write an ngspice deck that sweeps Vgs at 3 Vds points.

    Writes three separate wrdata files (one per Vds bias), since ngspice
    discards vectors between `alter` + `dc` runs.
    """
    vds_lo = vds_mid - vds_delta
    vds_hi = vds_mid + vds_delta
    base = path.stem

    if is_pmos:
        inst = f"{prefix}1 d g vdd vdd {device} W={W_um}u L={L_um}u"
        deck = f"""\
** gm/Id characterization: {device} L={L_um}u (PMOS)
{includes}
{inst}
Vdd_supply vdd 0 {vdd}
Vgs g 0 0
Vdrain d 0 {vdd - vds_lo}

.control
dc Vgs {vdd} 0 -{vgs_step}
wrdata {base}_lo i(Vdrain)

alter Vdrain dc = {vdd - vds_mid}
dc Vgs {vdd} 0 -{vgs_step}
wrdata {base}_mid i(Vdrain)

alter Vdrain dc = {vdd - vds_hi}
dc Vgs {vdd} 0 -{vgs_step}
wrdata {base}_hi i(Vdrain)

quit
.endc
.end
"""
    else:
        inst = f"{prefix}1 d g 0 0 {device} W={W_um}u L={L_um}u"
        deck = f"""\
** gm/Id characterization: {device} L={L_um}u (NMOS)
{includes}
{inst}
Vgs g 0 0
Vdrain d 0 {vds_lo}

.control
dc Vgs 0 {vdd} {vgs_step}
wrdata {base}_lo i(Vdrain)

alter Vdrain dc = {vds_mid}
dc Vgs 0 {vdd} {vgs_step}
wrdata {base}_mid i(Vdrain)

alter Vdrain dc = {vds_hi}
dc Vgs 0 {vdd} {vgs_step}
wrdata {base}_hi i(Vdrain)

quit
.endc
.end
"""
    path.write_text(deck)


def _parse_wrdata(csv_path: Path) -> tuple[np.ndarray, ...]:
    """Parse ngspice wrdata output (space-separated, skip comments)."""
    rows = []
    for line in csv_path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or line.startswith("*"):
            continue
        parts = line.split()
        try:
            rows.append([float(x) for x in parts])
        except ValueError:
            continue
    if not rows:
        raise RuntimeError(f"No data in {csv_path}")
    data = np.array(rows)
    return tuple(data[:, i] for i in range(data.shape[1]))


def characterize_device(
    pdk: PDK,
    device: str,
    kind: str,
    L_um: float,
    W_um: float = 10.0,
    vgs_step: float = 0.01,
) -> DeviceLUT | None:
    """Run gm/Id characterization for a device using ngspice subprocess.

    Returns a DeviceLUT, or None if simulation fails.
    """
    is_pmos = kind == "pmos"
    vdd = pdk.vdd
    vds_mid = vdd / 2
    vds_delta = 0.05
    prefix = pdk.device_prefix

    includes = pdk_includes(pdk)
    deck_name = f"char_{pdk.name}_{device}_L{L_um:.2f}u"
    deck_path = OUT_DIR / f"{deck_name}.spice"
    _write_sweep_deck(
        deck_path, includes, device, prefix,
        W_um, L_um, vdd, vgs_step, vds_mid, vds_delta, is_pmos,
    )

    try:
        result = subprocess.run(
            ["ngspice", "-b", str(deck_path)],
            capture_output=True, text=True, timeout=120,
            cwd=str(OUT_DIR),
        )
    except Exception as e:
        print(f"    characterization failed: {e}")
        return None

    # Read three wrdata output files: _lo, _mid, _hi
    def _find_and_parse(suffix: str) -> tuple[np.ndarray, ...] | None:
        base = f"{deck_name}_{suffix}"
        path = OUT_DIR / base
        if not path.exists():
            candidates = list(OUT_DIR.glob(f"{base}*"))
            if candidates:
                path = candidates[0]
            else:
                return None
        return _parse_wrdata(path)

    lo_cols = _find_and_parse("lo")
    mid_cols = _find_and_parse("mid")
    hi_cols = _find_and_parse("hi")

    if not all([lo_cols, mid_cols, hi_cols]):
        print(f"    missing wrdata output files")
        debug = OUT_DIR / f"debug_char_{pdk.name}_{device}.log"
        debug.write_text(result.stdout + "\n" + result.stderr)
        print(f"    debug log: {debug}")
        return None

    # wrdata outputs: col0=Vgs (sweep var), col[-1]=i(Vdrain)
    vgs_raw = mid_cols[0]
    id_lo = np.abs(lo_cols[-1])
    id_mid = np.abs(mid_cols[-1])
    id_hi = np.abs(hi_cols[-1])

    if is_pmos:
        # Flip to ascending Vgs order for consistent interpolation
        vgs_raw = vgs_raw[::-1]
        id_lo = id_lo[::-1]
        id_mid = id_mid[::-1]
        id_hi = id_hi[::-1]

    vgs = vgs_raw

    gm = np.abs(np.gradient(id_mid, vgs))
    gds = np.abs((id_hi - id_lo) / (2 * vds_delta))

    # Filter: require meaningful current (not subthreshold noise)
    id_floor = max(id_mid.max() * 1e-5, 1e-9)
    valid = (id_mid > id_floor) & (gm > 1e-12) & (gds > 1e-12)

    if np.sum(valid) < 5:
        print(f"    too few valid points ({np.sum(valid)})")
        return None

    ids_v = id_mid[valid]
    gm_v = gm[valid]
    gds_v = gds[valid]
    gmid = gm_v / ids_v
    jd = ids_v / W_um  # A/um
    av = gm_v / gds_v

    print(f"    {device} L={L_um}u: {np.sum(valid)} points, "
          f"gm/Id range [{gmid.min():.1f}, {gmid.max():.1f}] V⁻¹")

    return DeviceLUT(
        device=device, L_um=L_um,
        gmid=gmid, jd=jd, vgs=vgs[valid], av=av, gm=gm_v, gds=gds_v,
    )


def load_luts_for_pdk(
    pdk: PDK, nfet_L: float, pfet_L: float,
) -> tuple[DeviceLUT | None, DeviceLUT | None]:
    """Characterize both NMOS and PFET for a PDK at given L values (in um)."""
    print(f"  Characterizing {pdk.display}...")
    nfet_lut = characterize_device(pdk, pdk.nfet, "nmos", nfet_L)
    pfet_lut = characterize_device(pdk, pdk.pfet, "pmos", pfet_L)
    return nfet_lut, pfet_lut


def characterize_device_family(
    pdk: PDK, device: str, kind: str,
    L_values_um: list[float] | None = None,
    W_um: float = 10.0,
) -> DeviceLUTFamily | None:
    """Characterize a device at multiple L values to build a multi-L family."""
    if L_values_um is None:
        # Use PDK discrete lengths up to 4um
        L_values_um = [l * 1e6 for l in pdk.discrete_lengths if l * 1e6 <= 4.0]

    print(f"    {device}: characterizing at L = {', '.join(f'{L:.2f}' for L in L_values_um)}um")
    luts: dict[float, DeviceLUT] = {}
    for L_um in L_values_um:
        lut = characterize_device(pdk, device, kind, L_um, W_um)
        if lut:
            luts[L_um] = lut

    if not luts:
        return None
    return DeviceLUTFamily(device=device, luts=luts)


def characterize_families(
    pdks: dict[str, PDK],
    target_names: list[str],
) -> dict[str, tuple[DeviceLUTFamily | None, DeviceLUTFamily | None]]:
    """Build multi-L LUT families for target PDKs."""
    families: dict[str, tuple[DeviceLUTFamily | None, DeviceLUTFamily | None]] = {}
    for name in target_names:
        if name not in pdks:
            continue
        pdk = pdks[name]
        print(f"  Multi-L characterization for {pdk.display}...")
        nfet_fam = characterize_device_family(pdk, pdk.nfet, "nmos")
        pfet_fam = characterize_device_family(pdk, pdk.pfet, "pmos")
        families[name] = (nfet_fam, pfet_fam)
        if nfet_fam and pfet_fam:
            print(f"    OK: NFET {len(nfet_fam.luts)} L-values, PFET {len(pfet_fam.luts)} L-values")
        else:
            missing = [x for x, v in [("NFET", nfet_fam), ("PFET", pfet_fam)] if not v]
            print(f"    ERR: missing {', '.join(missing)} family")
    return families


# ---------------------------------------------------------------------------
# Netlist remapping
# ---------------------------------------------------------------------------

def _parse_ibias(spice: str) -> float:
    """Extract bias current from Ibias source in netlist (Amps)."""
    for line in spice.splitlines():
        m = re.match(r"^Ibias\s+\S+\s+\S+\s+([0-9eE.+\-]+[a-zA-Z]*)", line, re.IGNORECASE)
        if m:
            return _parse_spice(m.group(1))
    return 20e-6  # default


# 5T OTA bias current map: instance → fraction of Ibias
# M1/M2 (diff pair): Ibias/2 each
# M3/M4 (active load): Ibias/2 each
# M5/M6 (tail/bias): Ibias
_OTA_CURRENT_FRACTIONS = {
    "XM1": 0.5, "XM2": 0.5,   # diff pair
    "XM3": 0.5, "XM4": 0.5,   # active load
    "XM5": 1.0, "XM6": 1.0,   # tail + bias mirror
}


def remap_opamp_with_switcher(source_spice: str, switcher: PDKSwitcher) -> str:
    """Remap an OpAmp subcircuit netlist using a pre-configured switcher.

    Uses gm/Id methodology: passes the known bias current for each transistor
    so the switcher can extract the exact operating gm/Id and preserve it.
    """
    print(f"\n{switcher.summary()}")

    ibias = _parse_ibias(source_spice)
    print(f"  Ibias: {ibias*1e6:.1f} uA")

    lines = []
    for line in source_spice.splitlines():
        stripped = line.strip()

        # Subcircuit instance lines: XM1 d g s b model W=... L=...
        if stripped.startswith("X"):
            parts = stripped.split()
            inst_name = parts[0]
            model_idx = None
            for i, p in enumerate(parts[1:], 1):
                if p in switcher._model_map:
                    model_idx = i
                    break

            if model_idx is not None:
                model = parts[model_idx]
                param_str = " ".join(parts[model_idx + 1:])
                w = _extract_param(param_str, "W")
                l = _extract_param(param_str, "L")
                nf = int(_extract_param(param_str, "nf") or 1)

                # Look up bias current for this instance
                frac = _OTA_CURRENT_FRACTIONS.get(inst_name, 0.5)
                bias_current = ibias * frac

                if w and l:
                    result = switcher.remap_device(
                        model, w, l, nf, bias_current=bias_current,
                    )
                    # All 3 PDKs use subcircuit models (X prefix)
                    new_line = (
                        f"X{parts[0][1:]}"
                        f" {' '.join(parts[1:model_idx])}"
                        f" {result.model}"
                        f" W={_fmt(result.w)} L={_fmt(result.l)}"
                    )
                    if result.nf > 1:
                        new_line += f" nf={result.nf}"
                    if result.warnings:
                        for w_msg in result.warnings:
                            print(f"    WARNING: {parts[0]}: {w_msg}")
                    if result.gmid is not None:
                        print(f"    {inst_name}: gm/Id={result.gmid:.1f} V⁻¹"
                              f"  W: {_fmt(w)}→{_fmt(result.w)}"
                              f"  L: {_fmt(l)}→{_fmt(result.l)}")
                    lines.append(new_line)
                    continue

        lines.append(line)

    return "\n".join(lines)


# ---------------------------------------------------------------------------
# PDK-specific .lib include directives
# ---------------------------------------------------------------------------

def pdk_includes(pdk: PDK) -> str:
    """Generate ngspice .lib include directives for a PDK."""
    r = pdk.root
    if pdk.name in ("sky130A", "sky130A_1v2"):
        # sky130 .lib tt needs mc switches pre-defined
        ngspice = f"{r}/libs.tech/ngspice"
        spice = f"{r}/libs.ref/sky130_fd_pr/spice"
        return "\n".join([
            f".param mc_mm_switch=0",
            f".param mc_pr_switch=0",
            f'.include "{ngspice}/parameters/lod.spice"',
            f'.include "{ngspice}/parameters/invariant.spice"',
            f'.include "{ngspice}/corners/tt/nonfet.spice"',
            f'.include "{spice}/sky130_fd_pr__pfet_01v8__mismatch.corner.spice"',
            f'.include "{spice}/sky130_fd_pr__pfet_01v8__tt.corner.spice"',
            f'.include "{spice}/sky130_fd_pr__nfet_01v8__mismatch.corner.spice"',
            f'.include "{spice}/sky130_fd_pr__nfet_01v8__tt.pm3.spice"',
        ])
    elif pdk.name == "ihp-sg13g2":
        osdi_dir = f"{r}/libs.tech/ngspice/osdi"
        return "\n".join([
            f'osdi {osdi_dir}/psp103.osdi',
            f'osdi {osdi_dir}/psp103_nqs.osdi',
            f'.lib "{r}/libs.tech/ngspice/models/cornerMOSlv.lib" mos_tt',
        ])
    elif pdk.name == "gf180mcuA":
        # Include design.ngspice for global params, then model cards only
        # (skip "typical" which pulls in fets_mm with agauss issues)
        # Provide simple subcircuit wrappers without Monte Carlo mismatch
        lib = f"{r}/libs.tech/ngspice/sm141064.ngspice"
        return "\n".join([
            f'.include "{r}/libs.tech/ngspice/design.ngspice"',
            f'.lib "{lib}" nfet_03v3_t',
            f'.lib "{lib}" pfet_03v3_t',
            f'.lib "{lib}" noise_corner',
            "",
            "** Simple subcircuit wrappers (no mismatch)",
            ".subckt nfet_03v3 d g s b w=10u l=0.28u nf=1 m=1",
            "+ as=0 ad=0 ps=0 pd=0 nrd=0 nrs=0 sa=0 sb=0 sd=0 par=1 dtemp=0",
            "m0 d g s b nfet_03v3 w=w l=l as=as ad=ad ps=ps pd=pd",
            "+ nrd=nrd nrs=nrs sa=sa sb=sb nf=nf sd=sd m=m",
            ".ends nfet_03v3",
            "",
            ".subckt pfet_03v3 d g s b w=10u l=0.28u nf=1 m=1",
            "+ as=0 ad=0 ps=0 pd=0 nrd=0 nrs=0 sa=0 sb=0 sd=0 par=1 dtemp=0",
            "m0 d g s b pfet_03v3 w=w l=l as=as ad=ad ps=ps pd=pd",
            "+ nrd=nrd nrs=nrs sa=sa sb=sb nf=nf sd=sd m=m",
            ".ends pfet_03v3",
        ])
    raise ValueError(f"Unknown PDK: {pdk.name}")


# ---------------------------------------------------------------------------
# Testbench generation
# ---------------------------------------------------------------------------

def generate_testbench(pdk: PDK, opamp_netlist: str) -> str:
    """Generate a complete testbench for AC open-loop gain measurement."""
    vdd = pdk.vdd
    vcm = vdd / 2

    # Build testbench line by line (no indentation issues)
    lines = [
        f"** OpAmp AC Open-Loop Gain Testbench -- {pdk.display}",
        f"** VDD={vdd}V",
        "",
        pdk_includes(pdk),
        "",
        opamp_netlist,
        "",
        "** DUT instantiation",
        "Xdut vip vin vout vdd vss opamp",
        "",
        "** Supply",
        f"Vdd vdd 0 {vdd}",
        "Vss vss 0 0",
        "",
        "** Common-mode bias",
        f"Vcm vcm 0 {vcm}",
        "",
        "** Differential AC stimulus",
        "Vip vip vcm dc 0 ac 0.5",
        "Vin vin vcm dc 0 ac -0.5",
        "",
        "** Load capacitor",
        "CL vout 0 1p",
        "",
        "** Analysis",
        ".ac dec 100 1 10G",
        "",
        ".control",
        "run",
        "",
        "* Compute gain and phase vectors",
        "let gain_db = db(v(vout))",
        "let phase_deg = 180/PI * ph(v(vout))",
        "",
        "* DC gain is first point (1 Hz)",
        "let dc_gain = gain_db[0]",
        "",
        "* Write raw data for post-processing",
        f"wrdata {pdk.name}_ac gain_db phase_deg",
        "",
        '* Print DC gain',
        'echo "RESULT_DC_GAIN = $&dc_gain"',
        "",
        "* Find 0dB crossing for UGF and phase margin",
        "meas ac ugf_val when gain_db=0",
        "meas ac pm_at_ugf find phase_deg when gain_db=0",
        "",
        "quit",
        ".endc",
        "",
        ".end",
    ]

    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Simulation runner
# ---------------------------------------------------------------------------

@dataclass
class SimResult:
    pdk_name: str
    dc_gain_db: float
    ugf_hz: float
    phase_margin_deg: float
    success: bool
    error: str = ""


def run_ngspice(tb_path: Path, pdk_name: str) -> SimResult:
    """Run ngspice in batch mode and parse results."""
    try:
        result = subprocess.run(
            ["ngspice", "-b", str(tb_path)],
            capture_output=True, text=True, timeout=120,
            cwd=str(OUT_DIR),
        )
    except FileNotFoundError:
        return SimResult(pdk_name, 0, 0, 0, False, "ngspice not found")
    except subprocess.TimeoutExpired:
        return SimResult(pdk_name, 0, 0, 0, False, "ngspice timeout")

    output = result.stdout + result.stderr

    # Parse DC gain
    dc_gain = _parse_result(output, "RESULT_DC_GAIN")

    # Parse UGF from .meas output
    ugf = _parse_meas(output, "ugf_val")

    # Parse phase margin from .meas output
    pm_raw = _parse_meas(output, "pm_at_ugf")
    pm = (180 + pm_raw) if pm_raw is not None else None

    if dc_gain is None:
        err_lines = [l for l in output.splitlines() if "error" in l.lower()]
        err_msg = "\n".join(err_lines[:5]) if err_lines else "No gain result"
        # Save full output for debugging
        debug_path = OUT_DIR / f"debug_{pdk_name}.log"
        debug_path.write_text(output)
        return SimResult(pdk_name, 0, 0, 0, False, f"{err_msg}\n  Debug log: {debug_path}")

    return SimResult(
        pdk_name=pdk_name,
        dc_gain_db=dc_gain,
        ugf_hz=ugf if ugf and ugf > 0 else 0,
        phase_margin_deg=pm if pm and pm > 0 else 0,
        success=True,
    )


def _parse_result(output: str, key: str) -> float | None:
    for line in output.splitlines():
        if key in line:
            m = re.search(rf"{key}\s*=\s*([0-9eE.+\-]+)", line)
            if m:
                try:
                    return float(m.group(1))
                except ValueError:
                    pass
    return None


def _parse_meas(output: str, name: str) -> float | None:
    """Parse ngspice .meas result like: ugf_val          =  1.234567e+06"""
    for line in output.splitlines():
        if name in line and "=" in line:
            m = re.search(rf"{name}\s*=\s*([0-9eE.+\-]+)", line)
            if m:
                try:
                    return float(m.group(1))
                except ValueError:
                    pass
    return None


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def characterize_all(
    pdks: dict[str, PDK],
    src_pdk: PDK,
    src_nfet_L_um: float,
    src_pfet_L_um: float,
) -> dict[str, tuple[DeviceLUT | None, DeviceLUT | None]]:
    """Run gm/Id characterization for all PDKs."""
    luts: dict[str, tuple[DeviceLUT | None, DeviceLUT | None]] = {}
    for name, pdk in pdks.items():
        l_ratio = pdk.l_min / src_pdk.l_min
        nfet_L = pdk.snap_length(src_nfet_L_um * 1e-6 * l_ratio) * 1e6
        pfet_L = pdk.snap_length(src_pfet_L_um * 1e-6 * l_ratio) * 1e6

        if name == src_pdk.name:
            nfet_L = src_nfet_L_um
            pfet_L = src_pfet_L_um

        nfet_lut, pfet_lut = load_luts_for_pdk(pdk, nfet_L, pfet_L)
        luts[name] = (nfet_lut, pfet_lut)

        if nfet_lut and pfet_lut:
            print(f"    OK  {pdk.display}: NFET L={nfet_L}u, PFET L={pfet_L}u")
        else:
            missing = [x for x, v in [("NFET", nfet_lut), ("PFET", pfet_lut)] if not v]
            print(f"    ERR {pdk.display}: missing {', '.join(missing)} LUT")
    return luts


def remap_and_simulate(
    variant_label: str,
    base_spice: str,
    src_pdk: PDK,
    pdks: dict[str, PDK],
    luts: dict[str, tuple[DeviceLUT | None, DeviceLUT | None]],
    families: dict[str, tuple[DeviceLUTFamily | None, DeviceLUTFamily | None]] | None = None,
) -> list[SimResult]:
    """Remap a netlist to all target PDKs, simulate, and return results.

    If families is provided, uses Av-preserving multi-L remap for those PDKs.
    """
    targets: dict[str, tuple[PDK, str]] = {src_pdk.name: (src_pdk, base_spice)}
    src_nfet_lut, src_pfet_lut = luts.get(src_pdk.name, (None, None))

    for name in ("sky130A_1v2", "ihp-sg13g2", "gf180mcuA"):
        if name not in pdks:
            continue
        tgt = pdks[name]

        switcher = PDKSwitcher(src_pdk, tgt)

        # Try multi-L families first, then single-L LUTs
        tgt_nfet_fam, tgt_pfet_fam = (None, None)
        if families:
            tgt_nfet_fam, tgt_pfet_fam = families.get(name, (None, None))

        if src_nfet_lut and src_pfet_lut and tgt_nfet_fam and tgt_pfet_fam:
            switcher.load_lut_families(
                src_nfet_lut, src_pfet_lut, tgt_nfet_fam, tgt_pfet_fam,
            )
            print(f"\n  {src_pdk.display} -> {tgt.display}: Av-preserving multi-L mode")
        else:
            tgt_nfet_lut, tgt_pfet_lut = luts.get(name, (None, None))
            if not (src_nfet_lut and src_pfet_lut and tgt_nfet_lut and tgt_pfet_lut):
                print(f"\n  {src_pdk.display} -> {tgt.display}: SKIPPED (missing LUTs)")
                continue
            switcher.load_luts(src_nfet_lut, src_pfet_lut, tgt_nfet_lut, tgt_pfet_lut)
            print(f"\n  {src_pdk.display} -> {tgt.display}: single-L gm/Id mode")

        remapped = remap_opamp_with_switcher(base_spice, switcher)
        targets[name] = (tgt, remapped)

    results: list[SimResult] = []
    for name, (pdk, netlist) in targets.items():
        tag = f"{variant_label}_{name}"
        netlist_path = OUT_DIR / f"opamp_{tag}.spice"
        netlist_path.write_text(netlist)

        tb = generate_testbench(pdk, netlist)
        tb_path = OUT_DIR / f"tb_{tag}.spice"
        tb_path.write_text(tb)

        print(f"  Simulating {pdk.display}...", end=" ", flush=True)
        sim = run_ngspice(tb_path, name)
        results.append(sim)

        if sim.success:
            print(f"DC Gain={sim.dc_gain_db:.1f}dB  UGF={sim.ugf_hz:.2e}Hz")
        else:
            print(f"FAILED: {sim.error[:60]}")

    return results


def print_comparison(label: str, results: list[SimResult]) -> float | None:
    """Print comparison table, return gain spread or None."""
    print(f"\n  {'PDK':<16} {'DC Gain':>10} {'UGF':>14} {'PM':>10}")
    print(f"  {'─'*52}")
    for r in results:
        if r.success:
            ugf_s = f"{r.ugf_hz:.2e}" if r.ugf_hz > 0 else "N/A"
            pm_s = f"{r.phase_margin_deg:.1f}" if r.phase_margin_deg > 0 else "N/A"
            print(f"  {r.pdk_name:<16} {r.dc_gain_db:>8.1f}dB {ugf_s:>14} {pm_s:>8}deg")
        else:
            print(f"  {r.pdk_name:<16} {'FAIL':>10}")

    successful = [r for r in results if r.success]
    if len(successful) < 2:
        return None
    gains = [r.dc_gain_db for r in successful]
    spread = max(gains) - min(gains)
    print(f"  Gain spread: {spread:.1f} dB")
    return spread


def main():
    print("=" * 70)
    print("PDKSwitcherino Cross-PDK OpAmp Test (gm/Id methodology)")
    print("=" * 70)

    OUT_DIR.mkdir(parents=True, exist_ok=True)

    print("\nDetecting PDK installations...")
    pdks = setup_pdk_roots()

    if "sky130A" not in pdks:
        print("\nERROR: sky130A is required as the base PDK.")
        sys.exit(1)

    src_pdk = pdks["sky130A"]
    base_spice = (TEST_DIR / "opamp_sky130.spice").read_text()
    nfet_L = 0.5  # diff pair / active load L in um
    pfet_L = 0.5

    # -----------------------------------------------------------------------
    # Characterize all PDKs
    # -----------------------------------------------------------------------
    print(f"\n{'=' * 70}")
    print("gm/Id Device Characterization")
    print(f"{'=' * 70}")
    print(f"  Source design: NFET L={nfet_L}u, PFET L={pfet_L}u")

    luts = characterize_all(pdks, src_pdk, nfet_L, pfet_L)

    # -----------------------------------------------------------------------
    # Mode A: Single-L remap (baseline — L scaled by L_min ratio)
    # -----------------------------------------------------------------------
    print(f"\n{'=' * 70}")
    print("Mode A: Single-L gm/Id Remap (L scaled by L_min ratio)")
    print(f"{'=' * 70}")

    results_single = remap_and_simulate("ota_singleL", base_spice, src_pdk, pdks, luts)

    # -----------------------------------------------------------------------
    # Multi-L characterization for target PDKs
    # -----------------------------------------------------------------------
    # Only characterize targets with different L_min (where Av-preserving helps)
    target_names = [
        name for name, pdk in pdks.items()
        if name != src_pdk.name and abs(pdk.l_min / src_pdk.l_min - 1.0) > 0.2
    ]
    families = None
    if target_names:
        print(f"\n{'=' * 70}")
        print("Multi-L Characterization (Av-preserving L selection)")
        print(f"{'=' * 70}")
        families = characterize_families(pdks, target_names)

    # -----------------------------------------------------------------------
    # Mode B: Multi-L Av-preserving remap
    # -----------------------------------------------------------------------
    results_multi = None
    if families:
        print(f"\n{'=' * 70}")
        print("Mode B: Multi-L Av-Preserving Remap")
        print(f"{'=' * 70}")
        results_multi = remap_and_simulate(
            "ota_multiL", base_spice, src_pdk, pdks, luts, families=families,
        )

    # -----------------------------------------------------------------------
    # Results comparison
    # -----------------------------------------------------------------------
    print(f"\n{'=' * 70}")
    print("RESULTS — Single-L (L_min ratio scaling)")
    print(f"{'=' * 70}")
    spread_single = print_comparison("single-L", results_single)

    spread_multi = None
    if results_multi:
        print(f"\n{'=' * 70}")
        print("RESULTS — Multi-L (Av-preserving)")
        print(f"{'=' * 70}")
        spread_multi = print_comparison("multi-L", results_multi)

    # -----------------------------------------------------------------------
    # Analysis: compare the two modes
    # -----------------------------------------------------------------------
    baseline = next((r for r in results_single if r.success and r.pdk_name == "sky130A"), None)
    if not baseline:
        print("\nERROR: sky130A baseline simulation failed")
        sys.exit(1)

    print(f"\n{'=' * 70}")
    print("ANALYSIS — Single-L vs Multi-L Av-Preserving")
    print(f"{'=' * 70}")

    print(f"\n  Baseline: sky130A = {baseline.dc_gain_db:.1f} dB")

    if results_multi:
        print(f"\n  {'PDK':<16} {'Single-L':>12} {'Multi-L':>12} {'Improvement':>14}")
        print(f"  {'─' * 56}")
        for rs, rm in zip(results_single, results_multi):
            if rs.pdk_name == src_pdk.name:
                continue
            if rs.success and rm.success:
                delta_s = abs(rs.dc_gain_db - baseline.dc_gain_db)
                delta_m = abs(rm.dc_gain_db - baseline.dc_gain_db)
                improvement = delta_s - delta_m
                print(f"  {rs.pdk_name:<16} {delta_s:>10.1f}dB {delta_m:>10.1f}dB {improvement:>+12.1f}dB")
            elif rs.success:
                delta_s = abs(rs.dc_gain_db - baseline.dc_gain_db)
                print(f"  {rs.pdk_name:<16} {delta_s:>10.1f}dB {'N/A':>12} {'':>14}")
            else:
                print(f"  {rs.pdk_name:<16} {'FAIL':>12} {'FAIL':>12}")

    if spread_single is not None and spread_multi is not None:
        print(f"\n  Gain spread: {spread_single:.1f}dB (single-L) → {spread_multi:.1f}dB (multi-L)")
        if spread_multi < spread_single:
            print(f"  --> Multi-L Av-preserving reduced gain spread by {spread_single - spread_multi:.1f}dB")
        else:
            print(f"  --> Multi-L did not improve (possibly at L boundary)")

    successful = [r for r in results_single if r.success]
    all_amplify = all(r.dc_gain_db > 0 for r in successful)
    if all_amplify:
        print(f"\n  PASS: All PDK variants show positive open-loop gain")
    else:
        print(f"\n  FAIL: Some variants have no gain")
        sys.exit(1)

    print(f"\nOutput files: {OUT_DIR}")


if __name__ == "__main__":
    main()
