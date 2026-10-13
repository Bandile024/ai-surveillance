"""Durable, asynchronous delivery of engine events to Supabase."""
from __future__ import annotations

import json
import sqlite3
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, Optional, Protocol, Tuple


class SyncLogger(Protocol):
    def warning(self, message: str) -> None: ...
    def error(self, message: str) -> None: ...


def normalize_event(event: Dict[str, Any]) -> Dict[str, Any]:
    """Convert local engine records into the cloud event envelope."""
    event_id = str(event.get("event_id") or event.get("id") or uuid.uuid4())
    uuid.UUID(event_id)

    event_type = str(event.get("event_type") or event.get("type") or "")
    if event_type not in {
        "INTRUSION",
        "MODE_CHANGE",
        "CONTROL_REQUESTED",
        "CONTROL_APPLIED",
        "CONTROL_FAILED",
    }:
        raise ValueError(f"Unsupported Supabase event type: {event_type}")

    timestamp = event.get("occurred_at") or event.get("timestamp")
    if not timestamp:
        occurred_at = datetime.now(timezone.utc)
    else:
        occurred_at = datetime.fromisoformat(str(timestamp).replace("Z", "+00:00"))
        if occurred_at.tzinfo is None:
            occurred_at = occurred_at.astimezone()
        occurred_at = occurred_at.astimezone(timezone.utc)

    excluded = {
        "event_id", "id", "event_type", "type", "timestamp", "occurred_at",
        "snapshot_path", "snapshot",
    }
    payload = event.get("data")
    if payload is None:
        payload = {key: value for key, value in event.items() if key not in excluded}
    if not isinstance(payload, dict):
        raise ValueError("Event data must be a JSON object")

    return {
        "event_id": event_id,
        "event_type": event_type,
        "occurred_at": occurred_at.isoformat(timespec="milliseconds").replace("+00:00", "Z"),
        "data": payload,
    }


class SupabaseOutbox:
    """Persist events locally and retry delivery without blocking inference."""

    _MAX_SNAPSHOT_BYTES = 8 * 1024 * 1024

    def __init__(
        self,
        ingest_url: str,
        device_token: str,
        outbox_path: Path,
        logger: SyncLogger,
        timeout: float = 10.0,
    ) -> None:
        parsed_url = urllib.parse.urlparse(ingest_url)
        local_http = parsed_url.scheme == "http" and parsed_url.hostname in {
            "localhost", "127.0.0.1", "::1",
        }
        if parsed_url.scheme != "https" and not local_http:
            raise ValueError("SUPABASE_INGEST_URL must use HTTPS")
        if not parsed_url.netloc or not parsed_url.path:
            raise ValueError("SUPABASE_INGEST_URL must be a full Edge Function URL")
        if len(device_token) < 32:
            raise ValueError("SUPABASE_DEVICE_TOKEN must contain at least 32 characters")

        self.ingest_url = ingest_url
        self.device_token = device_token
        self.outbox_path = Path(outbox_path)
        self.outbox_path.parent.mkdir(parents=True, exist_ok=True)
        self.logger = logger
        self.timeout = timeout
        self._lock = threading.Lock()
        self._wake = threading.Event()
        self._stopping = False
        self._db = sqlite3.connect(self.outbox_path, check_same_thread=False)
        self._db.execute(
            """
            CREATE TABLE IF NOT EXISTS pending_events (
                event_id TEXT PRIMARY KEY,
                event_json TEXT NOT NULL,
                snapshot_path TEXT,
                attempts INTEGER NOT NULL DEFAULT 0,
                next_attempt REAL NOT NULL
            )
            """
        )
        self._db.commit()
        self._worker = threading.Thread(
            target=self._deliver_loop, name="supabase-outbox", daemon=True
        )
        self._worker.start()

    def enqueue(
        self,
        event: Dict[str, Any],
        snapshot_path: Optional[str] = None,
    ) -> None:
        envelope = normalize_event(event)
        event_json = json.dumps(envelope, separators=(",", ":"), allow_nan=False)
        with self._lock:
            self._db.execute(
                """
                INSERT OR IGNORE INTO pending_events
                    (event_id, event_json, snapshot_path, next_attempt)
                VALUES (?, ?, ?, ?)
                """,
                (envelope["event_id"], event_json, snapshot_path, time.time()),
            )
            self._db.commit()
        self._wake.set()

    def shutdown(self) -> None:
        self._stopping = True
        self._wake.set()
        self._worker.join(timeout=self.timeout + 1)
        with self._lock:
            self._db.close()

    def _next_event(self) -> Tuple[Optional[sqlite3.Row], Optional[float]]:
        with self._lock:
            self._db.row_factory = sqlite3.Row
            row = self._db.execute(
                """
                SELECT event_id, event_json, snapshot_path, attempts, next_attempt
                FROM pending_events
                ORDER BY next_attempt, event_id
                LIMIT 1
                """
            ).fetchone()
        if row is None:
            return None, None
        return row, max(0.0, float(row["next_attempt"]) - time.time())

    def _deliver_loop(self) -> None:
        while not self._stopping:
            row, wait_seconds = self._next_event()
            if row is None or wait_seconds:
                self._wake.wait(timeout=min(wait_seconds or 1.0, 1.0))
                self._wake.clear()
                continue

            try:
                envelope = json.loads(row["event_json"])
                self._post_event(envelope, row["snapshot_path"])
            except Exception as exc:
                attempts = int(row["attempts"]) + 1
                retry_delay = min(300.0, 2 ** min(attempts, 8))
                with self._lock:
                    self._db.execute(
                        """
                        UPDATE pending_events
                        SET attempts = ?, next_attempt = ?
                        WHERE event_id = ?
                        """,
                        (attempts, time.time() + retry_delay, row["event_id"]),
                    )
                    self._db.commit()
                self.logger.error(
                    f"Supabase delivery failed for event {row['event_id']}; "
                    f"retrying in {retry_delay:.0f}s: {exc}"
                )
            else:
                with self._lock:
                    self._db.execute(
                        "DELETE FROM pending_events WHERE event_id = ?",
                        (row["event_id"],),
                    )
                    self._db.commit()

    def _post_event(self, event: Dict[str, Any], snapshot_path: Optional[str]) -> None:
        boundary = f"----surveillance-{uuid.uuid4().hex}"
        body_parts = [
            f"--{boundary}\r\n".encode(),
            b'Content-Disposition: form-data; name="event"\r\n',
            b"Content-Type: application/json\r\n\r\n",
            json.dumps(event, separators=(",", ":"), allow_nan=False).encode("utf-8"),
            b"\r\n",
        ]

        if snapshot_path:
            path = Path(snapshot_path)
            if path.is_file():
                snapshot = path.read_bytes()
                if len(snapshot) > self._MAX_SNAPSHOT_BYTES:
                    raise ValueError("Snapshot exceeds the 8 MiB upload limit")
                body_parts.extend(
                    [
                        f"--{boundary}\r\n".encode(),
                        (
                            'Content-Disposition: form-data; name="snapshot"; '
                            f'filename="{path.name}"\r\n'
                        ).encode("utf-8"),
                        b"Content-Type: image/jpeg\r\n\r\n",
                        snapshot,
                        b"\r\n",
                    ]
                )
            else:
                self.logger.warning(
                    f"Snapshot for event {event['event_id']} is missing; "
                    "sending event metadata without an image."
                )
                event.setdefault("data", {})["snapshot_unavailable"] = True
                body_parts[3] = json.dumps(
                    event, separators=(",", ":"), allow_nan=False
                ).encode("utf-8")

        body_parts.append(f"--{boundary}--\r\n".encode())
        request = urllib.request.Request(
            self.ingest_url,
            data=b"".join(body_parts),
            headers={
                "Authorization": f"Bearer {self.device_token}",
                "Content-Type": f"multipart/form-data; boundary={boundary}",
                "Accept": "application/json",
            },
            method="POST",
        )
        with urllib.request.urlopen(request, timeout=self.timeout) as response:
            if not 200 <= response.status < 300:
                raise urllib.error.HTTPError(
                    self.ingest_url, response.status, "Supabase ingest failed",
                    response.headers, None,
                )
