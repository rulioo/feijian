import 'dart:async';
import 'dart:io';

import 'safe_name.dart';

/// Raised when the destination itself makes the transfer impossible.
///
/// Distinct from a network failure: the peer is fine and the bytes are fine,
/// and the right answer is a `file_reject` rather than a retry.
class IncomingFileException implements Exception {
  const IncomingFileException(this.message);

  final String message;

  @override
  String toString() => 'IncomingFileException: $message';
}

/// One file being received, from first byte to the name it finally lands under.
///
/// Writes go to `<name>.part` and the finished file appears only at [finish],
/// as a rename. A half-received file is therefore never a file the user can
/// open, and a cancelled transfer leaves nothing behind but a `.part` that
/// [abandon] removes — design.md §4.6.
///
/// The peer's declared size is enforced rather than trusted: [write] refuses to
/// go past it and [finish] refuses to run before it. A sender that lies about
/// the size, or dies halfway, produces an exception and a discarded `.part`
/// instead of a file that looks complete and is not.
class IncomingFile {
  IncomingFile._(this._handle, this._destination, this._part, this.totalSize);

  /// Creates a sink that will write [rawName] into [directory].
  ///
  /// [rawName] is treated as hostile and reduced to a single safe component; the
  /// directory is created if it is not there yet. An existing file of the same
  /// name is never overwritten — a second `report.pdf` becomes `report (1).pdf`,
  /// which is what a user copying files by hand would end up with.
  static Future<IncomingFile> create({
    required Directory directory,
    required String rawName,
    required int totalSize,
  }) async {
    if (totalSize < 0) {
      throw IncomingFileException('refusing a negative size: $totalSize');
    }
    await directory.create(recursive: true);

    final File destination = _available(directory, SafeName.fileName(rawName));
    final File part = File('${destination.path}.part');

    final RandomAccessFile handle = await part.open(mode: FileMode.write);
    return IncomingFile._(handle, destination, part, totalSize);
  }

  final RandomAccessFile _handle;

  /// Where the file will be when it is done.
  final File _destination;

  /// Where it is until then.
  final File _part;

  /// What the peer said the file weighs. Writes are bounded by it.
  final int totalSize;

  /// Bytes accepted so far.
  int received = 0;

  /// The handle's operations, in the order they were asked for.
  ///
  /// `RandomAccessFile` refuses to run two operations at once — it throws rather
  /// than queues, "an async operation is currently pending" — and these
  /// operations genuinely overlap: the flush that ends a transfer is issued
  /// while the last chunk's write is still on its way to the disk, and a cancel
  /// arrives whenever the user presses it. So the queueing has to happen here.
  /// A slot remembering only the newest operation would let the two meet and
  /// throw, and the `.part` the user asked to stop would still be sitting there:
  /// 取消后无残留 would hold only when the cancel happened to be well timed.
  ///
  /// A chain also gives the close one thing to wait for — everything asked for
  /// before it, in order, with nothing left in flight behind it.
  Future<void> _queue = Future<void>.value();

  /// The teardown in flight, if there is one.
  ///
  /// One teardown per transfer, however many callers ask for it — see
  /// [abandon] for what a second concurrent delete costs.
  Future<void>? _teardown;

  /// The close, once it has been asked for.
  Future<void>? _closing;

  /// The install in flight, if there is one.
  ///
  /// [finish] takes this on its first turn, before it suspends, so an [abandon]
  /// arriving at any point during the install sees it and waits rather than
  /// racing past it. That is what keeps a delivered file delivered: on Windows a
  /// delete is a property of the file and not of the name, so a delete issued
  /// against `report.pdf.part` while the rename is in flight takes `report.pdf`
  /// with it — the transfer completes and the file is gone, which is the residue
  /// problem wearing the opposite mask.
  Future<void>? _finishing;

  bool _closed = false;

  /// Where the file will land once [finish] has run.
  String get path => _destination.path;

  /// Where the bytes are until then. Goes in the `transfer` row as `temp_path`.
  String get partPath => _part.path;

  /// Whether every byte the peer promised has arrived.
  bool get isComplete => received == totalSize;

  /// Appends [chunk], refusing to run past the declared size.
  ///
  /// Chunks arrive from the network in whatever sizes the sender chose, so the
  /// bound is checked here rather than trusted from the frame that carried them:
  /// a peer that keeps sending after `file_done` would otherwise grow the disk
  /// until it filled.
  Future<void> write(List<int> chunk) async {
    _checkOpen();
    if (received + chunk.length > totalSize) {
      throw IncomingFileException(
        'peer sent past the declared size: '
        '${received + chunk.length} > $totalSize',
      );
    }
    await _run(() => _handle.writeFrom(chunk));
    received += chunk.length;
  }

  /// Closes the file, installs it under its final name, and returns that path.
  ///
  /// Throws if the transfer is short, leaving the `.part` for [abandon]: a
  /// truncated file renamed into place would be indistinguishable from a whole
  /// one, and the user would find out by opening it.
  Future<String> finish() async {
    _checkOpen();
    if (!isComplete) {
      throw IncomingFileException(
        'refusing to finish an incomplete file: $received of $totalSize',
      );
    }
    // No need to look for an [abandon] that started first: it closes the sink
    // before it suspends, so [_checkOpen] above has already turned this call
    // away. Claiming [_finishing] is the whole of the arbitration, and it
    // happens on this turn, with no suspension before it to slip into.
    final Completer<void> installed = Completer<void>();
    _finishing = installed.future;
    try {
      // Queued behind the last write rather than after it settles, so the order
      // the handle sees is the order the file needs, whatever a cancel is doing
      // at the same time.
      await _run(() => _handle.flush());
      await _close();

      // Same directory, so this is a rename and not a copy — and atomic, so a
      // crash either leaves the `.part` or leaves the whole file, never a
      // partial file under the real name.
      await _part.rename(_destination.path);
      return _destination.path;
    } finally {
      installed.complete();
    }
  }

  /// Gives up: closes the handle and deletes the partial file.
  ///
  /// Safe to call after [finish] and safe to call twice, because cancellation
  /// and failure arrive on paths that do not know about each other — a cancel
  /// the user pressed, the peer's `file_cancel`, a data socket that died. Each
  /// of them is entitled to the same answer: when this returns, the `.part` is
  /// not there.
  ///
  /// The later calls share the first one's work rather than repeating it. Two
  /// teardowns running at once would be two deletes over one name, and Windows
  /// answers the second in any of three ways — the file is not found, or it is
  /// in use, or access is denied, depending on how far into the first delete it
  /// arrives. All three read as a cancel that failed.
  Future<void> abandon() => _teardown ??= _abandon();

  Future<void> _abandon() async {
    // An install already under way goes first, for two reasons that are really
    // one: on Windows a delete issued while the rename is in flight follows the
    // file to its new name, so it would take a delivered file with it — and
    // until the install is over there is no way to tell whether there is a
    // `.part` here to delete at all.
    final Future<void>? installing = _finishing;
    if (installing != null) {
      try {
        await installing;
      } on Object {
        // An install that failed is its caller's to hear about. This only needed
        // it to be finished with the handle and the name — and a failed one
        // leaves the `.part` exactly where this call expects to find it.
      }
    }
    await _close();
    // Recreates nothing, removes nothing that is not ours: the `.part` is a
    // name only this transfer was ever told about.
    try {
      await _part.delete();
    } on PathNotFoundException {
      // Already gone. There is one teardown per transfer, so this is not a
      // second delete racing the first — it is the ending this call was waiting
      // on having won: [finish] renamed the `.part` into the delivered file, and
      // the file this was asked to remove is not a `.part` any more. Reporting
      // that as a failure would turn a cancel that arrived a moment too late
      // into one that errored.
    }
  }

  /// Closes the handle, and hands everyone the one close.
  ///
  /// Callers wait on this rather than checking a flag, because what the delete
  /// in [_abandon] needs is the *end* of the close and not its start: the close
  /// is a suspension point, and a second caller waved through by a flag would
  /// reach the delete with the handle still open — which on Windows throws
  /// rather than waits, and leaves the `.part` the user asked to remove.
  ///
  /// It also has to survive being called on an already-closed sink: [finish]
  /// closes before it renames, so an install that fails at the rename has
  /// already closed it, and the [abandon] that cleans up after such a failure
  /// would otherwise close again — throwing on the way to the delete that is
  /// the whole reason it was called.
  Future<void> _close() {
    // Marked before the wait, not after: a write that arrives while the close
    // is in flight has to be refused, not handed to a handle on its way out.
    _closed = true;
    // Straight onto the queue, past [_run]'s check: this *is* the close, and a
    // close that refused to queue because the sink was closed would never run.
    return _closing ??= _enqueue(() => _handle.close());
  }

  /// Runs [operation] on the handle, behind whatever is already queued.
  ///
  /// The failure goes to the caller and not into the chain: one refused chunk
  /// must not make every operation after it fail for a reason of its own.
  Future<T> _enqueue<T>(Future<T> Function() operation) {
    final Completer<T> result = Completer<T>();
    _queue = _queue.then((void _) async {
      try {
        result.complete(await operation());
      } on Object catch (error, stack) {
        result.completeError(error, stack);
      }
    });
    return result.future;
  }

  /// [operation], but refused if the sink is already closed.
  ///
  /// The check is here as well as in [write] and [finish] because it is only
  /// true here: those check when they are called, and the close can happen
  /// during the awaits that follow. Whatever a caller checked on the way in, the
  /// handle is asked to do nothing once the sink is shut.
  Future<T> _run<T>(Future<T> Function() operation) {
    if (_closed) {
      return Future<T>.error(
        const IncomingFileException('this sink is already closed'),
      );
    }
    return _enqueue(operation);
  }

  void _checkOpen() {
    if (_closed) {
      throw const IncomingFileException('this sink is already closed');
    }
  }

  /// The first name in `name`, `name (1)`, `name (2)`… that is not taken.
  ///
  /// Only the final name is tested. A `.part` left by an earlier attempt does
  /// not reserve anything: if `a.txt` is free, this transfer is `a.txt`, and
  /// `FileMode.write` truncates whatever the old `.part` held.
  static File _available(Directory directory, String name) {
    final String separator = Platform.pathSeparator;

    for (int attempt = 0; attempt < _maxNameAttempts; attempt++) {
      final String candidate = attempt == 0 ? name : _numbered(name, attempt);
      final File file = File('${directory.path}$separator$candidate');
      if (!file.existsSync()) {
        return file;
      }
    }
    throw IncomingFileException(
      'no free name for "$name" in ${directory.path} '
      'after $_maxNameAttempts attempts',
    );
  }

  /// How many collisions before the directory is treated as unusable.
  ///
  /// A bound exists so a transfer fails loudly rather than spinning, and it is
  /// high enough that a human sorting files by hand will never reach it.
  static const int _maxNameAttempts = 10000;

  /// `holiday.jpg` and 2 become `holiday (2).jpg`.
  static String _numbered(String name, int attempt) {
    final int dot = name.lastIndexOf('.');
    // `dot > 0` because a leading dot is a hidden file, not an extension.
    if (dot > 0) {
      return '${name.substring(0, dot)} ($attempt)${name.substring(dot)}';
    }
    return '$name ($attempt)';
  }
}
