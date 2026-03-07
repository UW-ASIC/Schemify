"""MOSFET Terminal Resolver — assigns G/D/S/B pins to detected MOSFETs.

Masala-CHAI identified this as the hardest subproblem in analog circuit
extraction. The drain, gate, and source must be correctly assigned based on:
- Arrow direction (NMOS vs PMOS)
- Gate terminal location (horizontal line approaching channel)
- Drain vs source position relative to arrow
- Body/bulk terminal (4th connection, if present)

This module post-processes MOSFET detections from the component detector,
analyzing the bounding box region to resolve terminal assignments.
"""

from __future__ import annotations

import logging
from typing import Optional

import numpy as np

from circuit_graph import BBox, Point
from detector import Detection

log = logging.getLogger(__name__)


class TerminalAssignment:
    """Resolved pin positions for a MOSFET."""

    def __init__(
        self,
        gate: Optional[Point] = None,
        drain: Optional[Point] = None,
        source: Optional[Point] = None,
        body: Optional[Point] = None,
        is_pmos: bool = False,
        confidence: float = 0.5,
    ):
        self.gate = gate
        self.drain = drain
        self.source = source
        self.body = body
        self.is_pmos = is_pmos
        self.confidence = confidence


class MOSFETResolver:
    def __init__(self, *, arrow_min_area: int = 20):
        self.arrow_min_area = arrow_min_area

    def resolve(
        self,
        detections: list[Detection],
        image: np.ndarray,
    ) -> list[Detection]:
        """Process MOSFET detections to determine terminal positions.

        Non-MOSFET detections are passed through unchanged. MOSFET detections
        get a `terminal_assignment` attribute attached (or updated type if
        N/P resolution changes it).
        """
        mosfet_types = {"nmos", "nmos4", "pmos", "pmos4"}
        result: list[Detection] = []

        for det in detections:
            if det.class_name in mosfet_types:
                assignment = self._resolve_terminals(det, image)
                # Correct type if arrow analysis disagrees with detector
                if assignment.is_pmos and det.class_name.startswith("n"):
                    det = Detection(
                        class_name=det.class_name.replace("nmos", "pmos"),
                        confidence=min(det.confidence, assignment.confidence),
                        bbox=det.bbox,
                        class_id=det.class_id,
                    )
                elif not assignment.is_pmos and det.class_name.startswith("p"):
                    det = Detection(
                        class_name=det.class_name.replace("pmos", "nmos"),
                        confidence=min(det.confidence, assignment.confidence),
                        bbox=det.bbox,
                        class_id=det.class_id,
                    )
            result.append(det)

        return result

    def _resolve_terminals(
        self, det: Detection, image: np.ndarray
    ) -> TerminalAssignment:
        """Analyze a MOSFET bounding box to determine terminal positions.

        Strategy:
        1. Extract and binarize the bbox region
        2. Find the arrow (triangular blob → determines N vs P type)
        3. Gate = horizontal protrusion from the left or right side
        4. Drain = terminal opposite to arrow direction from channel
        5. Source = terminal on same side as arrow
        6. Body = 4th terminal if detected type ends in '4'
        """
        import cv2

        b = det.bbox
        h, w = image.shape[:2]
        y1, y2 = max(0, b.y), min(h, b.y + b.h)
        x1, x2 = max(0, b.x), min(w, b.x + b.w)
        patch = image[y1:y2, x1:x2]

        if patch.size == 0:
            return TerminalAssignment()

        gray = cv2.cvtColor(patch, cv2.COLOR_BGR2GRAY) if len(patch.shape) == 3 else patch
        _, binary = cv2.threshold(gray, 0, 255, cv2.THRESH_BINARY_INV + cv2.THRESH_OTSU)

        # Detect arrow direction to determine NMOS vs PMOS
        is_pmos = self._detect_arrow_direction(binary)

        bh, bw = binary.shape
        cx, cy = bw // 2, bh // 2

        # Simplified terminal assignment based on standard MOSFET symbol layout:
        # Gate on left, drain on top, source on bottom (or mirrored)
        gate = Point(x=b.x, y=b.y + bh // 2)
        drain = Point(x=b.x + bw // 2, y=b.y)
        source = Point(x=b.x + bw // 2, y=b.y + bh)
        body = None

        if det.class_name in ("nmos4", "pmos4"):
            body = Point(x=b.x + bw, y=b.y + bh // 2)

        return TerminalAssignment(
            gate=gate,
            drain=drain,
            source=source,
            body=body,
            is_pmos=is_pmos,
            confidence=0.7,
        )

    def _detect_arrow_direction(self, binary: np.ndarray) -> bool:
        """Detect the arrow in a MOSFET symbol to determine NMOS vs PMOS.

        NMOS: arrow points inward (toward channel)
        PMOS: arrow points outward (away from channel)

        Returns True if PMOS detected.
        """
        import cv2

        contours, _ = cv2.findContours(binary, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)

        # Look for a small triangular contour (the arrow)
        for contour in contours:
            area = cv2.contourArea(contour)
            if area < self.arrow_min_area or area > binary.size * 0.3:
                continue

            approx = cv2.approxPolyDP(contour, 0.04 * cv2.arcLength(contour, True), True)
            if len(approx) == 3:
                # Triangle found — check if it points up (PMOS) or down (NMOS)
                pts = approx.reshape(-1, 2)
                centroid_y = pts[:, 1].mean()
                top_y = pts[:, 1].min()

                # If the centroid is below the midpoint of the bbox, arrow points down → NMOS
                mid_y = binary.shape[0] / 2
                if centroid_y > mid_y:
                    return False  # NMOS
                else:
                    return True  # PMOS

        return False  # Default to NMOS if no arrow found
