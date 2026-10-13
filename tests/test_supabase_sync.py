from contextlib import closing
import os
import sqlite3
import tempfile
import time
import unittest
from datetime import datetime, timezone
from pathlib import Path
from unittest.mock import MagicMock, patch

from main import load_local_env, supabase_ingest_config
from supabase_sync import SupabaseOutbox, normalize_event


class NullLogger:
    def __init__(self) -> None:
        self.warnings: list[str] = []
        self.errors: list[str] = []

    def warning(self, _message: str) -> None:
        self.warnings.append(_message)

    def error(self, _message: str) -> None:
        self.errors.append(_message)


class NormalizeEventTests(unittest.TestCase):
    def test_intrusion_alert_uses_uuid_and_omits_machine_snapshot_path(self) -> None:
        event = normalize_event(
            {
                "id": "26b16c89-6aa3-4634-9913-69ad8d79e838",
                "type": "INTRUSION",
                "timestamp": "2026-10-08T16:56:09.776+02:00",
                "person_count": 1,
                "max_confidence": 0.924,
                "snapshot_path": r"C:\private\intrusions\alert.jpg",
            }
        )

        self.assertEqual(event["event_id"], "26b16c89-6aa3-4634-9913-69ad8d79e838")
        self.assertEqual(event["event_type"], "INTRUSION")
        self.assertEqual(event["occurred_at"], "2026-10-08T14:56:09.776Z")
        self.assertEqual(event["data"], {"person_count": 1, "max_confidence": 0.924})

    def test_mode_event_preserves_mode_control_context(self) -> None:
        event = normalize_event(
            {
                "event_id": "26b16c89-6aa3-4634-9913-69ad8d79e838",
                "type": "MODE_CHANGE",
                "timestamp": datetime(2026, 10, 8, tzinfo=timezone.utc).isoformat(),
                "old_mode": "SAFE",
                "new_mode": "GUARD",
                "source": "local_keyboard",
            }
        )

        self.assertEqual(event["data"]["old_mode"], "SAFE")
        self.assertEqual(event["data"]["new_mode"], "GUARD")
        self.assertEqual(event["data"]["source"], "local_keyboard")

    def test_rejects_non_uuid_ids_and_unknown_event_types(self) -> None:
        with self.assertRaises(ValueError):
            normalize_event({"id": "not-a-uuid", "type": "INTRUSION"})
        with self.assertRaises(ValueError):
            normalize_event(
                {
                    "id": "26b16c89-6aa3-4634-9913-69ad8d79e838",
                    "type": "FRAME_DETECTION",
                }
            )


class LocalEnvTests(unittest.TestCase):
    def test_reads_values_and_preserves_process_environment(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            env_path = Path(temp_dir) / ".env.local"
            env_path.write_text(
                "# config\nSUPABASE_URL=\"https://example.test\"\n"
                "SUPABASE_PUBLISHABLE_KEY=publishable-test-key\n"
                "SUPABASE_DEVICE_TOKEN=file-token\n",
                encoding="utf-8",
            )
            with patch.dict(
                os.environ,
                {
                    "SUPABASE_URL": "https://override.test",
                    "SUPABASE_DEVICE_TOKEN": "",
                },
            ):
                load_local_env(env_path)
                self.assertEqual(
                    os.environ["SUPABASE_URL"],
                    "https://override.test",
                )
                self.assertEqual(os.environ["SUPABASE_DEVICE_TOKEN"], "")

            with patch.dict(os.environ, {}, clear=True):
                load_local_env(env_path)
                self.assertEqual(
                    os.environ["SUPABASE_URL"],
                    "https://example.test",
                )
                self.assertEqual(
                    os.environ["SUPABASE_PUBLISHABLE_KEY"],
                    "publishable-test-key",
                )
                self.assertEqual(os.environ["SUPABASE_DEVICE_TOKEN"], "file-token")

    def test_project_url_builds_engine_function_url(self) -> None:
        config = supabase_ingest_config(
            "https://project.supabase.co/",
            None,
            "device-token",
        )
        self.assertEqual(
            config,
            (
                "https://project.supabase.co/functions/v1/device-ingest",
                "device-token",
            ),
        )

    def test_publishable_app_config_alone_does_not_enable_engine_uploads(self) -> None:
        self.assertEqual(
            supabase_ingest_config("https://project.supabase.co", None, None),
            (None, None),
        )


class SupabaseUploadTests(unittest.TestCase):
    def test_upload_contains_event_and_snapshot_without_local_path(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            snapshot_path = Path(temp_dir) / "intrusion.jpg"
            snapshot_path.write_bytes(b"test-jpeg")
            outbox = SupabaseOutbox(
                "https://project.example/functions/v1/device-ingest",
                "a" * 48,
                Path(temp_dir) / "outbox.sqlite3",
                NullLogger(),
            )
            response = MagicMock()
            response.status = 201

            try:
                with patch("urllib.request.urlopen") as urlopen:
                    urlopen.return_value.__enter__.return_value = response
                    event = normalize_event(
                        {
                            "id": "26b16c89-6aa3-4634-9913-69ad8d79e838",
                            "type": "INTRUSION",
                            "timestamp": "2026-10-08T16:56:09.776+02:00",
                            "person_count": 1,
                            "max_confidence": 0.924,
                            "snapshot_path": str(snapshot_path),
                        }
                    )
                    outbox._post_event(event, str(snapshot_path))

                request = urlopen.call_args.args[0]
                self.assertEqual(request.get_header("Authorization"), f"Bearer {'a' * 48}")
                self.assertIn(b"test-jpeg", request.data)
                self.assertIn(b'"person_count":1', request.data)
                self.assertNotIn(str(snapshot_path).encode(), request.data)
            finally:
                outbox.shutdown()

    def test_failed_delivery_survives_restart_and_retries(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            db_path = Path(temp_dir) / "outbox.sqlite3"
            event = {
                "id": "26b16c89-6aa3-4634-9913-69ad8d79e838",
                "type": "MODE_CHANGE",
                "timestamp": "2026-10-08T16:56:09.776+02:00",
                "old_mode": "SAFE",
                "new_mode": "GUARD",
                "source": "local_keyboard",
            }
            with patch.object(
                SupabaseOutbox, "_post_event", side_effect=OSError("offline")
            ):
                outbox = SupabaseOutbox(
                    "https://project.example/functions/v1/device-ingest",
                    "a" * 48,
                    db_path,
                    NullLogger(),
                )
                outbox.enqueue(event)
                deadline = time.monotonic() + 2
                while time.monotonic() < deadline:
                    with closing(sqlite3.connect(db_path)) as db:
                        attempts = db.execute(
                            "SELECT attempts FROM pending_events"
                        ).fetchone()
                    if attempts and attempts[0] == 1:
                        break
                    time.sleep(0.01)
                outbox.shutdown()

            self.assertEqual(attempts[0], 1)
            with closing(sqlite3.connect(db_path)) as db:
                db.execute("UPDATE pending_events SET next_attempt = 0")
                db.commit()

            with patch.object(SupabaseOutbox, "_post_event") as post_event:
                retry_outbox = SupabaseOutbox(
                    "https://project.example/functions/v1/device-ingest",
                    "a" * 48,
                    db_path,
                    NullLogger(),
                )
                try:
                    deadline = time.monotonic() + 2
                    while time.monotonic() < deadline:
                        with closing(sqlite3.connect(db_path)) as db:
                            remaining = db.execute(
                                "SELECT count(*) FROM pending_events"
                            ).fetchone()[0]
                        if remaining == 0:
                            break
                        time.sleep(0.01)
                finally:
                    retry_outbox.shutdown()

            self.assertTrue(post_event.called)
            self.assertEqual(remaining, 0)


if __name__ == "__main__":
    unittest.main()
