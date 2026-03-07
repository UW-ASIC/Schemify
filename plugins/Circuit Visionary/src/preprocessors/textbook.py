"""Textbook schematic preprocessor.

Clean, professional images (Razavi, Sedra/Smith, etc.) need minimal processing:
1. Contrast normalization (some scanned textbooks have gray backgrounds)
2. Border/caption removal (crop to schematic region)
3. Resolution upscaling if from low-DPI PDF extraction
"""

from __future__ import annotations

import logging

import cv2
import numpy as np

log = logging.getLogger(__name__)


class TextbookPreprocessor:
    def __init__(
        self,
        *,
        target_min_dim: int = 1024,
        border_margin: float = 0.02,
    ):
        self.target_min_dim = target_min_dim
        self.border_margin = border_margin

    def process(self, image: np.ndarray) -> np.ndarray:
        """Full preprocessing chain for textbook schematics."""
        result = image.copy()

        # 1. Upscale if too small (low-DPI PDF extraction)
        result = self._upscale_if_needed(result)

        # 2. Contrast normalization (CLAHE)
        result = self._normalize_contrast(result)

        # 3. Crop to schematic region (remove borders, page numbers, captions)
        result = self._crop_to_content(result)

        log.info("Textbook preprocessing complete")
        return result

    def _upscale_if_needed(self, image: np.ndarray) -> np.ndarray:
        h, w = image.shape[:2]
        min_dim = min(h, w)
        if min_dim >= self.target_min_dim:
            return image

        scale = self.target_min_dim / min_dim
        new_w = int(w * scale)
        new_h = int(h * scale)
        result = cv2.resize(image, (new_w, new_h), interpolation=cv2.INTER_CUBIC)
        log.debug("Upscaled from %dx%d to %dx%d", w, h, new_w, new_h)
        return result

    def _normalize_contrast(self, image: np.ndarray) -> np.ndarray:
        """Apply CLAHE to improve contrast on scanned pages."""
        if len(image.shape) == 3:
            lab = cv2.cvtColor(image, cv2.COLOR_BGR2LAB)
            l, a, b = cv2.split(lab)
        else:
            l = image.copy()
            a = b = None

        clahe = cv2.createCLAHE(clipLimit=2.0, tileGridSize=(8, 8))
        l = clahe.apply(l)

        if a is not None:
            lab = cv2.merge([l, a, b])
            return cv2.cvtColor(lab, cv2.COLOR_LAB2BGR)
        return l

    def _crop_to_content(self, image: np.ndarray) -> np.ndarray:
        """Remove white borders, page numbers, and caption text.

        Finds the bounding box of non-white content with a margin.
        """
        gray = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY) if len(image.shape) == 3 else image
        h, w = gray.shape

        _, binary = cv2.threshold(gray, 240, 255, cv2.THRESH_BINARY_INV)

        # Find content bounding rect
        coords = cv2.findNonZero(binary)
        if coords is None:
            return image

        x, y, cw, ch = cv2.boundingRect(coords)

        margin_x = int(w * self.border_margin)
        margin_y = int(h * self.border_margin)
        x1 = max(0, x - margin_x)
        y1 = max(0, y - margin_y)
        x2 = min(w, x + cw + margin_x)
        y2 = min(h, y + ch + margin_y)

        cropped = image[y1:y2, x1:x2]

        if cropped.shape[0] < h * 0.3 or cropped.shape[1] < w * 0.3:
            log.debug("Crop too aggressive, keeping original")
            return image

        log.debug("Cropped to %dx%d (from %dx%d)", x2 - x1, y2 - y1, w, h)
        return cropped
