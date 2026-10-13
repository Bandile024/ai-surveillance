class DeviceRecord {
  const DeviceRecord({required this.id, required this.name});

  final String id;
  final String name;

  factory DeviceRecord.fromRow(Map<String, dynamic> row) {
    return DeviceRecord(id: row['id'] as String, name: row['name'] as String);
  }
}
