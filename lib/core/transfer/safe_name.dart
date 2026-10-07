import 'dart:convert';

import '../constants.dart';

/// Turns a peer-supplied name into one this device is willing to create.
///
/// Everything here treats the input as hostile. The name arrives in a
/// `file_offer` header from another machine — a peer that may be confused, may
/// be a different version, or may be trying to write to `~/.ssh/authorized_keys`
/// — and the receiver's only defence is to never let the peer's string reach the
/// filesystem intact (design.md §4.6).
///
/// A name is not a path: [fileName] keeps only the final component, and
/// [segments] gives a folder transfer's `relPath` the same treatment one
/// component at a time.
abstract final class SafeName {
  /// Used when nothing usable is left of what the peer sent.
  static const String fallback = 'file';

  /// Longest name this will produce, in UTF-8 bytes.
  ///
  /// Most filesystems cap a single component at 255 bytes. The budget is far
  /// below that because the name still has to absorb a ` (12)` collision suffix
  /// and a `.part` suffix on top.
  static const int maxBytes = 120;

  /// Names Windows keeps for devices, whatever extension follows.
  ///
  /// `CON.txt` is as unusable as `CON`: the check has to be on the stem, not on
  /// the whole name. On Linux these are ordinary files, which is precisely why
  /// this is a list rather than a filesystem probe — the same transfer has to
  /// land on both.
  static const Set<String> _reservedDevices = <String>{
    'con',
    'prn',
    'aux',
    'nul',
    'com0',
    'com1',
    'com2',
    'com3',
    'com4',
    'com5',
    'com6',
    'com7',
    'com8',
    'com9',
    'lpt0',
    'lpt1',
    'lpt2',
    'lpt3',
    'lpt4',
    'lpt5',
    'lpt6',
    'lpt7',
    'lpt8',
    'lpt9',
  };

  /// A single path component, safe to join onto a directory.
  ///
  /// Never empty and never a traversal: the caller can `File('$dir/$result')`
  /// without checking anything further.
  static String fileName(String raw) {
    // The last component of whatever path syntax the peer used. `C:\Users\x` and
    // `/home/x` and `..\..\x` all reduce to `x`, which is the point: any leading
    // directories, including `..`, are dropped rather than neutralised.
    return _component(raw.split(RegExp(r'[/\\]')).last);
  }

  /// The path inside a transferred folder, as one this device will create.
  ///
  /// Returns the components rather than a joined string because the two callers
  /// want different things from them: the row stores `/`-separated text, and the
  /// file system wants whatever separator the platform uses. Splitting is the
  /// only place the difference can be honoured, so it is where the answer is
  /// given.
  ///
  /// Null when the peer's string names no place at all, or names one deeper than
  /// [kMaxPathDepth]. Refusing is deliberate: a path that has to be *flattened*
  /// to be acceptable would put two of the peer's files on one name, and losing
  /// a file quietly is worse than refusing the folder where the user can see it.
  ///
  /// Unlike [fileName], `.` and `..` are **dropped rather than sanitised**.
  /// [fileName] would turn either into [fallback] — a file genuinely called
  /// `file`, which is not at all the same thing as "this segment named no
  /// place" — and a folder transfer that invented files out of traversal
  /// attempts would be a worse answer than one that ignored them.
  static List<String>? segments(String raw) {
    final List<String> parts = <String>[];
    for (final String segment in raw.split(RegExp(r'[/\\]'))) {
      if (segment.isEmpty || segment == '.' || segment == '..') {
        continue;
      }
      parts.add(_component(segment));
      if (parts.length > kMaxPathDepth) {
        return null;
      }
    }
    if (parts.isEmpty) {
      return null;
    }
    if (utf8.encode(parts.join('/')).length > kMaxRelPathLength) {
      return null;
    }
    return List<String>.unmodifiable(parts);
  }

  /// [segments] as the `/`-separated text a row stores.
  ///
  /// Always `/`, whatever the platform: this value is the peer's file's place
  /// within the folder and has to mean the same thing on both ends, which is
  /// exactly what a platform separator cannot promise.
  static String? relPath(String raw) => segments(raw)?.join('/');

  /// One component, already stripped of anything that would make it a path.
  static String _component(String raw) {
    // Control characters, and the set Windows refuses to create. `:` matters
    // beyond Windows — it is how `C:evil.txt` becomes an alternate data stream.
    String name = raw.replaceAll(RegExp(r'[\x00-\x1f<>:"|?*]'), '');

    // Trailing dots and spaces go because Windows silently strips them on
    // create, so the file on disk would not match the name the user was shown.
    // Leading *whitespace* goes for the same reason; a leading dot does not,
    // because `.gitignore` is a name and not debris. A name that is nothing but
    // dots collapses to empty here, which is what retires `.` and `..`.
    name = name.replaceAll(RegExp(r'^\s+|[.\s]+$'), '');

    if (name.isEmpty) {
      return fallback;
    }
    if (_isReservedDevice(name)) {
      // Prefixed rather than rejected: the user asked for this file, and a
      // rename is a smaller surprise than a transfer that refuses to land.
      name = '_$name';
    }
    return _fit(name);
  }

  /// Whether [name]'s stem names a Windows device.
  static bool _isReservedDevice(String name) {
    final int dot = name.indexOf('.');
    final String stem =
        (dot == -1 ? name : name.substring(0, dot)).toLowerCase();
    return _reservedDevices.contains(stem);
  }

  /// Truncates to [maxBytes] without cutting a character in half.
  ///
  /// The extension is kept when there is one: a `.jpg` that survives is a file
  /// the user can still open. Byte length rather than character count because
  /// that is what the filesystem caps, and one CJK character is three bytes —
  /// a 255-character name of them would be rejected at creation time, after the
  /// whole transfer had already been accepted.
  static String _fit(String name) {
    if (utf8.encode(name).length <= maxBytes) {
      return name;
    }

    final int dot = name.lastIndexOf('.');
    // A leading dot is a hidden file, not an extension, hence `dot > 0`.
    String stem = name;
    String extension = '';
    if (dot > 0) {
      stem = name.substring(0, dot);
      extension = name.substring(dot);
    }
    // A name that is nothing but a huge extension has no extension worth saving.
    if (utf8.encode(extension).length >= maxBytes) {
      stem = name;
      extension = '';
    }

    final String head =
        _fitBytes(stem, maxBytes - utf8.encode(extension).length);
    return head.isEmpty ? fallback : '$head$extension';
  }

  /// As much of [s] as fits in [budget] UTF-8 bytes, whole characters only.
  static String _fitBytes(String s, int budget) {
    final StringBuffer out = StringBuffer();
    int used = 0;
    for (final int rune in s.runes) {
      final String character = String.fromCharCode(rune);
      final int size = utf8.encode(character).length;
      if (used + size > budget) {
        break;
      }
      out.write(character);
      used += size;
    }
    return out.toString();
  }
}
