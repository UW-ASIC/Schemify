"""
Sky130 MOSFET Characterization Tool
Combines lookup table generation and analysis with easy configuration
"""

import numpy as np
import matplotlib.pyplot as plt
from mosplot.plot import load_lookup_table, Mosfet, Expression
from mosplot.lookup_table_generator.simulators import NgspiceSimulator
from mosplot.lookup_table_generator import TransistorSweep, LookupTableGenerator
import os
from enum import Enum
from pathlib import Path
import re

# ============================================================================
# USER CONFIGURATION - EDIT THIS SECTION
# ============================================================================

# --- Device Selection ---
DEVICE_TO_ANALYZE = "sky130_fd_pr__nfet_01v8"  # Options below

VBS = 0.0  # Body-source voltage
VDS = 0.9
VGS_RANGE = (
    0.01,
    1.8,
)  # Gate-source voltage range (use negative for PMOS, e.g., (-1.8, -0.01))
LENGTH_FILTER = None  # Specific length in meters (e.g., 0.15e-6) or None for all

PLOT_CONFIG = {
    # ========== gm/ID AS X-AXIS ==========
    # Current and Power Efficiency
    "gmid_vs_current_density": {
        "enabled": True,
        "x_axis": "gmid",
        "y_axis": "current_density",
        "y_scale": "log",
        "title": "gm/ID vs Current Density",
        "filename": "gmid_vs_current_density.svg",
    },
    "gmid_vs_id": {
        "enabled": True,
        "x_axis": "gmid",
        "y_axis": "id",
        "y_scale": "log",
        "title": "gm/ID vs Drain Current",
        "filename": "gmid_vs_id.svg",
    },
    # Transconductance Metrics
    "gmid_vs_gm": {
        "enabled": True,
        "x_axis": "gmid",
        "y_axis": "gm",
        "y_scale": "log",
        "title": "gm/ID vs Transconductance",
        "filename": "gmid_vs_gm.svg",
    },
    # Output Characteristics
    "gmid_vs_gds": {
        "enabled": True,
        "x_axis": "gmid",
        "y_axis": "gds",
        "y_scale": "log",
        "title": "gm/ID vs Output Conductance",
        "filename": "gmid_vs_gds.svg",
    },
    # Gain Metrics
    "gmid_vs_av": {
        "enabled": True,
        "x_axis": "gmid",
        "y_axis": "av",
        "y_scale": "log",
        "title": "gm/ID vs Intrinsic Gain (gm/gds)",
        "filename": "gmid_vs_av.svg",
    },
    # Frequency Performance
    "gmid_vs_ft": {
        "enabled": False,
        "x_axis": "gmid",
        "y_axis": "ft",
        "y_scale": "log",
        "title": "gm/ID vs Transit Frequency",
        "filename": "gmid_vs_ft.svg",
    },
    # Voltage Characteristics
    "gmid_vs_vds": {
        "enabled": False,
        "x_axis": "gmid",
        "y_axis": "vds",
        "y_scale": "linear",
        "title": "gm/ID vs Drain-Source Voltage",
        "filename": "gmid_vs_vds.svg",
    },
    # ========== VGS AS X-AXIS ==========
    # Basic Transfer Characteristics
    "vgs_vs_id": {
        "enabled": True,
        "x_axis": "vgs",
        "y_axis": "id",
        "y_scale": "log",
        "title": "VGS vs Drain Current",
        "filename": "vgs_vs_id.svg",
    },
    "vgs_vs_current_density": {
        "enabled": False,
        "x_axis": "vgs",
        "y_axis": "current_density",
        "y_scale": "log",
        "title": "VGS vs Current Density",
        "filename": "vgs_vs_jd.svg",
    },
    # Small-Signal Parameters
    "vgs_vs_gm": {
        "enabled": True,
        "x_axis": "vgs",
        "y_axis": "gm",
        "y_scale": "linear",
        "title": "VGS vs Transconductance",
        "filename": "vgs_vs_gm.svg",
    },
    "vgs_vs_gds": {
        "enabled": True,
        "x_axis": "vgs",
        "y_axis": "gds",
        "y_scale": "log",
        "title": "VGS vs Output Conductance",
        "filename": "vgs_vs_gds.svg",
    },
    # Efficiency and Gain
    "vgs_vs_gmid": {
        "enabled": True,
        "x_axis": "vgs",
        "y_axis": "gmid",
        "y_scale": "linear",
        "title": "VGS vs gm/ID",
        "filename": "vgs_vs_gmid.svg",
    },
    "vgs_vs_av": {
        "enabled": True,
        "x_axis": "vgs",
        "y_axis": "av",
        "y_scale": "log",
        "title": "VGS vs Intrinsic Gain",
        "filename": "vgs_vs_av.svg",
    },
    # Frequency Performance
    "vgs_vs_ft": {
        "enabled": False,
        "x_axis": "vgs",
        "y_axis": "ft",
        "y_scale": "log",
        "title": "VGS vs Transit Frequency",
        "filename": "vgs_vs_ft.svg",
    },
    # Voltage Relationships
    "vgs_vs_vds": {
        "enabled": False,
        "x_axis": "vgs",
        "y_axis": "vds",
        "y_scale": "linear",
        "title": "VGS vs VDS",
        "filename": "vgs_vs_vds.svg",
    },
}

# --- Generation Settings ---
LOOKUP_DIR = "./sky130_lookup_tables"
FIGURE_DIR = "./figures"
AUTO_GENERATE = True  # Automatically generate lookup tables if missing
REGENERATE = False  # Force regeneration even if tables exist

# ============================================================================
# END USER CONFIGURATION
# ============================================================================


class Sky130Device(Enum):
    """Available Sky130 1.8V devices for gm/ID characterization"""

    # NMOS devices
    NFET_01V8 = "sky130_fd_pr__nfet_01v8"

    # PMOS devices
    PFET_01V8 = "sky130_fd_pr__pfet_01v8"

    def is_nmos(self):
        return "nfet" in self.value

    def is_pmos(self):
        return "pfet" in self.value

    def __str__(self):
        return self.value


# ============================================================================
# Lookup Table Generator
# ============================================================================


def setup_lookup_generator():
    """Setup lookup table generator for Sky130"""

    # Get PDK paths
    PDK_ROOT = os.environ.get("PDK_ROOT", os.path.expanduser("~/.volare"))
    PDK = os.environ.get("PDK", "sky130A")
    PDK_PATH = os.path.join(PDK_ROOT, PDK)
    SKY130_CORNER = os.path.join(PDK_PATH, "libs.tech/ngspice/corners/tt.spice")
    SKY130_RC = os.path.join(
        PDK_PATH, "libs.tech/ngspice/r+c/res_typical__cap_typical.spice"
    )
    SKY130_RC_LIN = os.path.join(
        PDK_PATH, "libs.tech/ngspice/r+c/res_typical__cap_typical__lin.spice"
    )
    SKY130_SPECIALIZED = os.path.join(
        PDK_PATH, "libs.tech/ngspice/corners/tt/specialized_cells.spice"
    )

    # Common parameters for all devices
    common_base = {
        "simulator_path": "ngspice",
        "temperature": 27,
        "parameters_to_save": ["id", "vth", "vdsat", "gm", "gds", "gmbs"],
        "include_paths": [],  # We'll add includes in raw_spice instead
        "raw_spice": [
            ".param mc_mm_switch=0",
            ".param mc_pr_switch=0",
            f".include {SKY130_CORNER}",
            f".include {SKY130_RC}",
            f".include {SKY130_RC_LIN}",
            f".include {SKY130_SPECIALIZED}",
            ".option TEMP=27",
            ".option TNOM=27",
        ],
    }

    # Device-specific parameters - same for all standard devices
    # These formulas should work for all sky130_fd_pr devices
    sky130_device_params = {
        "W": 1,
        "nf": 1,
        "ad": "'int((nf+1)/2) * W/nf * 0.29'",
        "as": "'int((nf+2)/2) * W/nf * 0.29'",
        "pd": "'2*int((nf+1)/2) * (W/nf + 0.29)'",
        "ps": "'2*int((nf+2)/2) * (W/nf + 0.29)'",
        "nrd": "'0.29 / W'",
        "nrs": "'0.29 / W'",
        "sa": 0,
        "sb": 0,
        "sd": 0,
        "mult": 1,
        "m": 1,
    }

    # Create simulators for each device
    simulators = {
        "sky130_fd_pr__nfet_01v8": NgspiceSimulator(
            **common_base,
            device_parameters=sky130_device_params.copy(),
            mos_spice_symbols=("XM1", "m.xm1.msky130_fd_pr__nfet_01v8"),
        ),
        "sky130_fd_pr__pfet_01v8": NgspiceSimulator(
            **common_base,
            device_parameters=sky130_device_params.copy(),
            mos_spice_symbols=("XM1", "m.xm1.msky130_fd_pr__pfet_01v8"),
        ),
    }

    # Sweep configurations - Use MICRONS not meters!
    nmos_sweep = TransistorSweep(
        mos_type="nmos",
        vgs=(0, 1.8, 0.02),
        vds=(0, 1.8, 0.02),
        vbs=(0, -1.8, -0.2),
        length=[0.15, 0.3, 0.5, 1.0],
    )

    pmos_sweep = TransistorSweep(
        mos_type="pmos",
        vgs=(0, -1.8, -0.02),
        vds=(0, -1.8, -0.02),
        vbs=(0, 1.8, 0.2),
        length=[0.15, 0.3, 0.5, 1.0],
    )

    model_sweeps = {
        "sky130_fd_pr__nfet_01v8": nmos_sweep,
        "sky130_fd_pr__pfet_01v8": pmos_sweep,
    }

    return {"simulators": simulators, "model_sweeps": model_sweeps}


# ============================================================================
# Expression Helper
# ============================================================================


def get_expression(name, mosfet):
    """Get expression by name"""
    expressions = {
        "gmid": mosfet.gmid_expression,
        "vgs": mosfet.vgs_expression,
        "vds": mosfet.vds_expression,
        "id": Expression(variables=["id"], function=lambda id: id, label="$I_D$ (A)"),
        "gm": Expression(variables=["gm"], function=lambda gm: gm, label="$g_m$ (S)"),
        "gds": Expression(
            variables=["gds"], function=lambda gds: gds, label="$g_{ds}$ (S)"
        ),
        "current_density": mosfet.current_density_expression,
        "ft": Expression(
            variables=["gm", "id"],
            function=lambda gm, id: gm / (2 * np.pi * 1e-15),  # Simplified
            label="$f_T$ (Hz)",
        ),
        "av": Expression(
            variables=["gm", "gds"],
            function=lambda gm, gds: gm / gds,
            label="$A_v$ (V/V)",
        ),
    }
    return expressions.get(name.lower())


# ============================================================================
# Main Analysis Functions
# ============================================================================


def generate_lookup_tables(lookup_dir, force=False):
    """Generate lookup tables if needed"""
    lookup_path = Path(lookup_dir)
    lookup_path.mkdir(exist_ok=True)

    # Check if tables already exist
    all_devices = [d.value for d in Sky130Device]
    existing = [d for d in all_devices if (lookup_path / f"{d}.npz").exists()]

    if len(existing) == len(all_devices) and not force:
        print(f"✓ All lookup tables exist in {lookup_dir}")
        return

    if force:
        print("Regenerating all lookup tables (forced)...")
    else:
        print(f"Generating missing lookup tables in {lookup_dir}...")

    # Get the generator setup
    generators_data = setup_lookup_generator()
    simulators = generators_data["simulators"]
    model_sweeps = generators_data["model_sweeps"]

    # Generate table for each device
    for device_name in all_devices:
        if not force and (lookup_path / f"{device_name}.npz").exists():
            print(f"  Skipping {device_name} (already exists)")
            continue

        print(f"\n  Generating {device_name}...")

        generator = LookupTableGenerator(
            description=f"Sky130 PDK - {device_name}",
            simulator=simulators[device_name],
            model_sweeps={device_name: model_sweeps[device_name]},
            n_process=1,
        )

        try:
            print("Running OP simulation...")
            generator.op_simulation()
            print("Building lookup table...")
            generator.build(lookup_dir, device_name)
            print(f"    ✓ {device_name} complete")
        except Exception as e:
            print(f"    ✗ {device_name} failed: {e}")
            import traceback

            traceback.print_exc()
            raise

    print(f"\n✓ All lookup tables saved to: {lookup_dir}")


def create_mosfet(device_name, vbs, vds, vgs, length, lookup_dir):
    """Create Mosfet object from lookup table"""
    table_path = Path(lookup_dir) / f"{device_name}.npz"

    if not table_path.exists():
        raise FileNotFoundError(f"Lookup table not found: {table_path}")

    lookup_table = load_lookup_table(str(table_path))

    mosfet = Mosfet(
        lookup_table=lookup_table,
        mos=device_name,
        vbs=vbs,
        vds=vds,
        vgs=vgs,
    )

    if length is not None:
        mosfet.length = length

    return mosfet


def plot_analysis(mosfet, config, output_dir):
    """Create a plot based on configuration"""
    if not config["enabled"]:
        return

    x_expr = get_expression(config["x_axis"], mosfet)
    y_expr = get_expression(config["y_axis"], mosfet)

    if x_expr is None or y_expr is None:
        print(f"✗ Invalid expression in plot config: {config}")
        return

    output_path = Path(output_dir) / config["filename"]
    output_path.parent.mkdir(parents=True, exist_ok=True)

    print(f"  Plotting: {config['title']}")

    fil_val = mosfet.length[:] if LENGTH_FILTER is None else np.array([LENGTH_FILTER])
    mosfet.plot_by_expression(
        x_expression=x_expr,
        y_expression=y_expr,
        filtered_values=fil_val,
        y_scale=config["y_scale"],
        save_fig=str(output_path),
    )

    print(f"    Saved: {output_path}")


if __name__ == "__main__":
    print("=" * 70)
    print("Sky130 MOSFET Characterization Tool")
    print("=" * 70)

    # Step 1: Generate lookup tables if needed
    print("\n[1] Checking lookup tables...")
    try:
        if AUTO_GENERATE:
            generate_lookup_tables(LOOKUP_DIR, force=REGENERATE)
        else:
            print(f"Auto-generation disabled. Using tables in {LOOKUP_DIR}")
    except Exception as e:
        print(f"✗ Failed to generate lookup tables: {e}")
        exit(1)

    # Step 2: Load device and create Mosfet object
    print(f"\n[2] Loading device: {DEVICE_TO_ANALYZE}")
    try:
        mosfet = create_mosfet(
            DEVICE_TO_ANALYZE,
            vbs=VBS,
            vds=VDS,
            vgs=VGS_RANGE,
            length=LENGTH_FILTER,
            lookup_dir=LOOKUP_DIR,
        )
        print(f"✓ Device loaded successfully")
        print(f"  VBS = {VBS}V, VDS = {VDS}V, VGS = {VGS_RANGE}")
        if LENGTH_FILTER:
            print(f"  Length filter: {LENGTH_FILTER*1e6:.2f}μm")
    except Exception as e:
        print(f"✗ Failed to load device: {e}")
        exit(1)

    # Step 3: Generate plots
    enabled_plots = [k for k, v in PLOT_CONFIG.items() if v["enabled"]]
    if enabled_plots:
        print(f"\n[3] Generating {len(enabled_plots)} plot(s)...")
        for plot_name, config in PLOT_CONFIG.items():
            try:
                plot_analysis(mosfet, config, FIGURE_DIR)
            except Exception as e:
                print(f"  ✗ Failed to generate {plot_name}: {e}")
    else:
        print("\n[3] No plots enabled")
