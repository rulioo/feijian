import 'dart:io';
import 'dart:typed_data';

import 'package:feijian/core/protocol/frame_codec.dart';
import 'package:feijian/core/transfer/transfer_receiver.dart';
import 'package:flutter_test/flutter_test.dart';

/// What the sender is trusted for is exactly one thing: the bytes it agreed to
/// send, in the order it agreed to send them. Every test below takes one of
/// those away.
void main() {
  late Directory dir;
  late List<TransferReceiver> started;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('feijian_receiver_');
    started = <TransferReceiver>[];
  });

  tearDown(() async {
    for (final TransferReceiver receiver in started) {
      await receiver.cancel();
    }
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
  });

  Future<TransferReceiver> begin({
    String xferId = 'x1',
    String name = 'report.pdf',
    required int totalSize,
    String? relPath,
    Directory? into,
  }) async {
    final TransferReceiver receiver = await TransferReceiver.begin(
      directory: into ?? dir,
      xferId: xferId,
      rawName: name,
      totalSize: totalSize,
      relPath: relPath,
    );
    started.add(receiver);
    return receiver;
  }

  /// One `file_data` frame, as the sender would build it.
  Frame chunk(
    String xferId,
    int offset,
    List<int> bytes, {
    bool eof = false,
    String? relPath,
  }) =>
      Frame.of(
          FrameType.fileData,
          <String, Object?>{
            'xferId': xferId,
            if (relPath != null) 'relPath': relPath,
            'offset': offset,
            'eof': eof,
          },
          Uint8List.fromList(bytes));

  List<String> names() => dir
      .listSync()
      .map((FileSystemEntity e) => e.path.split(Platform.pathSeparator).last)
      .toList()
    ..sort();

  group('a well-behaved sender produces the file', () {
    test('chunks in order are written and the file is installed', () async {
      final TransferReceiver receiver = await begin(totalSize: 6);

      await receiver.accept(chunk('x1', 0, <int>[1, 2, 3]));
      expect(receiver.received, 3);
      expect(names(), <String>['report.pdf.part']);

      await receiver.accept(chunk('x1', 3, <int>[4, 5, 6], eof: true));
      final String path = await receiver.complete();

      expect(path, endsWith('report.pdf'));
      expect(File(path).readAsBytesSync(), <int>[1, 2, 3, 4, 5, 6]);
    });

    test('a single-chunk file works', () async {
      final TransferReceiver receiver = await begin(totalSize: 3);

      await receiver.accept(chunk('x1', 0, <int>[7, 8, 9], eof: true));

      expect(File(await receiver.complete()).readAsBytesSync(), <int>[7, 8, 9]);
    });

    test('an empty file completes without any data', () async {
      final TransferReceiver receiver = await begin(totalSize: 0);

      final String path = await receiver.complete();

      expect(File(path).lengthSync(), 0);
      expect(path, endsWith('report.pdf'));
    });

    test('sawEof reports the last chunk', () async {
      final TransferReceiver receiver = await begin(totalSize: 3);

      await receiver.accept(chunk('x1', 0, <int>[1, 2]));
      expect(receiver.sawEof, isFalse);

      await receiver.accept(chunk('x1', 2, <int>[3], eof: true));
      expect(receiver.sawEof, isTrue);
    });

    test('the part path is where the bytes are until the end', () async {
      final TransferReceiver receiver = await begin(totalSize: 2);

      expect(receiver.partPath, endsWith('report.pdf.part'));
      expect(receiver.path, endsWith('report.pdf'));

      await receiver.accept(chunk('x1', 0, <int>[1, 2], eof: true));
      expect(names(), <String>['report.pdf.part']);
      await receiver.complete();
    });
  });

  group('the stream must have no holes and no repeats', () {
    test('a chunk that skips ahead is refused', () async {
      final TransferReceiver receiver = await begin(totalSize: 10);
      await receiver.accept(chunk('x1', 0, <int>[1, 2, 3]));

      // Bytes 3..6 never arrived. Writing this at 3 would leave the file with a
      // hole that nothing downstream could detect.
      await expectLater(
        receiver.accept(chunk('x1', 6, <int>[4, 5, 6])),
        throwsA(isA<FileReceiveException>()),
      );
    });

    test('a replayed chunk is refused', () async {
      final TransferReceiver receiver = await begin(totalSize: 10);
      await receiver.accept(chunk('x1', 0, <int>[1, 2, 3]));

      await expectLater(
        receiver.accept(chunk('x1', 0, <int>[1, 2, 3])),
        throwsA(isA<FileReceiveException>()),
      );
      expect(receiver.received, 3);
    });

    test('a chunk starting from zero after progress is refused', () async {
      final TransferReceiver receiver = await begin(totalSize: 10);
      await receiver.accept(chunk('x1', 0, <int>[1, 2, 3]));

      await expectLater(
        receiver.accept(chunk('x1', 0, <int>[9, 9, 9])),
        throwsA(isA<FileReceiveException>()),
      );
    });

    test('a missing offset is refused', () async {
      final TransferReceiver receiver = await begin(totalSize: 4);

      await expectLater(
        receiver.accept(
          Frame.of(FrameType.fileData, <String, Object?>{'xferId': 'x1'},
              Uint8List.fromList(<int>[1, 2])),
        ),
        throwsA(isA<FileReceiveException>()),
      );
    });
  });

  group('the declared size is the bound', () {
    test('a chunk that overshoots is refused', () async {
      final TransferReceiver receiver = await begin(totalSize: 4);
      await receiver.accept(chunk('x1', 0, <int>[1, 2]));

      await expectLater(
        receiver.accept(chunk('x1', 2, <int>[3, 4, 5])),
        throwsA(isA<FileReceiveException>()),
      );
      expect(receiver.received, 2);
    });

    test('an empty chunk before the end is refused', () async {
      // It would advance nothing but would look like progress if it were
      // counted, and a sender looping on it would hang the transfer for good.
      final TransferReceiver receiver = await begin(totalSize: 4);

      await expectLater(
        receiver.accept(chunk('x1', 0, <int>[])),
        throwsA(isA<FileReceiveException>()),
      );
    });

    test('eof on a file that is not finished is refused', () async {
      final TransferReceiver receiver = await begin(totalSize: 10);

      await expectLater(
        receiver.accept(chunk('x1', 0, <int>[1, 2, 3], eof: true)),
        throwsA(isA<FileReceiveException>()),
      );
      expect(receiver.sawEof, isFalse);
    });

    test('a rejected eof does not let complete through', () async {
      final TransferReceiver receiver = await begin(totalSize: 10);
      await expectLater(
        receiver.accept(chunk('x1', 0, <int>[1, 2, 3], eof: true)),
        throwsA(isA<FileReceiveException>()),
      );

      await expectLater(
        receiver.complete(),
        throwsA(isA<FileReceiveException>()),
      );
    });
  });

  group('completion is not taken on trust', () {
    test('complete before the last chunk is refused', () async {
      final TransferReceiver receiver = await begin(totalSize: 6);
      await receiver.accept(chunk('x1', 0, <int>[1, 2, 3]));

      await expectLater(
        receiver.complete(),
        throwsA(isA<FileReceiveException>()),
      );
      // The bytes survive for the caller to discard deliberately.
      expect(names(), <String>['report.pdf.part']);
    });

    test('complete on an empty transfer with no chunks is refused', () async {
      // Nothing has been sent, so nothing says the file is the empty file the
      // offer claimed rather than one that never started.
      final TransferReceiver receiver = await begin(totalSize: 100);

      await expectLater(
        receiver.complete(),
        throwsA(isA<FileReceiveException>()),
      );
    });

    test('complete twice is refused', () async {
      final TransferReceiver receiver = await begin(totalSize: 1);
      await receiver.accept(chunk('x1', 0, <int>[1], eof: true));
      await receiver.complete();

      await expectLater(
        receiver.complete(),
        throwsA(isA<FileReceiveException>()),
      );
    });

    test('a chunk after completion is refused', () async {
      final TransferReceiver receiver = await begin(totalSize: 1);
      await receiver.accept(chunk('x1', 0, <int>[1], eof: true));
      await receiver.complete();

      await expectLater(
        receiver.accept(chunk('x1', 1, <int>[2])),
        throwsA(isA<FileReceiveException>()),
      );
    });
  });

  group('cancelling leaves nothing behind', () {
    test('cancel deletes the partial file', () async {
      final TransferReceiver receiver = await begin(totalSize: 10);
      await receiver.accept(chunk('x1', 0, <int>[1, 2, 3]));

      await receiver.cancel();

      expect(names(), isEmpty);
    });

    test('cancel after completion keeps the finished file', () async {
      final TransferReceiver receiver = await begin(totalSize: 2);
      await receiver.accept(chunk('x1', 0, <int>[1, 2], eof: true));
      await receiver.complete();

      await receiver.cancel();

      expect(names(), <String>['report.pdf']);
    });

    test('cancel before any chunk is harmless', () async {
      final TransferReceiver receiver = await begin(totalSize: 10);

      await receiver.cancel();
      await receiver.cancel();

      expect(names(), isEmpty);
    });

    test('a chunk after cancel is refused', () async {
      final TransferReceiver receiver = await begin(totalSize: 10);
      await receiver.cancel();

      await expectLater(
        receiver.accept(chunk('x1', 0, <int>[1])),
        throwsA(isA<FileReceiveException>()),
      );
    });
  });

  group('frames that are not this transfer', () {
    test('a chunk for another transfer is refused', () async {
      // Splicing two transfers into one file would produce a file neither side
      // ever sent, and both would report success.
      final TransferReceiver receiver = await begin(xferId: 'x1', totalSize: 6);

      await expectLater(
        receiver.accept(chunk('x2', 0, <int>[1, 2, 3])),
        throwsA(isA<FileReceiveException>()),
      );
    });

    test('a chunk with no xferId is refused', () async {
      final TransferReceiver receiver = await begin(totalSize: 6);

      await expectLater(
        receiver.accept(
          Frame.of(FrameType.fileData, <String, Object?>{'offset': 0},
              Uint8List.fromList(<int>[1, 2, 3])),
        ),
        throwsA(isA<FileReceiveException>()),
      );
    });

    test('a control frame is refused', () async {
      final TransferReceiver receiver = await begin(totalSize: 6);

      await expectLater(
        receiver.accept(
          Frame.of(FrameType.fileDone, <String, Object?>{'xferId': 'x1'}),
        ),
        throwsA(isA<FileReceiveException>()),
      );
    });
  });

  group('one file of a folder is not another file of it', () {
    // §4.6 rule 3 gives every file in a folder the same `xferId`, so the check
    // above lets a sibling's chunks straight through. Without this one they
    // would be spliced into the file being written — producing a file of the
    // right length that neither side ever sent, which is exactly the failure the
    // `xferId` check exists to prevent one level up.
    test('chunks naming this file are accepted', () async {
      final TransferReceiver receiver =
          await begin(totalSize: 6, relPath: 'sub/a.txt');

      await receiver.accept(chunk('x1', 0, <int>[1, 2, 3], relPath: 'sub/a.txt'));
      await receiver.accept(chunk('x1', 3, <int>[4, 5, 6],
          eof: true, relPath: 'sub/a.txt'));

      expect(receiver.received, 6);
    });

    test('a chunk for a sibling is refused', () async {
      final TransferReceiver receiver =
          await begin(totalSize: 6, relPath: 'sub/a.txt');

      await expectLater(
        receiver.accept(chunk('x1', 0, <int>[9, 9, 9], relPath: 'sub/b.txt')),
        throwsA(isA<FileReceiveException>()),
      );
      expect(receiver.received, 0);
    });

    test('a chunk with no relPath at all is refused', () async {
      // What a sender that lost track of which file it was on would send, and
      // the reason the check is equality rather than "if both are present".
      final TransferReceiver receiver =
          await begin(totalSize: 6, relPath: 'sub/a.txt');

      await expectLater(
        receiver.accept(chunk('x1', 0, <int>[1, 2, 3])),
        throwsA(isA<FileReceiveException>()),
      );
    });

    test('a single file refuses a chunk that claims to be in a folder',
        () async {
      // The other direction, and the same splice: a plain file transfer has no
      // folder for a relPath to be inside.
      final TransferReceiver receiver = await begin(totalSize: 6);

      await expectLater(
        receiver.accept(chunk('x1', 0, <int>[1, 2, 3], relPath: 'sub/a.txt')),
        throwsA(isA<FileReceiveException>()),
      );
    });

    test('a whole file of a folder still arrives', () async {
      final Directory sub =
          Directory('${dir.path}${Platform.pathSeparator}sub')
            ..createSync(recursive: true);
      final TransferReceiver receiver = await begin(
        totalSize: 3,
        name: 'a.txt',
        relPath: 'sub/a.txt',
        into: sub,
      );

      await receiver.accept(
          chunk('x1', 0, <int>[7, 8, 9], eof: true, relPath: 'sub/a.txt'));
      final String path = await receiver.complete();

      expect(File(path).readAsBytesSync(), <int>[7, 8, 9]);
    });
  });

  group('the name is sanitised on the way in', () {
    test('a traversing name lands inside the directory', () async {
      final TransferReceiver receiver =
          await begin(name: '../../../evil.sh', totalSize: 2);
      await receiver.accept(chunk('x1', 0, <int>[1, 2], eof: true));

      final String path = await receiver.complete();

      expect(path, endsWith('evil.sh'));
      expect(File(path).absolute.path.startsWith(dir.absolute.path), isTrue);
    });

    test('a colliding name is numbered rather than overwritten', () async {
      File('${dir.path}${Platform.pathSeparator}report.pdf')
          .writeAsStringSync('original');

      final TransferReceiver receiver = await begin(totalSize: 2);
      await receiver.accept(chunk('x1', 0, <int>[1, 2], eof: true));

      expect(await receiver.complete(), endsWith('report (1).pdf'));
      expect(File('${dir.path}/report.pdf').readAsStringSync(), 'original');
    });
  });

  test('a large file arrives whole across many chunks', () async {
    // Enough chunks that a single misplaced offset would be visible in the
    // content rather than only in the length.
    const int size = 512 * 1024;
    final Uint8List original = Uint8List(size);
    for (int i = 0; i < size; i++) {
      original[i] = i % 251;
    }

    final TransferReceiver receiver = await begin(totalSize: size);
    const int step = 32 * 1024;
    for (int offset = 0; offset < size; offset += step) {
      await receiver.accept(
        chunk('x1', offset, original.sublist(offset, offset + step),
            eof: offset + step >= size),
      );
    }

    final String path = await receiver.complete();
    expect(File(path).readAsBytesSync(), original);
  });
}
