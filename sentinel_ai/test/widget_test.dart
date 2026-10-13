import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sentinel_ai/main.dart';
import 'package:sentinel_ai/src/device_record.dart';
import 'package:sentinel_ai/src/profile_screen.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('shows Supabase setup instructions when not configured', (
    tester,
  ) async {
    await tester.pumpWidget(const SentinelApp(client: null));

    expect(find.text('Connect Sentinel to Supabase'), findsOneWidget);
    expect(find.textContaining('SUPABASE_PUBLISHABLE_KEY'), findsOneWidget);
    expect(find.textContaining('service-role key'), findsOneWidget);
  });

  testWidgets('restores the saved dark appearance', (tester) async {
    SharedPreferences.setMockInitialValues({'dark_mode_enabled': true});
    await tester.pumpWidget(const SentinelApp(client: null));
    await tester.pumpAndSettle();

    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.theme?.brightness, Brightness.dark);
  });

  testWidgets(
    'profile screen shows account, devices, and disabled notifications',
    (tester) async {
      final client = SupabaseClient(
        'https://example.supabase.co',
        'test-key',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );
      var requestedDarkMode = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ProfileScreen(
              client: client,
              devices: const [DeviceRecord(id: 'device-1', name: 'Front gate')],
              darkMode: false,
              onThemeChanged: (enabled) async {
                requestedDarkMode = enabled;
              },
            ),
          ),
        ),
      );

      expect(find.text('My Cameras'), findsOneWidget);
      expect(find.text('Sentinel user'), findsOneWidget);
      expect(find.text('Front gate'), findsOneWidget);
      expect(find.text('Registered'), findsOneWidget);
      expect(find.text('Notification Settings'), findsOneWidget);
      await tester.ensureVisible(find.text('Dark mode'));
      await tester.pumpAndSettle();
      expect(find.text('Appearance'), findsOneWidget);
      expect(find.text('Dark mode'), findsOneWidget);
      await tester.tap(find.byType(SwitchListTile).first);
      await tester.pump();
      expect(requestedDarkMode, isTrue);
    },
  );
}
