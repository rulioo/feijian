import 'package:feijian/core/constants.dart';
import 'package:feijian/core/models/peer.dart';
import 'package:feijian/core/protocol/frame_codec.dart';
import 'package:feijian/core/protocol/payloads.dart';
import 'package:flutter_test/flutter_test.dart';

HelloPayload sampleHello({
  ConnectionRole role = ConnectionRole.control,
  String deviceId = 'peer-uuid',
  String name = 'Bob-PC',
  DeviceType deviceType = DeviceType.windows,
  DeviceIcon icon = DeviceIcon.desktop,
  int port = 24250,
  int version = kProtocolVersion,
  List<String> caps = const <String>['file'],
}) {
  return HelloPayload(
    role: role,
    deviceId: deviceId,
    name: name,
    deviceType: deviceType,
    icon: icon,
    port: port,
    version: version,
    caps: caps,
  );
}

/// A `hello` frame with one field replaced or removed, to test validation
/// without restating the whole payload each time.
Frame helloFrame(String key, Object? value) {
  final Map<String, Object?> header = <String, Object?>{
    ...sampleHello().toFrame().header,
  };
  if (value == null) {
    header.remove(key);
  } else {
    header[key] = value;
  }
  return Frame(header);
}

void main() {
  group('HelloPayload', () {
    test('round-trips every field', () {
      final HelloPayload original = sampleHello(
        role: ConnectionRole.data,
        deviceType: DeviceType.android,
        icon: DeviceIcon.phone,
        caps: <String>['file', 'folder'],
      );

      final PayloadDecode<HelloPayload> decoded =
          HelloPayload.from(original.toFrame());

      expect(decoded.isSuccess, isTrue, reason: decoded.reason);
      final HelloPayload hello = decoded.value!;
      expect(hello.role, ConnectionRole.data);
      expect(hello.deviceId, original.deviceId);
      expect(hello.name, original.name);
      expect(hello.deviceType, DeviceType.android);
      expect(hello.icon, DeviceIcon.phone);
      expect(hello.port, 24250);
      expect(hello.version, kProtocolVersion);
      expect(hello.caps, <String>['file', 'folder']);
    });

    test('rejects a role it does not know', () {
      final PayloadDecode<HelloPayload> decoded =
          HelloPayload.from(helloFrame('role', 'gossip'));
      expect(decoded.isSuccess, isFalse);
      expect(decoded.reason, contains('role'));
    });

    test('rejects a missing or empty device id', () {
      expect(HelloPayload.from(helloFrame('deviceId', null)).isSuccess, isFalse);
      expect(HelloPayload.from(helloFrame('deviceId', '')).isSuccess, isFalse);
    });

    test('rejects an over-long device id or name', () {
      expect(
        HelloPayload.from(
          helloFrame('deviceId', 'x' * (kMaxDeviceIdLength + 1)),
        ).isSuccess,
        isFalse,
      );
      expect(
        HelloPayload.from(
          helloFrame('name', 'x' * (kMaxDeviceNameLength + 1)),
        ).isSuccess,
        isFalse,
      );
    });

    test('rejects a missing name', () {
      expect(HelloPayload.from(helloFrame('name', null)).isSuccess, isFalse);
      expect(HelloPayload.from(helloFrame('name', '')).isSuccess, isFalse);
    });

    test('rejects a port outside the valid range', () {
      for (final Object? port in <Object?>[null, 0, -1, 70000, '24250']) {
        expect(
          HelloPayload.from(helloFrame('port', port)).isSuccess,
          isFalse,
          reason: 'port=$port must be refused',
        );
      }
    });

    test('rejects a missing or nonsensical version', () {
      expect(HelloPayload.from(helloFrame('version', null)).isSuccess, isFalse);
      expect(HelloPayload.from(helloFrame('version', 0)).isSuccess, isFalse);
      expect(HelloPayload.from(helloFrame('version', 'v1')).isSuccess, isFalse);
    });

    test('accepts a platform and icon it does not know, as unknown', () {
      // Both are display-only. Refusing the connection over them would take the
      // whole chat down because a future peer added a platform.
      final PayloadDecode<HelloPayload> decoded = HelloPayload.from(
        helloFrame('device', 'harmonyos'),
      );
      expect(decoded.isSuccess, isTrue);
      expect(decoded.value!.deviceType, DeviceType.unknown);

      final PayloadDecode<HelloPayload> icon =
          HelloPayload.from(helloFrame('icon', 'watch'));
      expect(icon.isSuccess, isTrue);
      expect(icon.value!.icon, DeviceIcon.desktop);
    });

    test('drops non-string entries from caps rather than failing', () {
      final PayloadDecode<HelloPayload> decoded =
          HelloPayload.from(helloFrame('caps', <Object?>['file', 7, null]));
      expect(decoded.isSuccess, isTrue);
      expect(decoded.value!.caps, <String>['file']);
    });

    test('treats missing caps as none', () {
      final PayloadDecode<HelloPayload> decoded =
          HelloPayload.from(helloFrame('caps', null));
      expect(decoded.isSuccess, isTrue);
      expect(decoded.value!.caps, isEmpty);
    });
  });

  group('MessagePayload', () {
    test('round-trips text that is not ASCII', () {
      const String text = '你好，世界 🌏 — naïve';
      final MessagePayload original = MessagePayload(
        msgId: 'uuid-1',
        ts: DateTime(2026, 10, 4, 14, 23),
        text: text,
      );

      final PayloadDecode<MessagePayload> decoded =
          MessagePayload.from(original.toFrame());

      expect(decoded.isSuccess, isTrue, reason: decoded.reason);
      expect(decoded.value!.msgId, 'uuid-1');
      expect(decoded.value!.text, text);
      expect(
        decoded.value!.ts.millisecondsSinceEpoch,
        original.ts.millisecondsSinceEpoch,
      );
    });

    test('round-trips replyTo, and omits it when absent', () {
      final MessagePayload reply = MessagePayload(
        msgId: 'uuid-2',
        ts: DateTime(2026, 10, 4),
        text: 'yes',
        replyTo: 'uuid-1',
      );
      expect(reply.toFrame().header['replyTo'], 'uuid-1');
      expect(MessagePayload.from(reply.toFrame()).value!.replyTo, 'uuid-1');

      final MessagePayload plain = MessagePayload(
        msgId: 'uuid-3',
        ts: DateTime(2026, 10, 4),
        text: 'hi',
      );
      expect(plain.toFrame().header.containsKey('replyTo'), isFalse);
    });

    test('rejects a missing msgId or text', () {
      expect(
        MessagePayload.from(
          Frame.of(FrameType.msg, <String, Object?>{'text': 'hi'}),
        ).isSuccess,
        isFalse,
      );
      expect(
        MessagePayload.from(
          Frame.of(FrameType.msg, <String, Object?>{'msgId': 'a'}),
        ).isSuccess,
        isFalse,
      );
      // A non-string body is a broken peer, not an empty message.
      expect(
        MessagePayload.from(
          Frame.of(FrameType.msg, <String, Object?>{'msgId': 'a', 'text': 5}),
        ).isSuccess,
        isFalse,
      );
    });

    test('accepts an empty body', () {
      // Not something the composer produces, but it is not malformed either.
      final PayloadDecode<MessagePayload> decoded = MessagePayload.from(
        Frame.of(FrameType.msg, <String, Object?>{'msgId': 'a', 'text': ''}),
      );
      expect(decoded.isSuccess, isTrue);
      expect(decoded.value!.text, isEmpty);
    });

    test('rejects a body over the storage cap', () {
      expect(
        MessagePayload.from(
          Frame.of(FrameType.msg, <String, Object?>{
            'msgId': 'a',
            'text': 'x' * (kMaxMessageTextLength + 1),
          }),
        ).isSuccess,
        isFalse,
      );
    });

    group('ts is advisory, so a broken one must not lose the message', () {
      test('a missing or nonsensical ts falls back to the local clock', () {
        for (final Object? ts in <Object?>[null, 0, -5, 'now']) {
          final PayloadDecode<MessagePayload> decoded = MessagePayload.from(
            Frame.of(FrameType.msg, <String, Object?>{'msgId': 'a', 'text': 'x', 'ts': ts}),
          );
          expect(decoded.isSuccess, isTrue, reason: 'ts=$ts');
          expect(
            DateTime.now().difference(decoded.value!.ts).abs(),
            lessThan(const Duration(minutes: 1)),
            reason: 'ts=$ts should have been replaced by the local clock',
          );
        }
      });

      test('a plausible ts is preserved', () {
        final DateTime when = DateTime.now().subtract(const Duration(hours: 3));
        final PayloadDecode<MessagePayload> decoded = MessagePayload.from(
          Frame.of(FrameType.msg, <String, Object?>{
            'msgId': 'a',
            'text': 'x',
            'ts': when.millisecondsSinceEpoch,
          }),
        );
        expect(
          decoded.value!.ts.millisecondsSinceEpoch,
          when.millisecondsSinceEpoch,
        );
      });

      test('a wildly wrong clock is clamped rather than propagated', () {
        // Year 3000: a peer with an unset RTC. §4.5 never sorts by this, but a
        // garbage value must not reach the UI either.
        final PayloadDecode<MessagePayload> decoded = MessagePayload.from(
          Frame.of(FrameType.msg, <String, Object?>{
            'msgId': 'a',
            'text': 'x',
            'ts': DateTime(3000).millisecondsSinceEpoch,
          }),
        );
        expect(decoded.isSuccess, isTrue);
        expect(
          DateTime.now().difference(decoded.value!.ts).abs(),
          lessThan(const Duration(minutes: 1)),
        );
      });
    });
  });

  group('MsgAckPayload', () {
    test('round-trips', () {
      final MsgAckPayload original = MsgAckPayload(
        msgId: 'uuid-1',
        ts: DateTime(2026, 10, 4, 14, 24),
      );
      final PayloadDecode<MsgAckPayload> decoded =
          MsgAckPayload.from(original.toFrame());
      expect(decoded.isSuccess, isTrue);
      expect(decoded.value!.msgId, 'uuid-1');
      expect(
        decoded.value!.ts.millisecondsSinceEpoch,
        original.ts.millisecondsSinceEpoch,
      );
    });

    test('rejects a missing msgId', () {
      expect(MsgAckPayload.from(Frame.of(FrameType.msgAck)).isSuccess, isFalse);
    });
  });

  group('HeartbeatPayload', () {
    test('round-trips as both ping and pong', () {
      for (final String type in <String>[FrameType.ping, FrameType.pong]) {
        final Frame frame =
            HeartbeatPayload(ts: DateTime(2026, 10, 4)).toFrame(type);
        expect(frame.type, type);
        expect(HeartbeatPayload.from(frame).isSuccess, isTrue);
      }
    });
  });

  group('forward compatibility (design.md §4.3)', () {
    test('an unknown frame type is not one this build claims to know', () {
      // The connection ignores it and logs; it must not be a parse failure, or
      // a newer peer could not talk to this build at all.
      final Frame frame = Frame.of('telepathy', <String, Object?>{'x': 1});
      expect(frame.isKnownType, isFalse);
      expect(FrameType.msg, isNotEmpty);
    });

    test('unknown fields on a known frame are ignored', () {
      final Frame frame = Frame(
        <String, Object?>{
          ...sampleHello().toFrame().header,
          'futureField': <int>[1, 2, 3],
        },
      );
      final PayloadDecode<HelloPayload> decoded = HelloPayload.from(frame);
      expect(decoded.isSuccess, isTrue);
      expect(decoded.value!.deviceId, 'peer-uuid');
    });
  });
}
