import 'dart:convert';

import 'package:feijian/core/constants.dart';
import 'package:feijian/core/transfer/safe_name.dart';
import 'package:flutter_test/flutter_test.dart';

/// The input to these tests is a string a stranger chose. Each group is one way
/// the filesystem could be made to do something the user did not ask for.
void main() {
  group('ordinary names survive', () {
    test('a plain name is returned unchanged', () {
      expect(SafeName.fileName('holiday.jpg'), 'holiday.jpg');
    });

    test('spaces and dashes are not touched', () {
      expect(
          SafeName.fileName('Q3 report - final.pdf'), 'Q3 report - final.pdf');
    });

    test('a leading dot is a hidden file, not debris', () {
      // `.gitignore` is a real file people send. Only *trailing* dots are noise.
      expect(SafeName.fileName('.gitignore'), '.gitignore');
    });

    test('a name at exactly the limit is not truncated', () {
      final String name = '${'a' * (SafeName.maxBytes - 4)}.txt';
      expect(utf8.encode(name).length, SafeName.maxBytes);
      expect(SafeName.fileName(name), name);
    });
  });

  group('directory traversal', () {
    test('a Unix path keeps only its last component', () {
      expect(SafeName.fileName('/etc/passwd'), 'passwd');
    });

    test('a Windows path keeps only its last component', () {
      expect(
          SafeName.fileName(r'C:\Windows\System32\drivers\etc\hosts'), 'hosts');
    });

    test('a relative climb keeps only its last component', () {
      expect(SafeName.fileName('../../../.ssh/authorized_keys'),
          'authorized_keys');
    });

    test('a backslash climb keeps only its last component', () {
      expect(SafeName.fileName(r'..\..\..\Windows\win.ini'), 'win.ini');
    });

    test('a bare .. is not a name', () {
      // Nothing survives the split, and `..` must never reach the filesystem.
      expect(SafeName.fileName('..'), SafeName.fallback);
      expect(SafeName.fileName('../..'), SafeName.fallback);
    });

    test('a mixed-separator climb is split on both kinds', () {
      expect(SafeName.fileName(r'../foo\..\bar/baz.txt'), 'baz.txt');
    });
  });

  group('things Windows refuses to create', () {
    test('a colon cannot survive to become a drive or a stream', () {
      expect(SafeName.fileName('C:evil.txt'), 'Cevil.txt');
      expect(SafeName.fileName('report:2024.pdf'), 'report2024.pdf');
    });

    test('the rest of the forbidden set is dropped', () {
      expect(SafeName.fileName('a<b>c"d|e?f*g.txt'), 'abcdefg.txt');
    });

    test('control characters are dropped', () {
      expect(SafeName.fileName('a\u0000b\u001fc.txt'), 'abc.txt');
    });

    test('a device name is prefixed even with an extension', () {
      // The stem is what the OS resolves, so the extension offers no cover.
      expect(SafeName.fileName('CON'), '_CON');
      expect(SafeName.fileName('con.txt'), '_con.txt');
      expect(SafeName.fileName('NUL'), '_NUL');
      expect(SafeName.fileName('COM1.log'), '_COM1.log');
      expect(SafeName.fileName('lpt9'), '_lpt9');
    });

    test('a name that merely starts with a device name is left alone', () {
      expect(SafeName.fileName('console.txt'), 'console.txt');
      expect(SafeName.fileName('com10.txt'), 'com10.txt');
    });

    test('trailing dots and spaces are stripped', () {
      // Windows drops these on create, so the file on disk would not match the
      // name the user was shown.
      expect(SafeName.fileName('report.'), 'report');
      expect(SafeName.fileName('report '), 'report');
      expect(SafeName.fileName('report. . '), 'report');
    });

    test('a name that is only dots and spaces becomes the fallback', () {
      expect(SafeName.fileName('   '), SafeName.fallback);
      expect(SafeName.fileName('...'), SafeName.fallback);
      expect(SafeName.fileName(''), SafeName.fallback);
    });
  });

  group('length', () {
    test('a long name keeps its extension', () {
      final String name = '${'a' * 400}.jpeg';
      final String safe = SafeName.fileName(name);

      expect(utf8.encode(safe).length, lessThanOrEqualTo(SafeName.maxBytes));
      expect(safe, endsWith('.jpeg'));
    });

    test('truncation counts bytes, not characters', () {
      // 100 CJK characters is 300 bytes — over the limit, though only 100
      // characters long. Counting characters would have let this through and
      // the filesystem would have refused it after the transfer was accepted.
      final String name = '${'文' * 100}.txt';
      final String safe = SafeName.fileName(name);

      expect(utf8.encode(safe).length, lessThanOrEqualTo(SafeName.maxBytes));
      expect(safe, endsWith('.txt'));
      expect(safe, startsWith('文'));
    });

    test('a truncated name is still valid UTF-8', () {
      // Cutting at a byte boundary would leave a lone surrogate half here.
      final String safe = SafeName.fileName('${'é' * 200}.txt');
      expect(() => utf8.decode(utf8.encode(safe)), returnsNormally);
      expect(utf8.encode(safe).length, lessThanOrEqualTo(SafeName.maxBytes));
    });

    test('a name that is nothing but a long extension is still bounded', () {
      final String safe = SafeName.fileName('.${'x' * 400}');
      expect(utf8.encode(safe).length, lessThanOrEqualTo(SafeName.maxBytes));
    });
  });

  group('a folder transfer\'s relative path', () {
    test('an ordinary nested path survives', () {
      expect(SafeName.relPath('photos/2024/holiday.jpg'),
          'photos/2024/holiday.jpg');
    });

    test('the platform separator does not survive into the stored path', () {
      // The value has to mean the same thing on both ends, and a backslash
      // cannot: it is a separator here and an ordinary character on the peer.
      expect(SafeName.relPath(r'photos\2024\holiday.jpg'),
          'photos/2024/holiday.jpg');
      expect(SafeName.relPath(r'photos/2024\holiday.jpg'),
          'photos/2024/holiday.jpg');
    });

    test('a climb is dropped rather than turned into a file called file', () {
      // `fileName('..')` answers the fallback, which is right for a *name* and
      // wrong for a *segment*: it would invent a file out of a traversal
      // attempt. A segment that names no place is a segment with nothing in it.
      expect(SafeName.relPath('../../etc/shadow'), 'etc/shadow');
      expect(SafeName.relPath('a/../b.txt'), 'a/b.txt');
      expect(SafeName.relPath('./a/./b.txt'), 'a/b.txt');
      expect(SafeName.relPath(r'..\..\Windows\win.ini'), 'Windows/win.ini');
    });

    test('an absolute path becomes a relative one', () {
      expect(SafeName.relPath('/etc/passwd'), 'etc/passwd');
      // The drive letter survives as an ordinary component, the same way the
      // colon is stripped out of `C:evil.txt` by the single-component rules: it
      // is a harmless directory called `C` under the download root, and giving
      // it its own rule would be a second answer to a question `_component`
      // already answers.
      expect(SafeName.relPath(r'C:\Users\me\notes.txt'),
          'C/Users/me/notes.txt');
    });

    test('each segment gets the single-component rules', () {
      expect(SafeName.relPath('a/CON/b.txt'), 'a/_CON/b.txt');
      expect(SafeName.relPath('a/report.../b.txt'), 'a/report/b.txt');
      expect(SafeName.relPath('a/x:y/b.txt'), 'a/xy/b.txt');
      expect(SafeName.relPath('a/\u0000b/b.txt'), 'a/b/b.txt');
    });

    test('a path that names no place at all is refused', () {
      expect(SafeName.relPath(''), isNull);
      expect(SafeName.relPath('/'), isNull);
      expect(SafeName.relPath('.'), isNull);
      expect(SafeName.relPath('..'), isNull);
      expect(SafeName.relPath('../..'), isNull);
      expect(SafeName.relPath('//'), isNull);
    });

    test('a path nested to the limit is accepted and one deeper is not', () {
      final String atLimit =
          <String>[...List<String>.filled(kMaxPathDepth - 1, 'd'), 'f.txt']
              .join('/');
      expect(SafeName.segments(atLimit), hasLength(kMaxPathDepth));

      final String tooDeep =
          <String>[...List<String>.filled(kMaxPathDepth, 'd'), 'f.txt']
              .join('/');
      expect(SafeName.segments(tooDeep), isNull);
    });

    test('a path longer than the byte limit is refused', () {
      // Refused rather than truncated: a truncated path is a *different* place,
      // and the receiver would create the folder somewhere the sender never
      // named while the sender's own tree said otherwise.
      //
      // Every component is fitted to [SafeName.maxBytes] on its own, so the
      // total is only reachable through depth — which is why this is ten long
      // names rather than one enormous one.
      // Ten 200-character names become ten 120-byte ones, which joins to about
      // 1.2 KB — over the limit, and still well inside the depth cap, so this is
      // the byte bound being tested and not the other one.
      final String long =
          <String>[...List<String>.filled(10, 'a' * 200), 'f.txt'].join('/');
      expect(SafeName.segments(long), isNull);
    });

    test('nothing it returns can escape the directory it is joined onto', () {
      const List<String> hostile = <String>[
        '',
        '.',
        '..',
        '/',
        '\\',
        '//',
        r'..\..',
        '../../../etc/shadow',
        r'C:\..\..\x\y.txt',
        'a/../../b.txt',
        '/dev/null',
        r'\\server\share\file.txt',
        '\u0000',
        'CON/CON.txt',
        'a//b///c.txt',
        'a/ /b.txt',
      ];

      for (final String raw in hostile) {
        final List<String>? parts = SafeName.segments(raw);
        if (parts == null) {
          continue; // refused outright, which is always safe
        }
        final String joined = parts.join('/');
        expect(parts, isNotEmpty, reason: 'for ${jsonEncode(raw)}');
        expect(joined, isNot(startsWith('/')), reason: 'for ${jsonEncode(raw)}');
        for (final String part in parts) {
          expect(part, isNotEmpty, reason: 'for ${jsonEncode(raw)}');
          expect(part, isNot(anyOf('.', '..')),
              reason: 'for ${jsonEncode(raw)}');
          expect(part, isNot(contains('/')), reason: 'for ${jsonEncode(raw)}');
          expect(part, isNot(contains(r'\')), reason: 'for ${jsonEncode(raw)}');
          expect(part, isNot(contains(':')), reason: 'for ${jsonEncode(raw)}');
        }
      }
    });
  });

  group('the result is always a usable component', () {
    test('it is never empty and never a traversal', () {
      const List<String> hostile = <String>[
        '',
        ' ',
        '.',
        '..',
        '/',
        '\\',
        '//',
        r'..\..',
        '...',
        '../../../etc/shadow',
        r'C:\..\..\x',
        '\u0000',
        'CON',
        '/dev/null',
      ];

      for (final String raw in hostile) {
        final String safe = SafeName.fileName(raw);
        expect(safe, isNotEmpty, reason: 'for ${jsonEncode(raw)}');
        expect(safe, isNot(anyOf('.', '..')), reason: 'for ${jsonEncode(raw)}');
        expect(safe, isNot(contains('/')), reason: 'for ${jsonEncode(raw)}');
        expect(safe, isNot(contains(r'\')), reason: 'for ${jsonEncode(raw)}');
        expect(safe, isNot(contains(':')), reason: 'for ${jsonEncode(raw)}');
      }
    });
  });
}
