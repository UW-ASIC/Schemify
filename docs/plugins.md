# Standalone Plugin Candidates

Plugins that already have `pyproject.toml` with hatchling build and can be published to PyPI as independent packages.

## Ready for PyPI

### schemify-spiceimport (SpiceImport)
- **Language**: Python
- **Dependencies**: None
- **What it does**: Converts SPICE netlists to Schemify schematics (netlist parsing, topological placement, Manhattan wire routing, power symbol insertion)
- **CLI**: `spice2schematic/cli.py` works standalone
- **Package name**: `schemify-spiceimport`
- **Path**: `plugins/SpiceImport/`

### schemify-themes (Themes)
- **Language**: Python
- **Dependencies**: None
- **What it does**: Theme manager with 7 built-in JSON themes + user theme support (`~/.config/Schemify/themes/*.json`)
- **Package name**: `schemify-themes`
- **Path**: `plugins/Themes/`

### schemify-gmid-optimizer (GMIDOptimizer)
- **Language**: Python
- **Dependencies**: numpy, scipy, pyspice, botorch, gpytorch, torch, scikit-learn, matplotlib
- **What it does**: Bayesian optimization for MOSFET sizing using gm/Id methodology
- **Package name**: `schemify-gmid-optimizer`
- **Path**: `plugins/GMIDOptimizer/`

### schemify-pdk-switcherino (PDKSwitcherino)
- **Language**: Python
- **Dependencies**: PySpice>=1.5, numpy, scipy
- **What it does**: Cross-PDK remapping with gm/Id preservation. Supports sky130, gf180, ihp-sg13g2 via environment variables.
- **Package name**: `schemify-pdk-switcherino`
- **Path**: `plugins/PDKSwitcherino/`

## Partially Standalone

### schemify-ccreator (CCreator)
- **Language**: Python
- **Dependencies**: sympy, numpy, scipy, matplotlib, PySpice>=1.5, botorch, gpytorch, torch, scikit-learn
- **What it does**: Full circuit design toolkit (behavioral/realistic circuits, testbench builder, SPICE export)
- **Package name**: `schemify-ccreator`
- **Path**: `plugins/CCreator/`
- **Note**: Currently embeds gmid_optimizer, pdk_switcherino, and spice2schematic as internal subpackages. Extracting those as dependencies would make it cleaner.

## Not Standalone (Native Plugins)

| Plugin | Language | Reason |
|--------|----------|--------|
| EasyImport | Zig | Native binary, no Python layer |
| GitBlame | C | Native binary, no Python layer |
| GmIDVisualizer | C++ | Native binary with C++ dep submodule |
| VimKeybinds | C | Native binary, no Python layer |
| AgentHarness | Python | No pyproject.toml; deeply integrated (skill docs, RPC server, chat panel). Could be standalone but needs pyproject.toml + packaging work. |
