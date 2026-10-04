import 'dart:convert';
import 'dart:typed_data';

import '../constants.dart';
import '../models/peer.dart';

/// The three datagram kinds on the discovery channel — design.md §4.1.
enum AnnounceType {
  /// "I am here." Carries the full device record.
  announce('announce'),

  /// "I am leaving." Carries only the id, so peers drop this device now rather
  /// than waiting out [kPeerRemoveAfter].
  bye('bye'),

  /// "Who is there?" Sent at startup so peers answer immediately instead of
  /// waiting for their next scheduled announce.
  probe('probe');

  const AnnounceType(this.wire);

  /// Value used in the `type` field.
  final String wire;

  static AnnounceType? fromWire(Object? value) {
    for (final AnnounceType type in AnnounceType.values) {
      if (type.wire == value) {
        return type;
      }
    }
    return null;
  }
}

/// Thrown by [AnnouncePacket.encode] when the encoded JSON would exceed
/// [kMaxAnnounceBytes].
///
/// A hard failure rather than truncation: a datagram over the limit risks IP
/// fragmentation, which some APs drop outright, so sending it would produce a
/// device that is visible in its own list and nowhere else.
class AnnounceTooLargeException implements Exception {
  const AnnounceTooLargeException(this.size);

  final int size;

  @override
  String toString() =>
      'announce is $size bytes, over the $kMaxAnnounceBytes limit';
}

/// One discovery datagram — design.md §4.1.
///
/// Immutable and pure Dart, so the whole wire format is testable without a
/// socket: [encode] and [decode] are exact inverses.
class AnnouncePacket {
  const AnnouncePacket({
    required this.type,
    required this.id,
    required this.ts,
    this.version = kProtocolVersion,
    this.name,
    this.deviceType,
    this.icon,
    this.os,
    this.port,
  });

  /// Protocol version. Peers that disagree ignore each other rather than
  /// guessing at an unknown layout.
  final int version;

  final AnnounceType type;

  /// Device UUID — the identity every other decision keys off.
  final String id;

  /// When the sender encoded this packet. Used both to discard stale datagrams
  /// and, on the receiving side, to decide who counts as online.
  final DateTime ts;

  /// Display name. Present for [AnnounceType.announce] only.
  final String? name;

  /// Present for [AnnounceType.announce] only.
  final DeviceType? deviceType;

  /// Present for [AnnounceType.announce] only.
  final DeviceIcon? icon;

  /// Free-form OS description; display only.
  final String? os;

  /// The sender's TCP/UDP listen port.
  ///
  /// Carried on every packet type, not just `announce`, because the unicast
  /// reply to a probe must be addressed to the prober's own port — which is not
  /// necessarily ours, since the port is user-configurable.
  final int? port;

  /// Serialises to the UTF-8 JSON datagram body.
  Uint8List encode() {
    final Map<String, Object?> json = <String, Object?>{
      'v': version,
      'type': type.wire,
      'id': id,
      'ts': ts.toUtc().millisecondsSinceEpoch ~/ 1000,
      if (name != null) 'name': name,
      if (deviceType != null) 'device': deviceType!.wire,
      if (icon != null) 'icon': icon!.wire,
      if (os != null) 'os': os,
      if (port != null) 'port': port,
    };

    final Uint8List bytes = Uint8List.fromList(utf8.encode(jsonEncode(json)));
    if (bytes.length > kMaxAnnounceBytes) {
      throw AnnounceTooLargeException(bytes.length);
    }
    return bytes;
  }

  /// Parses a datagram body.
  ///
  /// Never throws. Port 24250 is ordinary UDP on a shared LAN: stray traffic
  /// from unrelated software and packets from an incompatible version are
  /// expected arrivals, not exceptional ones, so every rejection is reported
  /// through [AnnounceDecode.reason] for the debug log instead.
  ///
  /// [now] is injected so the freshness rules are testable without a clock.
  static AnnounceDecode decode(Uint8List bytes, {required DateTime now}) {
    if (bytes.isEmpty) {
      return const AnnounceDecode.failure('empty datagram');
    }
    if (bytes.length > kMaxAnnounceBytes) {
      return AnnounceDecode.failure(
        'oversized datagram (${bytes.length}B)',
      );
    }

    final Object? raw;
    try {
      raw = jsonDecode(utf8.decode(bytes));
    } on FormatException {
      // Covers both malformed UTF-8 and malformed JSON.
      return const AnnounceDecode.failure('not UTF-8 JSON');
    }

    if (raw is! Map) {
      return const AnnounceDecode.failure('body is not a JSON object');
    }
    final Map<Object?, Object?> json = raw;

    final Object? version = json['v'];
    if (version is! int) {
      return const AnnounceDecode.failure('missing protocol version');
    }
    if (version != kProtocolVersion) {
      return AnnounceDecode.failure(
        'protocol version $version, expected $kProtocolVersion',
      );
    }

    final AnnounceType? type = AnnounceType.fromWire(json['type']);
    if (type == null) {
      return AnnounceDecode.failure('unknown type "${json['type']}"');
    }

    final Object? id = json['id'];
    if (id is! String || id.isEmpty || id.length > kMaxDeviceIdLength) {
      return const AnnounceDecode.failure('missing or invalid id');
    }

    final Object? ts = json['ts'];
    if (ts is! int) {
      return const AnnounceDecode.failure('missing timestamp');
    }
    final DateTime sent = DateTime.fromMillisecondsSinceEpoch(
      ts * 1000,
      isUtc: true,
    );
    final Duration drift = now.toUtc().difference(sent);
    if (drift.abs() > kAnnounceMaxClockSkew) {
      return AnnounceDecode.failure('timestamp ${drift.inSeconds}s off');
    }

    final int? port = _portOrNull(json['port']);

    if (type != AnnounceType.announce) {
      // `probe` and `bye` carry identity only.
      return AnnounceDecode.success(
        AnnouncePacket(type: type, id: id, ts: sent, version: version, port: port),
      );
    }

    final Object? name = json['name'];
    if (name is! String || name.isEmpty || name.length > kMaxDeviceNameLength) {
      return const AnnounceDecode.failure('missing or invalid name');
    }
    if (port == null) {
      return const AnnounceDecode.failure('missing or invalid port');
    }

    return AnnounceDecode.success(
      AnnouncePacket(
        type: type,
        id: id,
        ts: sent,
        version: version,
        name: name,
        port: port,
        deviceType: DeviceType.fromWire(_stringOrNull(json['device'])),
        icon: DeviceIcon.fromWire(_stringOrNull(json['icon'])),
        os: _trimmedOrNull(json['os']),
      ),
    );
  }

  /// The device record this packet describes.
  ///
  /// Only meaningful for [AnnounceType.announce] — a probe carries no name or
  /// platform — so callers must not use it for the other types.
  Peer toPeer({required String fromIp, required DateTime seenAt}) {
    final DeviceType type = deviceType ?? DeviceType.unknown;
    return Peer(
      id: id,
      name: name ?? id,
      deviceType: type,
      icon: icon ?? DeviceIcon.defaultFor(type),
      os: os,
      lastIp: fromIp,
      lastPort: port,
      lastSeen: seenAt,
      isOnline: true,
    );
  }

  static String? _stringOrNull(Object? value) =>
      value is String && value.isNotEmpty ? value : null;

  /// Truncated rather than rejected: the OS string is display-only, and a peer
  /// running a future Windows whose version string is unusually long should
  /// still appear in the list.
  static String? _trimmedOrNull(Object? value) {
    if (value is! String || value.isEmpty) {
      return null;
    }
    return value.length <= kMaxDeviceNameLength
        ? value
        : value.substring(0, kMaxDeviceNameLength);
  }

  static int? _portOrNull(Object? value) =>
      value is int && value >= 1 && value <= 65535 ? value : null;
}

/// Outcome of parsing a discovery datagram.
class AnnounceDecode {
  const AnnounceDecode.success(AnnouncePacket this.packet) : reason = null;

  const AnnounceDecode.failure(this.reason) : packet = null;

  /// Null exactly when [reason] is set.
  final AnnouncePacket? packet;

  /// Why the datagram was rejected — for the debug log, never for the user.
  final String? reason;

  bool get isSuccess => packet != null;
}
