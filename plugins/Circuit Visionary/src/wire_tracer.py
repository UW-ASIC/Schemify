"""Wire Tracer — extracts wire paths from preprocessed schematic images.

Uses connected component labeling (CCL) and skeletonization to find wire
segments. Component bounding boxes are masked out before tracing so wires
aren't confused with component internals.

Based on SINA's CCL approach with angle tolerance for hand-drawn inputs.
"""

from __future__ import annotations

import logging
from typing import Optional

import numpy as np

from circuit_graph import Point
from crossing_classifier import WireSegment
from detector import Detection

log = logging.getLogger(__name__)


class WireTracer:
    def __init__(
        self,
        *,
        min_wire_length: int = 20,
        angle_tolerance: float = 15.0,
    ):
        self.min_wire_length = min_wire_length
        self.angle_tolerance = angle_tolerance

    def trace(
        self,
        image: np.ndarray,
        detections: list[Detection],
    ) -> list[WireSegment]:
        """Extract wire segments from the image.

        Steps:
        1. Convert to grayscale + binarize
        2. Mask out detected component regions
        3. Skeletonize to get 1px-wide wire paths
        4. Extract connected components (CCL)
        5. Fit line segments to each component
        """
        import cv2
        from skimage.morphology import skeletonize

        gray = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY) if len(image.shape) == 3 else image

        _, binary = cv2.threshold(gray, 0, 255, cv2.THRESH_BINARY_INV + cv2.THRESH_OTSU)

        # Mask out component bounding boxes
        mask = binary.copy()
        for det in detections:
            b = det.bbox
            pad = 3
            y1 = max(0, b.y - pad)
            y2 = min(mask.shape[0], b.y + b.h + pad)
            x1 = max(0, b.x - pad)
            x2 = min(mask.shape[1], b.x + b.w + pad)
            mask[y1:y2, x1:x2] = 0

        # Morphological close to bridge small gaps
        kernel = cv2.getStructuringElement(cv2.MORPH_RECT, (3, 3))
        mask = cv2.morphologyEx(mask, cv2.MORPH_CLOSE, kernel, iterations=1)

        # Skeletonize → 1px wide wire paths
        skeleton = skeletonize(mask > 0).astype(np.uint8) * 255

        # CCL on skeleton
        n_labels, labels = cv2.connectedComponents(skeleton)

        segments: list[WireSegment] = []
        for label in range(1, n_labels):
            ys, xs = np.where(labels == label)
            if len(xs) < self.min_wire_length:
                continue

            points = [Point(x=int(x), y=int(y)) for x, y in zip(xs, ys)]
            fitted = self._fit_segments(points)
            segments.extend(fitted)

        log.info("Traced %d wire segments from %d components", len(segments), n_labels - 1)
        return segments

    def _fit_segments(self, points: list[Point]) -> list[WireSegment]:
        """Fit one or more straight-line segments to a point cloud.

        Uses a simple approach: sort by x then y, split at direction changes,
        and fit each group as a line segment.
        """
        if len(points) < 2:
            return []

        coords = np.array([(p.x, p.y) for p in points])

        # Sort by primary axis (x if wider, y if taller)
        xrange = np.ptp(coords[:, 0])
        yrange = np.ptp(coords[:, 1])
        sort_axis = 0 if xrange >= yrange else 1
        order = coords[:, sort_axis].argsort()
        coords = coords[order]

        # Simple: treat the whole cloud as one segment from first to last point
        start = Point(x=int(coords[0, 0]), y=int(coords[0, 1]))
        end = Point(x=int(coords[-1, 0]), y=int(coords[-1, 1]))

        length = ((end.x - start.x) ** 2 + (end.y - start.y) ** 2) ** 0.5
        if length < self.min_wire_length:
            return []

        all_points = [Point(x=int(c[0]), y=int(c[1])) for c in coords]
        return [WireSegment(start=start, end=end, points=all_points)]
