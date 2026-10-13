# AI Surveillance System (YOLO + OpenCV)

Real-time person detection from your laptop webcam with two operating modes:

| Mode | Behaviour |
|------|-----------|
| **SAFE** (`S`) | People are expected. Continuous monitoring, **no alerts**, live statistics (peak count, occupancy %, mean confidence). |
| **GUARD** (`G`) | People are *not* expected. A person present **continuously for more than 3 seconds** triggers an intrusion: red warning overlay, snapshot saved to `intrusions/`, event logged with timestamp, notifications dispatched. |

The on-screen HUD shows: current mode, number of persons, detection confidence, and FPS.

---

## 1. Requirements

- Python **3.9 – 3.12** (check with `python --version`)
- A webcam
- ~500 MB free disk (PyTorch + dependencies). Internet is needed on the first run only (to download the YOLO weights).

## 2. Setup (copy-paste)

### Windows (PowerShell)
```powershell
cd ai-surveillance
python -m venv venv
venv\Scripts\activate
pip install -r requirements.txt
```
> If activation is blocked: `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`

Once the Python and Flutter prerequisites are installed and configured, start
the whole local system—AI engine plus Flutter app in Chrome—from the project
root with:

```powershell
.\run_sentinel.ps1
```

The launcher reads `SUPABASE_URL` and `SUPABASE_PUBLISHABLE_KEY` from the root
`.env.local`, starts the camera engine, and opens Flutter in parallel while the
engine loads. It resolves Flutter packages only on first setup or after
`pubspec.yaml`/`pubspec.lock` changes. Add the publishable key to that ignored
local file if it is not already there. Keep using the Supabase **publishable**
key; never use the `service_role` key in the app. Closing `flutter run` also
requests a clean engine shutdown. If PowerShell blocks the script due to
execution policy, run:

```powershell
powershell -ExecutionPolicy Bypass -File .\run_sentinel.ps1
```

### macOS / Linux
```bash
cd ai-surveillance
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
python main.py
```

On first launch the `yolov8n.pt` model (~6 MB) downloads automatically. **macOS:** allow camera access for your Terminal/IDE when prompted (System Settings → Privacy & Security → Camera).

## 3. Controls

| Key | Action |
|-----|--------|
| `S` | Switch to SAFE mode |
| `G` | Switch to GUARD mode |
| `Q` | Quit (or close the window) |

The system starts in **SAFE** mode.

## 4. Command-line options

```bash
python main.py --camera 1            # use a different webcam
python main.py --duration 5          # require 5s of presence before alerting
python main.py --conf 0.6            # stricter detection threshold
python main.py --model yolov8s.pt    # more accurate (slower) model
python main.py --device cuda:0       # force GPU (or: cpu, mps)
python main.py --width 640 --height 480   # lower resolution = higher FPS
python main.py --webhook https://your-server.example/api/alerts
python main.py --headless                 # run feed/API without OpenCV preview
```

| Option | Default | Description |
|--------|---------|-------------|
| `--camera` | `0` | Webcam index |
| `--width/--height` | `1280/720` | Capture resolution |
| `--model` | `yolov8n.pt` | YOLO weights |
| `--conf` | `0.5` | Minimum detection confidence |
| `--imgsz` | `640` | YOLO inference size (smaller = faster) |
| `--device` | auto | `cpu`, `cuda:0`, `mps` |
| `--duration` | `3.0` | Seconds of continuous presence before alert |
| `--grace` | `0.7` | Seconds a person can disappear (missed frames) without resetting the timer |
| `--webhook` | none | URL that receives each alert as a JSON `POST` |
| `--api-port` | `8765` | Loopback-only API port for the Flutter live camera |
| `--headless` | off | Run the camera and API without the OpenCV preview window |

## 5. Output

```
ai-surveillance/
├── intrusions/            # auto-created; one annotated .jpg per intrusion
│   └── intrusion_20261008_142530_123.jpg
└── logs/                  # auto-created
    ├── events.log         # human-readable, rotating (2 MB x 5 files)
    ├── events.jsonl       # one JSON event per line (machine-readable)
    └── supabase-outbox.sqlite3  # durable cloud-upload queue (when enabled)
```

Example `events.log` line:
```
2026-10-08 14:25:30,123 | WARNING | [INTRUSION] Intrusion detected: 1 person(s), confidence 87%
```

## 6. Project structure

| File | Responsibility |
|------|----------------|
| `detector.py` | `PersonDetector` – YOLO wrapper, **person class only**, returns `Detection` objects |
| `mode_manager.py` | `ModeManager` – SAFE/GUARD state machine, 3-second continuous-presence logic, SAFE statistics |
| `alert_engine.py` | `AlertEngine` – snapshot, red overlay, log, and dispatch to pluggable `NotificationChannel`s |
| `logger.py` | `EventLogger` – rotating text log + JSONL structured events |
| `main.py` | `SurveillanceApp` – camera loop, HUD, keyboard handling, CLI |
| `supabase_sync.py` | Durable asynchronous event/snapshot delivery to Supabase |

### How the 3-second rule works
In GUARD mode a timer starts when a person first appears. It keeps running if the person is momentarily missed (up to `--grace` seconds), and resets only after they've truly left. When the timer exceeds `--duration`, **one** alert fires per continuous episode (no spam while the person stays in view).

## 7. Mobile app & push notification integration

The system is built so notifications never touch the video loop:

- Every alert is a serializable `Alert` object (`id`, `type`, `timestamp`, `person_count`, `max_confidence`, `snapshot_path`, `message`).
- Channels run on a background thread pool; a failing channel is logged and never crashes detection.

**Fastest path – webhook:** run with `--webhook https://your-backend/alerts`. Your backend receives:
```json
{
  "id": "6f1c...", "type": "INTRUSION",
  "timestamp": "2026-10-08T14:25:30.123",
  "person_count": 1, "max_confidence": 0.87,
  "snapshot_path": "intrusions/intrusion_20261008_142530_123.jpg",
  "message": "Intrusion detected: 1 person(s), confidence 87%"
}
```
and can forward it to a phone via Firebase Cloud Messaging, APNs, Telegram, etc.

**Custom channel (e.g. Firebase push):**
```python
# alert_engine.py (or a new notifiers.py)
class FCMChannel(NotificationChannel):
    def __init__(self, device_token): ...
    def send(self, alert: Alert) -> None:
        # call firebase_admin.messaging.send(...) here
        ...
```
Then register it in `main.py`:
```python
channels.append(FCMChannel(token))
```

**Other natural next steps** (the architecture already supports them): a REST/WebSocket layer that reads `logs/events.jsonl`, serving `intrusions/` snapshots to the app, remote mode switching by calling `ModeManager.set_mode()`, and multi-camera support by running one `SurveillanceApp` per camera index.

## 8. Supabase event delivery (optional)

The engine can send intrusion events, their snapshots, and local SAFE/GUARD mode
changes to a Supabase project. Detection remains local. Events are queued in
`logs/supabase-outbox.sqlite3` and retried after network or server failures, so a
temporary outage does not stop monitoring. A local snapshot path is never sent;
images are uploaded to the private `intrusion-snapshots` Storage bucket.

This integration does not configure RTSP cameras or receive remote app commands.
The local Flutter app can view the annotated camera stream and request SAFE/GUARD
mode changes over a loopback-only API (`127.0.0.1:8765`). Start the engine first,
then run the Flutter app from `sentinel_ai/`; `--headless` avoids showing a
second preview window. This API has no authentication and must not be exposed
outside the local machine. Mode-change events identify whether the change came
from the keyboard or the Flutter app.

### Supabase setup

The integration files are under `supabase/`:

1. Install and authenticate the Supabase CLI, then link the project:
   ```powershell
   supabase login
   supabase link --project-ref YOUR_PROJECT_REF
   supabase db push
   supabase functions deploy device-ingest
   ```
2. Generate a random per-device token and its SHA-256 digest locally in
   PowerShell:
   ```powershell
   $env:SUPABASE_DEVICE_TOKEN = python -c "import secrets; print(secrets.token_urlsafe(48))"
   $tokenHash = python -c "import hashlib, os; print(hashlib.sha256(os.environ['SUPABASE_DEVICE_TOKEN'].encode()).hexdigest())"
   ```
   Create a device row for an existing Supabase Auth user's UUID in
   `public.devices`, then create its `public.device_credentials` row using the
   device UUID and `$tokenHash`. Insert **only the digest** into the database.
   Provision the raw token securely to the edge computer; do not store it in SQL
   scripts, the app, or source control.

   For example, create the row in the SQL editor with:
   ```sql
   insert into public.devices (owner_id, name)
   values ('YOUR_AUTH_USER_UUID', 'AI Engine');
   ```
   Copy the generated device `id`, then insert its credential using that ID and
   the locally calculated `$tokenHash`:
   ```sql
   insert into public.device_credentials (device_id, token_hash)
   values ('YOUR_DEVICE_UUID', 'YOUR_SHA256_HEX_DIGEST');
   ```
3. Put the Supabase Project URL in `SUPABASE_URL` and the raw device token in
   `SUPABASE_DEVICE_TOKEN` in the root `.env.local`, then run:
   ```powershell
   python main.py
   ```
   The engine constructs the function URL as
   `SUPABASE_URL/functions/v1/device-ingest`. It also accepts an explicit
   `SUPABASE_INGEST_URL` override. The engine reads `.env.local` at startup;
   existing environment variables take precedence. The publishable key is
   included for future Flutter setup but is not used by the engine. Never put
   the Supabase `service_role` key in this file or the Flutter app.

The Edge Function uses Supabase's server-side `SUPABASE_SERVICE_ROLE_KEY`; it
validates the device token hash before accepting events. The service-role key
must never be configured on the engine or Flutter app. The publishable key is
intended for the future Flutter client and is not device authentication. The function disables
gateway JWT verification because it authenticates the engine's device token
itself. The migration grants app users read access only to devices/events they
own and only to their event snapshots; device credential hashes are not exposed
to app users.

Event IDs are idempotent UUIDs. Intrusion records include person count,
maximum confidence, and the event message. Their snapshot object key is stored
on the event row. Mode changes include previous and new mode and
`local_keyboard` or `flutter_app` as the source. The schema reserves event types
for future remote control request/outcome auditing; the app's current mode
control is limited to this machine's loopback API.

To disable cloud delivery, leave both environment variables unset. If one is
set without the other, startup fails with a configuration error.

## 9. Troubleshooting

| Problem | Fix |
|---------|-----|
| `Cannot open camera index 0` | Close Zoom/Teams/other apps using the webcam; grant camera permission; try `--camera 1` |
| Low FPS | Use `--width 640 --height 480`, `--imgsz 480`, keep `yolov8n.pt`, or use a GPU (`--device cuda:0`) |
| Missed detections | Lower `--conf` (e.g. `0.35`) or use `--model yolov8s.pt`; improve lighting |
| False detections | Raise `--conf` (e.g. `0.6`) |
| Keys not responding | Click the video window first so it has focus |
| `pip install` fails on newest Python | Use Python 3.11 or 3.12 |
| Model download fails | Check internet, or manually place `yolov8n.pt` in the project folder |

## 10. Notes

- Only use this on spaces and with people you have the right to monitor. Snapshots contain images of people; protect the `intrusions/` folder accordingly and follow local privacy laws.
- Detection runs entirely on your machine; alerts and snapshots are uploaded only when you configure the webhook or Supabase integration.
