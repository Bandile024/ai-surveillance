"""Alert engine: snapshot, log, overlay, and pluggable notifications.

Extending to mobile / push notifications:
  Subclass `NotificationChannel`, implement `send(alert)`, and pass an instance
  in `channels`. Channels run on a background thread pool, so slow network
  calls (FCM, APNs, Twilio, Telegram, ...) never stall the video loop.
  `WebhookChannel` below already POSTs JSON to any HTTP endpoint, which is
  enough to feed a backend that fans out to a mobile app.
"""
from __future__ import annotations

import json
import math
import time
import urllib.request
import uuid
from abc import ABC, abstractmethod
from concurrent.futures import ThreadPoolExecutor
from dataclasses import asdict, dataclass
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Optional, Sequence

import cv2
import numpy as np

from detector import Detection, PersonDetector
from logger import EventLogger
from supabase_sync import SupabaseOutbox


@dataclass(frozen=True)
class Alert:
    """Serializable alert payload (safe to send over the network)."""

    id: str
    type: str
    timestamp: str
    person_count: int
    max_confidence: float
    snapshot_path: str
    message: str

    def to_dict(self) -> Dict:
        return asdict(self)


# ------------------------------------------------------------------ channels
class NotificationChannel(ABC):
    """Interface for anything that can deliver an alert to the outside world."""

    @abstractmethod
    def send(self, alert: Alert) -> None: ...


class ConsoleChannel(NotificationChannel):
    def send(self, alert: Alert) -> None:
        print(f"\n*** ALERT {alert.id[:8]} *** {alert.message} -> {alert.snapshot_path}\n")


class WebhookChannel(NotificationChannel):
    """POSTs the alert as JSON to an HTTP endpoint (e.g. your future mobile backend)."""

    def __init__(self, url: str, timeout: float = 5.0, headers: Optional[Dict[str, str]] = None) -> None:
        self.url = url
        self.timeout = timeout
        self.headers = {"Content-Type": "application/json", **(headers or {})}

    def send(self, alert: Alert) -> None:
        req = urllib.request.Request(
            self.url,
            data=json.dumps(alert.to_dict()).encode("utf-8"),
            headers=self.headers,
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=self.timeout):
            pass


class SupabaseChannel(NotificationChannel):
    """Queue intrusion alerts for authenticated delivery to Supabase."""

    def __init__(self, outbox: SupabaseOutbox) -> None:
        self.outbox = outbox

    def send(self, alert: Alert) -> None:
        self.outbox.enqueue(alert.to_dict(), snapshot_path=alert.snapshot_path)


# -------------------------------------------------------------------- engine
class AlertEngine:
    def __init__(
        self,
        snapshot_dir: Path,
        logger: EventLogger,
        channels: Optional[Sequence[NotificationChannel]] = None,
        overlay_seconds: float = 5.0,
    ) -> None:
        self.snapshot_dir = Path(snapshot_dir)
        self.snapshot_dir.mkdir(parents=True, exist_ok=True)
        self.logger = logger
        self.channels: List[NotificationChannel] = list(channels or [])
        self.overlay_seconds = overlay_seconds
        self._overlay_until = 0.0
        self._pool = ThreadPoolExecutor(max_workers=2, thread_name_prefix="notify")

    # ---------------------------------------------------------------- trigger
    def trigger(self, frame: np.ndarray, detections: Sequence[Detection], now: Optional[float] = None) -> Alert:
        now = time.time() if now is None else now
        stamp = datetime.fromtimestamp(now).astimezone()
        max_conf = max((d.confidence for d in detections), default=0.0)

        snapshot = frame.copy()
        PersonDetector.draw(snapshot, detections, color=(0, 0, 255))
        cv2.putText(snapshot, f"INTRUSION {stamp:%Y-%m-%d %H:%M:%S}", (10, 28),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.8, (0, 0, 255), 2, cv2.LINE_AA)
        path = self.snapshot_dir / f"intrusion_{stamp:%Y%m%d_%H%M%S_%f}"[:-3]
        path = path.with_suffix(".jpg")
        cv2.imwrite(str(path), snapshot)

        alert = Alert(
            id=str(uuid.uuid4()),
            type="INTRUSION",
            timestamp=stamp.isoformat(timespec="milliseconds"),
            person_count=len(detections),
            max_confidence=round(max_conf, 3),
            snapshot_path=str(path),
            message=f"Intrusion detected: {len(detections)} person(s), confidence {max_conf:.0%}",
        )
        self.logger.event(
            "INTRUSION", alert.message,
            alert_id=alert.id, person_count=alert.person_count,
            max_confidence=alert.max_confidence, snapshot=alert.snapshot_path,
        )
        self._overlay_until = now + self.overlay_seconds
        for channel in self.channels:
            self._pool.submit(self._safe_send, channel, alert)
        return alert

    def _safe_send(self, channel: NotificationChannel, alert: Alert) -> None:
        try:
            channel.send(alert)
        except Exception as exc:  # a failing channel must never crash the system
            self.logger.error(f"Notification channel {type(channel).__name__} failed: {exc}")

    # ---------------------------------------------------------------- overlay
    def overlay_active(self, now: Optional[float] = None) -> bool:
        return (time.time() if now is None else now) < self._overlay_until

    def render_overlay(self, frame: np.ndarray, now: Optional[float] = None) -> np.ndarray:
        """Red pulsing tint, border and warning banner."""
        now = time.time() if now is None else now
        h, w = frame.shape[:2]
        pulse = 0.5 + 0.5 * math.sin(now * 8)  # 0..1

        tint = np.zeros_like(frame)
        tint[:] = (0, 0, 255)
        cv2.addWeighted(tint, 0.10 + 0.15 * pulse, frame, 1 - (0.10 + 0.15 * pulse), 0, frame)
        cv2.rectangle(frame, (0, 0), (w - 1, h - 1), (0, 0, 255), 12)

        text = "!! INTRUSION DETECTED !!"
        font, scale, thick = cv2.FONT_HERSHEY_DUPLEX, 1.2, 2
        (tw, th), _ = cv2.getTextSize(text, font, scale, thick)
        x, y = (w - tw) // 2, h - 40
        cv2.rectangle(frame, (x - 15, y - th - 15), (x + tw + 15, y + 15), (0, 0, 160), -1)
        cv2.putText(frame, text, (x, y), font, scale, (255, 255, 255), thick, cv2.LINE_AA)
        return frame

    def shutdown(self) -> None:
        self._pool.shutdown(wait=True)
