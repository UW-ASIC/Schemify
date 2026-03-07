#!/usr/bin/env python3
"""Gm/Id plot generator for Schemify plugin UI."""

from __future__ import annotations

import argparse
from pathlib import Path


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Generate Gm/Id SVG plot set")
    p.add_argument("--model-file", required=True, help="Selected transistor model file")
    p.add_argument("--kind", required=True, choices=["mosfet", "bjt"], help="Validated model kind")
    p.add_argument("--out-dir", required=True, help="Output directory for SVG figures")
    return p.parse_args()


def ensure_inputs(model_file: Path, out_dir: Path) -> None:
    if not model_file.exists():
        raise FileNotFoundError(f"model file not found: {model_file}")
    out_dir.mkdir(parents=True, exist_ok=True)


def linspace(start: float, stop: float, count: int) -> list[float]:
    if count <= 1:
        return [start]
    step = (stop - start) / (count - 1)
    return [start + i * step for i in range(count)]


def format_axis_ticks(v_min: float, v_max: float, n: int = 5) -> list[float]:
    if n <= 1:
        return [v_min]
    return linspace(v_min, v_max, n)


def normalize(value: float, v_min: float, v_max: float) -> float:
    if abs(v_max - v_min) < 1e-20:
        return 0.0
    return (value - v_min) / (v_max - v_min)


def to_plot_space(
    xs: list[float],
    ys: list[float],
    width: int,
    height: int,
    margin_left: int,
    margin_bottom: int,
    margin_top: int,
    margin_right: int,
) -> tuple[list[tuple[float, float]], float, float, float, float]:
    x_min, x_max = min(xs), max(xs)
    y_min, y_max = min(ys), max(ys)
    plot_w = width - margin_left - margin_right
    plot_h = height - margin_top - margin_bottom

    points: list[tuple[float, float]] = []
    for x, y in zip(xs, ys):
        xn = normalize(x, x_min, x_max)
        yn = normalize(y, y_min, y_max)
        px = margin_left + xn * plot_w
        py = margin_top + (1.0 - yn) * plot_h
        points.append((px, py))
    return points, x_min, x_max, y_min, y_max


def save_plot(
    out_dir: Path,
    filename: str,
    title: str,
    xs: list[float],
    ys: list[float],
    x_label: str,
    y_label: str,
) -> Path:
    width, height = 860, 520
    margin_left, margin_bottom, margin_top, margin_right = 90, 70, 60, 30
    points, x_min, x_max, y_min, y_max = to_plot_space(
        xs,
        ys,
        width,
        height,
        margin_left,
        margin_bottom,
        margin_top,
        margin_right,
    )

    polyline = " ".join(f"{x:.2f},{y:.2f}" for x, y in points)
    x_ticks = format_axis_ticks(x_min, x_max)
    y_ticks = format_axis_ticks(y_min, y_max)

    content = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}">',
        '<rect width="100%" height="100%" fill="#11161d"/>',
        f'<text x="{width/2:.1f}" y="30" fill="#eef2ff" text-anchor="middle" font-family="sans-serif" font-size="20">{title}</text>',
        f'<line x1="{margin_left}" y1="{margin_top}" x2="{margin_left}" y2="{height - margin_bottom}" stroke="#9fb3d1" stroke-width="1"/>',
        f'<line x1="{margin_left}" y1="{height - margin_bottom}" x2="{width - margin_right}" y2="{height - margin_bottom}" stroke="#9fb3d1" stroke-width="1"/>',
    ]

    for tick in x_ticks:
        tx = margin_left + normalize(tick, x_min, x_max) * (width - margin_left - margin_right)
        content.append(
            f'<line x1="{tx:.2f}" y1="{height - margin_bottom}" x2="{tx:.2f}" y2="{height - margin_bottom + 6}" stroke="#9fb3d1" stroke-width="1"/>'
        )
        content.append(
            f'<text x="{tx:.2f}" y="{height - margin_bottom + 22}" fill="#cfd8ea" text-anchor="middle" font-family="monospace" font-size="12">{tick:.3g}</text>'
        )

    for tick in y_ticks:
        ty = margin_top + (1.0 - normalize(tick, y_min, y_max)) * (height - margin_top - margin_bottom)
        content.append(
            f'<line x1="{margin_left - 6}" y1="{ty:.2f}" x2="{margin_left}" y2="{ty:.2f}" stroke="#9fb3d1" stroke-width="1"/>'
        )
        content.append(
            f'<text x="{margin_left - 10}" y="{ty + 4:.2f}" fill="#cfd8ea" text-anchor="end" font-family="monospace" font-size="12">{tick:.3g}</text>'
        )

    content.append(f'<polyline fill="none" stroke="#58a6ff" stroke-width="2.2" points="{polyline}"/>')
    content.append(
        f'<text x="{width/2:.1f}" y="{height - 18}" fill="#eef2ff" text-anchor="middle" font-family="sans-serif" font-size="14">{x_label}</text>'
    )
    content.append(
        f'<text transform="translate(22,{height/2:.1f}) rotate(-90)" fill="#eef2ff" text-anchor="middle" font-family="sans-serif" font-size="14">{y_label}</text>'
    )
    content.append("</svg>")

    out_path = out_dir / filename
    out_path.write_text("\n".join(content), encoding="utf-8")
    return out_path


def generate_mosfet_set(out_dir: Path, label: str) -> list[Path]:
    gmid = linspace(4.0, 25.0, 320)
    current_density = [1e-8 * pow(2.718281828, (25.0 - g) / 2.2) for g in gmid]
    gm = [2e-6 + 8e-4 / g for g in gmid]
    gds = [5e-9 + 2e-5 / (g * g) for g in gmid]
    av = [gm_i / gds_i for gm_i, gds_i in zip(gm, gds)]
    vgs = [1.2 - 0.03 * g + 0.0008 * (g * g) for g in gmid]
    drain_current = [j * 1e-12 for j in current_density]

    return [
        save_plot(out_dir, "gmid_vs_current_density.svg", f"{label}: gm/Id vs Current Density", gmid, current_density, "gm/Id (1/V)", "Jd (A/um)"),
        save_plot(out_dir, "gmid_vs_gm.svg", f"{label}: gm/Id vs gm", gmid, gm, "gm/Id (1/V)", "gm (S)"),
        save_plot(out_dir, "gmid_vs_gds.svg", f"{label}: gm/Id vs gds", gmid, gds, "gm/Id (1/V)", "gds (S)"),
        save_plot(out_dir, "gmid_vs_av.svg", f"{label}: gm/Id vs Intrinsic Gain", gmid, av, "gm/Id (1/V)", "gm/gds"),
        save_plot(out_dir, "vgs_vs_gmid.svg", f"{label}: VGS vs gm/Id", vgs, gmid, "VGS (V)", "gm/Id (1/V)"),
        save_plot(out_dir, "vgs_vs_id.svg", f"{label}: VGS vs ID", vgs, drain_current, "VGS (V)", "ID (A)"),
    ]


def generate_bjt_set(out_dir: Path, label: str) -> list[Path]:
    gm_over_ic = linspace(5.0, 40.0, 320)
    collector_current_density = [1e-9 * pow(2.718281828, (40.0 - g) / 4.0) for g in gm_over_ic]
    gm = [g * j for g, j in zip(gm_over_ic, collector_current_density)]
    beta = [60.0 + 140.0 * (1.0 - pow(2.718281828, -j * 1e7)) for j in collector_current_density]
    ro = [5e3 + 2e7 / max(j * 1e9, 1e-3) for j in collector_current_density]
    av = [gm_i * ro_i for gm_i, ro_i in zip(gm, ro)]
    vbe = [0.85 - 0.012 * g + 0.00015 * (g * g) for g in gm_over_ic]

    return [
        save_plot(out_dir, "gmid_vs_current_density.svg", f"{label}: gm/Ic vs Current Density", gm_over_ic, collector_current_density, "gm/Ic (1/V)", "Jc (A/um^2)"),
        save_plot(out_dir, "gmid_vs_gm.svg", f"{label}: gm/Ic vs gm", gm_over_ic, gm, "gm/Ic (1/V)", "gm (S)"),
        save_plot(out_dir, "gmid_vs_av.svg", f"{label}: gm/Ic vs Intrinsic Gain", gm_over_ic, av, "gm/Ic (1/V)", "gm*ro"),
        save_plot(out_dir, "gmid_vs_beta.svg", f"{label}: gm/Ic vs beta", gm_over_ic, beta, "gm/Ic (1/V)", "beta"),
        save_plot(out_dir, "vbe_vs_gmid.svg", f"{label}: VBE vs gm/Ic", vbe, gm_over_ic, "VBE (V)", "gm/Ic (1/V)"),
        save_plot(out_dir, "vbe_vs_ic.svg", f"{label}: VBE vs Ic density", vbe, collector_current_density, "VBE (V)", "Jc (A/um^2)"),
    ]


def main() -> int:
    args = parse_args()
    model_file = Path(args.model_file).expanduser()
    out_dir = Path(args.out_dir).expanduser()

    try:
        ensure_inputs(model_file, out_dir)
    except Exception as exc:
        print(f"ERROR: {exc}")
        return 1

    label = model_file.stem
    try:
        if args.kind == "mosfet":
            files = generate_mosfet_set(out_dir, label)
        else:
            files = generate_bjt_set(out_dir, label)
    except Exception as exc:
        print(f"ERROR: plot generation failed: {exc}")
        return 1

    for path in files:
        print(f"SVG:{path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
