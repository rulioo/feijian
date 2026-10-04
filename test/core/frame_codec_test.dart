import 'dart:convert';
import 'dart:typed_data';

import 'package:feijian/core/constants.dart';
import 'package:feijian/core/protocol/frame_codec.dart';
import 'package:flutter_test/flutter_test.dart';

/// Builds the raw wire bytes by hand, so the tests do not verify the encoder
/// against itself. [header] is encoded as given; `headerLen` is derived.
Uint8List wire(Map<String, Object?> header, [List<int>? payload]) {
  final List<int> headerBytes = utf8.encode(jsonEncode(header));
  final BytesBuilder out = BytesBuilder();
  out.add(<int>[
    (headerBytes.length >> 24) & 0xff,
    (headerBytes.length >> 16) & 0xff,
    (headerBytes.length >> 8) & 0xff,
    headerBytes.length & 0xff,
  ]);
  out.add(headerBytes);
  if (payload != null) {
    out.add(payload);
  }
  return out.takeBytes();
}

void main() {
  group('FrameCodec.encode', () {
    test('writes the header length as a big-endian uint32', () {
      final Uint8List bytes = FrameCodec.encode(
        Frame.of(FrameType.ping, <String, Object?>{'ts': 1}),
      );

      final String header = utf8.decode(bytes.sublist(4));
      expect(ByteData.view(bytes.buffer).getUint32(0, Endian.big), header.length);
      expect(jsonDecode(header), <String, Object?>{'type': 'ping', 'ts': 1});
    });

    test('omits the size key when there is no payload', () {
      final Uint8List bytes = FrameCodec.encode(Frame.of(FrameType.bye));
      expect(jsonDecode(utf8.decode(bytes.sublist(4))), <String, Object?>{
        'type': 'bye',
      });
    });

    test('declares the payload length as size', () {
      final Uint8List bytes = FrameCodec.encode(
        Frame.of(FrameType.fileData, <String, Object?>{'xferId': 'x'}, Uint8List.fromList(<int>[1, 2, 3])),
      );
      final Map<String, Object?> header =
          jsonDecode(utf8.decode(bytes.sublist(4, bytes.length - 3)))
              as Map<String, Object?>;
      expect(header['size'], 3);
      expect(bytes.sublist(bytes.length - 3), <int>[1, 2, 3]);
    });

    test('ignores a size the caller tried to set by hand', () {
      // `size` belongs to the frame layer; a payload definition that sets it
      // would desync the declared length from the bytes actually written.
      final Uint8List bytes = FrameCodec.encode(
        Frame.of(
          FrameType.fileData,
          <String, Object?>{'xferId': 'x', 'size': 999},
          Uint8List.fromList(<int>[7, 7]),
        ),
      );
      expect(jsonDecode(utf8.decode(bytes.sublist(4, bytes.length - 2))), <String, Object?>{
        'type': 'file_data',
        'xferId': 'x',
        'size': 2,
      });
    });

    test('refuses a payload over the cap', () {
      expect(
        () => FrameCodec.encode(
          Frame.of(FrameType.fileData, const <String, Object?>{}, Uint8List(kMaxPayload + 1)),
        ),
        throwsA(isA<FrameException>()),
      );
    });

    test('refuses a header over the cap', () {
      expect(
        () => FrameCodec.encode(
          Frame.of(FrameType.msg, <String, Object?>{
            'text': 'x' * (kMaxFrameHeader + 1),
          }),
        ),
        throwsA(isA<FrameException>()),
      );
    });
  });

  group('FrameDecoder', () {
    test('round-trips a payload-free frame', () {
      final List<Frame> frames = FrameDecoder().add(
        FrameCodec.encode(Frame.of(FrameType.ping, <String, Object?>{'ts': 42})),
      );
      expect(frames, hasLength(1));
      expect(frames.single.type, 'ping');
      expect(frames.single.header['ts'], 42);
      expect(frames.single.payload, isNull);
    });

    test('round-trips a payload byte for byte', () {
      final List<int> payload = List<int>.generate(300, (int i) => i % 256);
      final List<Frame> frames = FrameDecoder().add(
        FrameCodec.encode(
          Frame.of(FrameType.fileData, const <String, Object?>{}, Uint8List.fromList(payload)),
        ),
      );
      expect(frames.single.payload, payload);
    });

    test('reassembles a frame delivered one byte at a time', () {
      final FrameDecoder decoder = FrameDecoder();
      final Uint8List bytes = FrameCodec.encode(
        Frame.of(
          FrameType.fileData,
          <String, Object?>{'xferId': 'abc'},
          Uint8List.fromList(<int>[9, 8, 7, 6]),
        ),
      );

      final List<Frame> got = <Frame>[];
      for (final int byte in bytes) {
        got.addAll(decoder.add(<int>[byte]));
      }

      expect(got, hasLength(1));
      expect(got.single.header['xferId'], 'abc');
      expect(got.single.payload, <int>[9, 8, 7, 6]);
    });

    test('returns every frame when several arrive in one chunk', () {
      final BytesBuilder all = BytesBuilder();
      for (int i = 0; i < 5; i++) {
        all.add(FrameCodec.encode(Frame.of(FrameType.msg, <String, Object?>{'msgId': '$i'})));
      }

      final List<Frame> frames = FrameDecoder().add(all.takeBytes());
      expect(frames.map((Frame f) => f.header['msgId']), <String>['0', '1', '2', '3', '4']);
    });

    test('holds a partial frame until the rest arrives', () {
      final FrameDecoder decoder = FrameDecoder();
      final Uint8List bytes = FrameCodec.encode(Frame.of(FrameType.ping, <String, Object?>{'ts': 1}));

      expect(decoder.add(bytes.sublist(0, bytes.length - 1)), isEmpty);
      expect(decoder.add(bytes.sublist(bytes.length - 1)), hasLength(1));
    });

    test('ignores an empty chunk', () {
      expect(FrameDecoder().add(const <int>[]), isEmpty);
    });

    test('survives a large payload split across chunks', () {
      final FrameDecoder decoder = FrameDecoder();
      final List<int> payload = List<int>.generate(kMaxPayload, (int i) => i % 256);
      final Uint8List bytes = FrameCodec.encode(
        Frame.of(FrameType.fileData, const <String, Object?>{}, Uint8List.fromList(payload)),
      );

      // Deliberately awkward split points: mid-length-prefix and mid-header.
      final List<Frame> got = <Frame>[];
      got.addAll(decoder.add(bytes.sublist(0, 2)));
      got.addAll(decoder.add(bytes.sublist(2, 100)));
      got.addAll(decoder.add(bytes.sublist(100)));

      expect(got, hasLength(1));
      expect(got.single.payload, payload);
    });

    test('carries a UTF-8 message body intact', () {
      const String text = '你好，世界 🌏 — okay?';
      final List<Frame> frames = FrameDecoder().add(
        FrameCodec.encode(Frame.of(FrameType.msg, <String, Object?>{'text': text})),
      );
      expect(frames.single.header['text'], text);
    });

    group('rejects a stream it cannot trust', () {
      test('header length over the cap, without buffering it', () {
        // Only 4 bytes are supplied: the check must happen before waiting for
        // the body, or a hostile length becomes an unbounded allocation.
        final FrameDecoder decoder = FrameDecoder();
        expect(
          () => decoder.add(<int>[0x00, 0x20, 0x00, 0x00]),
          throwsA(isA<FrameException>()),
        );
        expect(decoder.isBroken, isTrue);
      });

      test('payload length over the cap', () {
        expect(
          () => FrameDecoder().add(
            wire(<String, Object?>{
              'type': 'file_data',
              'size': kMaxPayload + 1,
            }),
          ),
          throwsA(isA<FrameException>()),
        );
      });

      test('a negative size', () {
        expect(
          () => FrameDecoder().add(
            wire(<String, Object?>{'type': 'file_data', 'size': -1}),
          ),
          throwsA(isA<FrameException>()),
        );
      });

      test('a non-integer size', () {
        expect(
          () => FrameDecoder().add(
            wire(<String, Object?>{'type': 'file_data', 'size': 'big'}),
          ),
          throwsA(isA<FrameException>()),
        );
      });

      test('a header that is not JSON', () {
        final List<int> header = utf8.encode('not json');
        expect(
          () => FrameDecoder().add(<int>[0, 0, 0, header.length, ...header]),
          throwsA(isA<FrameException>()),
        );
      });

      test('a header that is a JSON array rather than an object', () {
        final List<int> header = utf8.encode('[1,2,3]');
        expect(
          () => FrameDecoder().add(<int>[0, 0, 0, header.length, ...header]),
          throwsA(isA<FrameException>()),
        );
      });

      test('a header with no type', () {
        expect(
          () => FrameDecoder().add(wire(<String, Object?>{'ts': 1})),
          throwsA(isA<FrameException>()),
        );
      });

      test('a header with an empty type', () {
        expect(
          () => FrameDecoder().add(wire(<String, Object?>{'type': ''})),
          throwsA(isA<FrameException>()),
        );
      });

      test('a header that is not valid UTF-8', () {
        // 0xC3 starts a two-byte sequence; 0x28 cannot continue it.
        final List<int> header = <int>[0xC3, 0x28, 0x7B, 0x7D];
        expect(
          () => FrameDecoder().add(<int>[0, 0, 0, header.length, ...header]),
          throwsA(isA<FrameException>()),
        );
      });
    });

    test('refuses further input once broken, and reset revives it', () {
      final FrameDecoder decoder = FrameDecoder();
      expect(
        () => decoder.add(wire(<String, Object?>{'ts': 1})),
        throwsA(isA<FrameException>()),
      );
      // The bytes after a framing error are not known to be frame boundaries,
      // so resynchronising could act on whatever looks like a header.
      expect(
        () => decoder.add(FrameCodec.encode(Frame.of(FrameType.ping))),
        throwsA(isA<FrameException>()),
      );

      decoder.reset();
      expect(decoder.isBroken, isFalse);
      expect(decoder.add(FrameCodec.encode(Frame.of(FrameType.ping))), hasLength(1));
    });
  });

  group('the size key is reserved for the frame layer', () {
    test('a file offer reporting a multi-gigabyte total is not read as a frame '
        'length', () {
      // Regression guard. §4.2 declares the payload length as `size`, and §4.3
      // originally gave `file_offer` a `size` meaning the file's total — one
      // key, two meanings. A 4 GB offer would then have been read as a 4 GB
      // payload and the connection dropped as corrupt. The offer field is
      // `totalSize` for exactly this reason.
      final Uint8List bytes = FrameCodec.encode(
        Frame.of(FrameType.fileOffer, <String, Object?>{
          'xferId': 'x1',
          'name': 'huge.iso',
          'totalSize': 4 * 1024 * 1024 * 1024,
          'mime': 'application/octet-stream',
        }),
      );

      final List<Frame> frames = FrameDecoder().add(bytes);
      expect(frames, hasLength(1));
      expect(frames.single.header['totalSize'], 4294967296);
      expect(frames.single.payload, isNull);
    });
  });
}
