import 'dart:convert';

import 'package:http/http.dart' as http;

class EngineStatus {
  const EngineStatus({
    required this.cameraConnected,
    required this.mode,
    required this.personCount,
    required this.avgConfidence,
    required this.maxConfidence,
    required this.fps,
    required this.lastDetectionAt,
  });

  final bool cameraConnected;
  final String mode;
  final int personCount;
  final double avgConfidence;
  final double maxConfidence;
  final double fps;
  final DateTime? lastDetectionAt;

  factory EngineStatus.fromJson(Map<String, dynamic> json) {
    double number(String key) => (json[key] as num?)?.toDouble() ?? 0;
    final detectionTime = json['last_detection_at'];
    return EngineStatus(
      cameraConnected: json['camera_connected'] == true,
      mode: json['mode'] as String? ?? 'SAFE',
      personCount: (json['person_count'] as num?)?.toInt() ?? 0,
      avgConfidence: number('avg_confidence'),
      maxConfidence: number('max_confidence'),
      fps: number('fps'),
      lastDetectionAt: detectionTime is String
          ? DateTime.tryParse(detectionTime)?.toLocal()
          : null,
    );
  }
}

class EngineApi {
  EngineApi({http.Client? client, String? baseUrl})
    : _client = client ?? http.Client(),
      baseUrl = (baseUrl ?? _configuredBaseUrl).replaceFirst(RegExp(r'/$'), '');

  static const _configuredBaseUrl = String.fromEnvironment(
    'ENGINE_API_URL',
    defaultValue: 'http://127.0.0.1:8765',
  );

  final http.Client _client;
  final String baseUrl;

  Uri get streamUri => Uri.parse('$baseUrl/stream.mjpg');

  Future<EngineStatus> fetchStatus() async {
    final response = await _client
        .get(Uri.parse('$baseUrl/api/status'))
        .timeout(const Duration(seconds: 2));
    if (response.statusCode != 200) {
      throw Exception('Engine status returned HTTP ${response.statusCode}.');
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Engine returned an invalid status payload.');
    }
    return EngineStatus.fromJson(decoded);
  }

  Future<void> setMode(String mode) async {
    final response = await _client
        .post(
          Uri.parse('$baseUrl/api/mode'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({'mode': mode}),
        )
        .timeout(const Duration(seconds: 2));
    if (response.statusCode != 202) {
      throw Exception('Engine rejected mode change (HTTP ${response.statusCode}).');
    }
  }

  void close() => _client.close();
}
