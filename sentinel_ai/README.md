# Sentinel mobile dashboard

Flutter app for signing in to Supabase and viewing security events from devices
owned by the signed-in user. It lists recent intrusion and mode-change events,
updates when Supabase Realtime reports a new event, and shows intrusion details
and snapshots from the private `intrusion-snapshots` bucket.

## Configure Supabase

1. Apply the root project's Supabase migration and deploy the `device-ingest`
   Edge Function as described in the root [README](../README.md).
2. In Supabase **Authentication → Users**, create or enable an account for the
   person who owns the device. The app supports email/password sign-in and
   sign-up; confirmation emails may be required depending on the project's
   Auth settings.
3. Create the device row with that user's Auth UUID as `owner_id`, then
   register the engine's device-token hash in `device_credentials`. The user
   will only see devices and events allowed by the migration's row-level
   security policies.
4. Get the **Project URL** and **Publishable key** from **Project Settings →
   API**. Supply both at runtime; do not commit project credentials or use the
   `service_role` key in the app.

## Run the app and engine together (Windows)

After setting up the Python environment and Flutter SDK, add `SUPABASE_URL` and
`SUPABASE_PUBLISHABLE_KEY` to the root `.env.local` file. Then, from the project
root in PowerShell, run:

```powershell
.\run_sentinel.ps1
```

The launcher resolves Flutter dependencies only on first setup or after
dependency manifest changes, then starts the Python engine and opens the app
in Chrome while the engine model loads. The feed appears when the engine is
ready. Close the `flutter run` session to stop both. If PowerShell blocks
script execution, use:

```powershell
powershell -ExecutionPolicy Bypass -File .\run_sentinel.ps1
```

The URL must be the Supabase project's full URL. Use the publishable key, not
the `service_role` key. The app can also be run separately with the Flutter
commands below.

## Run Flutter separately

From the `sentinel_ai` directory:

```powershell
flutter pub get
flutter run -d chrome --dart-define=SUPABASE_URL=https://YOUR_PROJECT_REF.supabase.co --dart-define=SUPABASE_PUBLISHABLE_KEY=YOUR_PUBLISHABLE_KEY
```

The project includes the Flutter web entry point. To run in Chrome:

```powershell
flutter devices
flutter run -d chrome --dart-define=SUPABASE_URL=https://YOUR_PROJECT_REF.supabase.co --dart-define=SUPABASE_PUBLISHABLE_KEY=YOUR_PUBLISHABLE_KEY
```

If you use Supabase email confirmation or OAuth redirects on web, add the local
development URL printed by Flutter to **Authentication → URL Configuration →
Redirect URLs** in the Supabase dashboard.

## Local live camera

The Home and live-camera screens display the annotated stream produced by the
Python YOLO engine; Flutter does not open a second webcam. When starting the
components separately, start the engine on the same computer before launching
the app:

```powershell
cd ..
python main.py --headless
```

Then run the Flutter app in Chrome as above. The local engine API listens only
on `127.0.0.1:8765`; the app polls its status, displays its MJPEG stream, and
can request SAFE/GUARD mode changes. Keep the API bound to loopback. A browser
or app on another device cannot use this local-only feed. To use another local
port, start the engine with `--api-port PORT` and pass the matching URL to
Flutter with `--dart-define=ENGINE_API_URL=http://127.0.0.1:PORT`.

## Dashboard behavior

- Sign up or sign in with a Supabase email/password account.
- Open the profile from the dashboard to view the signed-in account and its
  registered devices; sign out from the profile screen.
- Switch between light and dark appearance from Profile → Appearance. The
  selected theme is saved locally and restored the next time the app opens.
- Push alert preferences are shown as unavailable until push delivery is
  configured.
- Use the bottom navigation to switch between the overview, all events,
  intrusion alerts, and profile.
- Browse the latest 100 events across the user's devices; filter the event list
  to intrusions or mode changes.
- View the local engine's camera preview from Home; open **View live camera**
  for the larger feed, SAFE/GUARD controls, and recent intrusion events. The
  app feed omits the engine's confidence and person-count overlays.
- Pull down or tap refresh to reload. Realtime inserts, updates, and deletes
  refresh the event list.
- Open an event to inspect its timestamp, device, JSON data, and snapshot.
  Snapshots are private and loaded through a 10-minute signed URL using the
  authenticated Supabase session.

## Tests

```powershell
flutter test
flutter analyze
```
