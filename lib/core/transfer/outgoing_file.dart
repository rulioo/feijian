import 'dart:io';
import 'dart:typed_data';

import '../constants.dart';
import '../protocol/frame_codec.dart';
import '../transport/frame_sink.dart';

/// Raised when a file cannot be read, or the connection died mid-transfer.
class FileSendException implements Exception {
  const FileSendException(this.message);

  final String message;

  @override
  String toString() => 'FileSendException: $message';
}

/// One file being sent, read a chunk at a time and never held whole.
///
/// `readAsBytes()` is what this class exists to avoid. It is the obvious way to
/// send a file and it works perfectly until someone sends a 4 GB video, at which
/// point it allocates 4 GB and the app dies — on the *sender*, before the
/// receiver has seen a byte (design.md §4.6, 背压控制).
///
/// So the file stays on disk and [pump] walks it: read [chunkSize], hand the
/// bytes to the sink, repeat. The sink's [FrameSink.flush] is what stops the
/// walk from outrunning the network — without it the socket accepts everything
/// instantly and the whole file collects in its buffer instead of in a
/// `Uint8List`, which is the same OOM wearing a different hat.
class OutgoingFile {
  OutgoingFile._(this._handle, this.totalSize, this._offset, this.chunkSize);

  /// Opens [file] for reading.
  ///
  /// [from] is where to start, for a transfer the receiver is resuming: it sent
  /// `file_accept {resumeFrom}` and already holds that many bytes, so re-sending
  /// them would duplicate the prefix. Throws [FileSendException] if the file
  /// cannot be read or [from] is not a real position in it.
  static Future<OutgoingFile> open(
    File file, {
    int from = 0,
    int chunkSize = kChunkSize,
  }) async {
    if (chunkSize <= 0) {
      throw FileSendException('chunk size must be positive, got $chunkSize');
    }
    if (chunkSize > kMaxPayload) {
      // A chunk that cannot fit in a frame would be rejected by the encoder
      // after the file had been opened and the transfer accepted.
      throw FileSendException(
        'chunk size $chunkSize exceeds the $kMaxPayload byte frame limit',
      );
    }

    final int length;
    try {
      length = await file.length();
    } on FileSystemException catch (error) {
      throw FileSendException('cannot read ${file.path}: ${error.message}');
    }

    if (from < 0 || from > length) {
      throw FileSendException('cannot start at $from in a $length byte file');
    }

    try {
      final RandomAccessFile handle = await file.open();
      if (from > 0) {
        await handle.setPosition(from);
      }
      return OutgoingFile._(handle, length, from, chunkSize);
    } on FileSystemException catch (error) {
      throw FileSendException('cannot open ${file.path}: ${error.message}');
    }
  }

  final RandomAccessFile _handle;

  /// The file's size when it was opened. Sent as `totalSize` and used as the
  /// loop bound, so a file that grows mid-transfer is truncated to what the
  /// receiver agreed to rather than overrunning it.
  final int totalSize;

  /// How much of each read is handed on at once.
  final int chunkSize;

  /// The next byte to read. Starts at `resumeFrom` and is what `file_data.offset`
  /// reports, so the receiver can tell a reordered frame from a duplicated one.
  int get offset => _offset;
  int _offset;

  /// The read in flight, if there is one — see [close].
  Future<Uint8List>? _reading;

  bool _closed = false;

  /// Whether every byte has been read.
  bool get isComplete => _offset >= totalSize;

  /// Reads the file to the end, sending it as `file_data` frames.
  ///
  /// [relPath] names which file inside a folder this is, for the only case where
  /// one `xferId` covers several files (design.md §4.6 rule 3). Every chunk
  /// carries it, not just the first: the frames of a folder's files share an
  /// `xferId`, so without it a receiver that had somehow got two of them at once
  /// could splice one file's bytes into another's, and the result would be a
  /// file of the right length that neither side ever sent.
  ///
  /// Returns the offset the receiver now holds, which is [totalSize] unless the
  /// file shrank underneath us. Throws [FileSendException] if the sink stops
  /// accepting — the connection went away, and the caller's job is to mark the
  /// transfer failed rather than to keep reading a file nobody is listening for.
  ///
  /// The last frame carries `eof`, so a receiver can tell "that was the file"
  /// from "that was a chunk" without comparing offsets against a size it half
  /// trusts.
  Future<int> pump(
    FrameSink sink, {
    required String xferId,
    String? relPath,
    void Function(int sent, int total)? onProgress,
  }) async {
    int unflushed = 0;

    while (_offset < totalSize) {
      final Uint8List chunk = await _readChunk();
      if (chunk.isEmpty) {
        // The file is shorter than it was when we opened it. Stop rather than
        // loop forever re-reading nothing at the same offset.
        break;
      }

      final int start = _offset;
      _offset += chunk.length;

      final bool sent = sink.send(
        Frame.of(
            FrameType.fileData,
            <String, Object?>{
              'xferId': xferId,
              // Omitted for a single file, whose frames stay byte-for-byte what
              // M3 sent.
              if (relPath != null) 'relPath': relPath,
              'offset': start,
              'eof': _offset >= totalSize,
            },
            chunk),
      );
      if (!sent) {
        throw FileSendException(
          'connection refused a chunk at offset $start '
          '(${_offset - start} bytes)',
        );
      }

      unflushed += chunk.length;
      if (unflushed >= kFileFlushBytes) {
        await sink.flush();
        unflushed = 0;
      }
      onProgress?.call(_offset, totalSize);
    }

    // The tail is usually smaller than the threshold, and it is the part the
    // user is watching for: without this the progress bar sits at 97% while the
    // last megabytes wait in a buffer for something else to flush them.
    if (unflushed > 0) {
      await sink.flush();
    }
    return _offset;
  }

  /// Reads at most [chunkSize] bytes, returning fewer only at the end.
  Future<Uint8List> _readChunk() async {
    if (_closed) {
      // The read is refused rather than attempted: the handle is on its way
      // out, and handing it one more operation is what makes [close] throw.
      throw const FileSendException('this file is closed');
    }
    try {
      final Future<Uint8List> reading = _handle.read(chunkSize);
      _reading = reading;
      try {
        return await reading;
      } finally {
        if (identical(_reading, reading)) {
          _reading = null;
        }
      }
    } on FileSystemException catch (error) {
      throw FileSendException('read failed at $_offset: ${error.message}');
    }
  }

  /// Releases the file handle.
  ///
  /// Safe to call more than once, and safe to call without ever pumping — a
  /// transfer the user cancelled before it started still opened the file.
  ///
  /// [pump] awaits its own reads, but a dispose or a cancel lands between two of
  /// them, and `RandomAccessFile.close()` throws rather than waits when another
  /// operation is pending on the handle. The lock is not released and the file
  /// stays un-deletable until the app exits, so the close waits for the read
  /// instead of finding out the hard way.
  Future<void> close() async {
    if (_closed) {
      return;
    }
    // Set before the wait rather than after it: the pump is a loop, and one
    // that is parked on a read will come back for another the moment that read
    // returns. Marked closed first, it finds the door shut instead.
    _closed = true;
    final Future<Uint8List>? reading = _reading;
    if (reading != null) {
      try {
        await reading;
      } on Object {
        // The pump reports it; this only needed it to be over.
      }
    }
    await _handle.close();
  }
}
