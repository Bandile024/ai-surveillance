"""AI surveillance system - entry point.

Controls:  S = Safe mode   G = Guard mode   Q = Quit
Run:       python main.py            (see README.md for options)
"""
from __future__ import annotations

import argparse
import os
import sys
import time
import uuid
from pathlib import Path
from typing import Optional

import cv2
import numpy as np

from alert_engine import (
    AlertEngine,
    ConsoleChannel,
    NotificationChannel,
    SupabaseChannel,
    WebhookChannel,
)
from detector import PersonDetector
from logger import EventLogger
from local_engine_api import LocalEngineBridge, LocalEngineServer
from mode_manager import FrameState, Mode, ModeManager
from supabase_sync import SupabaseOutbox

BASE_DIR = Path(__file__).resolve().parent
WINDOW_NAME = "AI Surveillance"
LOCAL_ENV_PATH = BASE_DIR / ".env.local"

GREEN, RED, ORANGE, WHITE = (0, 200, 0), (0, 0, 255), (0, 165, 255), (255, 255, 255)


def load_local_env(path: Path) -> None:
    """Load simple KEY=value entries without overriding process environment."""
    if not path.exists():
        return

    for line_number, raw_line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            raise ValueError(f"Invalid entry in {path.name} at line {line_number}.")

        key, value = line.split("=", 1)
        key, value = key.strip(), value.strip()
        if not key:
            raise ValueError(f"Missing variable name in {path.name} at line {line_number}.")
        if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
            value = value[1:-1]
        os.environ.setdefault(key, value)


def supabase_ingest_config(
    project_url: Optional[str],
    ingest_url: Optional[str],
    device_token: Optional[str],
) -> tuple[Optional[str], Optional[str]]:
    project_url = project_url.rstrip("/") if project_url else None
    if device_token and not ingest_url and project_url:
        ingest_url = f"{project_url}/functions/v1/device-ingest"
    if ingest_url and not device_token:
        raise RuntimeError(
            "SUPABASE_DEVICE_TOKEN is required when Supabase engine uploads are configured."
        )
    if device_token and not ingest_url:
        raise RuntimeError(
            "Set SUPABASE_URL or SUPABASE_INGEST_URL when "
            "SUPABASE_DEVICE_TOKEN is configured."
        )
    return ingest_url, device_token


class SurveillanceApp:
    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        self.logger = EventLogger(BASE_DIR / "logs")

        load_local_env(LOCAL_ENV_PATH)
        ingest_url, device_token = supabase_ingest_config(
            os.getenv("SUPABASE_URL"),
            os.getenv("SUPABASE_INGEST_URL"),
            os.getenv("SUPABASE_DEVICE_TOKEN"),
        )

        self.logger.info("Loading YOLO model (first run downloads the weights)...")
        self.detector = PersonDetector(
            model_path=args.model, confidence=args.conf,
            image_size=args.imgsz, device=args.device,
        )

        self.supabase_outbox: Optional[SupabaseOutbox] = None
        if ingest_url and device_token:
            self.supabase_outbox = SupabaseOutbox(
                ingest_url,
                device_token,
                BASE_DIR / "logs" / "supabase-outbox.sqlite3",
                self.logger,
            )
            self.logger.info("Supabase event delivery enabled.")

        channels: list[NotificationChannel] = [ConsoleChannel()]
        if args.webhook:
            channels.append(WebhookChannel(args.webhook))
        if self.supabase_outbox:
            channels.append(SupabaseChannel(self.supabase_outbox))
        self.alerts = AlertEngine(BASE_DIR / "intrusions", self.logger, channels)

        self.modes = ModeManager(
            intrusion_seconds=args.duration,
            grace_seconds=args.grace,
            on_mode_change=self._on_mode_change,
        )
        self._fps = 0.0
        self._mode_change_source = "local_keyboard"
        self._last_detection_at: Optional[str] = None

    # ----------------------------------------------------------------- setup
    def _open_camera(self) -> cv2.VideoCapture:
        backend = cv2.CAP_DSHOW if sys.platform.startswith("win") else cv2.CAP_ANY
        cap = cv2.VideoCapture(self.args.camera, backend)
        if not cap.isOpened():
            raise RuntimeError(
                f"Cannot open camera index {self.args.camera}. Close other apps using the "
                "webcam, check OS camera permissions, or try --camera 1."
            )
        cap.set(cv2.CAP_PROP_FRAME_WIDTH, self.args.width)
        cap.set(cv2.CAP_PROP_FRAME_HEIGHT, self.args.height)
        return cap

    def _on_mode_change(self, old: Mode, new: Mode) -> None:
        record = self.logger.event(
            "MODE_CHANGE",
            f"Mode changed {old.value} -> {new.value}",
            event_id=str(uuid.uuid4()),
            old_mode=old.value,
            new_mode=new.value,
            source=self._mode_change_source,
        )
        if self.supabase_outbox:
            self.supabase_outbox.enqueue(record)

    def _set_mode(self, mode: Mode, source: str) -> None:
        self._mode_change_source = source
        try:
            self.modes.set_mode(mode)
        finally:
            self._mode_change_source = "local_keyboard"

    # ------------------------------------------------------------------- run
    def run(self) -> None:
        bridge = LocalEngineBridge()
        server = LocalEngineServer(bridge, port=self.args.api_port)
        cap: Optional[cv2.VideoCapture] = None
        failures, last = 0, time.time()

        try:
            server.start()
            self.logger.info(
                f"Local app API listening at http://127.0.0.1:{server.port}"
            )
            cap = self._open_camera()
            bridge.set_camera_connected(True)
            self.logger.event("SYSTEM", f"System started in {self.modes.mode.value} mode")
            if not self.args.headless:
                cv2.namedWindow(WINDOW_NAME, cv2.WINDOW_NORMAL)

            while True:
                if bridge.take_shutdown_request():
                    break
                ok, frame = cap.read()
                if not ok:
                    failures += 1
                    if failures > 30:
                        raise RuntimeError("Camera stopped delivering frames.")
                    continue
                failures = 0

                now = time.time()
                requested_mode = bridge.take_mode_request()
                if requested_mode:
                    self._set_mode(Mode(requested_mode), "flutter_app")
                detections = self.detector.detect(frame)
                state = self.modes.update([d.confidence for d in detections], now)
                if detections:
                    self._last_detection_at = time.strftime(
                        "%Y-%m-%dT%H:%M:%SZ", time.gmtime(now)
                    )

                if state.intrusion_triggered:
                    self.alerts.trigger(frame, detections, now)

                stream_frame = frame.copy()
                self._render(
                    stream_frame,
                    detections,
                    state,
                    now,
                    show_confidence_labels=False,
                )
                self._render(frame, detections, state, now)

                # Smoothed FPS (exponential moving average)
                dt = now - last
                last = now
                if dt > 0:
                    self._fps = 0.9 * self._fps + 0.1 * (1.0 / dt) if self._fps else 1.0 / dt

                ok, encoded = cv2.imencode(
                    ".jpg", stream_frame, [int(cv2.IMWRITE_JPEG_QUALITY), 82]
                )
                if ok:
                    safe_stats = self.modes.safe_stats
                    bridge.publish(
                        encoded.tobytes(),
                        mode=state.mode.value,
                        person_count=state.person_count,
                        avg_confidence=state.avg_confidence,
                        max_confidence=state.max_confidence,
                        fps=self._fps,
                        last_detection_at=self._last_detection_at,
                        last_frame_at=time.strftime(
                            "%Y-%m-%dT%H:%M:%SZ", time.gmtime(now)
                        ),
                        peak_count=safe_stats.peak_count,
                        occupancy_ratio=safe_stats.occupancy_ratio,
                    )

                if not self.args.headless:
                    self._render_hud(frame, state)
                    cv2.imshow(WINDOW_NAME, frame)
                    key = cv2.waitKey(1) & 0xFF
                    if key in (ord("q"), ord("Q")):
                        break
                    if key in (ord("s"), ord("S")):
                        self._set_mode(Mode.SAFE, "local_keyboard")
                    elif key in (ord("g"), ord("G")):
                        self._set_mode(Mode.GUARD, "local_keyboard")
                    if cv2.getWindowProperty(WINDOW_NAME, cv2.WND_PROP_VISIBLE) < 1:
                        break
        except KeyboardInterrupt:
            pass
        finally:
            bridge.set_camera_connected(False)
            server.shutdown()
            if cap is not None:
                cap.release()
            cv2.destroyAllWindows()
            self.alerts.shutdown()
            if self.supabase_outbox:
                self.supabase_outbox.shutdown()
            self.logger.event("SYSTEM", "System stopped")

    # ------------------------------------------------------------- rendering
    def _render(
        self,
        frame: np.ndarray,
        detections,
        state: FrameState,
        now: float,
        *,
        show_confidence_labels: bool = True,
    ) -> None:
        guard = state.mode is Mode.GUARD
        box_color = RED if (guard and detections) else GREEN
        PersonDetector.draw(
            frame,
            detections,
            box_color,
            show_confidence=show_confidence_labels,
        )

        if self.alerts.overlay_active(now):
            self.alerts.render_overlay(frame, now)

    def _render_hud(self, frame: np.ndarray, state: FrameState) -> None:
        guard = state.mode is Mode.GUARD
        lines = [
            (f"MODE: {state.mode.value}", ORANGE if guard else GREEN),
            (f"Persons: {state.person_count}", WHITE),
            (f"Confidence: avg {state.avg_confidence:.0%} | max {state.max_confidence:.0%}", WHITE),
            (f"FPS: {self._fps:.1f}", WHITE),
        ]
        if guard:
            if state.presence_seconds > 0:
                lines.append((f"Presence: {state.presence_seconds:.1f}s / {self.modes.intrusion_seconds:.1f}s", RED))
            else:
                lines.append(("Area clear", GREEN))
        else:
            s = self.modes.safe_stats
            lines.append((f"Peak: {s.peak_count} | Occupied: {s.occupancy_ratio:.0%} | "
                          f"Mean conf: {s.mean_confidence:.0%} | Frames: {s.frames}", WHITE))
        lines.append(("[S] Safe  [G] Guard  [Q] Quit", (200, 200, 200)))

        panel_w = 520
        panel_h = 14 + 24 * len(lines)
        roi = frame[0:panel_h, 0:panel_w]
        cv2.addWeighted(np.zeros_like(roi), 0.55, roi, 0.45, 0, roi)  # dark translucent panel
        for i, (text, color) in enumerate(lines):
            cv2.putText(frame, text, (10, 26 + 24 * i), cv2.FONT_HERSHEY_SIMPLEX,
                        0.6, color, 1, cv2.LINE_AA)


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Real-time AI surveillance (YOLO + OpenCV)")
    p.add_argument("--camera", type=int, default=0, help="webcam index (default 0)")
    p.add_argument("--width", type=int, default=1280)
    p.add_argument("--height", type=int, default=720)
    p.add_argument("--model", default="yolov8n.pt",
                   help="YOLO weights (yolov8n.pt fastest; yolov8s.pt/yolov8m.pt more accurate)")
    p.add_argument("--conf", type=float, default=0.5, help="min detection confidence (0-1)")
    p.add_argument("--imgsz", type=int, default=640, help="YOLO inference size")
    p.add_argument("--device", default=None, help="'cpu', 'cuda:0', 'mps' (default: auto)")
    p.add_argument("--duration", type=float, default=3.0, help="seconds of presence before intrusion alert")
    p.add_argument("--grace", type=float, default=0.7, help="seconds a person may vanish without resetting the timer")
    p.add_argument("--webhook", default=None, help="URL to POST intrusion alerts to (JSON)")
    p.add_argument(
        "--api-port",
        type=int,
        default=8765,
        help="loopback app API port (default 8765)",
    )
    p.add_argument(
        "--headless",
        action="store_true",
        help="run camera and local app API without the OpenCV preview window",
    )
    return p.parse_args()


def main() -> int:
    args = parse_args()
    try:
        SurveillanceApp(args).run()
    except (OSError, RuntimeError, ValueError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
