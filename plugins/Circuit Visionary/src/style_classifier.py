"""Style Classifier — detects whether an input image is hand-drawn, textbook,
or datasheet style.

Image2Net's key insight: detect the style first, then adapt processing.
This classifier routes input through the correct preprocessing chain and
selects the appropriate YOLO detection head.

Approaches (in order of preference):
1. Lightweight CNN trained on style-labeled data (Phase 4)
2. Heuristic analysis of line regularity, noise levels, and text density
"""

from __future__ import annotations

import logging
from pathlib import Path
from typing import Optional

import numpy as np

from circuit_graph import Style

log = logging.getLogger(__name__)


class StyleClassifier:
    def __init__(self, *, model_path: Optional[Path] = None):
        self._model = None
        if model_path and (model_path / "style_classifier.pt").exists():
            self._model = self._load_model(model_path / "style_classifier.pt")

    def classify(self, image: np.ndarray) -> tuple[Style, float]:
        """Classify the image style.

        Returns (style, confidence) where confidence is in [0, 1].
        """
        if self._model is not None:
            return self._classify_cnn(image)
        return self._classify_heuristic(image)

    # ── CNN-based classification ──────────────────────────────────────── #

    def _load_model(self, path: Path):
        try:
            import torch

            model = torch.jit.load(str(path), map_location="cpu")
            model.eval()
            log.info("Loaded style classifier from %s", path)
            return model
        except Exception as e:
            log.warning("Could not load style model: %s", e)
            return None

    def _classify_cnn(self, image: np.ndarray) -> tuple[Style, float]:
        import torch
        import cv2

        resized = cv2.resize(image, (224, 224))
        tensor = torch.from_numpy(resized).permute(2, 0, 1).float() / 255.0
        tensor = tensor.unsqueeze(0)

        with torch.no_grad():
            logits = self._model(tensor)
            probs = torch.softmax(logits, dim=1)[0]

        styles = [Style.HANDDRAWN, Style.TEXTBOOK, Style.DATASHEET]
        idx = probs.argmax().item()
        return styles[idx], probs[idx].item()

    # ── Heuristic fallback ────────────────────────────────────────────── #

    def _classify_heuristic(self, image: np.ndarray) -> tuple[Style, float]:
        """Rule-based classification using image statistics.

        Heuristics:
        - Hand-drawn: high noise (variance in Laplacian), irregular lines
        - Textbook: clean, high contrast, low noise, sparse layout
        - Datasheet: dense text regions, very uniform line widths
        """
        import cv2

        gray = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY) if len(image.shape) == 3 else image
        h, w = gray.shape

        # Edge density via Canny
        edges = cv2.Canny(gray, 50, 150)
        edge_density = np.count_nonzero(edges) / (h * w)

        # Noise level via Laplacian variance
        laplacian_var = cv2.Laplacian(gray, cv2.CV_64F).var()

        # Line regularity: Hough transform for straight lines
        lines = cv2.HoughLinesP(edges, 1, np.pi / 180, 50, minLineLength=30, maxLineGap=10)
        n_lines = len(lines) if lines is not None else 0

        # Angle distribution of detected lines
        angle_std = 0.0
        if lines is not None and len(lines) > 2:
            angles = []
            for line in lines:
                x1, y1, x2, y2 = line[0]
                angle = np.arctan2(y2 - y1, x2 - x1) * 180 / np.pi
                # Snap to nearest 90° for manhattan-ness measurement
                angles.append(angle % 90)
            angle_std = np.std(angles)

        # Scoring
        scores = {Style.HANDDRAWN: 0.0, Style.TEXTBOOK: 0.0, Style.DATASHEET: 0.0}

        # High noise → hand-drawn
        if laplacian_var > 500:
            scores[Style.HANDDRAWN] += 0.4
        elif laplacian_var < 100:
            scores[Style.TEXTBOOK] += 0.3
            scores[Style.DATASHEET] += 0.2

        # Irregular angles → hand-drawn
        if angle_std > 15:
            scores[Style.HANDDRAWN] += 0.3
        elif angle_std < 5:
            scores[Style.TEXTBOOK] += 0.2
            scores[Style.DATASHEET] += 0.2

        # High edge density → datasheet (dense)
        if edge_density > 0.15:
            scores[Style.DATASHEET] += 0.3
        elif edge_density < 0.05:
            scores[Style.TEXTBOOK] += 0.2

        # Many straight lines → not hand-drawn
        line_density = n_lines / max(h * w / 10000, 1)
        if line_density > 5:
            scores[Style.DATASHEET] += 0.2
        elif line_density > 1:
            scores[Style.TEXTBOOK] += 0.2

        best = max(scores, key=scores.get)
        total = sum(scores.values()) or 1.0
        confidence = scores[best] / total

        log.debug(
            "Heuristic: laplacian=%.1f edge_dens=%.3f angle_std=%.1f lines=%d → %s (%.2f)",
            laplacian_var,
            edge_density,
            angle_std,
            n_lines,
            best.value,
            confidence,
        )
        return best, confidence
