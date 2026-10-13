import 'package:flutter_test/flutter_test.dart';
import 'package:sentinel_ai/main.dart';
import 'package:sentinel_ai/src/device_record.dart';
import 'package:sentinel_ai/src/profile_screen.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  testWidgets('shows Supabase setup instructions when not configured', (
    tester,
  ) async {
    await tester.pumpWidget(const SentinelApp(client: null));

    expect(find.text('Connect Sentinel to Supabase'), findsOneWidget);
    expect(find.textContaining('SUPABASE_PUBLISHABLE_KEY'), findsOneWidget);
    expect(find.textContaining('service-role key'), findsOneWidget);
  });

  testWidgets(
    'profile screen shows account, devices, and disabled notifications',
    (tester) async {
      final client = SupabaseClient('https://example.supabase.co', 'test-key');
      await tester.pumpWidget(
        MaterialApp(
          home: ProfileScreen(
            client: client,
            devices: const [DeviceRecord(id: 'device-1', name: 'Front gate')],
          ),
        ),
      );

      expect(find.text('My Cameras'), findsOneWidget);
      expect(find.text('Front gate'), findsOneWidget);
      expect(find.text('Registered'), findsOneWidget);
      expect(find.text('Notification Settings'), findsOneWidget);
      expect(find.text('Logout'), findsOneWidget);
      expect(find.text('Sentinel user'), findsOneWidget);

      await client.dispose();
    },
  );
}
