import 'package:feijian/core/models/manifest_entry.dart';
import 'package:flutter_test/flutter_test.dart';

/// What an entry says its own name is — design.md §4.3, §4.6.
///
/// The one thing here that decides something is [ManifestEntry.name]: it is what
/// the sender writes into `attachment.file_name`, so a wrong answer puts a row
/// on disk that names a file by its whole path. What an entry *encodes* is
/// pinned in `folder_manifest_test.dart` and `payloads_test.dart`, and is not
/// repeated here.
void main() {
  String nameOf(String relPath) => ManifestEntry(relPath: relPath, size: 0).name;

  group('an entry is named by the end of its path', () {
    test('a file at the top of the folder is named by itself', () {
      expect(nameOf('report.pdf'), 'report.pdf');
    });

    test('a nested file is named by its last component', () {
      expect(nameOf('photos/2026/holiday.jpg'), 'holiday.jpg');
    });

    test('a directory entry is named by the folder', () {
      // The entry's name is the directory's, not the files under it: a
      // directory is an entry of its own (§4.6 rule 2).
      expect(ManifestEntry(relPath: 'photos/2026', size: 0, isDir: true).name,
          '2026');
    });
  });

  group('a separator is a separator whichever one it is', () {
    test('a backslash separates as well as a slash', () {
      // The manifest walk always writes `/`, but the string this reads can be
      // the peer's, and a path off a Windows machine may arrive with either.
      expect(nameOf(r'photos\holiday.jpg'), 'holiday.jpg');
    });

    test('a path can mix the two and still end at its file', () {
      expect(nameOf(r'photos\2026/summer.jpg'), 'summer.jpg');
    });

    test('a trailing separator still names the entry before it', () {
      // `sub/` names the directory `sub`; the empty piece after the separator is
      // not a name.
      expect(nameOf('sub/'), 'sub');
      expect(nameOf('sub//'), 'sub');
    });
  });

  group('a path that names nothing answers with itself', () {
    test('a path of nothing but separators has no name to find', () {
      // Not an empty string, which would be a name the file system refuses with
      // an exception somewhere far from here. The receiver turns a path like
      // this away outright — `SafeName.segments` finds no component in it — so
      // nothing downstream ever stores what comes back.
      expect(nameOf('///'), '///');
      expect(nameOf(r'\\'), r'\\');
    });

    test('an empty path is left alone rather than invented into something', () {
      expect(nameOf(''), '');
    });
  });

  group('the name is the peer\'s, not a tidied one', () {
    test('a component that names no place survives untouched', () {
      // Verbatim is the point: this is the record of what was sent, and the
      // row's `local_path` is what says where the bytes actually landed.
      // `SafeName.relPath` would have dropped the `..`; this must not, or the
      // attachment would name a file the sender never sent.
      expect(nameOf('photos/..'), '..');
      expect(nameOf('../etc/passwd'), 'passwd');
    });

    test('a name that is only a path is never returned as one', () {
      for (final String relPath in <String>[
        'a/b/c.txt',
        r'a\b\c.txt',
        'a/b/',
      ]) {
        expect(nameOf(relPath), isNot(contains('/')));
        expect(nameOf(relPath), isNot(contains(r'\')));
      }
    });
  });
}
