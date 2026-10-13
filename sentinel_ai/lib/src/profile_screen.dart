import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'device_record.dart';

const _blue = Color(0xFF2488F5);
const _blueDark = Color(0xFF2865E8);

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({
    super.key,
    required this.client,
    required this.devices,
    required this.darkMode,
    required this.onThemeChanged,
  });

  final SupabaseClient client;
  final List<DeviceRecord> devices;
  final bool darkMode;
  final Future<void> Function(bool enabled) onThemeChanged;

  String get _email => client.auth.currentUser?.email ?? 'No email available';

  String get _displayName {
    final metadata = client.auth.currentUser?.userMetadata;
    final metadataName =
        metadata?['full_name'] ??
        metadata?['name'] ??
        metadata?['display_name'];
    if (metadataName is String && metadataName.trim().isNotEmpty) {
      return metadataName.trim();
    }

    final emailName = client.auth.currentUser?.email?.split('@').first;
    if (emailName == null || emailName.isEmpty) return 'Sentinel user';
    return emailName
        .replaceAll(RegExp(r'[._-]+'), ' ')
        .split(' ')
        .where((part) => part.isNotEmpty)
        .map((part) => '${part[0].toUpperCase()}${part.substring(1)}')
        .join(' ');
  }

  String get _initial {
    final name = _displayName.trim();
    return name.isEmpty ? 'S' : name[0].toUpperCase();
  }

  Future<void> _signOut(BuildContext context) async {
    try {
      await client.auth.signOut();
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not sign out: $error')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
      children: [
        _ProfileCard(
          child: Row(
            children: [
              Container(
                width: 72,
                height: 72,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(colors: [_blue, _blueDark]),
                  borderRadius: BorderRadius.circular(22),
                ),
                child: Text(
                  _initial,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 30,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 18),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _displayName,
                      style: TextStyle(
                        color: colors.onSurface,
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 5),
                    SelectableText(
                      _email,
                      style: TextStyle(
                        color: colors.onSurfaceVariant,
                        fontSize: 15,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        const _SectionTitle(icon: Icons.videocam_outlined, title: 'My Cameras'),
        const SizedBox(height: 10),
        if (devices.isEmpty)
          _ProfileCard(
            child: Text(
              'No devices are linked to your account yet.',
              style: TextStyle(color: colors.onSurfaceVariant),
            ),
          )
        else
          ...devices.map(
            (device) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _ProfileCard(
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    device.name,
                    style: TextStyle(
                      color: colors.onSurface,
                      fontSize: 17,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  subtitle: Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Row(
                      children: [
                        const Icon(Icons.circle, color: _blue, size: 10),
                        const SizedBox(width: 8),
                        Text(
                          'Registered',
                          style: TextStyle(color: colors.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  trailing: Icon(
                    Icons.chevron_right,
                    color: colors.onSurfaceVariant,
                  ),
                  onTap: () => showDialog<void>(
                    context: context,
                    builder: (context) => AlertDialog(
                      backgroundColor: colors.surfaceContainerHigh,
                      title: Text(
                        device.name,
                        style: TextStyle(color: colors.onSurface),
                      ),
                      content: SelectableText(
                        'Device ID\n${device.id}',
                        style: TextStyle(color: colors.onSurface),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: const Text('Close'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        const SizedBox(height: 14),
        const _SectionTitle(icon: Icons.palette_outlined, title: 'Appearance'),
        const SizedBox(height: 10),
        _ProfileCard(
          child: SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: Text(
              'Dark mode',
              style: TextStyle(
                color: colors.onSurface,
                fontSize: 17,
                fontWeight: FontWeight.w500,
              ),
            ),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 5),
              child: Text(
                darkMode ? 'Dark theme is on' : 'Use a darker app appearance',
                style: TextStyle(color: colors.onSurfaceVariant),
              ),
            ),
            secondary: Icon(
              darkMode ? Icons.dark_mode_outlined : Icons.light_mode_outlined,
              color: colors.primary,
            ),
            value: darkMode,
            onChanged: (enabled) async {
              try {
                await onThemeChanged(enabled);
              } catch (error) {
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Could not save theme setting: $error'),
                  ),
                );
              }
            },
          ),
        ),
        const SizedBox(height: 14),
        const _SectionTitle(
          icon: Icons.notifications_none,
          title: 'Notification Settings',
        ),
        const SizedBox(height: 10),
        _ProfileCard(
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(
              'Person detection alerts',
              style: TextStyle(
                color: colors.onSurface,
                fontSize: 17,
                fontWeight: FontWeight.w500,
              ),
            ),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 5),
              child: Text(
                'Push notifications are not configured yet',
                style: TextStyle(color: colors.onSurfaceVariant),
              ),
            ),
            trailing: Switch(value: false, onChanged: null),
          ),
        ),
        const SizedBox(height: 26),
        SizedBox(
          height: 58,
          child: OutlinedButton.icon(
            onPressed: () => _signOut(context),
            style: OutlinedButton.styleFrom(
              foregroundColor: _blueDark,
              side: const BorderSide(color: _blue),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18),
              ),
            ),
            icon: const Icon(Icons.logout),
            label: const Text(
              'Logout',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
            ),
          ),
        ),
      ],
    );
  }
}

class _ProfileCard extends StatelessWidget {
  const _ProfileCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(24),
        boxShadow: const [
          BoxShadow(
            color: Color(0x080F172A),
            blurRadius: 14,
            offset: Offset(0, 5),
          ),
        ],
      ),
      child: Material(color: Colors.transparent, child: child),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.icon, required this.title});

  final IconData icon;
  final String title;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(
          icon,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          size: 20,
        ),
        const SizedBox(width: 10),
        Text(
          title,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurface,
            fontSize: 17,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}
