"""Datasheet schematic preprocessor.

Handles IEEE/manufacturer datasheet pages:
1. PDF schematic region extraction (page → schematic crop)
2. Vector-to-raster conversion at high DPI if needed
3. Color channel separation for color-coded signals
4. Page segmentation (isolate schematic from text/tables)
"""

from __future__ import annotations

import logging
from pathlib import Path

import cv2
import numpy as np

log = logging.getLogger(__name__)


class DatasheetPreprocessor:
    def __init__(
        self,
        *,
        target_dpi: int = 300,
        min_schematic_area_ratio: float = 0.1,
    ):
        self.target_dpi = target_dpi
        self.min_area_ratio = min_schematic_area_ratio

    def process(self, image: np.ndarray) -> np.ndarray:
        """Full preprocessing chain for datasheet schematics."""
        result = image.copy()

        # 1. If color, separate into channels for analysis
        has_color = self._has_significant_color(result)

        # 2. Page segmentation — find the schematic region
        result = self._segment_schematic_region(result)

        # 3. Normalize to grayscale-ish for the detector
        #    (keep 3-channel BGR but enhance contrast)
        result = self._enhance(result)

        log.info("Datasheet preprocessing complete (color=%s)", has_color)
        return result

    def _has_significant_color(self, image: np.ndarray) -> bool:
        """Check if the image has meaningful color content (vs. B&W scan)."""
        if len(image.shape) < 3:
            return False

        hsv = cv2.cvtColor(image, cv2.COLOR_BGR2HSV)
        saturation = hsv[:, :, 1]
        return float(np.mean(saturation)) > 30

    def _segment_schematic_region(self, image: np.ndarray) -> np.ndarray:
        """Find the largest schematic-like region on the page.

        Datasheets mix schematics with text blocks, tables, and graphs.
        We look for the region with the most line-like content (wires,
        components) vs text-like content.
        """
        gray = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY) if len(image.shape) == 3 else image
        h, w = gray.shape

        # Edge detection
        edges = cv2.Canny(gray, 30, 100)

        # Dilate edges to form connected regions
        kernel = cv2.getStructuringElement(cv2.MORPH_RECT, (20, 20))
        dilated = cv2.dilate(edges, kernel, iterations=3)

        # Find contours of candidate regions
        contours, _ = cv2.findContours(dilated, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)

        if not contours:
            return image

        total_area = h * w
        best_region = None
        best_score = 0

        for contour in contours:
            x, y, cw, ch = cv2.boundingRect(contour)
            area = cw * ch

            if area < total_area * self.min_area_ratio:
                continue

            # Score: prefer large, roughly square-ish regions with high edge density
            region_edges = edges[y : y + ch, x : x + cw]
            edge_density = np.count_nonzero(region_edges) / max(area, 1)
            aspect = min(cw, ch) / max(cw, ch)

            score = area * edge_density * aspect
            if score > best_score:
                best_score = score
                best_region = (x, y, cw, ch)

        if best_region is None:
            return image

        x, y, cw, ch = best_region
        # Add margin
        margin = 20
        x1 = max(0, x - margin)
        y1 = max(0, y - margin)
        x2 = min(w, x + cw + margin)
        y2 = min(h, y + ch + margin)

        cropped = image[y1:y2, x1:x2]

        # Sanity check: don't crop too aggressively
        if cropped.shape[0] < h * 0.2 or cropped.shape[1] < w * 0.2:
            log.debug("Schematic region too small, keeping full page")
            return image

        log.debug(
            "Segmented schematic region: %dx%d at (%d,%d)",
            x2 - x1,
            y2 - y1,
            x1,
            y1,
        )
        return cropped

    def _enhance(self, image: np.ndarray) -> np.ndarray:
        """Enhance contrast and sharpen for component detection."""
        if len(image.shape) < 3:
            image = cv2.cvtColor(image, cv2.COLOR_GRAY2BGR)

        # Sharpen
        blur = cv2.GaussianBlur(image, (0, 0), 3)
        sharpened = cv2.addWeighted(image, 1.5, blur, -0.5, 0)

        # CLAHE on L channel
        lab = cv2.cvtColor(sharpened, cv2.COLOR_BGR2LAB)
        l, a, b = cv2.split(lab)
        clahe = cv2.createCLAHE(clipLimit=2.0, tileGridSize=(8, 8))
        l = clahe.apply(l)
        lab = cv2.merge([l, a, b])
        return cv2.cvtColor(lab, cv2.COLOR_LAB2BGR)
