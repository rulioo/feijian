import 'dart:io';

import 'safe_name.dart';

/// Where one file of a folder transfer goes on this device.
///
/// Deliberately does not offer a `path` getter. [IncomingFile] picks a free name
/// when the file's turn comes to be written, so `a.txt` in a directory that
/// already holds one lands as `a (1).txt` — a path computed here would be a
/// prediction, and a caller that stored it as the file's location would be
/// recording somewhere the file never went. The real path is the one
/// `TransferReceiver.complete` returns.
class FolderTarget {
  const FolderTarget({required this.directory, required this.name});

  /// The directory the file goes in. It exists by the time this is built.
  final Directory directory;

  /// One safe component — the file's own name, never a path.
  final String name;
}

/// Turns the relative paths of a folder manifest into places under a download
/// root — design.md §4.6 rule 4.
///
/// Every path here comes from the peer, so every one of them is treated as
/// hostile in the same way a single file's name is: `SafeName.segments` drops
/// the components that would climb out (`..`), flattens the ones that would
/// split a name (`/`, `\`), and bounds the depth and the length. What is left is
/// only ever joined onto [root], never allowed to replace it.
///
/// The two ways of failing are kept apart, because they have different answers:
///
/// * **null** — the peer's string names nothing this device will create. A
///   manifest entry like this is a broken or hostile sender, and §4.6 rule 5's
///   answer applies: refuse the folder, because a transfer that arrives looking
///   complete while quietly missing an entry is the worst of the three possible
///   answers.
/// * **throwing** — the name was fine and the file system said no: a file
///   already sits where this wants a directory, the volume is read-only, the
///   joined path is past the platform's own limit. That is a local failure to be
///   reported as one, not a reason to disbelieve the sender.
abstract final class FolderLayout {
  /// Creates the directory [relPath] names, and everything above it, under
  /// [root]. Returns null if [relPath] names nothing creatable.
  ///
  /// This is how empty directories arrive: a folder's structure is part of what
  /// was sent, and a directory the sender has and the receiver does not is a
  /// difference the user would have to reconstruct by hand (§4.6 rule 4).
  static Directory? createDirectory(Directory root, String relPath) {
    final List<String>? parts = SafeName.segments(relPath);
    if (parts == null) {
      return null;
    }
    return _descend(root, parts);
  }

  /// The directory the file at [relPath] goes in — created, with the ones above
  /// it — and the name to write there. Null if [relPath] names nothing
  /// creatable.
  ///
  /// [name] is already one safe component, so a caller hands it straight to
  /// `IncomingFile`. The `relPath` such a caller gives the receiver must be the
  /// **wire** value this was resolved from and not the sanitised one: the
  /// receiver matches what arrives against what the sender wrote, and a sender
  /// whose file was called `a:b.txt` writes that, on every chunk.
  static FolderTarget? fileTarget(Directory root, String relPath) {
    final List<String>? parts = SafeName.segments(relPath);
    if (parts == null) {
      return null;
    }
    return FolderTarget(
      directory: _descend(root, parts.sublist(0, parts.length - 1)),
      name: parts.last,
    );
  }

  /// Creates `parts` under [root], in order, and returns the deepest.
  ///
  /// One `recursive: true` would create the whole chain, but the components are
  /// joined here rather than handed to the platform as one string so that the
  /// separator is the only thing this has to know about the platform — and so
  /// that a component which is itself a path cannot rejoin into one.
  static Directory _descend(Directory root, List<String> parts) {
    String path = root.path;
    for (final String part in parts) {
      path = '$path${Platform.pathSeparator}$part';
    }
    final Directory directory = Directory(path);
    directory.createSync(recursive: true);
    return directory;
  }
}
