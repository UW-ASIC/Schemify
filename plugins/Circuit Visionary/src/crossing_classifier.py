"""Crossing Classifier — determines whether intersecting wires are connected.

At any wire intersection, one of three things is true:
1. Connected junction (dot at crossing) — wires share a node
2. Unconnected crossing, bridge style (arc over)
3. Unconnected crossing, plain (wires cross with no indicator)

The Style informs the default assumption:
- Textbook: plain crossing = unconnected, dot = connected
- Datasheet: same as textbook (IEEE convention)
- Hand-drawn: require explicit dot, else flag for review

Based on Image2Net's crossing identification dataset.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass
from enum import Enum
from pathlib import Path
from typing import Optional

import numpy as np

from circuit_graph import Style, Point

log = logging.getLogger(__name__)


class CrossingType(Enum):
    CONNECTED = "connected"
    BRIDGE = "bridge"
    PLAIN_UNCONNECTED = "plain_unconnected"
    AMBIGUOUS = "ambiguous"


@dataclass
class WireSegment:
    """A traced wire segment between two endpoints."""

    start: Point
    end: Point
    points: list[Point]


@dataclass
class Crossing:
    """A detected wire crossing/junction."""

    location: Point
    type: CrossingType
    confidence: float
    segments: list[int]  # indices into the wire segment list


class CrossingClassifier:
    def __init__(self, *, model_path: Optional[Path] = None):
        self._model = None
        if model_path and (model_path / "crossing_classifier.pt").exists():
            self._model = self._load_model(model_path / "crossing_classifier.pt")

    def classify(
        self,
        image: np.ndarray,
        wire_segments: list[WireSegment],
        style: Style,
    ) -> list[Crossing]:
        """Find and classify all wire crossings in the image."""
        intersections = self._find_intersections(wire_segments)

        crossings: list[Crossing] = []
        for loc, seg_indices in intersections:
            if self._model is not None:
                ctype, conf = self._classify_patch(image, loc)
            else:
                ctype, conf = self._classify_heuristic(image, loc, style)
            crossings.append(
                Crossing(
                    location=loc,
                    type=ctype,
                    confidence=conf,
                    segments=seg_indices,
                )
            )

        log.info("Classified %d crossings", len(crossings))
        return crossings

    def _find_intersections(
        self, segments: list[WireSegment]
    ) -> list[tuple[Point, list[int]]]:
        """Find points where wire segments intersect."""
        results: list[tuple[Point, list[int]]] = []

        for i in range(len(segments)):
            for j in range(i + 1, len(segments)):
                pt = self._segment_intersection(segments[i], segments[j])
                if pt is not None:
                    # Check if near an existing crossing
                    merged = False
                    for k, (existing, indices) in enumerate(results):
                        if _dist(existing, pt) < 10:
                            indices.append(j)
                            merged = True
                            break
                    if not merged:
                        results.append((pt, [i, j]))

        return results

    def _segment_intersection(
        self, seg_a: WireSegment, seg_b: WireSegment
    ) -> Optional[Point]:
        """Compute intersection of two line segments, or None if they don't cross."""
        ax1, ay1 = seg_a.start.x, seg_a.start.y
        ax2, ay2 = seg_a.end.x, seg_a.end.y
        bx1, by1 = seg_b.start.x, seg_b.start.y
        bx2, by2 = seg_b.end.x, seg_b.end.y

        denom = (ax1 - ax2) * (by1 - by2) - (ay1 - ay2) * (bx1 - bx2)
        if abs(denom) < 1e-10:
            return None

        t = ((ax1 - bx1) * (by1 - by2) - (ay1 - by1) * (bx1 - bx2)) / denom
        u = -((ax1 - ax2) * (ay1 - by1) - (ay1 - ay2) * (ax1 - bx1)) / denom

        if 0 <= t <= 1 and 0 <= u <= 1:
            ix = ax1 + t * (ax2 - ax1)
            iy = ay1 + t * (ay2 - ay1)
            return Point(x=int(ix), y=int(iy))
        return None

    def _classify_heuristic(
        self, image: np.ndarray, loc: Point, style: Style
    ) -> tuple[CrossingType, float]:
        """Heuristic: check for a dot/blob at the crossing location."""
        import cv2

        gray = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY) if len(image.shape) == 3 else image
        h, w = gray.shape
        r = 8  # patch radius

        y1 = max(0, loc.y - r)
        y2 = min(h, loc.y + r)
        x1 = max(0, loc.x - r)
        x2 = min(w, loc.x + r)
        patch = gray[y1:y2, x1:x2]

        if patch.size == 0:
            return CrossingType.AMBIGUOUS, 0.3

        # A junction dot appears as a dark blob — threshold and check area
        _, binary = cv2.threshold(patch, 0, 255, cv2.THRESH_BINARY_INV + cv2.THRESH_OTSU)
        dark_ratio = np.count_nonzero(binary) / binary.size

        if dark_ratio > 0.5:
            return CrossingType.CONNECTED, 0.8
        elif dark_ratio < 0.25:
            if style == Style.HANDDRAWN:
                return CrossingType.AMBIGUOUS, 0.5
            return CrossingType.PLAIN_UNCONNECTED, 0.75
        else:
            if style == Style.TEXTBOOK:
                return CrossingType.PLAIN_UNCONNECTED, 0.6
            return CrossingType.AMBIGUOUS, 0.5

    def _load_model(self, path: Path):
        try:
            import torch

            model = torch.jit.load(str(path), map_location="cpu")
            model.eval()
            log.info("Loaded crossing classifier from %s", path)
            return model
        except Exception as e:
            log.warning("Could not load crossing model: %s", e)
            return None

    def _classify_patch(
        self, image: np.ndarray, loc: Point
    ) -> tuple[CrossingType, float]:
        import torch
        import cv2

        h, w = image.shape[:2]
        r = 32
        y1, y2 = max(0, loc.y - r), min(h, loc.y + r)
        x1, x2 = max(0, loc.x - r), min(w, loc.x + r)
        patch = image[y1:y2, x1:x2]
        patch = cv2.resize(patch, (64, 64))

        tensor = torch.from_numpy(patch).permute(2, 0, 1).float() / 255.0
        tensor = tensor.unsqueeze(0)

        with torch.no_grad():
            logits = self._model(tensor)
            probs = torch.softmax(logits, dim=1)[0]

        types = [
            CrossingType.CONNECTED,
            CrossingType.BRIDGE,
            CrossingType.PLAIN_UNCONNECTED,
        ]
        idx = probs.argmax().item()
        return types[idx], probs[idx].item()


def _dist(a: Point, b: Point) -> float:
    return ((a.x - b.x) ** 2 + (a.y - b.y) ** 2) ** 0.5
