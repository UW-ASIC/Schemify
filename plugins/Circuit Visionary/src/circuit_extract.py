"""circuit_extract.py — CLI entry point for the CircuitVision pipeline.

Usage:
    python circuit_extract.py --input image.jpg --stdout
    python circuit_extract.py --input image.jpg --output result.json
    python circuit_extract.py --input schematic.pdf --style datasheet --stdout

The Zig editor spawns this as a subprocess and reads CircuitGraph JSON from
stdout. No FFI, no shared memory — just a process boundary.
"""

from __future__ import annotations

import argparse
import json
import logging
import sys
import time
from pathlib import Path
from typing import Optional

import numpy as np

from circuit_graph import (
    CircuitGraph,
    Metadata,
    ImageDimensions,
    Style,
    Warning,
    WarningType,
)
from style_classifier import StyleClassifier
from preprocessors import PREPROCESSORS
from detector import ComponentDetector
from crossing_classifier import CrossingClassifier
from wire_tracer import WireTracer
from mosfet_resolver import MOSFETResolver
from label_reader import LabelReader
from topology import TopologyBuilder
from vlm_verify import VLMVerifier

log = logging.getLogger("CircuitVision")


# ── Pipeline ──────────────────────────────────────────────────────────────── #


class Pipeline:
    """Orchestrates the full image → CircuitGraph extraction."""

    def __init__(
        self,
        *,
        style_override: Optional[str] = None,
        enable_vlm: bool = False,
        vlm_backend: str = "claude",
        model_dir: Optional[str] = None,
    ):
        self.style_override = style_override
        self.enable_vlm = enable_vlm

        model_path = Path(model_dir) if model_dir else None
        self.style_classifier = StyleClassifier(model_path=model_path)
        self.detector = ComponentDetector(model_path=model_path)
        self.crossing_classifier = CrossingClassifier(model_path=model_path)
        self.wire_tracer = WireTracer()
        self.mosfet_resolver = MOSFETResolver()
        self.label_reader = LabelReader()
        self.topology_builder = TopologyBuilder()
        self.vlm_verifier = VLMVerifier(backend=vlm_backend) if enable_vlm else None

    def run(self, image_path: str | Path) -> CircuitGraph:
        image_path = Path(image_path)
        if not image_path.exists():
            raise FileNotFoundError(f"Image not found: {image_path}")

        t0 = time.monotonic()
        image = _load_image(image_path)
        h, w = image.shape[:2]

        # Stage 1: Style classification
        if self.style_override:
            style = Style(self.style_override)
            style_conf = 1.0
        else:
            style, style_conf = self.style_classifier.classify(image)
        log.info("Style: %s (%.2f)", style.value, style_conf)

        # Stage 2: Per-style preprocessing
        preprocessor_cls = PREPROCESSORS.get(style.value)
        if preprocessor_cls:
            preprocessor = preprocessor_cls()
            processed = preprocessor.process(image)
        else:
            processed = image

        # Stage 3: Component detection (YOLOv11)
        detections = self.detector.detect(processed)
        log.info("Detected %d components", len(detections))

        # Stage 4: Wire tracing (CCL + skeletonization)
        wire_segments = self.wire_tracer.trace(processed, detections)
        log.info("Traced %d wire segments", len(wire_segments))

        # Stage 5: Crossing classification
        crossings = self.crossing_classifier.classify(processed, wire_segments, style)

        # Stage 6: MOSFET terminal resolution (Razavi-style)
        resolved = self.mosfet_resolver.resolve(detections, processed)

        # Stage 7: OCR / label reading
        labels = self.label_reader.read(processed, detections)

        # Stage 8: Topology construction
        graph = self.topology_builder.build(
            detections=resolved,
            wire_segments=wire_segments,
            crossings=crossings,
            labels=labels,
            style=style,
        )

        # Stage 9: VLM verification (optional)
        if self.vlm_verifier:
            vlm_warnings = self.vlm_verifier.verify(image_path, graph)
            graph.warnings.extend(vlm_warnings)

        # Finalize metadata
        elapsed = time.monotonic() - t0
        graph.metadata = Metadata(
            source_image=str(image_path),
            detected_style=style.value,
            overall_confidence=_overall_confidence(graph),
            image_dimensions=ImageDimensions(width=w, height=h),
            crossing_convention=_infer_crossing_convention(style),
            pipeline_version="0.1.0",
        )
        log.info(
            "Pipeline complete: %d components, %d nets, %.2fs",
            len(graph.components),
            len(graph.nets),
            elapsed,
        )
        return graph


def _load_image(path: Path) -> np.ndarray:
    """Load an image from disk. Handles common formats + PDF first page."""
    import cv2

    if path.suffix.lower() == ".pdf":
        try:
            from pdf2image import convert_from_path

            pages = convert_from_path(str(path), first_page=1, last_page=1, dpi=300)
            return np.array(pages[0])[:, :, ::-1]  # RGB → BGR for OpenCV
        except ImportError:
            raise RuntimeError("pdf2image required for PDF input: pip install pdf2image")

    img = cv2.imread(str(path))
    if img is None:
        raise ValueError(f"Could not read image: {path}")
    return img


def _overall_confidence(graph: CircuitGraph) -> float:
    confidences = [c.confidence for c in graph.components]
    confidences += [n.confidence for n in graph.nets]
    if not confidences:
        return 0.0
    return sum(confidences) / len(confidences)


def _infer_crossing_convention(style: Style) -> str:
    if style == Style.TEXTBOOK:
        return "dot_means_connected"
    if style == Style.DATASHEET:
        return "dot_means_connected"
    return "ambiguous"


# ── CLI ───────────────────────────────────────────────────────────────────── #


def main():
    parser = argparse.ArgumentParser(
        description="CircuitVision: extract circuit topology from images"
    )
    parser.add_argument("--input", required=True, help="Path to input image or PDF")
    parser.add_argument("--output", help="Path to write CircuitGraph JSON")
    parser.add_argument(
        "--stdout", action="store_true", help="Write JSON to stdout (for editor IPC)"
    )
    parser.add_argument(
        "--style",
        choices=["handdrawn", "textbook", "datasheet"],
        help="Override automatic style detection",
    )
    parser.add_argument("--vlm", action="store_true", help="Enable VLM verification")
    parser.add_argument(
        "--vlm-backend",
        default="claude",
        choices=["claude", "openai"],
        help="VLM backend for verification",
    )
    parser.add_argument("--model-dir", help="Path to model weights directory")
    parser.add_argument(
        "--verbose", "-v", action="store_true", help="Verbose logging"
    )
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="[CircuitVision] %(levelname)s %(message)s",
        stream=sys.stderr,
    )

    pipeline = Pipeline(
        style_override=args.style,
        enable_vlm=args.vlm,
        vlm_backend=args.vlm_backend,
        model_dir=args.model_dir,
    )

    graph = pipeline.run(args.input)
    output_json = graph.to_json()

    if args.stdout:
        print(output_json, flush=True)

    if args.output:
        graph.write(args.output)
        log.info("Wrote %s", args.output)

    if not args.stdout and not args.output:
        print(output_json)


if __name__ == "__main__":
    main()
