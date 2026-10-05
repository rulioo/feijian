import 'dart:io';

import '../protocol/frame_codec.dart';
import 'incoming_file.dart';

/// Raised when the peer's `file_data` frames do not describe the file it
/// offered.
///
/// Every throw from this class means the sender is broken or hostile — a chunk
/// from a different transfer, an offset that skips bytes, a claim of `eof` on a
/// file that is not finished. The answer is always the same: abandon the
/// partial file and cancel the transfer.
class FileReceiveException implements Exception {
  const FileReceiveException(this.message);

  final String message;

  @override
  String toString() => 'FileReceiveException: $message';
}

/// Fills one [IncomingFile] from the `file_data` frames of one transfer.
///
/// The sender decides what offsets to send and in what order; this class decides
/// whether to believe it. Chunks are only written when their `offset` is exactly
/// where the file has got to, which makes a truncated stream, a replayed chunk
/// and a sender that skipped a frame all fail the same way — rather than
/// producing a file with a hole in it that opens without complaint.
///
/// Deliberately knows nothing about the control connection, the offer, or the
/// user. The session that owns those feeds frames in and asks for the finished
/// path.
class TransferReceiver {
  TransferReceiver._(this._sink, this._xferId);

  /// Creates the sink for [rawName] and prepares to fill it.
  ///
  /// Resuming is not supported yet: [IncomingFile] always starts at zero, so
  /// this always answers `file_accept` with `resumeFrom: 0`. Deciding otherwise
  /// needs the transfer row — the recorded size and the previous attempt's
  /// `.part` — to tell an interrupted transfer of *this* file from a different
  /// file that happens to share its name, and that belongs to the session.
  static Future<TransferReceiver> begin({
    required Directory directory,
    required String xferId,
    required String rawName,
    required int totalSize,
  }) async {
    final IncomingFile sink = await IncomingFile.create(
      directory: directory,
      rawName: rawName,
      totalSize: totalSize,
    );
    return TransferReceiver._(sink, xferId);
  }

  final IncomingFile _sink;
  final String _xferId;

  bool _finished = false;
  bool _sawEof = false;

  /// Bytes written so far, for the progress the row reports.
  int get received => _sink.received;

  /// The size the peer declared in its offer.
  int get totalSize => _sink.totalSize;

  /// Whether the peer marked a chunk as the last one.
  ///
  /// Not used to decide completeness — that is the byte count's job. It is what
  /// tells "the peer said it was finished and then the socket died" apart from
  /// "the socket died mid-file", which is the difference between a retry that
  /// can resume and one that cannot.
  bool get sawEof => _sawEof;

  /// Where the bytes are until [complete] renames them.
  String get partPath => _sink.partPath;

  /// Where the file will land.
  String get path => _sink.path;

  /// Writes one `file_data` frame.
  ///
  /// Throws [FileReceiveException] if the frame is not this transfer's, if it
  /// does not start where the file has got to, or if it would run past the
  /// offered size.
  Future<void> accept(Frame frame) async {
    if (_finished) {
      throw const FileReceiveException('this transfer is already finished');
    }
    if (frame.type != FrameType.fileData) {
      throw FileReceiveException('expected file_data, got ${frame.type}');
    }

    final String? xferId = frame.header['xferId'] as String?;
    if (xferId != _xferId) {
      // Two transfers interleaved on one connection would otherwise splice
      // their bytes into a single file, and the result would be a valid-looking
      // file neither side ever sent.
      throw FileReceiveException(
        'chunk for transfer "$xferId" arrived on the connection for "$_xferId"',
      );
    }

    final Object? rawOffset = frame.header['offset'];
    if (rawOffset is! int) {
      throw FileReceiveException('chunk has no integer offset: $rawOffset');
    }
    if (rawOffset != received) {
      throw FileReceiveException(
        'chunk at $rawOffset, expected $received — the stream has a hole or a '
        'repeat',
      );
    }

    final List<int> chunk = frame.payload ?? const <int>[];
    if (chunk.isEmpty && !_isEof(frame)) {
      throw const FileReceiveException(
          'empty chunk before the end of the file');
    }

    // IncomingFile enforces the bound as well; this turns the same condition
    // into an error that names the transfer rather than the byte count.
    try {
      await _sink.write(chunk);
    } on IncomingFileException catch (error) {
      throw FileReceiveException(error.message);
    }

    // Only recorded once it is known to be true, so a rejected `eof` cannot
    // later let [complete] through.
    final bool eof = _isEof(frame);
    if (eof && !_sink.isComplete) {
      throw FileReceiveException(
        'peer declared the end at ${_sink.received} of $totalSize bytes',
      );
    }
    _sawEof = eof;
  }

  /// Installs the file under its final name and returns that path.
  ///
  /// Called when the sender's `file_done` arrives. What is required is that every
  /// offered byte is present, which [IncomingFile.finish] checks — not that the
  /// last chunk was marked `eof`. For an empty file there is no last chunk, so
  /// an `eof` requirement would reject every zero-byte file there is; and for a
  /// non-empty one the byte count already says everything `eof` would.
  Future<String> complete() async {
    if (_finished) {
      throw const FileReceiveException('this transfer is already finished');
    }
    try {
      final String path = await _sink.finish();
      _finished = true;
      return path;
    } on IncomingFileException catch (error) {
      throw FileReceiveException(error.message);
    }
  }

  /// Gives up and deletes the partial file — design.md §4.6, 取消后无残留.
  ///
  /// Safe after [complete] and safe to call twice, because a cancel and a
  /// socket error can arrive together.
  Future<void> cancel() async {
    _finished = true;
    await _sink.abandon();
  }

  static bool _isEof(Frame frame) => frame.header['eof'] == true;
}
