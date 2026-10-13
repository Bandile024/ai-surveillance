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

## Run

From the `sentinel_ai` directory in PowerShell:

```powershell
flutter pub get
flutter run --dart-define=SUPABASE_URL=https://YOUR_PROJECT_REF.supabase.co --dart-define=SUPABASE_PUBLISHABLE_KEY=YOUR_PUBLISHABLE_KEY
```

Replace both placeholders. The URL must be the new project's full URL. If the
app opens with setup instructions, one or both `--dart-define` values were not
provided.

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
Python YOLO engine; Flutter does not open a second webcam. Start the engine on
the same computer before launching the app:

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
