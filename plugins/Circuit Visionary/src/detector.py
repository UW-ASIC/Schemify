"""Component Detector — YOLOv11-based circuit component detection.

Wraps Ultralytics YOLO for detecting components in preprocessed schematic
images. Supports per-style model weights (hand-drawn, textbook, datasheet).

When model weights are not available, falls back to a stub that returns
empty detections (useful for testing the pipeline without trained models).
"""

from __future__ import annotations

import logging
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

import numpy as np

from circuit_graph import ComponentType, BBox

log = logging.getLogger(__name__)

# YOLO class index → ComponentType mapping (matches training label order)
YOLO_CLASS_MAP: dict[int, str] = {
    0: "resistor",
    1: "capacitor",
    2: "inductor",
    3: "diode",
    4: "led",
    5: "zener",
    6: "npn",
    7: "pnp",
    8: "nmos",
    9: "nmos4",
    10: "pmos",
    11: "pmos4",
    12: "opamp",
    13: "voltage_source",
    14: "current_source",
    15: "ground",
    16: "vdd",
    17: "vss",
    18: "junction_dot",
    19: "crossing_bridge",
    20: "ic_block",
    21: "potentiometer",
}


@dataclass
class Detection:
    """A single detected component in the image."""

    class_name: str
    confidence: float
    bbox: BBox
    class_id: int = -1

    @property
    def center(self) -> tuple[float, float]:
        return self.bbox.center


class ComponentDetector:
    def __init__(
        self,
        *,
        model_path: Optional[Path] = None,
        confidence_threshold: float = 0.4,
        iou_threshold: float = 0.5,
    ):
        self.conf_thresh = confidence_threshold
        self.iou_thresh = iou_threshold
        self._model = None

        if model_path:
            for name in ["yolo_base.pt", "yolo_textbook.pt", "yolo_handdrawn.pt"]:
                p = model_path / name
                if p.exists():
                    self._model = self._load_model(p)
                    break

    def detect(self, image: np.ndarray) -> list[Detection]:
        """Run component detection on a preprocessed image.

        Returns a list of Detection objects sorted by confidence (descending).
        """
        if self._model is None:
            log.warning("No YOLO model loaded — returning empty detections")
            return []

        return self._detect_yolo(image)

    def _load_model(self, path: Path):
        try:
            from ultralytics import YOLO

            model = YOLO(str(path))
            log.info("Loaded YOLO model from %s", path)
            return model
        except ImportError:
            log.warning("ultralytics not installed — detection unavailable")
            return None
        except Exception as e:
            log.warning("Could not load YOLO model: %s", e)
            return None

    def _detect_yolo(self, image: np.ndarray) -> list[Detection]:
        results = self._model(
            image,
            conf=self.conf_thresh,
            iou=self.iou_thresh,
            verbose=False,
        )

        detections: list[Detection] = []
        for result in results:
            boxes = result.boxes
            if boxes is None:
                continue
            for i in range(len(boxes)):
                cls_id = int(boxes.cls[i].item())
                conf = float(boxes.conf[i].item())
                x1, y1, x2, y2 = boxes.xyxy[i].tolist()

                class_name = YOLO_CLASS_MAP.get(cls_id, f"unknown_{cls_id}")
                detections.append(
                    Detection(
                        class_name=class_name,
                        confidence=conf,
                        bbox=BBox(
                            x=int(x1),
                            y=int(y1),
                            w=int(x2 - x1),
                            h=int(y2 - y1),
                        ),
                        class_id=cls_id,
                    )
                )

        detections.sort(key=lambda d: d.confidence, reverse=True)
        log.info("YOLO: %d detections above %.2f", len(detections), self.conf_thresh)
        return detections
