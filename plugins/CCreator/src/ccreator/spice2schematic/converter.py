"""Converts a parsed ngspice Netlist into schematic output representations.

Output:
  - One SchematicOutput per .subckt block (component)
  - One SchematicOutput for top-level if it contains analyses/top elements (testbench)

Produces JSON-serializable dicts for consumption by Schemify or other tools.
"""

from __future__ import annotations

import json
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any, Optional

from .layout import (
    PlacedElement,
    is_vdd_net,
    is_gnd_net,
    place,
    sym_info_for,
)
from .parser import AnalysisKind, Element, Model, Netlist, Param, Subckt
from .router import (
    ConnEntry,
    PowerKind,
    PowerSym,
    RouteResult,
    RouteWire,
    build_conns,
    route,
)


@dataclass
class Component:
    name: str
    symbol: str
    kind: str
    x: int
    y: int
    rot: int = 0
    flip: bool = False
    props: list[dict[str, str]] = field(default_factory=list)
    conns: list[dict[str, str]] = field(default_factory=list)
    spice_line: Optional[str] = None


@dataclass
class Wire:
    x0: int
    y0: int
    x1: int
    y1: int
    net_name: Optional[str] = None
    bus: bool = False


@dataclass
class Pin:
    name: str
    x: int
    y: int
    direction: str = "inout"


@dataclass
class SchematicOutput:
    """One schematic output file (component or testbench)."""

    filename: str
    stype: str  # "component" or "testbench"
    name: str
    pins: list[Pin] = field(default_factory=list)
    components: list[Component] = field(default_factory=list)
    wires: list[Wire] = field(default_factory=list)
    power_symbols: list[dict[str, Any]] = field(default_factory=list)
    sym_props: dict[str, str] = field(default_factory=dict)
    globals: list[str] = field(default_factory=list)
    plugin_block: dict[str, str] = field(default_factory=dict)
    control_block: Optional[str] = None

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)

    def to_json(self, indent: int = 2) -> str:
        return json.dumps(self.to_dict(), indent=indent)

    def to_chn(self) -> str:
        """Serialize to Schemify's native CHN text format."""
        lines: list[str] = []

        # Header
        if self.stype == "testbench":
            lines.append("chn_testbench 1.0")
        else:
            lines.append("chn 1.0")

        lines.append("")

        # Section header
        if self.stype == "testbench":
            lines.append(f"TESTBENCH {self.name}")
        else:
            lines.append(f"SYMBOL {self.name}")
            # Pins
            if self.pins:
                lines.append("  pins:")
                for pin in self.pins:
                    d = _pin_dir_str(pin.direction)
                    line = f"    {pin.name}  {d}"
                    if pin.x != 0 or pin.y != 0:
                        line += f"  x={pin.x}  y={pin.y}"
                    lines.append(line)
            # Params (non-metadata sym_props)
            _meta = {
                "description", "symbol_type", "format", "type",
                "template", "spice_format", "spice_lib",
            }
            params = {
                k: v for k, v in self.sym_props.items()
                if not k.startswith("analysis.") and not k.startswith("measure.")
                and k not in _meta
            }
            if params:
                lines.append("  params:")
                for k, v in params.items():
                    lines.append(f"    {k} = {v}")

        lines.append("")

        # SCHEMATIC (components only)
        if self.stype == "component":
            lines.append("SCHEMATIC")

        # Instances
        if self.components:
            lines.append("  instances:")
            for comp in self.components:
                kind_name = _kind_to_chn_name(comp.kind)
                if comp.kind == "subckt":
                    kind_name = comp.symbol
                line = f"    {comp.name}  {kind_name}  x={comp.x}  y={comp.y}"
                if comp.rot != 0:
                    line += f"  rot={comp.rot}"
                if comp.flip:
                    line += "  flip=1"
                for prop in comp.props:
                    line += f"  {prop['key']}={prop['val']}"
                lines.append(line)

        # Nets — built from component connections
        net_map: dict[str, list[str]] = {}
        for comp in self.components:
            for conn in comp.conns:
                net = conn["net"]
                if not net or net == "?":
                    continue
                net_map.setdefault(net, []).append(f"{comp.name}.{conn['pin']}")

        if net_map:
            lines.append("")
            lines.append("  nets:")
            for net_name, pins in net_map.items():
                lines.append(f"    {net_name}  -> {', '.join(pins)}")

        # Analyses
        analyses = {
            k[len("analysis."):]: v
            for k, v in self.sym_props.items()
            if k.startswith("analysis.")
        }
        if analyses:
            lines.append("")
            lines.append("  analyses:")
            for kind, val in analyses.items():
                lines.append(f"    {kind}: {val}")

        # Measures
        measures = {
            k[len("measure."):]: v
            for k, v in self.sym_props.items()
            if k.startswith("measure.")
        }
        if measures:
            lines.append("")
            lines.append("  measures:")
            for name, expr in measures.items():
                lines.append(f"    {name}: {expr}")

        # Code block
        if self.control_block:
            lines.append("  code_block:")
            for code_line in self.control_block.split("\n"):
                lines.append(f"    {code_line}")

        # Wires + power symbols as zero-length labeled wires
        all_wires = list(self.wires)
        for ps in self.power_symbols:
            all_wires.append(
                Wire(
                    x0=ps["x"], y0=ps["y"],
                    x1=ps["x"], y1=ps["y"],
                    net_name=ps.get("kind", ""),
                )
            )

        if all_wires:
            lines.append("")
            lines.append("  wires:")
            for w in all_wires:
                if w.x0 == w.x1 and w.y0 == w.y1 and not w.net_name:
                    continue
                line = f"    {w.x0} {w.y0} {w.x1} {w.y1}"
                if w.net_name:
                    line += f" {w.net_name}"
                lines.append(line)

        # Plugin block
        if self.plugin_block:
            lines.append("")
            lines.append("PLUGIN CCreator")
            for k, v in self.plugin_block.items():
                lines.append(f"  {k}: {v}")

        lines.append("")
        return "\n".join(lines)

    def write_chn(self, output_dir: str | Path) -> Path:
        """Write native CHN text format to output_dir/filename."""
        path = Path(output_dir) / self.filename
        path.write_text(self.to_chn())
        return path

    def write_json(self, output_dir: str | Path) -> Path:
        path = Path(output_dir) / self.filename
        path.write_text(self.to_json())
        return path


def convert(
    netlist: Netlist,
    source_path: str = "",
    flatten: bool = False,
) -> list[SchematicOutput]:
    """Convert a parsed netlist into schematic outputs."""
    outputs: list[SchematicOutput] = []

    # Convert each .subckt -> component
    for subckt in netlist.subckts:
        elems = subckt.elements
        placed = place(elems, netlist.models)
        route_result = route(elems, placed)
        sch = _build_component(netlist, subckt, placed, route_result, source_path)
        outputs.append(sch)

    # Convert top-level elements -> testbench if needed
    has_top = len(netlist.top_elements) > 0
    has_analyses = len(netlist.analyses) > 0 or netlist.control_block is not None

    if has_top or has_analyses:
        placed = place(netlist.top_elements, netlist.models)
        route_result = route(netlist.top_elements, placed)
        sch = _build_testbench(netlist, placed, route_result, source_path)
        outputs.append(sch)

    return outputs


def import_spice(
    source: str,
    source_path: str = "",
) -> list[SchematicOutput]:
    """Parse, layout, route, and convert a SPICE netlist source."""
    from .parser import parse

    netlist = parse(source)
    return convert(netlist, source_path)


def _build_component(
    netlist: Netlist,
    subckt: Subckt,
    placed: list[PlacedElement],
    route_result: RouteResult,
    source_path: str,
) -> SchematicOutput:
    sch = SchematicOutput(
        filename=f"{subckt.name}.chn",
        stype="component",
        name=subckt.name,
    )

    # Symbol pins (ports)
    n_ports = len(subckt.ports)
    for i, port in enumerate(subckt.ports):
        pin_x = -40 if i < n_ports // 2 + n_ports % 2 else 40
        pin_y = -(i * 40)
        sch.pins.append(Pin(name=port, x=pin_x, y=pin_y))

    # Symbol metadata
    sch.sym_props["format"] = _build_format_str(subckt)
    sch.sym_props["type"] = "subcircuit"
    sch.sym_props["template"] = _build_template_str(subckt)

    # Populate instances, wires, power
    _populate_instances(sch, subckt.elements, placed, netlist.models)
    _populate_wires(sch, route_result)
    _populate_power_symbols(sch, route_result.power)

    for g in netlist.globals:
        sch.globals.append(g)

    sch.plugin_block = {"source": source_path, "subckt": subckt.name}

    return sch


def _build_testbench(
    netlist: Netlist,
    placed: list[PlacedElement],
    route_result: RouteResult,
    source_path: str,
) -> SchematicOutput:
    safe_title = _sanitize_name(netlist.title)
    sch = SchematicOutput(
        filename=f"{safe_title}_tb.chn_tb",
        stype="testbench",
        name=safe_title,
    )

    _populate_instances(sch, netlist.top_elements, placed, netlist.models)
    _populate_wires(sch, route_result)
    _populate_power_symbols(sch, route_result.power)

    for g in netlist.globals:
        sch.globals.append(g)

    # Analyses
    for an in netlist.analyses:
        key = f"analysis.{an.kind.value}"
        sch.sym_props[key] = _analysis_val(an)

    # Measures
    for m in netlist.measures:
        sch.sym_props[f"measure.{m.name}"] = m.expr

    # .control block
    if netlist.control_block:
        sch.control_block = netlist.control_block

    sch.plugin_block = {"source": source_path}

    return sch


def _populate_instances(
    sch: SchematicOutput,
    elems: list[Element],
    placed: list[PlacedElement],
    models: list[Model],
) -> None:
    for i, elem in enumerate(elems):
        if i >= len(placed):
            break
        p = placed[i]
        dk = _device_kind_for(elem, models)
        props = _build_props(elem)
        conns = build_conns(elem, p.sym.sym)

        sch.components.append(
            Component(
                name=elem.name,
                symbol=p.sym.sym,
                kind=dk,
                x=p.x,
                y=p.y,
                props=[{"key": pr.key, "val": pr.val} for pr in props],
                conns=[{"pin": c.pin, "net": c.net} for c in conns],
                spice_line=_spice_line_for(elem),
            )
        )


def _populate_wires(sch: SchematicOutput, route_result: RouteResult) -> None:
    for w in route_result.wires:
        sch.wires.append(
            Wire(x0=w.x0, y0=w.y0, x1=w.x1, y1=w.y1, net_name=w.net_name)
        )


def _populate_power_symbols(
    sch: SchematicOutput, power: list[PowerSym]
) -> None:
    for i, ps in enumerate(power):
        sym_name = ps.kind.value
        sch.power_symbols.append(
            {
                "name": f"{sym_name}{i}",
                "symbol": sym_name,
                "kind": sym_name,
                "x": ps.x,
                "y": ps.y,
            }
        )


def _device_kind_for(elem: Element, models: list[Model]) -> str:
    info = sym_info_for(elem, models)
    mapping = {
        "r": "resistor",
        "c": "capacitor",
        "l": "inductor",
        "d": "zener" if info.sym == "zener" else "diode",
        "m": "pmos4" if info.sym == "pmos4" else "nmos4",
        "q": "pnp" if info.sym == "pnp" else "npn",
        "j": "pjfet" if info.sym == "pjfet" else "njfet",
        "v": "vsource",
        "i": "isource",
        "e": "vcvs",
        "g": "vccs",
        "f": "cccs",
        "h": "ccvs",
        "b": "behavioral",
        "x": "subckt",
    }
    return mapping.get(elem.prefix, "unknown")


def _build_props(elem: Element) -> list[Param]:
    props: list[Param] = []
    p = elem.prefix

    if p in ("r", "c"):
        if elem.value:
            props.append(Param("value", elem.value))
        device = "resistor" if p == "r" else "capacitor"
        props.append(Param("device", device))
        props.append(Param("m", "1"))
    elif p == "l":
        if elem.value:
            props.append(Param("value", elem.value))
        props.append(Param("m", "1"))
    elif p == "d":
        if elem.model:
            props.append(Param("model", elem.model))
    elif p == "m":
        if elem.model:
            props.append(Param("model", elem.model))
        canon_keys = {"w": "W", "l": "L", "m": "M", "nf": "nf", "ad": "ad", "as": "as"}
        allowed = {"w", "l", "nf", "m", "ad", "as"}
        has_m = False
        for par in elem.params:
            kl = par.key.lower()
            if kl in allowed:
                canon = canon_keys.get(kl, par.key)
                props.append(Param(canon, par.val))
                if kl == "m":
                    has_m = True
        if not has_m:
            props.append(Param("M", "1"))
    elif p == "q":
        if elem.model:
            props.append(Param("model", elem.model))
        for par in elem.params:
            props.append(Param(par.key, par.val))
    elif p == "j":
        if elem.model:
            props.append(Param("model", elem.model))
    elif p in ("v", "i"):
        if elem.value:
            props.append(Param("value", elem.value))
    elif p == "x":
        for par in elem.params:
            props.append(Param(par.key, par.val))
    else:
        if elem.value:
            props.append(Param("value", elem.value))
        for par in elem.params:
            props.append(Param(par.key, par.val))

    return props


def _spice_line_for(elem: Element) -> Optional[str]:
    if elem.prefix in ("e", "g", "f", "h", "b"):
        return elem.value
    return None


def _build_format_str(subckt: Subckt) -> str:
    parts = ["@name @pinlist @symname"]
    for p in subckt.params:
        parts.append(f"{p.key}=@{p.key}")
    return " ".join(parts)


def _build_template_str(subckt: Subckt) -> str:
    parts = ["name=X1"]
    for p in subckt.params:
        parts.append(f"{p.key}={p.val}")
    return " ".join(parts)


def _analysis_val(an) -> str:
    from .parser import Analysis, AnalysisKind

    if an.kind == AnalysisKind.OP:
        return ""

    toks = an.raw.split()

    if an.kind == AnalysisKind.TRAN:
        step = toks[0] if len(toks) > 0 else "1n"
        stop = toks[1] if len(toks) > 1 else "1u"
        return f"step={step} stop={stop}"

    if an.kind == AnalysisKind.AC:
        pts = toks[1] if len(toks) > 1 else "20"
        f1 = toks[2] if len(toks) > 2 else "1"
        f2 = toks[3] if len(toks) > 3 else "1G"
        return f"points_per_dec={pts} start={f1} stop={f2}"

    if an.kind == AnalysisKind.DC:
        src = toks[0] if len(toks) > 0 else "V1"
        start = toks[1] if len(toks) > 1 else "0"
        stop = toks[2] if len(toks) > 2 else "1.8"
        step = toks[3] if len(toks) > 3 else "0.01"
        return f"source={src} start={start} stop={stop} step={step}"

    if an.kind == AnalysisKind.NOISE:
        out = toks[0] if len(toks) > 0 else "V(out)"
        src = toks[1] if len(toks) > 1 else "VIN"
        return f"output={out} input={src}"

    if an.kind == AnalysisKind.TF:
        out = toks[0] if len(toks) > 0 else "V(out)"
        src = toks[1] if len(toks) > 1 else "VIN"
        return f"output={out} input={src}"

    return ""


def _sanitize_name(name: str) -> str:
    if not name:
        return "netlist"
    first_word = name.split()[0] if name.split() else "netlist"
    return first_word


def _kind_to_chn_name(kind: str) -> str:
    """Map internal device kind to CHN format name (mirrors Writer.zig kindToName)."""
    mapping = {
        "nmos4": "nmos",
        "pmos4": "pmos",
        "resistor3": "resistor",
        "var_resistor": "resistor",
        "zener": "diode",
        "sqwsource": "vsource",
        "ammeter": "vsource",
    }
    return mapping.get(kind, kind)


def _pin_dir_str(direction: str) -> str:
    """Map pin direction to CHN format string (mirrors Writer.zig pinDirStr)."""
    mapping = {
        "input": "in",
        "output": "out",
        "inout": "inout",
        "power": "inout",
        "ground": "inout",
    }
    return mapping.get(direction, direction)
