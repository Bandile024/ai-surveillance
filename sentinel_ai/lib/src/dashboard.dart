import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'camera_feed.dart';
import 'device_record.dart';
import 'engine_api.dart';
import 'profile_screen.dart';

class DeviceEvent {
  const DeviceEvent({
    required this.id,
    required this.deviceId,
    required this.deviceName,
    required this.type,
    required this.occurredAt,
    required this.data,
    this.snapshotPath,
  });

  final String id;
  final String deviceId;
  final String deviceName;
  final String type;
  final DateTime occurredAt;
  final Map<String, dynamic> data;
  final String? snapshotPath;

  factory DeviceEvent.fromRow(
    Map<String, dynamic> row,
    Map<String, String> deviceNames,
  ) {
    final data = row['data'];
    return DeviceEvent(
      id: row['id'] as String,
      deviceId: row['device_id'] as String,
      deviceName: deviceNames[row['device_id']] ?? 'Unknown device',
      type: row['event_type'] as String,
      occurredAt: DateTime.parse(row['occurred_at'] as String).toLocal(),
      data: data is Map ? Map<String, dynamic>.from(data) : const {},
      snapshotPath: row['snapshot_path'] as String?,
    );
  }
}

class EventsDashboard extends StatefulWidget {
  const EventsDashboard({
    super.key,
    required this.client,
    required this.darkMode,
    required this.onThemeChanged,
  });

  final SupabaseClient client;
  final bool darkMode;
  final Future<void> Function(bool enabled) onThemeChanged;

  @override
  State<EventsDashboard> createState() => _EventsDashboardState();
}

class _EventsDashboardState extends State<EventsDashboard> {
  List<DeviceRecord> _devices = [];
  List<DeviceEvent> _events = [];
  String _filter = 'INTRUSION';
  int _selectedTab = 0;
  DeviceRecord? _activeCamera;
  String? _error;
  bool _loading = true;
  bool _modeBusy = false;
  EngineStatus? _engineStatus;
  Timer? _engineTimer;
  RealtimeChannel? _channel;
  final EngineApi _engineApi = EngineApi();

  @override
  void initState() {
    super.initState();
    _loadEvents();
    _refreshEngineStatus();
    _engineTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _refreshEngineStatus(),
    );
    _channel =
        widget.client
            .channel('device-events-${widget.client.auth.currentUser!.id}')
            .onPostgresChanges(
              event: PostgresChangeEvent.all,
              schema: 'public',
              table: 'device_events',
              callback: (_) => _loadEvents(),
            )
          ..subscribe();
  }

  @override
  void dispose() {
    _engineTimer?.cancel();
    _engineApi.close();
    final channel = _channel;
    if (channel != null) {
      unawaited(widget.client.removeChannel(channel));
    }
    super.dispose();
  }

  Future<void> _refreshEngineStatus() async {
    try {
      final status = await _engineApi.fetchStatus();
      if (!mounted) return;
      setState(() => _engineStatus = status);
    } catch (_) {
      if (!mounted || _engineStatus == null) return;
      setState(() => _engineStatus = null);
    }
  }

  Future<void> _requestMode(String mode) async {
    if (_modeBusy) return;
    setState(() => _modeBusy = true);
    try {
      await _engineApi.setMode(mode);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not change engine mode: $error')),
      );
    } finally {
      if (mounted) setState(() => _modeBusy = false);
    }
  }

  Future<void> _loadEvents() async {
    if (_devices.isEmpty && mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }

    try {
      final deviceRows = await widget.client
          .from('devices')
          .select('id, name')
          .order('created_at', ascending: false);
      final devices = deviceRows
          .map((row) => DeviceRecord.fromRow(Map<String, dynamic>.from(row)))
          .toList();
      final deviceNames = {
        for (final device in devices) device.id: device.name,
      };
      List<DeviceEvent> events = [];

      if (devices.isNotEmpty) {
        final eventRows = await widget.client
            .from('device_events')
            .select(
              'id, device_id, event_type, occurred_at, data, snapshot_path',
            )
            .inFilter('device_id', devices.map((device) => device.id).toList())
            .order('occurred_at', ascending: false)
            .limit(100);
        events = eventRows
            .map(
              (row) => DeviceEvent.fromRow(
                Map<String, dynamic>.from(row),
                deviceNames,
              ),
            )
            .toList();
      }

      if (!mounted) return;
      setState(() {
        _devices = devices;
        _events = events;
        _error = null;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load events: $error';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final intrusions = _events
        .where((event) => event.type == 'INTRUSION')
        .length;
    final visibleEvents = switch (_selectedTab) {
      2 => _events.where((event) => event.type == 'INTRUSION').toList(),
      1 when _filter != 'ALL' =>
        _events.where((event) => event.type == _filter).toList(),
      _ => _events,
    };
    final titles = ['Home', 'Events', 'Alerts', 'Profile'];
    final selectedTitle = _activeCamera?.name ?? titles[_selectedTab];

    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      appBar: AppBar(
        leading: _activeCamera == null
            ? null
            : IconButton(
                tooltip: 'Back to Home',
                onPressed: () => setState(() => _activeCamera = null),
                icon: const Icon(Icons.arrow_back),
              ),
        title: Text(
          selectedTitle,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurface,
            fontWeight: FontWeight.w700,
          ),
        ),
        actions: [
          if (_activeCamera == null && _selectedTab != 3)
            IconButton(
              tooltip: 'Refresh events',
              onPressed: _loadEvents,
              icon: const Icon(Icons.refresh),
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: _activeCamera != null
          ? _CameraDetail(
              camera: _activeCamera!,
              status: _engineStatus,
              streamUrl: _engineApi.streamUri.toString(),
              events: _events,
              modeBusy: _modeBusy,
              onModeRequested: _requestMode,
              onEventTap: (event) => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) =>
                      EventDetailsScreen(client: widget.client, event: event),
                ),
              ),
            )
          : _selectedTab == 3
          ? ProfileScreen(
              client: widget.client,
              devices: _devices,
              darkMode: widget.darkMode,
              onThemeChanged: widget.onThemeChanged,
            )
          : _selectedTab == 0
          ? _HomeTab(
              devices: _devices,
              events: _events,
              status: _engineStatus,
              streamUrl: _engineApi.streamUri.toString(),
              onOpenCamera: (camera) => setState(() => _activeCamera = camera),
            )
          : RefreshIndicator(
              onRefresh: _loadEvents,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
                children: [
                  if (_selectedTab == 0) ...[
                    _SummaryCard(
                      deviceCount: _devices.length,
                      intrusionCount: intrusions,
                      eventCount: _events.length,
                    ),
                    const SizedBox(height: 22),
                  ],
                  Row(
                    children: [
                      Text(
                        switch (_selectedTab) {
                          0 => 'Recent activity',
                          1 => 'Events',
                          _ => 'Intrusion alerts',
                        },
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          color: Theme.of(context).colorScheme.onSurface,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        '${visibleEvents.length} loaded',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                  if (_selectedTab == 1) ...[
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      children: [
                        _filterChip('INTRUSION', 'Intrusions'),
                        _filterChip('MODE_CHANGE', 'Mode changes'),
                      ],
                    ),
                  ],
                  const SizedBox(height: 12),
                  if (_error != null)
                    Card(
                      color: Theme.of(context).colorScheme.surfaceContainerLow,
                      surfaceTintColor: Colors.transparent,
                      shape: RoundedRectangleBorder(
                        side: BorderSide(
                          color: Theme.of(context).colorScheme.outlineVariant,
                        ),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: ListTile(
                        leading: const Icon(
                          Icons.error_outline,
                          color: Color(0xFFB42318),
                        ),
                        title: Text(
                          'Unable to load dashboard',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                        ),
                        subtitle: Text(
                          _error!,
                          style: TextStyle(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant,
                          ),
                        ),
                        trailing: IconButton(
                          tooltip: 'Retry',
                          onPressed: _loadEvents,
                          icon: const Icon(Icons.refresh),
                        ),
                      ),
                    )
                  else if (_loading)
                    const Padding(
                      padding: EdgeInsets.all(36),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else if (_devices.isEmpty)
                    const _EmptyState(
                      icon: Icons.videocam_off_outlined,
                      title: 'No devices linked yet',
                      message: 'Register a device to your signed-in account in Supabase to see its activity here.',
                    )
                  else if (visibleEvents.isEmpty)
                    _EmptyState(
                      icon: Icons.notifications_none,
                      title: _selectedTab == 2
                          ? 'No intrusion alerts yet'
                          : _selectedTab == 1 && _filter != 'ALL'
                          ? 'No matching events'
                          : 'No events yet',
                      message: _selectedTab == 2
                          ? 'New intrusion alerts from your devices will appear here.'
                          : 'Events from your devices will appear here.',
                    )
                  else
                    ...visibleEvents.map(
                      (event) => Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: _EventCard(
                          event: event,
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => EventDetailsScreen(
                                client: widget.client,
                                event: event,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedTab,
        onDestinationSelected: (index) {
          setState(() {
            _activeCamera = null;
            _selectedTab = index;
            if (index == 1) _filter = 'INTRUSION';
          });
        },
        backgroundColor: Theme.of(context).colorScheme.surface,
        surfaceTintColor: Colors.transparent,
        indicatorColor: Theme.of(context).colorScheme.secondaryContainer,
        elevation: 8,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: 'Home',
          ),
          NavigationDestination(
            icon: Icon(Icons.shield_outlined),
            selectedIcon: Icon(Icons.shield),
            label: 'Events',
          ),
          NavigationDestination(
            icon: Icon(Icons.notifications_none),
            selectedIcon: Icon(Icons.notifications),
            label: 'Alerts',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline),
            selectedIcon: Icon(Icons.person),
            label: 'Profile',
          ),
        ],
      ),
    );
  }

  Widget _filterChip(String value, String label) {
    final selected = _filter == value;
    return FilterChip(
      label: Text(label),
      selected: selected,
      showCheckmark: false,
      backgroundColor: Theme.of(context).colorScheme.surface,
      selectedColor: Theme.of(context).colorScheme.primaryContainer,
      side: BorderSide(
        color: selected
            ? const Color(0xFF2488F5)
            : Theme.of(context).colorScheme.outlineVariant,
      ),
      labelStyle: TextStyle(
        color: selected
            ? const Color(0xFF1D4ED8)
            : Theme.of(context).colorScheme.onSurfaceVariant,
        fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
      ),
      onSelected: (selected) =>
          setState(() => _filter = selected ? value : 'ALL'),
    );
  }
}

class _HomeTab extends StatelessWidget {
  const _HomeTab({
    required this.devices,
    required this.events,
    required this.status,
    required this.streamUrl,
    required this.onOpenCamera,
  });

  final List<DeviceRecord> devices;
  final List<DeviceEvent> events;
  final EngineStatus? status;
  final String streamUrl;
  final ValueChanged<DeviceRecord> onOpenCamera;

  @override
  Widget build(BuildContext context) {
    final camera = DeviceRecord(
      id: devices.isEmpty ? 'local-camera' : devices.first.id,
      name: 'AI Surveillance PC',
    );
    final intrusions = events
        .where((event) => event.type == 'INTRUSION')
        .length;

    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 28),
      children: [
        Text(
          'Welcome back',
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurface,
            fontSize: 27,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 5),
        Text(
          'Your security overview at a glance.',
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 20),
        Row(
          children: [
            Expanded(
              child: _HomeMetric(
                label: 'CAMERA',
                value: status?.cameraConnected == true ? 'Online' : 'Offline',
                icon: Icons.videocam_outlined,
                color: status?.cameraConnected == true
                    ? const Color(0xFF138A54)
                    : Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _HomeMetric(
                label: 'ALERTS',
                value: '$intrusions',
                icon: Icons.warning_amber_rounded,
                color: const Color(0xFFB42318),
              ),
            ),
          ],
        ),
        const SizedBox(height: 22),
        Row(
          children: [
            Expanded(
              child: Text(
                'Your camera',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurface,
                  fontSize: 19,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Card(
          clipBehavior: Clip.antiAlias,
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
            side: BorderSide(
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                height: 205,
                child: status?.cameraConnected == true
                    ? CameraFeed(streamUrl: streamUrl)
                    : const _CameraUnavailable(),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: _CameraCardDetail(
                            label: 'Camera name',
                            value: camera.name,
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _CameraCardDetail(
                            label: 'Connection',
                            value: status?.cameraConnected == true
                                ? 'Connected'
                                : 'Offline',
                            color: status?.cameraConnected == true
                                ? const Color(0xFF138A54)
                                : Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _CameraCardDetail(
                            label: 'Current mode',
                            value: status?.cameraConnected == true
                                ? status!.mode
                                : 'Unavailable',
                            color: status?.mode == 'GUARD'
                                ? const Color(0xFFB42318)
                                : const Color(0xFF138A54),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: () => onOpenCamera(camera),
                        icon: const Icon(Icons.open_in_new),
                        label: const Text('View live camera'),
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFF2488F5),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 13),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerRight,
          child: OutlinedButton.icon(
            onPressed: () {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Camera onboarding is coming soon.'),
                ),
              );
            },
            icon: Icon(
              Icons.add,
              color: Theme.of(context).colorScheme.onSurface,
            ),
            label: Text(
              'Add camera',
              style: TextStyle(color: Theme.of(context).colorScheme.onSurface),
            ),
            style: OutlinedButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.surface,
              side: BorderSide(
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            ),
          ),
        ),
      ],
    );
  }
}

class _CameraDetail extends StatelessWidget {
  const _CameraDetail({
    required this.camera,
    required this.status,
    required this.streamUrl,
    required this.events,
    required this.modeBusy,
    required this.onModeRequested,
    required this.onEventTap,
  });

  final DeviceRecord camera;
  final EngineStatus? status;
  final String streamUrl;
  final List<DeviceEvent> events;
  final bool modeBusy;
  final ValueChanged<String> onModeRequested;
  final ValueChanged<DeviceEvent> onEventTap;

  @override
  Widget build(BuildContext context) {
    final intrusions = events
        .where(
          (event) => event.type == 'INTRUSION' && event.deviceId == camera.id,
        )
        .take(4)
        .toList();
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 26),
      children: [
        Card(
          clipBehavior: Clip.antiAlias,
          color: const Color(0xFF111827),
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
          ),
          child: SizedBox(
            height: 250,
            child: status?.cameraConnected == true
                ? CameraFeed(streamUrl: streamUrl)
                : const _CameraUnavailable(),
          ),
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: Text(
                'Live camera',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurface,
                  fontWeight: FontWeight.w700,
                  fontSize: 19,
                ),
              ),
            ),
            _StatusPill(
              label: status?.cameraConnected == true ? 'LIVE' : 'OFFLINE',
              color: status?.cameraConnected == true
                  ? const Color(0xFF138A54)
                  : Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ],
        ),
        const SizedBox(height: 18),
        Text(
          'Security mode',
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurface,
            fontWeight: FontWeight.w700,
            fontSize: 18,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _ModeButton(
                label: 'SAFE MODE',
                selected: status?.mode == 'SAFE',
                color: const Color(0xFF138A54),
                busy: modeBusy || status?.cameraConnected != true,
                onPressed: () => onModeRequested('SAFE'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _ModeButton(
                label: 'GUARD MODE',
                selected: status?.mode == 'GUARD',
                color: const Color(0xFFB42318),
                busy: modeBusy || status?.cameraConnected != true,
                onPressed: () => onModeRequested('GUARD'),
              ),
            ),
          ],
        ),
        if (status?.cameraConnected != true)
          Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(
              'Start the Python engine on this computer to enable live view and mode controls.',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        const SizedBox(height: 22),
        Row(
          children: [
            Expanded(
              child: Text(
                'Recent intrusion events',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurface,
                  fontWeight: FontWeight.w700,
                  fontSize: 18,
                ),
              ),
            ),
            Text(
              camera.name,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (intrusions.isEmpty)
          const _EmptyState(
            icon: Icons.shield_outlined,
            title: 'No recent intrusions',
            message: 'New alerts for this account will appear here.',
          )
        else
          ...intrusions.map(
            (event) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _EventCard(event: event, onTap: () => onEventTap(event)),
            ),
          ),
      ],
    );
  }
}

class _CameraCardDetail extends StatelessWidget {
  const _CameraCardDetail({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label,
        style: TextStyle(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          fontSize: 12,
        ),
      ),
      const SizedBox(height: 3),
      Text(
        value,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: color, fontWeight: FontWeight.w600),
      ),
    ],
  );
}

class _HomeMetric extends StatelessWidget {
  const _HomeMetric({
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
  });

  final String label;
  final String value;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(17),
      border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: color, size: 19),
        const SizedBox(height: 9),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: color, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 3),
        Text(
          label,
          maxLines: 1,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            fontSize: 10,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    ),
  );
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.1),
      borderRadius: BorderRadius.circular(24),
    ),
    child: Text(
      label,
      style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w700),
    ),
  );
}

class _CameraUnavailable extends StatelessWidget {
  const _CameraUnavailable();

  @override
  Widget build(BuildContext context) => const Center(
    child: Padding(
      padding: EdgeInsets.all(20),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.videocam_off_outlined, color: Colors.white70, size: 38),
          SizedBox(height: 10),
          Text(
            'Camera engine is offline',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
          ),
          SizedBox(height: 4),
          Text(
            'Run python main.py --headless to start the local feed.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white70, fontSize: 12),
          ),
        ],
      ),
    ),
  );
}

class _ModeButton extends StatelessWidget {
  const _ModeButton({
    required this.label,
    required this.selected,
    required this.color,
    required this.busy,
    required this.onPressed,
  });

  final String label;
  final bool selected;
  final Color color;
  final bool busy;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => OutlinedButton(
    onPressed: busy ? null : onPressed,
    style: OutlinedButton.styleFrom(
      foregroundColor: color,
      side: BorderSide(
        color: selected ? color : Theme.of(context).colorScheme.outlineVariant,
      ),
      backgroundColor: selected
          ? color.withValues(alpha: 0.08)
          : Theme.of(context).colorScheme.surface,
      padding: const EdgeInsets.symmetric(vertical: 14),
    ),
    child: busy && selected
        ? const SizedBox(
            width: 17,
            height: 17,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
  );
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({
    required this.deviceCount,
    required this.intrusionCount,
    required this.eventCount,
  });

  final int deviceCount;
  final int intrusionCount;
  final int eventCount;

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              Theme.of(context).colorScheme.surfaceContainerHigh,
              Theme.of(context).colorScheme.surfaceContainerLow,
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.shield_outlined, color: Color(0xFF2488F5)),
                const SizedBox(width: 8),
                Text(
                  'MONITORING OVERVIEW',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                _SummaryValue(label: 'Devices', value: '$deviceCount'),
                _SummaryValue(label: 'Intrusions', value: '$intrusionCount'),
                _SummaryValue(label: 'Events loaded', value: '$eventCount'),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SummaryValue extends StatelessWidget {
  const _SummaryValue({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: Theme.of(context).textTheme.headlineMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurface,
              fontWeight: FontWeight.w700,
            ),
          ),
          Text(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _EventCard extends StatelessWidget {
  const _EventCard({required this.event, required this.onTap});

  final DeviceEvent event;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isIntrusion = event.type == 'INTRUSION';
    final color = isIntrusion
        ? const Color(0xFFB42318)
        : const Color(0xFF2488F5);
    final title = switch (event.type) {
      'INTRUSION' => 'Intrusion detected',
      'MODE_CHANGE' => 'Mode changed',
      _ => event.type.replaceAll('_', ' ').toLowerCase(),
    };

    return Card(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(20),
      ),
      child: ListTile(
        onTap: onTap,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: CircleAvatar(
          backgroundColor: color.withValues(alpha: 0.14),
          child: Icon(
            isIntrusion ? Icons.warning_amber_rounded : Icons.swap_horiz,
            color: color,
          ),
        ),
        title: Text(
          title,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurface,
            fontWeight: FontWeight.w600,
          ),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 5),
          child: Text(
            '${event.deviceName}  ·  ${_formatDate(event.occurredAt)}'
            '${event.snapshotPath == null ? '' : '\nSnapshot available'}',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        isThreeLine: event.snapshotPath != null,
        trailing: Icon(
          Icons.chevron_right,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class EventDetailsScreen extends StatefulWidget {
  const EventDetailsScreen({
    super.key,
    required this.client,
    required this.event,
  });

  final SupabaseClient client;
  final DeviceEvent event;

  @override
  State<EventDetailsScreen> createState() => _EventDetailsScreenState();
}

class _EventDetailsScreenState extends State<EventDetailsScreen> {
  late Future<String> _snapshotUrl;

  @override
  void initState() {
    super.initState();
    _snapshotUrl = _createSnapshotUrl();
  }

  Future<String> _createSnapshotUrl() {
    return widget.client.storage
        .from('intrusion-snapshots')
        .createSignedUrl(widget.event.snapshotPath!, 600);
  }

  @override
  Widget build(BuildContext context) {
    final event = widget.event;
    final isIntrusion = event.type == 'INTRUSION';

    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      appBar: AppBar(title: const Text('Event details')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            color: Theme.of(context).colorScheme.surfaceContainerLow,
            surfaceTintColor: Colors.transparent,
            shape: RoundedRectangleBorder(
              side: BorderSide(
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        isIntrusion
                            ? Icons.warning_amber_rounded
                            : Icons.event_note_outlined,
                        color: isIntrusion
                            ? const Color(0xFFB42318)
                            : const Color(0xFF2488F5),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          isIntrusion ? 'Intrusion detected' : event.type,
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(
                                color: Theme.of(context).colorScheme.onSurface,
                              ),
                        ),
                      ),
                    ],
                  ),
                  const Divider(height: 28),
                  _DetailRow(label: 'Device', value: event.deviceName),
                  _DetailRow(label: 'Event ID', value: event.id),
                  _DetailRow(
                    label: 'Occurred',
                    value: _formatDate(event.occurredAt),
                  ),
                ],
              ),
            ),
          ),
          if (event.snapshotPath != null) ...[
            const SizedBox(height: 16),
            Text(
              'Snapshot',
              style: Theme.of(context).textTheme.titleLarge
                  ?.copyWith(color: Theme.of(context).colorScheme.onSurface),
            ),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: FutureBuilder<String>(
                future: _snapshotUrl,
                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    return _SnapshotMessage(
                      icon: Icons.broken_image_outlined,
                      text: 'Could not load snapshot: ${snapshot.error}',
                      action: TextButton.icon(
                        onPressed: () =>
                            setState(() => _snapshotUrl = _createSnapshotUrl()),
                        icon: const Icon(Icons.refresh),
                        label: const Text('Try again'),
                      ),
                    );
                  }
                  if (!snapshot.hasData) {
                    return const AspectRatio(
                      aspectRatio: 4 / 3,
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }
                  return Image.network(
                    snapshot.data!,
                    fit: BoxFit.contain,
                    errorBuilder: (_, error, _) => _SnapshotMessage(
                      icon: Icons.broken_image_outlined,
                      text: 'Snapshot could not be displayed: $error',
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Private image access link; it expires after 10 minutes.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ] else if (isIntrusion) ...[
            const SizedBox(height: 16),
            const _SnapshotMessage(
              icon: Icons.image_not_supported_outlined,
              text: 'No snapshot was attached to this event.',
            ),
          ],
          const SizedBox(height: 20),
          Text(
            'Event data',
            style: Theme.of(context).textTheme.titleLarge
                ?.copyWith(color: Theme.of(context).colorScheme.onSurface),
          ),
          const SizedBox(height: 10),
          Card(
            color: Theme.of(context).colorScheme.surfaceContainerLow,
            surfaceTintColor: Colors.transparent,
            shape: RoundedRectangleBorder(
              side: BorderSide(
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: SelectableText(
                const JsonEncoder.withIndent('  ').convert(event.data),
                style: const TextStyle(fontFamily: 'monospace', height: 1.5),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 82,
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: TextStyle(color: Theme.of(context).colorScheme.onSurface),
            ),
          ),
        ],
      ),
    );
  }
}

class _SnapshotMessage extends StatelessWidget {
  const _SnapshotMessage({required this.icon, required this.text, this.action});

  final IconData icon;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      constraints: const BoxConstraints(minHeight: 180),
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            icon,
            size: 36,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 10),
          Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(color: Theme.of(context).colorScheme.onSurface),
          ),
          ?action,
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.message,
  });

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 44, horizontal: 22),
      child: Column(
        children: [
          Icon(icon, size: 44, color: const Color(0xFF2488F5)),
          const SizedBox(height: 12),
          Text(
            title,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurface,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

String _formatDate(DateTime date) {
  String twoDigits(int value) => value.toString().padLeft(2, '0');
  return '${date.year}-${twoDigits(date.month)}-${twoDigits(date.day)} '
      '${twoDigits(date.hour)}:${twoDigits(date.minute)}:${twoDigits(date.second)}';
}
