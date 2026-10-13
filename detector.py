"""YOLO-based person detection.

The detector is intentionally restricted to the COCO "person" class (id 0).
It knows nothing about modes, alerts, or logging, so it can be swapped for a
different model/backend without touching the rest of the system.
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import List, Optional, Sequence, Tuple

import cv2
import numpy as np
from ultralytics import YOLO

PERSON_CLASS_ID = 0  # COCO class index for "person"


@dataclass(frozen=True)
class Detection:
    """A single detected person."""

    bbox: Tuple[int, int, int, int]  # x1, y1, x2, y2 (pixels)
    confidence: float


class PersonDetector:
    """Wraps a YOLO model and returns only person detections."""

    def __init__(
        self,
        model_path: str = "yolov8n.pt",
        confidence: float = 0.5,
        image_size: int = 640,
        device: Optional[str] = None,
    ) -> None:
        self.confidence = confidence
        self.image_size = image_size
        self.device = device  # None -> ultralytics auto-selects (CUDA/MPS/CPU)
        self._model = YOLO(model_path)  # auto-downloads weights on first run
        self._warm_up()

    def _warm_up(self) -> None:
        """Run one dummy inference so the first real frame isn't slow."""
        dummy = np.zeros((self.image_size, self.image_size, 3), dtype=np.uint8)
        self.detect(dummy)

    def detect(self, frame: np.ndarray) -> List[Detection]:
        """Return all persons found in a BGR frame."""
        results = self._model.predict(
            frame,
            classes=[PERSON_CLASS_ID],
            conf=self.confidence,
            imgsz=self.image_size,
            device=self.device,
            verbose=False,
        )[0]

        detections: List[Detection] = []
        for box in results.boxes:
            x1, y1, x2, y2 = (int(v) for v in box.xyxy[0].tolist())
            detections.append(Detection((x1, y1, x2, y2), float(box.conf[0])))
        return detections

    @staticmethod
    def draw(
        frame: np.ndarray,
        detections: Sequence[Detection],
        color: Tuple[int, int, int] = (0, 255, 0),
        show_confidence: bool = True,
    ) -> np.ndarray:
        """Draw bounding boxes and confidence labels in place."""
        for det in detections:
            x1, y1, x2, y2 = det.bbox
            cv2.rectangle(frame, (x1, y1), (x2, y2), color, 2)
            if not show_confidence:
                continue
            label = f"person {det.confidence:.0%}"
            (w, h), _ = cv2.getTextSize(label, cv2.FONT_HERSHEY_SIMPLEX, 0.5, 1)
            top = max(y1 - h - 8, 0)
            cv2.rectangle(frame, (x1, top), (x1 + w + 6, top + h + 8), color, -1)
            cv2.putText(frame, label, (x1 + 3, top + h + 2),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0, 0, 0), 1, cv2.LINE_AA)
        return frame
