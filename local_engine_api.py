"""Loopback-only API for the local engine's live feed and mode controls."""
from __future__ import annotations

import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Optional
from urllib.parse import urlsplit


class LocalEngineBridge:
    def __init__(self) -> None:
        self._condition = threading.Condition()
        self._frame: Optional[bytes] = None
        self._frame_number = 0
        self._closed = False
        self._mode_request: Optional[str] = None
        self._status: dict[str, Any] = {
            "camera_connected": False,
            "mode": "SAFE",
            "person_count": 0,
            "avg_confidence": 0.0,
            "max_confidence": 0.0,
            "fps": 0.0,
            "last_detection_at": None,
            "last_frame_at": None,
            "peak_count": 0,
            "occupancy_ratio": 0.0,
        }

    def set_camera_connected(self, connected: bool) -> None:
        with self._condition:
            self._status["camera_connected"] = connected

    def publish(
        self,
        frame: bytes,
        *,
        mode: str,
        person_count: int,
        avg_confidence: float,
        max_confidence: float,
        fps: float,
        last_detection_at: Optional[str],
        last_frame_at: str,
        peak_count: int,
        occupancy_ratio: float,
    ) -> None:
        with self._condition:
            self._frame = frame
            self._frame_number += 1
            self._status.update(
                camera_connected=True,
                mode=mode,
                person_count=person_count,
                avg_confidence=avg_confidence,
                max_confidence=max_confidence,
                fps=fps,
                last_detection_at=last_detection_at,
                last_frame_at=last_frame_at,
                peak_count=peak_count,
                occupancy_ratio=occupancy_ratio,
            )
            self._condition.notify_all()

    def status(self) -> dict[str, Any]:
        with self._condition:
            return dict(self._status)

    def request_mode(self, mode: str) -> bool:
        if mode not in {"SAFE", "GUARD"}:
            return False
        with self._condition:
            self._mode_request = mode
            self._condition.notify_all()
        return True

    def take_mode_request(self) -> Optional[str]:
        with self._condition:
            mode, self._mode_request = self._mode_request, None
            return mode

    def wait_for_frame(self, after_frame: int) -> tuple[Optional[int], Optional[bytes]]:
        with self._condition:
            while not self._closed and self._frame_number <= after_frame:
                self._condition.wait(timeout=1.0)
            if self._closed:
                return None, None
            return self._frame_number, self._frame

    def close(self) -> None:
        with self._condition:
            self._closed = True
            self._condition.notify_all()


class LocalEngineServer:
    """Serve a camera stream and mode API on the local machine only."""

    def __init__(
        self,
        bridge: LocalEngineBridge,
        host: str = "127.0.0.1",
        port: int = 8765,
    ) -> None:
        if host not in {"127.0.0.1", "::1", "localhost"}:
            raise ValueError("The local engine API must bind to loopback only.")
        self.bridge = bridge

        class Handler(BaseHTTPRequestHandler):
            server_version = "SentinelLocalEngine/1.0"

            def _allowed_origin(self) -> Optional[str]:
                origin = self.headers.get("Origin")
                if not origin:
                    return None
                parsed = urlsplit(origin)
                if parsed.scheme == "http" and parsed.hostname in {
                    "localhost",
                    "127.0.0.1",
                    "::1",
                }:
                    return origin
                return ""

            def _cors_headers(self) -> bool:
                origin = self._allowed_origin()
                if origin == "":
                    self.send_error(403, "Only localhost origins are allowed")
                    return False
                if origin:
                    self.send_header("Access-Control-Allow-Origin", origin)
                    self.send_header("Vary", "Origin")
                    self.send_header(
                        "Access-Control-Allow-Methods", "GET, POST, OPTIONS"
                    )
                    self.send_header("Access-Control-Allow-Headers", "Content-Type")
                return True

            def do_OPTIONS(self) -> None:
                if self._allowed_origin() == "":
                    self.send_error(403, "Only localhost origins are allowed")
                    return
                self.send_response(204)
                self._cors_headers()
                self.end_headers()

            def do_GET(self) -> None:
                if self._allowed_origin() == "":
                    self.send_error(403, "Only localhost origins are allowed")
                    return
                if self.path == "/api/status":
                    body = json.dumps(bridge.status(), separators=(",", ":")).encode()
                    self.send_response(200)
                    self._cors_headers()
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                elif self.path == "/stream.mjpg":
                    self._stream()
                else:
                    self.send_error(404, "Not found")

            def _stream(self) -> None:
                self.send_response(200)
                self._cors_headers()
                self.send_header(
                    "Content-Type", "multipart/x-mixed-replace; boundary=frame"
                )
                self.send_header("Cache-Control", "no-store, no-cache, must-revalidate")
                self.end_headers()
                frame_number = -1
                try:
                    while True:
                        next_number, frame = bridge.wait_for_frame(frame_number)
                        if next_number is None or frame is None:
                            return
                        frame_number = next_number
                        self.wfile.write(
                            b"--frame\r\n"
                            b"Content-Type: image/jpeg\r\n"
                            + f"Content-Length: {len(frame)}\r\n\r\n".encode()
                            + frame
                            + b"\r\n"
                        )
                        self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError):
                    return

            def do_POST(self) -> None:
                if self._allowed_origin() == "":
                    self.send_error(403, "Only localhost origins are allowed")
                    return
                if self.path != "/api/mode":
                    self.send_error(404, "Not found")
                    return
                content_length = self.headers.get("Content-Length", "")
                if not content_length.isdigit() or int(content_length) > 128:
                    self.send_error(400, "Invalid request size")
                    return
                try:
                    body = json.loads(self.rfile.read(int(content_length)))
                except (json.JSONDecodeError, UnicodeDecodeError):
                    self.send_error(400, "Invalid JSON body")
                    return
                if not isinstance(body, dict) or not isinstance(body.get("mode"), str):
                    self.send_error(400, "Expected a mode string")
                    return
                mode = body["mode"].upper()
                if not bridge.request_mode(mode):
                    self.send_error(400, "Mode must be SAFE or GUARD")
                    return
                response = json.dumps({"requested_mode": mode}).encode()
                self.send_response(202)
                self._cors_headers()
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(response)))
                self.end_headers()
                self.wfile.write(response)

            def log_message(self, format: str, *args: Any) -> None:
                return

        self._server = ThreadingHTTPServer((host, port), Handler)
        self._server.daemon_threads = True
        self.host, self.port = self._server.server_address[:2]
        self._thread = threading.Thread(
            target=self._server.serve_forever,
            name="local-engine-api",
            daemon=True,
        )
        self._started = False

    def start(self) -> None:
        self._thread.start()
        self._started = True

    def shutdown(self) -> None:
        self.bridge.close()
        if self._started:
            self._server.shutdown()
        self._server.server_close()
        if self._started:
            self._thread.join(timeout=2)
