import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:feijian/core/constants.dart';
import 'package:feijian/core/protocol/frame_codec.dart';
import 'package:feijian/core/transfer/outgoing_file.dart';
import 'package:feijian/core/transport/frame_sink.dart';
import 'package:flutter_test/flutter_test.dart';

/// Stands in for the connection, recording what the sender wrote and when.
///
/// The flush cadence is the reason this exists: a real socket accepts writes
/// instantly whatever the sender does, so the far end cannot tell a loop that
/// flushes from one that does not. Counting here can.
class _RecordingSink implements FrameSink {
  final List<Frame> frames = <Frame>[];

  /// Bytes written since the last flush, one entry per completed batch.
  final List<int> flushedBatches = <int>[];

  int _unflushed = 0;

  /// Refuses the write with this index, as a dead connection would.
  int? failAtSend;

  /// Set to make [flush] hang, so a test can see whether the pump awaited it.
  Completer<void>? blockFlush;

  int _sends = 0;

  @override
  bool send(Frame frame) {
    if (failAtSend != null && _sends >= failAtSend!) {
      return false;
    }
    _sends++;
    frames.add(frame);
    _unflushed += frame.payload?.length ?? 0;
    return true;
  }

  @override
  Future<void> flush() async {
    if (blockFlush != null) {
      await blockFlush!.future;
    }
    flushedBatches.add(_unflushed);
    _unflushed = 0;
  }

  /// This is the other half of the backpressure proof: if the pump awaited
  /// every flush, the batch size would be one chunk, and the loop would be
  /// paying a syscall per 256 KB for no benefit.
  int get maxBatch => flushedBatches.isEmpty
      ? 0
      : flushedBatches.reduce((int a, int b) => a > b ? a : b);

  int get totalPayload =>
      frames.fold(0, (int sum, Frame f) => sum + (f.payload?.length ?? 0));
}

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('feijian_outgoing_');
  });

  tearDown(() {
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
  });

  /// A file of [length] bytes with a position-dependent pattern, so a chunk
  /// written at the wrong offset is visible rather than merely the right size.
  File makeFile(String name, int length) {
    final File file = File('${dir.path}${Platform.pathSeparator}$name');
    final Uint8List bytes = Uint8List(length);
    for (int i = 0; i < length; i++) {
      bytes[i] = i % 251;
    }
    file.writeAsBytesSync(bytes);
    return file;
  }

  Future<int> pump(File file, _RecordingSink sink,
      {int from = 0, int? chunk}) async {
    final OutgoingFile source = await OutgoingFile.open(
      file,
      from: from,
      chunkSize: chunk ?? kChunkSize,
    );
    try {
      return await source.pump(sink, xferId: 'x1');
    } finally {
      await source.close();
    }
  }

  group('framing the file into chunks', () {
    test('a file smaller than one chunk is one frame', () async {
      final _RecordingSink sink = _RecordingSink();

      await pump(makeFile('small.bin', 1000), sink);

      expect(sink.frames, hasLength(1));
      expect(sink.frames.single.header['offset'], 0);
      expect(sink.frames.single.header['eof'], isTrue);
      expect(sink.frames.single.payload, hasLength(1000));
    });

    test('a file of exactly one chunk is one frame, not two', () async {
      // The loop must not emit a trailing empty frame at the boundary, which
      // would tell the receiver there is more data coming and then send none.
      final _RecordingSink sink = _RecordingSink();

      await pump(makeFile('exact.bin', 4096), sink, chunk: 4096);

      expect(sink.frames, hasLength(1));
      expect(sink.frames.single.header['eof'], isTrue);
      expect(sink.frames.single.payload, hasLength(4096));
    });

    test('one byte past a chunk boundary is two frames', () async {
      final _RecordingSink sink = _RecordingSink();

      await pump(makeFile('over.bin', 4097), sink, chunk: 4096);

      expect(sink.frames, hasLength(2));
      expect(sink.frames[0].header['offset'], 0);
      expect(sink.frames[0].header['eof'], isFalse);
      expect(sink.frames[1].header['offset'], 4096);
      expect(sink.frames[1].header['eof'], isTrue);
      expect(sink.frames[1].payload, hasLength(1));
    });

    test('an empty file sends nothing at all', () async {
      final _RecordingSink sink = _RecordingSink();

      final int sent = await pump(makeFile('empty.bin', 0), sink);

      expect(sink.frames, isEmpty);
      expect(sent, 0);
    });

    test('offsets are contiguous and cover the file exactly once', () async {
      final _RecordingSink sink = _RecordingSink();

      await pump(makeFile('run.bin', 10000), sink, chunk: 4096);

      int expected = 0;
      for (final Frame frame in sink.frames) {
        expect(frame.header['xferId'], 'x1');
        expect(frame.header['offset'], expected);
        expected += frame.payload!.length;
      }
      expect(expected, 10000);
      expect(sink.totalPayload, 10000);
    });

    test('the bytes arrive in order and unaltered', () async {
      final File file = makeFile('roundtrip.bin', 10000);
      final _RecordingSink sink = _RecordingSink();

      await pump(file, sink, chunk: 4096);

      final BytesBuilder assembled = BytesBuilder();
      for (final Frame frame in sink.frames) {
        assembled.add(frame.payload!);
      }
      expect(assembled.takeBytes(), file.readAsBytesSync());
    });

    test('only the last frame is marked eof', () async {
      final _RecordingSink sink = _RecordingSink();

      await pump(makeFile('tail.bin', 10000), sink, chunk: 4096);

      final List<bool> eofs =
          sink.frames.map((Frame f) => f.header['eof']! as bool).toList();
      expect(eofs, <bool>[false, false, true]);
    });
  });

  group('a large file is never held whole', () {
    test('a file far past the frame limit becomes many frames', () async {
      // The regression this guards is `readAsBytes()`: it would produce a single
      // frame carrying the whole file, which the encoder rejects for exceeding
      // the payload cap — but only after allocating every byte. Asserting the
      // frame count and the per-frame size catches it without needing to
      // measure memory.
      const int size = 5 * 1024 * 1024;
      final _RecordingSink sink = _RecordingSink();

      await pump(makeFile('big.bin', size), sink);

      expect(sink.frames, hasLength(size ~/ kChunkSize));
      for (final Frame frame in sink.frames) {
        expect(frame.payload!.length, lessThanOrEqualTo(kMaxPayload));
        expect(frame.payload!.length, lessThanOrEqualTo(kChunkSize));
      }
    });

    test('the socket is flushed long before the file is finished', () async {
      // 5 MB at 256 KB per chunk is 20 chunks: flush at 2 MB and at 4 MB, then
      // the tail. Anything much sparser means the socket is buffering the file.
      const int size = 5 * 1024 * 1024;
      final _RecordingSink sink = _RecordingSink();

      await pump(makeFile('flushed.bin', size), sink);

      expect(sink.flushedBatches.length, greaterThanOrEqualTo(3));
      for (final int batch in sink.flushedBatches) {
        // Never more than one threshold's worth in flight, plus the one chunk
        // that crossed it.
        expect(batch, lessThan(kFileFlushBytes + kChunkSize));
      }
      expect(sink.maxBatch, greaterThanOrEqualTo(kFileFlushBytes));
      expect(
        sink.flushedBatches.fold(0, (int a, int b) => a + b),
        size,
      );
    });

    test('a small file is still flushed once at the end', () async {
      // Without the trailing flush the last chunks sit in the buffer until
      // something else writes, and the progress bar stops just short of done.
      final _RecordingSink sink = _RecordingSink();

      await pump(makeFile('tiny.bin', 10), sink);

      expect(sink.flushedBatches, <int>[10]);
    });

    test('the pump waits for each flush to complete', () async {
      // A flush that is not awaited is not backpressure at all — the loop would
      // race ahead and the buffer would grow exactly as before.
      final _RecordingSink sink = _RecordingSink();
      sink.blockFlush = Completer<void>();

      final Future<int> pumping =
          pump(makeFile('blocked.bin', 5 * 1024 * 1024), sink);

      // Two phases, because either one alone can be fooled. First wait for the
      // pump to get as far as the threshold — generous, since the chunks are
      // real file reads and a loaded machine is slow.
      const int threshold = kFileFlushBytes ~/ kChunkSize;
      for (int i = 0; i < 2000 && sink.frames.length < threshold; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(sink.frames.length, threshold, reason: 'never reached the flush');

      // Then keep going. A pump that awaits its flush is deadlocked here and
      // cannot advance however long this runs; one that ignores the pending
      // flush finishes the file. So this phase is what tells a parked pump
      // from one that merely passed through the eighth frame.
      for (int i = 0; i < 200; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(sink.frames.length, threshold,
          reason: 'ran past the pending flush');

      sink.blockFlush!.complete();
      await pumping;
      expect(sink.totalPayload, 5 * 1024 * 1024);
    });
  });

  group('resuming from an offset', () {
    test('the first frame starts where the receiver left off', () async {
      final _RecordingSink sink = _RecordingSink();

      final int sent = await pump(makeFile('resume.bin', 10000), sink,
          from: 4096, chunk: 4096);

      expect(sent, 10000);
      expect(sink.frames.first.header['offset'], 4096);
      expect(sink.frames.first.payload, hasLength(4096));
      expect(sink.totalPayload, 10000 - 4096);
      expect(sink.frames.last.header['eof'], isTrue);
    });

    test('the resumed bytes are the right ones', () async {
      final File file = makeFile('resume2.bin', 10000);
      final _RecordingSink sink = _RecordingSink();

      await pump(file, sink, from: 5000, chunk: 4096);

      final BytesBuilder assembled = BytesBuilder();
      for (final Frame frame in sink.frames) {
        assembled.add(frame.payload!);
      }
      expect(
        assembled.takeBytes(),
        file.readAsBytesSync().sublist(5000),
      );
    });

    test('resuming at the very end sends nothing', () async {
      final _RecordingSink sink = _RecordingSink();

      final int sent = await pump(makeFile('done.bin', 1000), sink, from: 1000);

      expect(sent, 1000);
      expect(sink.frames, isEmpty);
    });

    test('an offset past the end is refused', () async {
      await expectLater(
        OutgoingFile.open(makeFile('short.bin', 100), from: 101),
        throwsA(isA<FileSendException>()),
      );
    });

    test('a negative offset is refused', () async {
      await expectLater(
        OutgoingFile.open(makeFile('neg.bin', 100), from: -1),
        throwsA(isA<FileSendException>()),
      );
    });
  });

  group('refusing work it cannot do', () {
    test('a missing file reports the path', () async {
      final File missing = File('${dir.path}${Platform.pathSeparator}nope.bin');

      await expectLater(
        OutgoingFile.open(missing),
        throwsA(
          isA<FileSendException>().having(
            (FileSendException e) => e.message,
            'message',
            contains('nope.bin'),
          ),
        ),
      );
    });

    test('a chunk larger than a frame is refused up front', () async {
      // Otherwise the encoder throws mid-transfer, after the receiver has
      // accepted an offer it will never see finished.
      await expectLater(
        OutgoingFile.open(makeFile('x.bin', 10), chunkSize: kMaxPayload + 1),
        throwsA(isA<FileSendException>()),
      );
    });

    test('a non-positive chunk size is refused', () async {
      await expectLater(
        OutgoingFile.open(makeFile('y.bin', 10), chunkSize: 0),
        throwsA(isA<FileSendException>()),
      );
    });

    test('a connection that stops accepting stops the read', () async {
      final _RecordingSink sink = _RecordingSink()..failAtSend = 2;
      final OutgoingFile source =
          await OutgoingFile.open(makeFile('dead.bin', 10000), chunkSize: 4096);

      await expectLater(
        source.pump(sink, xferId: 'x1'),
        throwsA(isA<FileSendException>()),
      );
      // Read no further than the write that failed — the file is still open and
      // there is no point reading from it.
      expect(sink.frames, hasLength(2));
      await source.close();
    });
  });

  group('the caller owns the handle', () {
    test('close is safe twice', () async {
      final OutgoingFile source = await OutgoingFile.open(makeFile('c.bin', 4));
      await source.close();
      await source.close();
    });

    test('a transfer cancelled before pumping still closes', () async {
      final Directory watched =
          Directory.systemTemp.createTempSync('feijian_held_');
      addTearDown(() {
        if (watched.existsSync()) {
          watched.deleteSync(recursive: true);
        }
      });
      final File file = File('${watched.path}${Platform.pathSeparator}k.bin')
        ..writeAsBytesSync(<int>[1, 2, 3]);

      final OutgoingFile source = await OutgoingFile.open(file);
      await source.close();

      // On Windows an open handle blocks deletion, so this is the assertion:
      // nothing is still holding the file.
      watched.deleteSync(recursive: true);
      expect(watched.existsSync(), isFalse);
    });

    test('closing a file that is mid-read still releases it', () async {
      // `RandomAccessFile.close()` throws rather than waits when another
      // operation is pending on the handle, and the pump leaves a read pending
      // between every pair of chunks — which is exactly where a cancel or a
      // dispose lands. Without the wait, this close throws, the handle is never
      // released, and on Windows the file stays un-deletable until the process
      // exits.
      final Directory watched =
          Directory.systemTemp.createTempSync('feijian_midread_');
      addTearDown(() {
        if (watched.existsSync()) {
          watched.deleteSync(recursive: true);
        }
      });
      final File file = File('${watched.path}${Platform.pathSeparator}m.bin')
        ..writeAsBytesSync(List<int>.filled(2 * 1024 * 1024, 9));

      final OutgoingFile source = await OutgoingFile.open(
        file,
        chunkSize: kMaxPayload,
      );
      final _RecordingSink sink = _RecordingSink();
      // Deliberately not awaited: the point is to close while the first read is
      // still in flight. The listener goes on before the close rather than
      // after, because the pump fails *during* it and a future that fails with
      // nobody listening is reported as an unhandled error.
      final Completer<Object?> outcome = Completer<Object?>();
      unawaited(
        source.pump(sink, xferId: 'x1').then<void>(
              (int _) => outcome.complete(null),
              onError: (Object error) => outcome.complete(error),
            ),
      );

      await source.close();

      // The pump fails — it was reading a file that closed underneath it, and
      // saying so is the whole point of the guard. What this test is about is
      // that the close, unlike the pump, did not.
      expect(await outcome.future, isA<FileSendException>());
      watched.deleteSync(recursive: true);
      expect(watched.existsSync(), isFalse);
    });

    test('progress is reported as bytes leave', () async {
      final _RecordingSink sink = _RecordingSink();
      final List<int> updates = <int>[];

      final OutgoingFile source =
          await OutgoingFile.open(makeFile('p.bin', 10000), chunkSize: 4096);
      await source.pump(
        sink,
        xferId: 'x1',
        onProgress: (int sent, int total) {
          expect(total, 10000);
          updates.add(sent);
        },
      );
      await source.close();

      expect(updates, <int>[4096, 8192, 10000]);
    });
  });
}
