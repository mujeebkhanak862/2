/// Device Status model (Architecture v4, Section 9.2, 10.1, 11)
library;

/// Normalized device state jo Background Agent report karta hai.
enum DeviceState {
  onlineUnlocked,
  onlineLocked,
  screenOff,
  sleeping,
  offline,
  poweredOff,
}

extension DeviceStateWire on DeviceState {
  static DeviceState fromWire(String v) => switch (v) {
        'ONLINE_UNLOCKED' => DeviceState.onlineUnlocked,
        'ONLINE_LOCKED' => DeviceState.onlineLocked,
        'SCREEN_OFF' => DeviceState.screenOff,
        'SLEEPING' => DeviceState.sleeping,
        'OFFLINE' => DeviceState.offline,
        'POWERED_OFF' => DeviceState.poweredOff,
        _ => DeviceState.offline,
      };

  /// Section 9.2 — kya background-capable actions is state mein allowed
  /// hain (screen automation ke bina bhi).
  bool get allowsBackgroundActions => switch (this) {
        DeviceState.onlineUnlocked ||
        DeviceState.onlineLocked ||
        DeviceState.screenOff =>
          true,
        DeviceState.sleeping || DeviceState.offline || DeviceState.poweredOff =>
          false,
      };

  /// Section 10.1 — dashboard label.
  String get label => switch (this) {
        DeviceState.onlineUnlocked => 'Online',
        DeviceState.onlineLocked => 'Locked',
        DeviceState.screenOff => 'Screen Off',
        DeviceState.sleeping => 'Sleeping',
        DeviceState.offline => 'Offline',
        DeviceState.poweredOff => 'Powered Off',
      };
}

class DeviceLocation {
  final double latitude;
  final double longitude;
  final double accuracyM;
  final DateTime timestamp;
  final String source;

  const DeviceLocation({
    required this.latitude,
    required this.longitude,
    required this.accuracyM,
    required this.timestamp,
    required this.source,
  });

  factory DeviceLocation.fromJson(Map<String, dynamic> json) =>
      DeviceLocation(
        latitude: (json['latitude'] as num).toDouble(),
        longitude: (json['longitude'] as num).toDouble(),
        accuracyM: (json['accuracy_m'] as num).toDouble(),
        timestamp: DateTime.parse(json['timestamp'] as String),
        source: json['source'] as String,
      );
}

class DeviceNetwork {
  final bool connected;
  final String? ssid;
  final String connectionType; // "WIFI" | "CELLULAR" | "ETHERNET" | ...
  final DateTime timestamp;

  const DeviceNetwork({
    required this.connected,
    this.ssid,
    required this.connectionType,
    required this.timestamp,
  });

  factory DeviceNetwork.fromJson(Map<String, dynamic> json) => DeviceNetwork(
        connected: json['connected'] as bool,
        ssid: json['ssid'] as String?,
        connectionType: json['connection_type'] as String,
        timestamp: DateTime.parse(json['timestamp'] as String),
      );
}

/// Section 10.1 dashboard card ke liye combined status.
class DeviceStatus {
  final String deviceId;
  final DeviceState state;
  final bool backgroundActive;
  final DeviceLocation? lastKnownLocation;
  final DeviceNetwork? network;
  final int? batteryPercent;

  const DeviceStatus({
    required this.deviceId,
    required this.state,
    required this.backgroundActive,
    this.lastKnownLocation,
    this.network,
    this.batteryPercent,
  });

  factory DeviceStatus.fromJson(Map<String, dynamic> json) => DeviceStatus(
        deviceId: json['device_id'] as String,
        state: DeviceStateWire.fromWire(json['state'] as String? ?? 'OFFLINE'),
        backgroundActive: json['background_active'] as bool? ?? false,
        lastKnownLocation: json['location'] != null
            ? DeviceLocation.fromJson(json['location'] as Map<String, dynamic>)
            : null,
        network: json['network'] != null
            ? DeviceNetwork.fromJson(json['network'] as Map<String, dynamic>)
            : null,
        batteryPercent: json['battery_percent'] as int?,
      );
}
