"""Configuration parser/serializer for .chn files (PLUGIN Optimizer block).

Preserves compatibility with the Schemify plugin config format.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Optional

from .problem import (
    Parameter,
    Problem,
    Resistor,
    SpecKind,
    Specification,
    Testbench,
    Transistor,
)


@dataclass
class OptimizerConfig:
    """Parsed optimizer configuration."""
    transistors: list[dict] = field(default_factory=list)
    resistors: list[dict] = field(default_factory=list)
    parameters: list[dict] = field(default_factory=list)
    testbenches: list[str] = field(default_factory=list)
    objectives: list[dict] = field(default_factory=list)
    max_iter: int = 50
    lhc_samples: int = 20
    model_lib: str = ""
    vdd: float = 1.8
    best_values: dict[str, float] = field(default_factory=dict)


def parse_config(data: str) -> Optional[OptimizerConfig]:
    """Parse PLUGIN Optimizer block from .chn file content."""
    cfg = OptimizerConfig()
    found = False
    in_optimizer = False

    for raw_line in data.splitlines():
        line = raw_line.rstrip()

        if line.startswith("PLUGIN "):
            plugin_name = line[7:].strip()
            in_optimizer = plugin_name == "Optimizer"
            if in_optimizer:
                found = True
            continue

        if in_optimizer and line and not line[0].isspace():
            in_optimizer = False

        if not in_optimizer:
            continue

        trimmed = line.strip()
        if not trimmed:
            continue

        colon = trimmed.find(":")
        if colon < 0:
            continue

        key = trimmed[:colon].strip()
        val = trimmed[colon + 1:].strip()

        if key.startswith("tb."):
            cfg.testbenches.append(val)
        elif key.startswith("param."):
            rest = key[6:]
            last_dot = rest.rfind(".")
            if last_dot < 0:
                continue
            inst = rest[:last_dot]
            prop = rest[last_dot + 1:]
            fields = _parse_kv_fields(val)
            cfg.parameters.append({
                "instance": inst,
                "property": prop,
                "enabled": fields.get("enabled", "1") != "0",
                "min": float(fields.get("min", "0")),
                "max": float(fields.get("max", "1")),
                "step": float(fields.get("step", "0")),
            })
        elif key.startswith("transistor."):
            rest = key[11:]
            fields = _parse_kv_fields(val)
            cfg.transistors.append({
                "instance": rest,
                "model": fields.get("model", ""),
                "kind": fields.get("kind", "nmos"),
                "L": float(fields.get("L", "100e-9")),
                "gmid_min": float(fields.get("gmid_min", "3")),
                "gmid_max": float(fields.get("gmid_max", "25")),
            })
        elif key.startswith("obj."):
            name = key[4:]
            fields = _parse_kv_fields(val)
            kind_str = fields.get("kind", "maximize")
            cfg.objectives.append({
                "name": name,
                "kind": kind_str,
                "target": float(fields.get("target", "0")),
                "weight": float(fields.get("weight", "1.0")),
            })
        elif key.startswith("best."):
            name = key[5:]
            cfg.best_values[name] = _parse_float(val)
        elif key == "settings.max_iter":
            cfg.max_iter = int(_parse_float(val))
        elif key == "settings.lhc_samples":
            cfg.lhc_samples = int(_parse_float(val))
        elif key == "settings.model_lib":
            cfg.model_lib = val
        elif key == "settings.vdd":
            cfg.vdd = _parse_float(val)

    return cfg if found else None


def config_to_problem(cfg: OptimizerConfig) -> Problem:
    """Convert parsed config to Problem instance."""
    kind_map = {
        "maximize": SpecKind.MAXIMIZE,
        "minimize": SpecKind.MINIMIZE,
        "geq": SpecKind.GREATER_EQUAL,
        "leq": SpecKind.LESS_EQUAL,
    }

    transistors = [
        Transistor(
            instance=t["instance"],
            model=t["model"],
            kind=t["kind"],
            L=t["L"],
            gmid_min=t.get("gmid_min", 3.0),
            gmid_max=t.get("gmid_max", 25.0),
        )
        for t in cfg.transistors
    ]

    specs = [
        Specification(
            name=o["name"],
            kind=kind_map.get(o["kind"], SpecKind.MAXIMIZE),
            target=o.get("target", 0.0),
            weight=o.get("weight", 1.0),
        )
        for o in cfg.objectives
    ]

    testbenches = [
        Testbench(path=p, name=p, specs=specs)
        for p in cfg.testbenches
    ]

    return Problem(
        transistors=transistors,
        testbenches=testbenches,
    )


def build_block(cfg: OptimizerConfig) -> str:
    """Build PLUGIN Optimizer block text."""
    lines = ["\nPLUGIN Optimizer", "  version: 1"]

    for i, tb in enumerate(cfg.testbenches):
        lines.append(f"  tb.{i}: {tb}")

    for t in cfg.transistors:
        parts = [f"model={t['model']}", f"kind={t['kind']}", f"L={t['L']:.4e}"]
        if "gmid_min" in t:
            parts.append(f"gmid_min={t['gmid_min']}")
        if "gmid_max" in t:
            parts.append(f"gmid_max={t['gmid_max']}")
        lines.append(f"  transistor.{t['instance']}: {' '.join(parts)}")

    for p in cfg.parameters:
        enabled = 1 if p.get("enabled", True) else 0
        lines.append(
            f"  param.{p['instance']}.{p['property']}: "
            f"enabled={enabled} min={p['min']:.4e} max={p['max']:.4e} step={p['step']:.4e}"
        )

    for o in cfg.objectives:
        lines.append(
            f"  obj.{o['name']}: kind={o['kind']} target={o['target']:.4e} weight={o['weight']:.4e}"
        )

    for name, val in cfg.best_values.items():
        lines.append(f"  best.{name}: {val:.4e}")

    lines.append(f"  settings.max_iter: {cfg.max_iter}")
    lines.append(f"  settings.lhc_samples: {cfg.lhc_samples}")

    if cfg.model_lib:
        lines.append(f"  settings.model_lib: {cfg.model_lib}")
    if cfg.vdd != 1.8:
        lines.append(f"  settings.vdd: {cfg.vdd}")

    lines.append("")
    return "\n".join(lines)


def _parse_kv_fields(val: str) -> dict[str, str]:
    """Parse 'key=value key2=value2' into dict."""
    fields = {}
    for field_str in val.split():
        eq = field_str.find("=")
        if eq > 0:
            fields[field_str[:eq]] = field_str[eq + 1:]
    return fields


def _parse_float(s: str) -> float:
    try:
        return float(s)
    except ValueError:
        return 0.0
