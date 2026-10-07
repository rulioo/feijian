/// One entry in a folder offer — design.md §4.3's
/// `files: [{relPath, size, mtime, isDir}]`.
///
/// A model rather than a payload, and in `models/` rather than in
/// `transfer/folder_manifest.dart` where the walk that produces it lives,
/// because the protocol layer has to parse it: `payloads.dart` already reaches
/// into `models/` for `peer.dart`, and the alternative — having the protocol
/// import the byte layer — would point the dependency the wrong way for a type
/// whose whole job is to be a wire structure.
///
/// Pure data, like [Message] and [Attachment]: no file system, no JSON decoding,
/// nothing that needs a device.
class ManifestEntry {
  const ManifestEntry({
    required this.relPath,
    required this.size,
    this.mtime,
    this.isDir = false,
  });

  /// The file's place inside the folder, always `/`-separated.
  ///
  /// What the receiver rebuilds its directories from, so it is the one field
  /// that must mean the same thing on both ends: never absolute, never empty.
  /// The sender's copy comes from its own tree and already satisfies that; the
  /// receiver runs what arrives through `SafeName.segments` anyway, because the
  /// string is the peer's.
  final String relPath;

  /// Zero for a directory. A directory has no bytes of its own; the files inside
  /// it are entries in their own right, which is what makes an empty directory
  /// describable at all.
  final int size;

  /// Milliseconds since the epoch, when the file system would say. Advisory,
  /// like every other timestamp off the wire.
  final int? mtime;

  final bool isDir;

  /// The entry's own name: the last component of [relPath].
  ///
  /// Verbatim, not run through `SafeName`. This is the peer's name for the file,
  /// and the row that stores it is the record of what was sent — where the bytes
  /// actually landed is `local_path`'s job, and the two are allowed to differ
  /// (a name the platform will not create is renamed on the way in).
  ///
  /// Splits on `\` as well as `/` because the receiver runs this against a
  /// string off the wire, where the separator is whatever the peer felt like,
  /// and empty components are dropped for the same reason — a path of `sub/`
  /// ends in a separator and still names `sub`. A path of nothing *but*
  /// separators has no name to find and answers with itself; it is a string the
  /// receiver refuses outright, so nothing downstream ever stores it.
  String get name {
    final List<String> parts = relPath
        .split(_separators)
        .where((String part) => part.isNotEmpty)
        .toList(growable: false);
    return parts.isEmpty ? relPath : parts.last;
  }

  static final RegExp _separators = RegExp(r'[/\\]');

  Map<String, Object?> toJson() => <String, Object?>{
        'relPath': relPath,
        'size': size,
        // Omitted rather than written as null, the same way `file_offer` omits
        // what it does not have: the field is optional, and absent is how this
        // protocol spells "no value".
        if (mtime != null) 'mtime': mtime,
        if (isDir) 'isDir': true,
      };

  @override
  String toString() => 'ManifestEntry($relPath, $size, isDir: $isDir)';
}
