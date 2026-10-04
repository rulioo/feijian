import 'dart:convert';
import 'dart:typed_data';

import 'package:feijian/core/constants.dart';
import 'package:feijian/core/discovery/announce.dart';
import 'package:feijian/core/models/peer.dart';
import 'package:flutter_test/flutter_test.dart';

/// A fixed "now" so the freshness rules are exercised without a clock.
final DateTime _now = DateTime.utc(2026, 10, 4, 12);

Uint8List _bytes(Object? json) =>
    Uint8List.fromList(utf8.encode(jsonEncode(json)));

/// A well-formed announce body, with [overrides] applied on top so each test
/// can break exactly one field.
Map<String, Object?> _validJson([Map<String, Object?> overrides = const {}]) {
  return <String, Object?>{
    'v': kProtocolVersion,
    'type': 'announce',
    'id': '7f3a9c21-4e8b-4d2a-9f11-2c5e8a0b3d47',
    'name': 'Alice-Laptop',
    'device': 'windows',
    'os': 'Windows 11 23H2',
    'icon': 'laptop',
    'port': 24250,
    'ts': _now.millisecondsSinceEpoch ~/ 1000,
    ...overrides,
  };
}

AnnounceDecode _decode(Map<String, Object?> json) =>
    AnnouncePacket.decode(_bytes(json), now: _now);

void main() {
  group('encode', () {
    test('round-trips through decode', () {
      final AnnouncePacket original = AnnouncePacket(
        type: AnnounceType.announce,
        id: 'abc-123',
        ts: _now,
        name: 'Bob-PC',
        deviceType: DeviceType.windows,
        icon: DeviceIcon.desktop,
        os: 'Windows 11',
        port: 24250,
      );

      final AnnounceDecode decoded = AnnouncePacket.decode(
        original.encode(),
        now: _now,
      );

      expect(decoded.isSuccess, isTrue, reason: decoded.reason);
      final AnnouncePacket packet = decoded.packet!;
      expect(packet.type, AnnounceType.announce);
      expect(packet.id, 'abc-123');
      expect(packet.name, 'Bob-PC');
      expect(packet.deviceType, DeviceType.windows);
      expect(packet.icon, DeviceIcon.desktop);
      expect(packet.os, 'Windows 11');
      expect(packet.port, 24250);
      // Second precision on the wire, so compare at that resolution.
      expect(
        packet.ts.millisecondsSinceEpoch ~/ 1000,
        _now.millisecondsSinceEpoch ~/ 1000,
      );
    });

    test('stays inside the no-fragmentation budget for a full record', () {
      final AnnouncePacket packet = AnnouncePacket(
        type: AnnounceType.announce,
        id: '7f3a9c21-4e8b-4d2a-9f11-2c5e8a0b3d47',
        ts: _now,
        // Both at their maximum, which is the largest record we can produce.
        name: 'N' * kMaxDeviceNameLength,
        deviceType: DeviceType.android,
        icon: DeviceIcon.tablet,
        os: 'O' * kMaxDeviceNameLength,
        port: 65535,
      );

      expect(packet.encode().length, lessThanOrEqualTo(kMaxAnnounceBytes));
    });

    test('rejects a name too large to fit one datagram', () {
      final AnnouncePacket packet = AnnouncePacket(
        type: AnnounceType.announce,
        id: 'abc',
        ts: _now,
        name: 'N' * (kMaxAnnounceBytes * 2),
        port: 24250,
      );

      expect(
        packet.encode,
        throwsA(isA<AnnounceTooLargeException>()),
      );
    });

    test('emits only id, type and ts for a probe', () {
      final AnnouncePacket packet = AnnouncePacket(
        type: AnnounceType.probe,
        id: 'abc',
        ts: _now,
      );

      final Map<String, Object?> json =
          jsonDecode(utf8.decode(packet.encode())) as Map<String, Object?>;
      expect(json.keys, containsAll(<String>['v', 'type', 'id', 'ts']));
      expect(json.containsKey('name'), isFalse);
      expect(json.containsKey('port'), isFalse);
    });
  });

  group('decode rejects', () {
    test('an empty datagram', () {
      expect(
        AnnouncePacket.decode(Uint8List(0), now: _now).reason,
        'empty datagram',
      );
    });

    test('an oversized datagram without parsing it', () {
      final AnnounceDecode decoded = AnnouncePacket.decode(
        Uint8List(kMaxAnnounceBytes + 1),
        now: _now,
      );
      expect(decoded.isSuccess, isFalse);
      expect(decoded.reason, contains('oversized'));
    });

    test('traffic that is not JSON at all', () {
      final AnnounceDecode decoded = AnnouncePacket.decode(
        Uint8List.fromList(<int>[0x00, 0x01, 0xff, 0xfe]),
        now: _now,
      );
      expect(decoded.reason, 'not UTF-8 JSON');
    });

    test('a JSON value that is not an object', () {
      for (final Object? body in <Object?>[
        <int>[1, 2, 3],
        'announce',
        42,
      ]) {
        expect(
          AnnouncePacket.decode(_bytes(body), now: _now).reason,
          'body is not a JSON object',
          reason: '$body should be rejected',
        );
      }
    });

    test('a different protocol version, rather than guessing', () {
      final AnnounceDecode decoded = _decode(
        _validJson(<String, Object?>{'v': kProtocolVersion + 1}),
      );
      expect(decoded.isSuccess, isFalse);
      expect(decoded.reason, contains('protocol version 2'));
    });

    test('an unknown type', () {
      expect(
        _decode(_validJson(<String, Object?>{'type': 'shout'})).reason,
        contains('unknown type'),
      );
    });

    test('an announce with no usable id', () {
      expect(
        _decode(_validJson(<String, Object?>{'id': ''})).reason,
        'missing or invalid id',
      );
      expect(
        _decode(_validJson(<String, Object?>{'id': 42})).reason,
        'missing or invalid id',
      );
    });

    test('an announce with no name', () {
      expect(
        _decode(_validJson(<String, Object?>{'name': ''})).reason,
        'missing or invalid name',
      );
    });

    test('a name longer than the render cap', () {
      expect(
        _decode(
          _validJson(<String, Object?>{'name': 'N' * (kMaxDeviceNameLength + 1)}),
        ).reason,
        'missing or invalid name',
      );
    });

    test('a port outside the valid range', () {
      for (final Object? port in <Object?>[0, -1, 65536, '24250', null]) {
        expect(
          _decode(_validJson(<String, Object?>{'port': port})).reason,
          'missing or invalid port',
          reason: 'port $port should be rejected',
        );
      }
    });

    test('a timestamp that is stale or from a clock far off ours', () {
      final int stale =
          _now.subtract(kAnnounceMaxClockSkew * 2).millisecondsSinceEpoch ~/ 1000;
      final int future =
          _now.add(kAnnounceMaxClockSkew * 2).millisecondsSinceEpoch ~/ 1000;

      for (final int ts in <int>[stale, future]) {
        expect(
          _decode(_validJson(<String, Object?>{'ts': ts})).reason,
          contains('off'),
        );
      }
    });

    test('a timestamp missing entirely', () {
      final Map<String, Object?> json = _validJson()..remove('ts');
      expect(_decode(json).reason, 'missing timestamp');
    });
  });

  group('decode accepts', () {
    test('small clock differences, which are normal on a LAN', () {
      final int skewed =
          _now.add(const Duration(seconds: 20)).millisecondsSinceEpoch ~/ 1000;
      final AnnounceDecode decoded = _decode(
        _validJson(<String, Object?>{'ts': skewed}),
      );
      expect(decoded.isSuccess, isTrue, reason: decoded.reason);
    });

    test('a probe carrying nothing but identity and port', () {
      final AnnounceDecode decoded = _decode(<String, Object?>{
        'v': kProtocolVersion,
        'type': 'probe',
        'id': 'peer-1',
        'port': 24250,
        'ts': _now.millisecondsSinceEpoch ~/ 1000,
      });

      expect(decoded.isSuccess, isTrue, reason: decoded.reason);
      expect(decoded.packet!.type, AnnounceType.probe);
      expect(decoded.packet!.port, 24250);
      expect(decoded.packet!.name, isNull);
    });

    test('an announce missing the optional display fields', () {
      final Map<String, Object?> json = _validJson()
        ..remove('device')
        ..remove('icon')
        ..remove('os');

      final AnnounceDecode decoded = _decode(json);
      expect(decoded.isSuccess, isTrue, reason: decoded.reason);
      // Falls back rather than rejecting: an older peer that omits them is
      // still a peer worth listing.
      expect(decoded.packet!.deviceType, DeviceType.unknown);
      expect(decoded.packet!.icon, DeviceIcon.desktop);
      expect(decoded.packet!.os, isNull);
    });
  });

  group('toPeer', () {
    test('carries the sender address and port onto the peer record', () {
      final AnnounceDecode decoded = _decode(_validJson());
      final Peer peer = decoded.packet!.toPeer(
        fromIp: '192.168.1.101',
        seenAt: _now,
      );

      expect(peer.id, '7f3a9c21-4e8b-4d2a-9f11-2c5e8a0b3d47');
      expect(peer.name, 'Alice-Laptop');
      expect(peer.deviceType, DeviceType.windows);
      expect(peer.icon, DeviceIcon.laptop);
      expect(peer.os, 'Windows 11 23H2');
      expect(peer.lastIp, '192.168.1.101');
      expect(peer.lastPort, 24250);
      expect(peer.lastSeen, _now);
      expect(peer.isOnline, isTrue);
    });
  });
}
