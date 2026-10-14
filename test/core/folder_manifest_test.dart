import 'dart:convert';
import 'dart:io';

import 'package:feijian/core/constants.dart';
import 'package:feijian/core/models/manifest_entry.dart';
import 'package:feijian/core/transfer/folder_manifest.dart';
import 'package:flutter_test/flutter_test.dart';

/// These tests build a real tree on disk and walk it, because the thing under
/// test is what a file system actually contains — an empty directory that
/// survives a listing, a symlink that is or is not followed. A faked listing
/// would agree with whatever the walker believed.
void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('feijian_manifest_');
  });

  tearDown(() {
    if (root.existsSync()) {
      root.deleteSync(recursive: true);
    }
  });

  /// Makes `root/<relPath>`; a path ending in `/` is a directory.
  File makeFile(String relPath, {String contents = 'x', DateTime? modified}) {
    final File file = File(_join(root.path, relPath));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(contents);
    if (modified != null) {
      file.setLastModifiedSync(modified);
    }
    return file;
  }

  Directory makeDir(String relPath) {
    final Directory dir = Directory(_join(root.path, relPath));
    dir.createSync(recursive: true);
    return dir;
  }

  Future<FolderManifest> walk() => FolderManifest.walk(root);

  /// relPath -> entry, for asserting on a tree without depending on order.
  Map<String, ManifestEntry> byPath(FolderManifest manifest) => <String,
      ManifestEntry>{
    for (final ManifestEntry entry in manifest.entries) entry.relPath: entry,
  };

  group('the walk finds what is there', () {
    test('a nested tree comes out with every file', () async {
      makeFile('a.txt');
      makeFile('photos/holiday.jpg');
      makeFile('photos/2024/beach.jpg');

      final FolderManifest manifest = await walk();

      expect(
        byPath(manifest).keys,
        unorderedEquals(<String>[
          'a.txt',
          'photos',
          'photos/holiday.jpg',
          'photos/2024',
          'photos/2024/beach.jpg',
        ]),
      );
      // The directories are in the manifest but are not files.
      expect(manifest.fileCount, 3);
    });

    test('directories are entries of their own', () async {
      makeDir('photos/2024');
      makeFile('photos/holiday.jpg');

      final FolderManifest manifest = await walk();

      expect(byPath(manifest)['photos']?.isDir, isTrue);
      expect(byPath(manifest)['photos/2024']?.isDir, isTrue);
      expect(byPath(manifest)['photos/holiday.jpg']?.isDir, isFalse);
    });

    test('an empty directory is in the manifest', () async {
      // The receiver has nothing else to reconstruct it from: a directory with
      // no files in it produces no file entries, so if the walk dropped it the
      // folder would arrive one directory short (§4.6 rule 4).
      makeDir('empty');
      makeFile('a.txt');

      final FolderManifest manifest = await walk();

      expect(byPath(manifest)['empty']?.isDir, isTrue);
      expect(byPath(manifest)['empty']?.size, 0);
    });

    test('an empty folder is a manifest with nothing in it', () async {
      final FolderManifest manifest = await walk();

      expect(manifest.entries, isEmpty);
      expect(manifest.fileCount, 0);
      expect(manifest.totalSize, 0);
    });

    test('the folder\'s own name is the last component of its path', () async {
      makeFile('a.txt');
      final FolderManifest manifest = await walk();

      expect(manifest.name, root.path.split(Platform.pathSeparator).last);
    });
  });

  group('sizes and times', () {
    test('totalSize adds the files and ignores the directories', () async {
      makeFile('a.txt', contents: 'aaaa'); // 4
      makeFile('b/c.txt', contents: 'ccc'); // 3
      makeDir('b/empty');

      final FolderManifest manifest = await walk();

      expect(byPath(manifest)['b']?.size, 0);
      expect(byPath(manifest)['b/empty']?.size, 0);
      expect(manifest.totalSize, 7);
    });

    test('a zero-byte file is a file and counts as one', () async {
      makeFile('empty.txt', contents: '');

      final FolderManifest manifest = await walk();

      expect(manifest.fileCount, 1);
      expect(manifest.totalSize, 0);
      expect(byPath(manifest)['empty.txt']?.size, 0);
    });

    test('mtime is carried for a file', () async {
      final DateTime when = DateTime.fromMillisecondsSinceEpoch(1700000000000);
      makeFile('a.txt', modified: when);

      final FolderManifest manifest = await walk();

      expect(byPath(manifest)['a.txt']?.mtime, when.millisecondsSinceEpoch);
    });

    test('a directory has no mtime to carry', () async {
      makeDir('sub');
      makeFile('sub/a.txt');

      final FolderManifest manifest = await walk();

      expect(byPath(manifest)['sub']?.mtime, isNull);
    });
  });

  group('separators', () {
    test('relPaths are /-separated whatever the platform uses', () async {
      makeFile('a/b/c.txt');

      final FolderManifest manifest = await walk();

      expect(byPath(manifest).keys, contains('a/b/c.txt'));
      for (final String relPath in byPath(manifest).keys) {
        expect(relPath, isNot(contains(r'\')));
      }
    });

    test('no relPath is absolute or starts at the root', () async {
      makeFile('a/b/c.txt');

      final FolderManifest manifest = await walk();

      for (final ManifestEntry entry in manifest.entries) {
        expect(entry.relPath, isNot(startsWith('/')));
        expect(entry.relPath, isNot(startsWith(Platform.pathSeparator)));
        expect(entry.relPath, isNotEmpty);
      }
    });
  });

  group('what it will not send', () {
    test('a symlink is skipped and counted rather than followed', () async {
      makeFile('real.txt', contents: 'hello');
      final Link link = Link(_join(root.path, 'shortcut'));
      try {
        link.createSync(_join(root.path, 'real.txt'));
      } on FileSystemException {
        // Creating a link needs a privilege Windows does not always grant.
        return;
      }

      final FolderManifest manifest = await walk();

      expect(byPath(manifest).keys, <String>['real.txt']);
      expect(manifest.skipped, 1);
      expect(manifest.fileCount, 1);
    });
  });

  group('the manifest is bounded', () {
    test('the default ceiling is the 256 KB the design names', () {
      // §4.6 rule 5. The default is what production uses, so it is the one
      // worth pinning: a test that always passes its own limit would go on
      // passing while the real one drifted.
      expect(kMaxManifestBytes, 256 * 1024);
    });

    test('a tree under the default ceiling walks', () async {
      for (int i = 0; i < 20; i++) {
        makeFile('f$i.txt');
      }

      final FolderManifest manifest = await walk();

      expect(manifest.fileCount, 20);
    });

    test('a manifest that passes the limit is refused, not truncated', () async {
      // Refused rather than cut short: a truncated manifest describes some of
      // the folder, so the transfer arrives looking complete and is missing
      // files — the one outcome §4.6 rule 5 exists to avoid.
      for (int i = 0; i < 40; i++) {
        makeFile('file-with-a-fairly-long-name-$i.txt');
      }

      await expectLater(
        FolderManifest.walk(root, maxBytes: 300),
        throwsA(isA<FolderTooLargeException>()),
      );
    });

    test('the refusal says how far it got and what the limit was', () async {
      for (int i = 0; i < 40; i++) {
        makeFile('file-with-a-fairly-long-name-$i.txt');
      }

      try {
        await FolderManifest.walk(root, maxBytes: 300);
        fail('expected the walk to refuse a manifest over 300 bytes');
      } on FolderTooLargeException catch (error) {
        expect(error.limit, 300);
        expect(error.bytes, greaterThan(300));
      }
    });

    test('an empty folder is never too large', () async {
      final FolderManifest manifest = await FolderManifest.walk(root,
          maxBytes: 1);

      expect(manifest.entries, isEmpty);
    });
  });

  group('the order is the same every time', () {
    test('entries come out sorted by relPath', () async {
      makeFile('z.txt');
      makeFile('a.txt');
      makeFile('m/n.txt');

      final FolderManifest manifest = await walk();
      final List<String> paths = manifest.entries
          .map((ManifestEntry e) => e.relPath)
          .toList(growable: false);

      expect(paths, List<String>.of(paths)..sort());
    });

    test('two walks of one tree agree exactly', () async {
      makeFile('b.txt');
      makeFile('a/c.txt');
      makeDir('a/d');

      final FolderManifest first = await walk();
      final FolderManifest second = await walk();

      expect(
        first.entries.map((ManifestEntry e) => e.relPath),
        second.entries.map((ManifestEntry e) => e.relPath),
      );
      expect(first.totalSize, second.totalSize);
    });
  });

  group('what goes on the wire', () {
    test('an entry encodes the four fields the offer names', () {
      const ManifestEntry entry = ManifestEntry(
        relPath: 'a/b.txt',
        size: 12,
        mtime: 1700000000000,
      );

      expect(entry.toJson(), <String, Object?>{
        'relPath': 'a/b.txt',
        'size': 12,
        'mtime': 1700000000000,
      });
    });

    test('a directory says so, and carries no time', () {
      const ManifestEntry entry = ManifestEntry(relPath: 'a', size: 0, isDir: true);

      expect(entry.toJson(), <String, Object?>{
        'relPath': 'a',
        'size': 0,
        'isDir': true,
      });
    });

    test('an entry survives a round trip through JSON', () {
      const ManifestEntry entry = ManifestEntry(
        relPath: 'photos/2024/holiday.jpg',
        size: 4096,
        mtime: 1700000000000,
      );

      final Map<String, Object?> decoded =
          jsonDecode(jsonEncode(entry.toJson())) as Map<String, Object?>;

      expect(decoded['relPath'], entry.relPath);
      expect(decoded['size'], entry.size);
      expect(decoded['mtime'], entry.mtime);
      expect(decoded['isDir'], isNull);
    });
  });
}

String _join(String root, String relPath) =>
    <String>[root, ...relPath.split('/')].join(Platform.pathSeparator);
