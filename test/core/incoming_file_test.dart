import 'dart:async';
import 'dart:io';

import 'package:feijian/core/transfer/incoming_file.dart';
import 'package:feijian/core/transfer/safe_name.dart';
import 'package:flutter_test/flutter_test.dart';

/// These tests use a real directory, because the thing being tested is what the
/// filesystem ends up holding. A mocked `File` would agree with whatever the
/// code believed and would prove nothing about a rename landing or a `.part`
/// being cleaned up.
void main() {
  late Directory dir;

  /// Every sink this file opens, so cleanup can close the ones a test left open
  /// on purpose.
  late List<IncomingFile> opened;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('feijian_incoming_');
    opened = <IncomingFile>[];
  });

  tearDown(() async {
    // A sink still holding its handle blocks deletion on Windows. Most tests
    // finish or abandon their own, but several are about what happens when
    // neither runs — and those would otherwise take the temp directory with
    // them. That the caller has to close every path is the point of the class,
    // not an accident of this harness.
    for (final IncomingFile sink in opened) {
      await sink.abandon();
    }
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
  });

  List<String> names() => dir
      .listSync()
      .map((FileSystemEntity e) => e.path.split(Platform.pathSeparator).last)
      .toList()
    ..sort();

  Future<IncomingFile> open(
    String name, {
    int totalSize = 0,
    Directory? into,
  }) async {
    final IncomingFile sink = await IncomingFile.create(
      directory: into ?? dir,
      rawName: name,
      totalSize: totalSize,
    );
    opened.add(sink);
    return sink;
  }

  group('the file appears only when it is whole', () {
    test('writes land in a .part that the user never sees', () async {
      final IncomingFile sink = await open('report.pdf', totalSize: 5);

      await sink.write(<int>[1, 2, 3]);

      expect(names(), <String>['report.pdf.part']);
      expect(sink.received, 3);
      expect(sink.isComplete, isFalse);
    });

    test('finish installs it under the real name with the real bytes',
        () async {
      final IncomingFile sink = await open('report.pdf', totalSize: 5);
      await sink.write(<int>[1, 2, 3]);
      await sink.write(<int>[4, 5]);

      final String path = await sink.finish();

      expect(names(), <String>['report.pdf']);
      expect(await File(path).readAsBytes(), <int>[1, 2, 3, 4, 5]);
    });

    test('a chunk larger than one read is written whole', () async {
      // What the peer actually sends: 256 KiB frames, several per second.
      final List<int> big = List<int>.generate(300000, (int i) => i % 251);
      final IncomingFile sink = await open('big.bin', totalSize: big.length);

      await sink.write(big);

      expect(await File(await sink.finish()).readAsBytes(), big);
    });

    test('an empty chunk is accepted and changes nothing', () async {
      final IncomingFile sink = await open('empty.bin', totalSize: 0);
      await sink.write(<int>[]);
      expect(await File(await sink.finish()).length(), 0);
    });
  });

  group('an existing file is never overwritten', () {
    test('a second file of the same name is numbered', () async {
      File('${dir.path}${Platform.pathSeparator}report.pdf')
          .writeAsStringSync('first');

      final IncomingFile sink = await open('report.pdf', totalSize: 6);
      await sink.write(<int>[0, 1, 2, 3, 4, 5]);
      final String path = await sink.finish();

      expect(path, endsWith('report (1).pdf'));
      expect(File('${dir.path}/report.pdf').readAsStringSync(), 'first');
    });

    test('numbering walks up past every name already taken', () async {
      for (final String name in <String>['a.txt', 'a (1).txt', 'a (2).txt']) {
        File('${dir.path}${Platform.pathSeparator}$name')
            .writeAsStringSync('x');
      }

      final IncomingFile sink = await open('a.txt', totalSize: 0);
      expect(await sink.finish(), endsWith('a (3).txt'));
    });

    test('the number goes before the extension', () async {
      File('${dir.path}${Platform.pathSeparator}holiday.jpg.tar.gz')
          .writeAsStringSync('x');

      final IncomingFile sink = await open('holiday.jpg.tar.gz', totalSize: 0);
      expect(await sink.finish(), endsWith('holiday.jpg.tar (1).gz'));
    });

    test('a name with no extension is numbered at the end', () async {
      File('${dir.path}${Platform.pathSeparator}Makefile')
          .writeAsStringSync('x');

      final IncomingFile sink = await open('Makefile', totalSize: 0);
      expect(await sink.finish(), endsWith('Makefile (1)'));
    });

    test('a hidden file is numbered whole, dot kept', () async {
      // `.gitignore` has no extension to insert before, and the leading dot has
      // to survive — `.gitignore (1)` is a hidden file, `gitignore (1)` is not.
      File('${dir.path}${Platform.pathSeparator}.gitignore')
          .writeAsStringSync('x');

      final IncomingFile sink = await open('.gitignore', totalSize: 0);
      expect(await sink.finish(), endsWith('.gitignore (1)'));
    });

    test('a leftover .part does not reserve the name', () async {
      // An earlier attempt at the same file was cancelled. Its debris must not
      // push this transfer to `report (1).pdf` when `report.pdf` is free.
      File('${dir.path}${Platform.pathSeparator}report.pdf.part')
          .writeAsStringSync('stale');

      final IncomingFile sink = await open('report.pdf', totalSize: 2);
      await sink.write(<int>[7, 8]);

      expect(await sink.finish(), endsWith('report.pdf'));
      expect(File('${dir.path}/report.pdf').readAsBytesSync(), <int>[7, 8]);
    });
  });

  group('cancelling leaves nothing behind', () {
    test('abandon deletes the partial file', () async {
      final IncomingFile sink = await open('report.pdf', totalSize: 100);
      await sink.write(<int>[1, 2, 3]);

      await sink.abandon();

      expect(names(), isEmpty);
    });

    test('abandon after finish keeps the finished file', () async {
      final IncomingFile sink = await open('report.pdf', totalSize: 1);
      await sink.write(<int>[1]);
      await sink.finish();

      await sink.abandon();

      expect(names(), <String>['report.pdf']);
    });

    test('abandon twice is harmless', () async {
      final IncomingFile sink = await open('report.pdf', totalSize: 1);
      await sink.abandon();
      await sink.abandon();

      expect(names(), isEmpty);
    });

    test('two cancels landing a turn apart still delete the .part', () async {
      // A cancel from the user and the peer's own `file_cancel` travel in
      // different directions and meet here; so does a dead data socket. They do
      // not arrive in the same turn — each comes off its own stream — so the
      // second one starts while the first is already inside its delete, and two
      // deletes over one name is a `PathAccessException` out of a cancel that
      // did exactly what it was asked to.
      //
      // The race is a race, so it is run rather than performed once: one turn of
      // separation lands the second teardown inside the first's delete most of
      // the time, and repeating it makes that "most" into "always" without
      // lengthening the test in any way a reader would notice.
      for (int attempt = 0; attempt < 20; attempt++) {
        final IncomingFile sink = await open('both.bin', totalSize: 4);
        await sink.write(<int>[1, 2, 3, 4]);

        final Future<void> first = sink.abandon();
        // One turn: enough for the first teardown to be past its close and into
        // the delete, which is where the second one finds it.
        await Future<void>.delayed(Duration.zero);
        await sink.abandon();
        await first;

        expect(names(), isEmpty,
            reason: 'attempt $attempt left a .part behind');
        for (final FileSystemEntity entity in dir.listSync()) {
          entity.deleteSync(recursive: true);
        }
      }
    });

    test('a cancel arriving while the file is being finished keeps the file',
        () async {
      // The two endings meet: the last chunk has landed and [finish] is
      // installing the file, and the user presses cancel inside that window.
      // They cannot both happen, and the wrong winner is silent — on Windows a
      // delete is a property of the file rather than of the name, so a delete
      // issued against `both.bin.part` while the rename is in flight takes
      // `both.bin` with it. The transfer reports success and the user's file is
      // not there.
      //
      // The bytes are what makes this repeatable: a 2 MB write leaves the flush
      // that follows it with real work to do, so the cancel lands inside the
      // install every time rather than sometimes.
      final IncomingFile sink = await open('both.bin', totalSize: 2 << 20);
      await sink.write(List<int>.filled(2 << 20, 4));

      final Future<String> installed = sink.finish();
      await sink.abandon();

      expect(await installed, endsWith('both.bin'));
      expect(names(), <String>['both.bin']);
    });

    test('abandon is not asked to delete a file finish already installed',
        () async {
      // The same window reached from the other side, and the case that decides
      // which ending the pair is allowed to produce. Whoever gets there first
      // ends the transfer; the other one finds it over. Here that is the cancel,
      // so the install must fail rather than publish a file next to a `cancelled`
      // row — and it must fail in the caller's own vocabulary, not with a
      // `PathNotFoundException` from the rename that has been left to run.
      final IncomingFile sink = await open('both.bin', totalSize: 2 << 20);
      await sink.write(List<int>.filled(2 << 20, 5));

      await sink.abandon();

      await expectLater(
        sink.finish(),
        throwsA(isA<IncomingFileException>()),
      );
      expect(names(), isEmpty);
    });

    test('abandon still cleans up after an install that failed', () async {
      // The install can fail after it has closed the handle: the name it picked
      // when the transfer began is taken by the time it renames. The `.part` is
      // still there afterwards and [abandon] is the only thing that can remove
      // it, so that path has to work — which means the close has to be safe to
      // repeat, and an install that published nothing must not be read as an
      // ending that already happened.
      final IncomingFile sink = await open('taken.bin', totalSize: 2);
      await sink.write(<int>[1, 2]);
      // A directory rather than a file, so this fails for certain: renaming a
      // file onto an existing file may replace it, but not onto a directory.
      Directory('${dir.path}${Platform.pathSeparator}taken.bin').createSync();

      await expectLater(sink.finish(), throwsA(isA<FileSystemException>()));
      await sink.abandon();

      expect(names(), <String>['taken.bin'],
          reason: 'the .part went, and the intruder was left alone');
    });

    test('abandoning a sink that is mid-write still deletes the .part',
        () async {
      // `RandomAccessFile.close()` throws rather than waits when another
      // operation is pending on the handle — "an async operation is currently
      // pending" — and a cancel arrives whenever the user presses it, including
      // between a chunk being handed to the disk and the disk taking it. An
      // abandon that throws on the way to its own delete leaves the `.part`
      // sitting in the user's folder: 取消后无残留 would hold only when the
      // cancel happened to be well timed.
      final IncomingFile sink = await open('midwrite.bin', totalSize: 1 << 20);

      // Issued and deliberately not awaited. Nothing has yielded to the event
      // loop since, so the write cannot have finished — the cancel lands on a
      // pending handle every time rather than on a lucky one.
      unawaited(sink.write(List<int>.filled(1 << 20, 7)));

      await sink.abandon();

      expect(names(), isEmpty);
      // And the directory goes too: on Windows an unreleased handle would keep
      // the `.part` un-deletable, so this is the assertion that the handle is
      // really gone rather than merely renamed around.
      dir.deleteSync(recursive: true);
      expect(dir.existsSync(), isFalse);
    });
  });

  group('the declared size is enforced, not trusted', () {
    test('a chunk that would overshoot is refused', () async {
      final IncomingFile sink = await open('report.pdf', totalSize: 5);
      await sink.write(<int>[1, 2, 3]);

      await expectLater(
        sink.write(<int>[4, 5, 6]),
        throwsA(isA<IncomingFileException>()),
      );
      // Nothing of the refused chunk reached the disk.
      expect(await File(sink.partPath).length(), 3);
    });

    test('a peer that keeps sending after the last byte is refused', () async {
      final IncomingFile sink = await open('report.pdf', totalSize: 2);
      await sink.write(<int>[1, 2]);

      await expectLater(
        sink.write(<int>[3]),
        throwsA(isA<IncomingFileException>()),
      );
    });

    test('exactly the declared size is accepted', () async {
      final IncomingFile sink = await open('report.pdf', totalSize: 3);
      await sink.write(<int>[1, 2, 3]);
      expect(sink.isComplete, isTrue);
      expect(await sink.finish(), endsWith('report.pdf'));
    });

    test('finishing a short file is refused and keeps the .part', () async {
      final IncomingFile sink = await open('report.pdf', totalSize: 100);
      await sink.write(<int>[1, 2, 3]);

      await expectLater(sink.finish(), throwsA(isA<IncomingFileException>()));

      // The bytes are still there for the caller to discard deliberately — a
      // truncated file renamed into place would look whole.
      expect(names(), <String>['report.pdf.part']);
    });

    test('a negative size is refused before anything is created', () async {
      await expectLater(
        open('report.pdf', totalSize: -1),
        throwsA(isA<IncomingFileException>()),
      );
      expect(names(), isEmpty);
    });
  });

  group('a closed sink stays closed', () {
    test('writing after finish is refused', () async {
      final IncomingFile sink = await open('report.pdf', totalSize: 1);
      await sink.write(<int>[1]);
      await sink.finish();

      await expectLater(
        sink.write(<int>[2]),
        throwsA(isA<IncomingFileException>()),
      );
    });

    test('writing after abandon is refused', () async {
      final IncomingFile sink = await open('report.pdf', totalSize: 10);
      await sink.abandon();

      await expectLater(
        sink.write(<int>[1]),
        throwsA(isA<IncomingFileException>()),
      );
    });

    test('finishing twice is refused', () async {
      final IncomingFile sink = await open('report.pdf', totalSize: 1);
      await sink.write(<int>[1]);
      await sink.finish();

      await expectLater(sink.finish(), throwsA(isA<IncomingFileException>()));
    });
  });

  group('hostile names cannot escape the directory', () {
    test('a traversing name lands inside the directory', () async {
      final Directory nested =
          Directory('${dir.path}${Platform.pathSeparator}inbox');

      final IncomingFile sink = await IncomingFile.create(
        directory: nested,
        rawName: '../../../evil.txt',
        totalSize: 1,
      );
      await sink.write(<int>[1]);
      final String path = await sink.finish();

      expect(path.split(Platform.pathSeparator).last, 'evil.txt');
      expect(
        File(path).absolute.path.startsWith(nested.absolute.path),
        isTrue,
        reason: 'landed at $path',
      );
    });

    test('an absolute path is reduced to its basename', () async {
      final IncomingFile sink =
          await open(r'C:\Windows\System32\evil.dll', totalSize: 0);
      expect(await sink.finish(), endsWith('evil.dll'));
      expect(names(), <String>['evil.dll']);
    });

    test('a name with nothing usable left still produces a file', () async {
      final IncomingFile sink = await open('../..', totalSize: 0);
      expect(await sink.finish(), endsWith(SafeName.fallback));
    });
  });

  test('the destination directory is created if it is missing', () async {
    final Directory nested = Directory(
        '${dir.path}${Platform.pathSeparator}a${Platform.pathSeparator}b');

    final IncomingFile sink = await IncomingFile.create(
        directory: nested, rawName: 'x.txt', totalSize: 0);

    expect(await sink.finish(), endsWith('x.txt'));
    expect(nested.existsSync(), isTrue);
  });

  test('the part path is the destination path plus .part', () async {
    final IncomingFile sink = await open('report.pdf', totalSize: 0);

    expect(sink.path, endsWith('report.pdf'));
    expect(sink.partPath, '${sink.path}.part');
    await sink.abandon();
  });
}
