import 'dart:io' show Platform;

/// A device discovered on the LAN, or this device itself.
///
/// Mirrors the ANNOUNCE payload (design.md §4.1) plus the local-only fields the
/// DB tracks. Kept in `core/` — pure Dart, no Flutter — so it can be
/// constructed and compared in unit tests.
class Peer {
  const Peer({
    required this.id,
    required this.name,
    required this.deviceType,
    required this.icon,
    this.os,
    this.lastIp,
    this.lastSeen,
    this.isOnline = false,
    this.isTrusted = false,
  });

  /// Device UUID, generated once on first install and persisted forever.
  /// This — not the name — is the identity used for connections and dedupe.
  final String id;

  /// User-editable display name. Defaults to the system hostname.
  final String name;

  final DeviceType deviceType;

  /// User-selectable icon; also used as the default avatar.
  final DeviceIcon icon;

  /// Free-form OS description, e.g. "Windows 11 23H2". Display only.
  final String? os;

  final String? lastIp;
  final DateTime? lastSeen;
  final bool isOnline;

  /// Trusted peers may auto-accept file offers (design.md §6.4).
  final bool isTrusted;

  Peer copyWith({
    String? name,
    DeviceType? deviceType,
    DeviceIcon? icon,
    String? os,
    String? lastIp,
    DateTime? lastSeen,
    bool? isOnline,
    bool? isTrusted,
  }) {
    return Peer(
      id: id,
      name: name ?? this.name,
      deviceType: deviceType ?? this.deviceType,
      icon: icon ?? this.icon,
      os: os ?? this.os,
      lastIp: lastIp ?? this.lastIp,
      lastSeen: lastSeen ?? this.lastSeen,
      isOnline: isOnline ?? this.isOnline,
      isTrusted: isTrusted ?? this.isTrusted,
    );
  }

  @override
  bool operator ==(Object other) => other is Peer && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// The platform a peer runs. Sent in the ANNOUNCE `device` field.
enum DeviceType {
  windows('windows'),
  android('android'),
  ios('ios'),
  unknown('unknown');

  const DeviceType(this.wire);

  /// Value used on the wire and in the DB.
  final String wire;

  static DeviceType fromWire(String? value) {
    return DeviceType.values.firstWhere(
      (DeviceType t) => t.wire == value,
      orElse: () => DeviceType.unknown,
    );
  }

  /// This device's platform, for the "this device" card.
  static DeviceType get current {
    if (Platform.isWindows) {
      return DeviceType.windows;
    }
    if (Platform.isAndroid) {
      return DeviceType.android;
    }
    if (Platform.isIOS) {
      return DeviceType.ios;
    }
    return DeviceType.unknown;
  }
}

/// Icon shown in the device list. User-selectable in settings (design.md §6.4).
enum DeviceIcon {
  desktop('desktop'),
  laptop('laptop'),
  phone('phone'),
  tablet('tablet');

  const DeviceIcon(this.wire);

  final String wire;

  static DeviceIcon fromWire(String? value) {
    return DeviceIcon.values.firstWhere(
      (DeviceIcon i) => i.wire == value,
      orElse: () => DeviceIcon.desktop,
    );
  }

  /// Sensible starting icon for a platform — laptops and tablets cannot be
  /// told apart from the OS alone, so the user can correct it in settings.
  static DeviceIcon defaultFor(DeviceType type) {
    return switch (type) {
      DeviceType.windows => DeviceIcon.desktop,
      DeviceType.android => DeviceIcon.phone,
      DeviceType.ios => DeviceIcon.phone,
      DeviceType.unknown => DeviceIcon.desktop,
    };
  }
}
