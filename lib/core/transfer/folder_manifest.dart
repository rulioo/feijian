import 'dart:convert';
import 'dart:io';

import '../constants.dart';
import '../models/manifest_entry.dart';

/// Raised when a folder has more in it than a `file_offer` can describe —
/// design.md §4.6 rule 5.
///
/// Carries the numbers rather than a finished sentence: the message a user
/// reads is the ARB's (§8.1), and this class has no business choosing words.
class FolderTooLargeException implements Exception {
  const FolderTooLargeException({required this.bytes, required this.limit});

  /// How many bytes the manifest had reached when the walk gave up.
  final int bytes;
  final int limit;

  @override
  String toString() =>
      'FolderTooLargeException: the manifest passed $limit bytes at $bytes';
}

/// A directory walked into the list of files a `file_offer` describes.
///
/// The walk is the sender's half of design.md §4.6's folder rules: it produces
/// the manifest, and the session layer offers it and then sends the files in the
/// order this gives.
class FolderManifest {
  const FolderManifest({
    required this.name,
    required this.entries,
    this.skipped = 0,
  });

  /// The folder's own name — the last component of its path, which is what the
  /// peer is offered (§4.6 rule 2's `name`).
  final String name;

  /// Everything inside, **files and directories both**, ordered by `relPath`.
  ///
  /// Deterministic order matters more than it looks: the sender sends in this
  /// order, so two runs over one folder put the same files on the wire in the
  /// same sequence, which is what makes a transfer reproducible in a test and
  /// comparable between attempts.
  final List<ManifestEntry> entries;

  /// What the walk could not describe, and so left out of the folder.
  ///
  /// Symbolic links are not followed: `link -> /` would offer the whole file
  /// system, and two links pointing at each other would walk forever. They are
  /// not sent as empty files either, which would land a file of the wrong kind
  /// under the link's name. A file that vanished between the listing and the
  /// stat is in the same position — what cannot be described cannot be sent —
  /// and so is anything else the platform grows that is neither file nor
  /// directory.
  ///
  /// Counted rather than merely dropped, because a folder that arrives an item
  /// short with no explanation is worse than one the sender can say so about:
  /// this manifest holds what was describable, not what was there, so nothing
  /// downstream can notice the difference. What the caller does with the number
  /// is the caller's business — this class has no business choosing words.
  ///
  /// (Named for what it counts rather than for the commonest case: a link is
  /// one of the things in here, not all of them.)
  final int skipped;

  /// How many *files* — directories are not files, and a folder of empty
  /// directories honestly has none.
  int get fileCount => entries.where((ManifestEntry e) => !e.isDir).length;

  /// What every file in the folder adds up to. Directories contribute nothing,
  /// which is why this is not simply the sum of [ManifestEntry.size].
  int get totalSize => entries.fold(
        0,
        (int sum, ManifestEntry entry) => sum + entry.size,
      );

  /// Walks [directory] into a manifest.
  ///
  /// Throws [FolderTooLargeException] once the encoded manifest passes
  /// [maxBytes]. The check is on *encoded* size rather than entry count because
  /// that is what the offer has to fit in — a hundred files with 900-byte paths
  /// are a bigger manifest than a thousand with short ones — and it is
  /// accumulated as the walk goes rather than measured at the end, so a
  /// pathological tree is abandoned instead of being read in full first.
  static Future<FolderManifest> walk(
    Directory directory, {
    int maxBytes = kMaxManifestBytes,
  }) async {
    final List<ManifestEntry> entries = <ManifestEntry>[];
    int bytes = 0;
    int skipped = 0;

    await for (final FileSystemEntity entity
        in directory.list(recursive: true, followLinks: false)) {
      final String? relPath = _relative(entity.path, directory.path);
      if (relPath == null || relPath.isEmpty) {
        // The root itself, or a path the platform spelled differently from the
        // one we were handed. Neither is something to put in a manifest.
        continue;
      }

      final ManifestEntry entry;
      if (entity is Directory) {
        entry = ManifestEntry(relPath: relPath, size: 0, isDir: true);
      } else if (entity is File) {
        final FileStat stat;
        try {
          stat = await entity.stat();
        } on FileSystemException {
          // Gone between the listing and the stat, or unreadable. Skipping is
          // the same answer the walk gives a link, and for the same reason: what
          // cannot be described cannot be sent.
          skipped++;
          continue;
        }
        entry = ManifestEntry(
          relPath: relPath,
          size: stat.size,
          mtime: stat.modified.millisecondsSinceEpoch,
        );
      } else {
        // A link, and anything else the platform grows later. See [skipped].
        skipped++;
        continue;
      }

      bytes += utf8.encode(jsonEncode(entry.toJson())).length;
      if (bytes > maxBytes) {
        throw FolderTooLargeException(bytes: bytes, limit: maxBytes);
      }
      entries.add(entry);
    }

    entries.sort((ManifestEntry a, ManifestEntry b) =>
        a.relPath.compareTo(b.relPath));

    return FolderManifest(
      name: _baseName(directory.path),
      entries: List<ManifestEntry>.unmodifiable(entries),
      skipped: skipped,
    );
  }

  /// [path]'s place inside [root], `/`-separated, or null when it is not in it.
  ///
  /// The prefix is matched with a separator on the end so that `/a/bc` is not
  /// read as living inside `/a/b`.
  static String? _relative(String path, String root) {
    final String prefix =
        root.endsWith(Platform.pathSeparator) ? root : '$root${Platform.pathSeparator}';
    if (!path.startsWith(prefix)) {
      return null;
    }
    return path.substring(prefix.length).split(Platform.pathSeparator).join('/');
  }

  static String _baseName(String path) {
    final String trimmed = path.endsWith(Platform.pathSeparator)
        ? path.substring(0, path.length - Platform.pathSeparator.length)
        : path;
    final int cut = trimmed.lastIndexOf(Platform.pathSeparator);
    final String name = cut < 0 ? trimmed : trimmed.substring(cut + 1);
    return name.isEmpty ? trimmed : name;
  }
}
