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

    test('a control hello is byte-for-byte what it was before xferId', () {
      // The field is additive, and this is what "additive" has to mean: an
      // existing peer sees exactly the frame it saw before.
      expect(sampleHello().toFrame().header.containsKey('xferId'), isFalse);
    });

    test('a data hello names the transfer it belongs to', () {
      final HelloPayload hello = sampleHello().forTransfer('xfer-7');

      expect(hello.role, ConnectionRole.data);
      expect(hello.xferId, 'xfer-7');

      final PayloadDecode<HelloPayload> decoded =
          HelloPayload.from(hello.toFrame());
      expect(decoded.value!.xferId, 'xfer-7');
      expect(decoded.value!.role, ConnectionRole.data);
    });

    test('a data hello with no xferId is still accepted', () {
      // What a build from before this field existed sends. Refusing it would
      // break the forward-compatibility rule in §4.3 for a field the receiver
      // can simply do without.
      final PayloadDecode<HelloPayload> decoded = HelloPayload.from(
        helloFrame('role', ConnectionRole.data.wire),
      );

      expect(decoded.isSuccess, isTrue, reason: decoded.reason);
      expect(decoded.value!.xferId, isNull);
    });

    test('a control hello carrying an xferId keeps it', () {
      // Nothing sends this, but a peer that did would not corrupt the parse.
      final PayloadDecode<HelloPayload> decoded =
          HelloPayload.from(helloFrame('xferId', 'xfer-9'));

      expect(decoded.value!.xferId, 'xfer-9');
    });

    test('a nonsensical xferId is dropped, not fatal', () {
      // The connection is still usable — the transfer layer finds nothing to
      // attach it to and closes it with a clear log, which is a better outcome
      // than refusing a handshake over an optional field.
      expect(HelloPayload.from(helloFrame('xferId', '')).value!.xferId, isNull);
      expect(HelloPayload.from(helloFrame('xferId', 42)).value!.xferId, isNull);
      expect(
        HelloPayload.from(
          helloFrame('xferId', 'x' * (kMaxDeviceIdLength + 1)),
        ).value!.xferId,
        isNull,
      );
    });

    test('answering echoes the role and the transfer from the request', () {
      // The accepting side answers with `answering`. Dropping the xferId there
      // leaves the dialler unable to recognise the data connection it asked
      // for — which is exactly the bug this test exists for.
      final HelloPayload ours = sampleHello(deviceId: 'us', name: 'Me');
      final HelloPayload answer =
          ours.answering(sampleHello().forTransfer('xfer-7'));

      expect(answer.role, ConnectionRole.data);
      expect(answer.xferId, 'xfer-7');
      // Everything else is still us: the peer is being told who answered.
      expect(answer.deviceId, 'us');
      expect(answer.name, 'Me');
    });

    test('answering a control request carries no transfer over', () {
      final HelloPayload answer =
          sampleHello(deviceId: 'us').answering(sampleHello());

      expect(answer.role, ConnectionRole.control);
      expect(answer.xferId, isNull);
      // A `hello` we send on a control connection must stay byte-for-byte what
      // it was before the field existed.
      expect(answer.toFrame().header.containsKey('xferId'), isFalse);
    });

    test('rejects a role it does not know', () {
      final PayloadDecode<HelloPayload> decoded =
          HelloPayload.from(helloFrame('role', 'gossip'));
      expect(decoded.isSuccess, isFalse);
      expect(decoded.reason, contains('role'));
    });

    test('rejects a missing or empty device id', () {
      expect(
          HelloPayload.from(helloFrame('deviceId', null)).isSuccess, isFalse);
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
            Frame.of(FrameType.msg,
                <String, Object?>{'msgId': 'a', 'text': 'x', 'ts': ts}),
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

  group('FileOfferPayload', () {
    FileOfferPayload sample({
      String xferId = 'xfer-1',
      String name = 'holiday.jpg',
      int totalSize = 4096,
      String? mime = 'image/jpeg',
    }) {
      return FileOfferPayload(
        xferId: xferId,
        name: name,
        totalSize: totalSize,
        mime: mime,
      );
    }

    /// The offer frame with one field replaced or removed.
    Frame frameWith(String key, Object? value) {
      final Map<String, Object?> header = <String, Object?>{
        ...sample().toFrame().header,
      };
      if (value == null) {
        header.remove(key);
      } else {
        header[key] = value;
      }
      return Frame(header);
    }

    test('round-trips every field', () {
      final FileOfferPayload original = FileOfferPayload(
        xferId: 'xfer-1',
        name: '报表 2026.xlsx',
        totalSize: 123456789,
        mime: 'application/vnd.ms-excel',
        sha256: 'a' * 64,
        mtime: 1767225600000,
      );

      final PayloadDecode<FileOfferPayload> decoded =
          FileOfferPayload.from(original.toFrame());

      expect(decoded.isSuccess, isTrue, reason: decoded.reason);
      final FileOfferPayload offer = decoded.value!;
      expect(offer.xferId, 'xfer-1');
      expect(offer.name, '报表 2026.xlsx');
      expect(offer.totalSize, 123456789);
      expect(offer.mime, 'application/vnd.ms-excel');
      expect(offer.sha256, 'a' * 64);
      expect(offer.mtime, 1767225600000);
      expect(offer.isDir, isFalse);
    });

    test('a plain offer omits the fields it does not have', () {
      // Every one of these was added for the folder and resume work; an
      // ordinary file offer must not grow them.
      final Map<String, Object?> header = sample().toFrame().header;
      expect(header.containsKey('isDir'), isFalse);
      expect(header.containsKey('sha256'), isFalse);
      expect(header.containsKey('mtime'), isFalse);
    });

    test('rejects a missing or empty xferId', () {
      expect(
          FileOfferPayload.from(frameWith('xferId', null)).isSuccess, isFalse);
      expect(FileOfferPayload.from(frameWith('xferId', '')).isSuccess, isFalse);
      expect(
        FileOfferPayload.from(
          frameWith('xferId', 'x' * (kMaxXferIdLength + 1)),
        ).isSuccess,
        isFalse,
      );
    });

    test('rejects a missing, empty or over-long name', () {
      expect(FileOfferPayload.from(frameWith('name', null)).isSuccess, isFalse);
      expect(FileOfferPayload.from(frameWith('name', '')).isSuccess, isFalse);
      expect(
        FileOfferPayload.from(
          frameWith('name', 'x' * (kMaxFileNameLength + 1)),
        ).isSuccess,
        isFalse,
      );
    });

    group('totalSize has no safe default, so it is refused rather than guessed',
        () {
      test('rejects a missing, negative or non-integer size', () {
        for (final Object? size in <Object?>[null, -1, '4096', 4096.5]) {
          expect(
            FileOfferPayload.from(frameWith('totalSize', size)).isSuccess,
            isFalse,
            reason: 'totalSize=$size must be refused',
          );
        }
      });

      test('accepts zero, which is a real empty file', () {
        final PayloadDecode<FileOfferPayload> decoded =
            FileOfferPayload.from(frameWith('totalSize', 0));
        expect(decoded.isSuccess, isTrue);
        expect(decoded.value!.totalSize, 0);
      });
    });

    test('drops a checksum that could not be one', () {
      // Stored and later compared against a real digest, a 3-character
      // "checksum" would make two different files look like a match.
      for (final String bad in <String>['abc', 'A' * 64, 'z' * 64, 'a' * 63]) {
        expect(
          FileOfferPayload.from(frameWith('sha256', bad)).value!.sha256,
          isNull,
          reason: 'sha256="$bad" must be dropped',
        );
      }
    });

    test('drops an over-long mime and a nonsensical mtime', () {
      expect(
        FileOfferPayload.from(
          frameWith('mime', 'x' * (kMaxMimeLength + 1)),
        ).value!.mime,
        isNull,
      );
      expect(FileOfferPayload.from(frameWith('mtime', 0)).value!.mtime, isNull);
      expect(
          FileOfferPayload.from(frameWith('mtime', -5)).value!.mtime, isNull);
      expect(
        FileOfferPayload.from(frameWith('mtime', 'now')).value!.mtime,
        isNull,
      );
    });

    test('isDir is true only for exactly true', () {
      // Otherwise a peer writing `"isDir": "yes"` would have an ordinary file
      // refused as an unsupported folder.
      final PayloadDecode<FileOfferPayload> truthy =
          FileOfferPayload.from(frameWith('isDir', 'yes'));
      expect(truthy.value!.isDir, isFalse);

      final PayloadDecode<FileOfferPayload> real =
          FileOfferPayload.from(FileOfferPayload(
        xferId: 'xfer-1',
        name: 'photos',
        totalSize: 0,
        isDir: true,
      ).toFrame());
      expect(real.value!.isDir, isTrue);
    });

    test('an unknown field does not break the offer', () {
      final PayloadDecode<FileOfferPayload> decoded = FileOfferPayload.from(
        Frame(<String, Object?>{
          ...sample().toFrame().header,
          'compression': 'zstd',
        }),
      );
      expect(decoded.isSuccess, isTrue);
      expect(decoded.value!.name, 'holiday.jpg');
    });
  });

  group('FileAcceptPayload', () {
    test('round-trips', () {
      final PayloadDecode<FileAcceptPayload> decoded = FileAcceptPayload.from(
        const FileAcceptPayload(xferId: 'xfer-1', resumeFrom: 262144).toFrame(),
      );
      expect(decoded.isSuccess, isTrue);
      expect(decoded.value!.xferId, 'xfer-1');
      expect(decoded.value!.resumeFrom, 262144);
    });

    test('an absent resumeFrom means the beginning', () {
      // A peer that does not send the field can only mean "from zero".
      final Map<String, Object?> header = <String, Object?>{
        ...const FileAcceptPayload(xferId: 'xfer-1').toFrame().header,
      }..remove('resumeFrom');

      final PayloadDecode<FileAcceptPayload> decoded =
          FileAcceptPayload.from(Frame(header));
      expect(decoded.isSuccess, isTrue);
      expect(decoded.value!.resumeFrom, 0);
    });

    test('a nonsensical resumeFrom is refused, not defaulted', () {
      // Seeking to a position that does not exist is worse than restarting:
      // the sender would read past the end of the file and send nothing.
      for (final Object? from in <Object?>[-1, '0', 1.5]) {
        final Map<String, Object?> header = <String, Object?>{
          ...const FileAcceptPayload(xferId: 'xfer-1').toFrame().header,
          'resumeFrom': from,
        };
        expect(
          FileAcceptPayload.from(Frame(header)).isSuccess,
          isFalse,
          reason: 'resumeFrom=$from must be refused',
        );
      }
    });

    test('rejects a missing xferId', () {
      expect(
        FileAcceptPayload.from(Frame.of(FrameType.fileAccept)).isSuccess,
        isFalse,
      );
    });
  });

  group('FileRejectPayload', () {
    test('round-trips every reason', () {
      for (final RejectReason reason in RejectReason.values) {
        final PayloadDecode<FileRejectPayload> decoded = FileRejectPayload.from(
          FileRejectPayload(xferId: 'xfer-1', reason: reason).toFrame(),
        );
        expect(decoded.isSuccess, isTrue);
        expect(decoded.value!.reason, reason, reason: reason.wire);
      }
    });

    test('an unrecognised reason is unknown, not a decline', () {
      // "The peer said no for a reason I did not understand" and "the user
      // pressed Decline" are different sentences to show someone.
      final Map<String, Object?> header = <String, Object?>{
        ...const FileRejectPayload(xferId: 'xfer-1').toFrame().header,
        'reason': 'quota_exceeded',
      };
      expect(
        FileRejectPayload.from(Frame(header)).value!.reason,
        RejectReason.unknown,
      );
    });

    test('an absent reason is unknown too', () {
      final Map<String, Object?> header = <String, Object?>{
        ...const FileRejectPayload(xferId: 'xfer-1').toFrame().header,
      }..remove('reason');
      expect(
        FileRejectPayload.from(Frame(header)).value!.reason,
        RejectReason.unknown,
      );
    });

    test('rejects a missing xferId', () {
      expect(
        FileRejectPayload.from(Frame.of(FrameType.fileReject)).isSuccess,
        isFalse,
      );
    });
  });

  group('TransferRefPayload', () {
    test('round-trips as file_done, file_cancel and xfer_done', () {
      for (final String type in <String>[
        FrameType.fileDone,
        FrameType.fileCancel,
        FrameType.xferDone,
      ]) {
        final Frame frame =
            const TransferRefPayload(xferId: 'xfer-1').toFrame(type);
        expect(frame.type, type);
        final PayloadDecode<TransferRefPayload> decoded =
            TransferRefPayload.from(frame);
        expect(decoded.isSuccess, isTrue);
        expect(decoded.value!.xferId, 'xfer-1');
      }
    });

    test('rejects a missing, empty or over-long xferId', () {
      for (final Object? id in <Object?>[
        null,
        '',
        'x' * (kMaxXferIdLength + 1)
      ]) {
        final Map<String, Object?> header = <String, Object?>{'xferId': id};
        expect(
          TransferRefPayload.from(Frame.of(FrameType.fileDone, header))
              .isSuccess,
          isFalse,
          reason: 'xferId=$id must be refused',
        );
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
