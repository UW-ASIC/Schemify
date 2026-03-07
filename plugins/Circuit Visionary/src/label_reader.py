"""Label Reader — OCR for component reference designators and values.

Uses PaddleOCR to read text labels near detected components. Assigns labels
to components based on spatial proximity.

For hand-drawn inputs, OCR confidence is typically low — the pipeline
auto-generates reference designators (R1, R2, C1...) and flags them for
user review.
"""

from __future__ import annotations

import logging
import re
from dataclasses import dataclass
from typing import Optional

import numpy as np

from circuit_graph import BBox, Point
from detector import Detection

log = logging.getLogger(__name__)

# Reference designator prefixes by component type
REF_PREFIX: dict[str, str] = {
    "resistor": "R",
    "capacitor": "C",
    "inductor": "L",
    "potentiometer": "RV",
    "fuse": "F",
    "diode": "D",
    "led": "D",
    "zener": "D",
    "schottky": "D",
    "npn": "Q",
    "pnp": "Q",
    "nmos": "M",
    "nmos4": "M",
    "pmos": "M",
    "pmos4": "M",
    "voltage_source": "V",
    "current_source": "I",
    "opamp": "U",
    "comparator": "U",
    "ic_block": "U",
}

# Pattern for common component values
VALUE_PATTERN = re.compile(
    r"(\d+\.?\d*)\s*([kKMmμunp]?)\s*([ΩΩFHVAohm]?)",
    re.UNICODE,
)

# Known net/power labels
POWER_LABELS = {"VDD", "VSS", "VCC", "VEE", "GND", "VREF", "AVDD", "DVDD"}


@dataclass
class TextLabel:
    """A piece of text detected near a component."""

    text: str
    confidence: float
    bbox: BBox
    center: Point


@dataclass
class ComponentLabel:
    """Assigned labels for a detected component."""

    detection_idx: int
    ref: Optional[str] = None
    ref_confidence: float = 0.0
    value: Optional[str] = None
    value_confidence: float = 0.0


class LabelReader:
    def __init__(
        self,
        *,
        proximity_threshold: int = 80,
        min_confidence: float = 0.5,
    ):
        self.proximity = proximity_threshold
        self.min_conf = min_confidence
        self._ocr = None

    def read(
        self,
        image: np.ndarray,
        detections: list[Detection],
    ) -> list[ComponentLabel]:
        """Read text labels from the image and assign them to components."""
        texts = self._extract_text(image)
        labels = self._assign_labels(texts, detections)

        # Auto-generate missing reference designators
        self._fill_missing_refs(labels, detections)

        return labels

    def _extract_text(self, image: np.ndarray) -> list[TextLabel]:
        """Run OCR on the image."""
        if self._ocr is None:
            self._ocr = self._init_ocr()
        if self._ocr is None:
            return []

        try:
            results = self._ocr.ocr(image, cls=True)
        except Exception as e:
            log.warning("OCR failed: %s", e)
            return []

        labels: list[TextLabel] = []
        if not results or not results[0]:
            return labels

        for line in results[0]:
            box_pts, (text, conf) = line
            if conf < self.min_conf:
                continue

            xs = [p[0] for p in box_pts]
            ys = [p[1] for p in box_pts]
            bbox = BBox(
                x=int(min(xs)),
                y=int(min(ys)),
                w=int(max(xs) - min(xs)),
                h=int(max(ys) - min(ys)),
            )
            center = Point(
                x=int(sum(xs) / len(xs)),
                y=int(sum(ys) / len(ys)),
            )
            labels.append(TextLabel(text=text.strip(), confidence=conf, bbox=bbox, center=center))

        log.info("OCR: found %d text labels", len(labels))
        return labels

    def _assign_labels(
        self,
        texts: list[TextLabel],
        detections: list[Detection],
    ) -> list[ComponentLabel]:
        """Assign text labels to their nearest component."""
        labels = [ComponentLabel(detection_idx=i) for i in range(len(detections))]

        for text in texts:
            # Find nearest detection
            best_idx = -1
            best_dist = float("inf")
            for i, det in enumerate(detections):
                cx, cy = det.center
                d = ((text.center.x - cx) ** 2 + (text.center.y - cy) ** 2) ** 0.5
                if d < best_dist and d < self.proximity:
                    best_dist = d
                    best_idx = i

            if best_idx < 0:
                continue

            label = labels[best_idx]
            t = text.text.upper()

            # Classify: reference designator or value?
            if self._looks_like_ref(t):
                if label.ref is None or text.confidence > label.ref_confidence:
                    label.ref = text.text
                    label.ref_confidence = text.confidence
            elif self._looks_like_value(text.text):
                if label.value is None or text.confidence > label.value_confidence:
                    label.value = text.text
                    label.value_confidence = text.confidence
            elif t in POWER_LABELS:
                pass  # Power labels are net names, handled by topology builder

        return labels

    def _fill_missing_refs(
        self,
        labels: list[ComponentLabel],
        detections: list[Detection],
    ) -> None:
        """Auto-generate reference designators for components without OCR labels."""
        counters: dict[str, int] = {}

        for label, det in zip(labels, detections):
            if label.ref:
                continue

            prefix = REF_PREFIX.get(det.class_name, "X")
            counters[prefix] = counters.get(prefix, 0) + 1
            label.ref = f"{prefix}{counters[prefix]}"
            label.ref_confidence = 0.0  # auto-generated → zero confidence

    def _looks_like_ref(self, text: str) -> bool:
        """Check if text matches a reference designator pattern (R1, C2, M3, etc.)."""
        return bool(re.match(r"^[A-Z]{1,3}\d+$", text.upper()))

    def _looks_like_value(self, text: str) -> bool:
        """Check if text looks like a component value (10k, 100nF, 1.2V, etc.)."""
        return bool(VALUE_PATTERN.match(text))

    def _init_ocr(self):
        try:
            from paddleocr import PaddleOCR

            ocr = PaddleOCR(use_angle_cls=True, lang="en", show_log=False)
            log.info("PaddleOCR initialized")
            return ocr
        except ImportError:
            log.warning("paddleocr not installed — OCR unavailable")
            return None
