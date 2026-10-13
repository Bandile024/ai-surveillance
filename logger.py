"""Event logging.

Two outputs are written:
  logs/events.log    - human-readable, rotating text log (also echoed to console)
  logs/events.jsonl  - one JSON object per line; machine-readable, ready to be
                       tailed or ingested by a future API / mobile backend.
"""
from __future__ import annotations

import json
import logging
import threading
from datetime import datetime, timezone
from logging.handlers import RotatingFileHandler
from pathlib import Path
from typing import Any, Dict


class EventLogger:
    def __init__(self, log_dir: Path, name: str = "surveillance") -> None:
        self.log_dir = Path(log_dir)
        self.log_dir.mkdir(parents=True, exist_ok=True)
        self._jsonl_path = self.log_dir / "events.jsonl"
        self._lock = threading.Lock()

        self._logger = logging.getLogger(name)
        self._logger.setLevel(logging.INFO)
        self._logger.propagate = False

        if not self._logger.handlers:  # avoid duplicate handlers on re-instantiation
            fmt = logging.Formatter("%(asctime)s | %(levelname)-7s | %(message)s")
            file_handler = RotatingFileHandler(
                self.log_dir / "events.log", maxBytes=2_000_000, backupCount=5, encoding="utf-8"
            )
            file_handler.setFormatter(fmt)
            console = logging.StreamHandler()
            console.setFormatter(fmt)
            self._logger.addHandler(file_handler)
            self._logger.addHandler(console)

    def info(self, message: str) -> None:
        self._logger.info(message)

    def warning(self, message: str) -> None:
        self._logger.warning(message)

    def error(self, message: str) -> None:
        self._logger.error(message)

    def event(self, event_type: str, message: str, **data: Any) -> Dict[str, Any]:
        """Log a structured event to both the text log and the JSONL file."""
        record = {
            "timestamp": datetime.now(timezone.utc).isoformat(timespec="milliseconds"),
            "type": event_type,
            "message": message,
            **data,
        }
        level = logging.WARNING if event_type == "INTRUSION" else logging.INFO
        self._logger.log(level, f"[{event_type}] {message}")
        with self._lock:
            with open(self._jsonl_path, "a", encoding="utf-8") as fh:
                fh.write(json.dumps(record) + "\n")
        return record
