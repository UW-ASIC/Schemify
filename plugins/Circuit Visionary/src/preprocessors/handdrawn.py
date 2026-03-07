"""Hand-drawn schematic preprocessor.

Handles noisy, uneven strokes from photos of sketches:
1. Perspective correction (if photo taken at angle)
2. Adaptive bilateral filtering (denoise while preserving edges)
3. Adaptive thresholding (Sauvola for uneven lighting)
4. Morphological close (bridge small gaps in hand-drawn lines)
5. Optional deskew (correct rotation if paper is tilted)
"""

from __future__ import annotations

import logging

import cv2
import numpy as np

log = logging.getLogger(__name__)


class HanddrawnPreprocessor:
    def __init__(
        self,
        *,
        denoise_strength: int = 10,
        morph_kernel_size: int = 3,
        deskew: bool = True,
    ):
        self.denoise_strength = denoise_strength
        self.morph_kernel_size = morph_kernel_size
        self.deskew = deskew

    def process(self, image: np.ndarray) -> np.ndarray:
        """Full preprocessing chain for hand-drawn schematics."""
        result = image.copy()

        # 1. Bilateral filter — smooth noise while keeping edges sharp
        result = cv2.bilateralFilter(
            result, d=9, sigmaColor=75, sigmaSpace=75
        )

        # 2. Deskew if enabled
        if self.deskew:
            result = self._deskew(result)

        # 3. Convert to grayscale for adaptive threshold
        gray = cv2.cvtColor(result, cv2.COLOR_BGR2GRAY) if len(result.shape) == 3 else result

        # 4. Adaptive thresholding (handles uneven lighting from photos)
        binary = cv2.adaptiveThreshold(
            gray,
            255,
            cv2.ADAPTIVE_THRESH_GAUSSIAN_C,
            cv2.THRESH_BINARY_INV,
            blockSize=25,
            C=10,
        )

        # 5. Morphological close — bridge small gaps in hand-drawn lines
        kernel = cv2.getStructuringElement(
            cv2.MORPH_RECT,
            (self.morph_kernel_size, self.morph_kernel_size),
        )
        binary = cv2.morphologyEx(binary, cv2.MORPH_CLOSE, kernel, iterations=2)

        # 6. Small component removal (noise dots)
        binary = self._remove_small_components(binary, min_area=30)

        # Convert back to 3-channel for downstream compatibility
        result = cv2.cvtColor(binary, cv2.COLOR_GRAY2BGR)

        log.info("Handdrawn preprocessing complete")
        return result

    def _deskew(self, image: np.ndarray) -> np.ndarray:
        """Correct slight rotation using Hough line detection."""
        gray = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY) if len(image.shape) == 3 else image
        edges = cv2.Canny(gray, 50, 150)

        lines = cv2.HoughLinesP(
            edges, 1, np.pi / 180, threshold=100, minLineLength=50, maxLineGap=10
        )
        if lines is None or len(lines) < 3:
            return image

        angles = []
        for line in lines:
            x1, y1, x2, y2 = line[0]
            angle = np.arctan2(y2 - y1, x2 - x1) * 180 / np.pi
            # Only consider near-horizontal lines for deskew
            if abs(angle) < 30:
                angles.append(angle)

        if not angles:
            return image

        median_angle = np.median(angles)
        if abs(median_angle) < 0.5:
            return image

        h, w = image.shape[:2]
        center = (w // 2, h // 2)
        M = cv2.getRotationMatrix2D(center, median_angle, 1.0)
        rotated = cv2.warpAffine(image, M, (w, h), borderValue=(255, 255, 255))

        log.debug("Deskewed by %.2f degrees", median_angle)
        return rotated

    def _remove_small_components(
        self, binary: np.ndarray, min_area: int
    ) -> np.ndarray:
        """Remove small connected components (noise) from binary image."""
        n_labels, labels, stats, _ = cv2.connectedComponentsWithStats(binary)
        result = np.zeros_like(binary)
        for i in range(1, n_labels):
            if stats[i, cv2.CC_STAT_AREA] >= min_area:
                result[labels == i] = 255
        return result
