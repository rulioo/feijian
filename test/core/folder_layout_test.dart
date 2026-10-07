import 'dart:io';

import 'package:feijian/core/transfer/folder_layout.dart';
import 'package:flutter_test/flutter_test.dart';

/// Every path here comes from another machine. What this file is about is that
/// the only thing the receiver does with one is join it onto a directory it
/// chose — never to follow it.
void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('feijian_layout_');
  });

  tearDown(() {
    if (root.existsSync()) {
      root.deleteSync(recursive: true);
    }
  });

  String join(String relative) =>
      '${root.path}${Platform.pathSeparator}'
      '${relative.replaceAll('/', Platform.pathSeparator)}';

  bool exists(String relative, {bool asDirectory = false}) {
    final String path = join(relative);
    return asDirectory
        ? Directory(path).existsSync()
        : FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound;
  }

  group('a file target is a directory and one name', () {
    test('a nested file goes in the directory it names', () {
      final FolderTarget? target = FolderLayout.fileTarget(root, 'sub/a.txt');

      expect(target, isNotNull);
      expect(target!.name, 'a.txt');
      expect(target.directory.path, join('sub'));
      expect(target.directory.existsSync(), isTrue);
    });

    test('a top-level file goes in the root itself', () {
      final FolderTarget? target = FolderLayout.fileTarget(root, 'a.txt');

      expect(target!.directory.path, root.path);
      expect(target.name, 'a.txt');
    });

    test('every level above the file is created', () {
      // A manifest lists directories as well, but the file's own path is what
      // the receiver acts on when the file's turn comes — and a sender that
      // listed only files would otherwise fail here rather than land.
      final FolderTarget? target =
          FolderLayout.fileTarget(root, 'a/b/c/d.txt');

      expect(target!.directory.path, join('a/b/c'));
      expect(exists('a/b/c', asDirectory: true), isTrue);
    });

    test('the name is one component, with the separator of this platform', () {
      // The peer's `/` is not this platform's separator on Windows, so a caller
      // that stored [FolderTarget.name] and joined it by hand would produce a
      // file called `sub/a.txt` — which Windows reads as a path.
      final FolderTarget? target = FolderLayout.fileTarget(root, 'sub/a.txt');

      expect(target!.name, isNot(contains('/')));
      expect(target.name, isNot(contains(r'\')));
    });
  });

  group('an empty directory is created', () {
    test('a directory with nothing in it is still a directory', () {
      // §4.6 rule 4. The structure is part of what was sent; a directory the
      // sender has and the receiver does not is a difference the user would
      // have to rebuild by hand.
      final Directory? made = FolderLayout.createDirectory(root, 'empty');

      expect(made, isNotNull);
      expect(exists('empty', asDirectory: true), isTrue);
      expect(join('empty'), made!.path);
    });

    test('a nested directory brings its parents', () {
      FolderLayout.createDirectory(root, 'a/b/c');

      expect(exists('a', asDirectory: true), isTrue);
      expect(exists('a/b', asDirectory: true), isTrue);
      expect(exists('a/b/c', asDirectory: true), isTrue);
    });

    test('creating one that is already there is not an error', () {
      // Two manifest entries can share a parent — every file in a folder does.
      FolderLayout.createDirectory(root, 'sub');
      FolderLayout.createDirectory(root, 'sub');

      expect(exists('sub', asDirectory: true), isTrue);
    });

    test('the root is created if it is not there yet', () {
      final Directory fresh =
          Directory('${root.path}${Platform.pathSeparator}downloads');

      final Directory? made = FolderLayout.createDirectory(fresh, 'a');

      expect(made!.path, '${fresh.path}${Platform.pathSeparator}a');
      expect(fresh.existsSync(), isTrue);
    });
  });

  group('the peer cannot leave the download root', () {
    test('a traversing path is dropped, not followed', () {
      // The `..` segments vanish rather than being kept and then cancelled: the
      // file the peer named becomes `etc/shadow` under the root, which is what
      // `SafeName.relPath` reports for the same string and so what the row will
      // say the file's place in the folder is.
      final FolderTarget? target =
          FolderLayout.fileTarget(root, '../../etc/shadow');

      expect(target!.directory.path, join('etc'));
      expect(target.name, 'shadow');
      expect(target.directory.path.startsWith(root.path), isTrue);
    });

    test('a traversal in the middle is dropped too', () {
      final FolderTarget? target = FolderLayout.fileTarget(root, 'a/../b.txt');

      expect(target!.directory.path, join('a'));
      expect(target.name, 'b.txt');
    });

    test('an absolute path becomes a path under the root', () {
      final Directory? made = FolderLayout.createDirectory(root, '/etc/passwd');

      expect(made!.path, join('etc/passwd'));
      expect(made.path.startsWith(root.path), isTrue);
    });

    test('a drive letter is an ordinary component', () {
      // `C:` stripped of its colon is a directory called `C` under the root —
      // never the C drive.
      final FolderTarget? target =
          FolderLayout.fileTarget(root, r'C:\Users\me\notes.txt');

      expect(target!.directory.path, join('C/Users/me'));
      expect(target.directory.path.startsWith(root.path), isTrue);
    });

    test('a UNC path is an ordinary path under the root', () {
      final FolderTarget? target =
          FolderLayout.fileTarget(root, r'\\server\share\evil.txt');

      expect(target!.directory.path, join('server/share'));
      expect(target.directory.path.startsWith(root.path), isTrue);
    });
  });

  group('a path that names no place is refused', () {
    test('nothing but traversal gives nothing back', () {
      // Not an empty folder and not the root: an entry like this is a broken or
      // hostile sender, and the caller's answer is to refuse the whole folder
      // (§4.6 rule 5) rather than to receive one short of its manifest.
      expect(FolderLayout.fileTarget(root, '..'), isNull);
      expect(FolderLayout.fileTarget(root, '.'), isNull);
      expect(FolderLayout.fileTarget(root, ''), isNull);
      expect(FolderLayout.fileTarget(root, '///'), isNull);
      expect(FolderLayout.createDirectory(root, '..'), isNull);
    });

    test('one level past the depth limit is refused', () {
      final String deep = List<String>.filled(33, 'a').join('/');
      final String justInside = List<String>.filled(32, 'a').join('/');

      expect(FolderLayout.createDirectory(root, deep), isNull);
      expect(FolderLayout.createDirectory(root, justInside), isNotNull);
    });

    test('a long path is refused even at a shallow depth', () {
      // Each component is capped on its own, so the total is only reachable by
      // having many of them — which is why the byte limit and the depth limit
      // are both here.
      final String long = List<String>.filled(9, 'a' * 200).join('/');

      expect(FolderLayout.fileTarget(root, long), isNull);
    });

    test('a refused path creates nothing', () {
      FolderLayout.fileTarget(root, '..');
      FolderLayout.fileTarget(root, List<String>.filled(40, 'a').join('/'));

      expect(root.listSync(), isEmpty);
    });
  });

  group('a name the platform will not create', () {
    test('a reserved device name is still a directory', () {
      final Directory? made = FolderLayout.createDirectory(root, 'aux');

      expect(made!.path, join('_aux'));
    });

    test('a name with a colon loses it', () {
      // Valid on Linux, not on Windows, and the same transfer has to land on
      // both — so the colon goes regardless of which end is running.
      final FolderTarget? target = FolderLayout.fileTarget(root, 'a:b.txt');

      expect(target!.name, 'ab.txt');
    });
  });

  group('when the file system refuses', () {
    test('a file in the way of a directory throws rather than becoming a path',
        () {
      // The sender is fine and the name is fine; this device simply cannot do
      // it. Kept distinct from the null above so the caller can tell a broken
      // manifest from a full disk.
      File(join('sub')).writeAsStringSync('not a directory');

      expect(
        () => FolderLayout.fileTarget(root, 'sub/a.txt'),
        throwsA(isA<FileSystemException>()),
      );
      // And nothing was written over the file that was in the way.
      expect(File(join('sub')).readAsStringSync(), 'not a directory');
    });
  });
}
