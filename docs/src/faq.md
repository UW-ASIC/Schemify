# FAQ

## General

**What platforms does Schemify run on?**

Schemify runs natively on Linux (X11 and Wayland). It also compiles to WebAssembly for the browser. macOS and Windows support is planned.

**Is Schemify free?**

Yes. Schemify is open-source under the MIT license.

**How does Schemify compare to KiCad / Xschem / LTspice?**

Schemify focuses on schematic capture with tight simulation integration. It's faster to launch and navigate than Electron-based tools, and its text-based file format is designed for version control. It does not (yet) include PCB layout -- use KiCad or another tool for that.

## Installation

**Why does Schemify require Rust nightly?**

Some egui/eframe features and performance optimizations use nightly-only Rust features. A stable Rust build is a future goal.

**Do I need Python for simulation?**

Yes. The simulation pipeline uses PySpice (a Python module) to translate circuits and drive SPICE backends. Without Python, you can still use Schemify as a schematic editor -- just simulation won't work.

**Which SPICE backend should I install?**

Start with NgSpice -- it's free, widely available, and the best-tested backend. Install it with your system package manager (`apt install ngspice`, `pacman -S ngspice`, etc.).

## Usage

**How do I undo a mistake?**

Press **Ctrl+Z**. Every action in Schemify is undoable. Redo with **Ctrl+Y**.

**Can I use Schemify without a mouse?**

Yes. Every action has a keyboard shortcut. Use **:** to open the command palette for anything you can't remember the shortcut for.

**How do I connect two distant parts of a schematic?**

Use net labels (`lab_pin`). Place a label on each wire and give them the same name. They're electrically connected without a visible wire.

**How do I create a hierarchical design?**

Save your sub-block as a `.chn` file. In the parent schematic, place it as a `subckt` instance. The sub-block's ports become the instance's pins.

**Can I import existing SPICE netlists?**

Yes:
```sh
schemify --file output.chn import-spice existing_circuit.spice --save
```
This creates a schematic from the netlist with automatic component placement.

## Simulation

**Simulation isn't running. What do I check?**

1. Is Python 3 installed? (`python3 --version`)
2. Is NgSpice (or another backend) installed? (`ngspice --version`)
3. Is PySpice available? (Check `PYSPICE_MODULE_DIR` or build with Nix)
4. Are you running a testbench (`.chn_tb`), not a plain schematic?

**Can I simulate directly from a .chn file?**

No. You need a testbench (`.chn_tb`) that instantiates your circuit, adds stimulus, and specifies which analysis to run.

**How do I add AC/transient stimulus?**

In your testbench, set the voltage source parameters. For example, a 1 kHz sine wave: set the source to `ac=1 sin(0 1 1k)`.

## Files & Version Control

**Can I use Git with Schemify files?**

Yes -- this is a core design goal. `.chn` files are line-oriented plain text. They diff cleanly and merge with standard Git tools.

**What's the difference between .chn and .chn_tb?**

Structurally, they're almost identical. `.chn` is a reusable circuit (can be a subcircuit). `.chn_tb` is a testbench -- it instantiates a DUT and adds stimulus for simulation.

## Plugins

**What languages can I write plugins in?**

Any language that can read/write JSON over stdin/stdout. The repo includes examples in Python, JavaScript, Rust, and Bash.

**How do I install a plugin?**

Place the plugin directory (with its `plugin.toml` manifest) in your project's `plugins/` folder. Press **F6** to load it.
