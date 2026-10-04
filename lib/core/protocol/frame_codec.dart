import 'dart:convert';
import 'dart:typed_data';

import '../constants.dart';

/// Raised when a byte stream cannot be a valid stream of frames.
///
/// Every throw from this file means the peer is broken or hostile — a corrupt
/// length, an oversized header, JSON that is not an object. The caller's
/// response is always the same: log it and drop the connection (design.md §4.2).
class FrameException implements Exception {
  const FrameException(this.reason);

  final String reason;

  @override
  String toString() => 'FrameException: $reason';
}

/// The frame `type` values this build understands — design.md §4.3.
///
/// String constants rather than an enum, deliberately. §4.3 requires an unknown
/// `type` to be logged and ignored so a newer peer can still talk to an older
/// one; an enum would turn "the peer knows a frame I don't" into a parse
/// failure, and the two versions would stop interoperating.
abstract final class FrameType {
  static const String hello = 'hello';
  static const String msg = 'msg';
  static const String msgAck = 'msg_ack';
  static const String fileOffer = 'file_offer';
  static const String fileAccept = 'file_accept';
  static const String fileReject = 'file_reject';
  static const String fileData = 'file_data';
  static const String fileDone = 'file_done';
  static const String fileCancel = 'file_cancel';
  static const String xferDone = 'xfer_done';
  static const String ping = 'ping';
  static const String pong = 'pong';
  static const String bye = 'bye';
}

/// The header key that declares the payload length — design.md §4.2.
///
/// Reserved at the frame layer: no payload definition may reuse it, which is
/// why `file_offer` announces a file's size as `totalSize` rather than `size`.
/// The two meanings would otherwise collide on the same key, and a 4 GB offer
/// would read as a 4 GB frame.
const String kFrameSizeKey = 'size';

/// One frame: a JSON header plus an optional binary payload.
class Frame {
  Frame(Map<String, Object?> header, {this.payload})
    : header = Map<String, Object?>.unmodifiable(header);

  /// Convenience constructor: the `type` plus the frame's own fields.
  ///
  /// [payload] is only ever non-null for `file_data`; every other frame type
  /// puts everything it has in the header.
  factory Frame.of(
    String type, [
    Map<String, Object?> fields = const <String, Object?>{},
    Uint8List? payload,
  ]) {
    return Frame(<String, Object?>{'type': type, ...fields}, payload: payload);
  }

  /// The decoded header. Always contains a non-empty `type`.
  final Map<String, Object?> header;

  /// Raw bytes, or null when the frame carries none.
  final Uint8List? payload;

  String get type => header['type']! as String;

  bool get isKnownType => const <String>{
    FrameType.hello,
    FrameType.msg,
    FrameType.msgAck,
    FrameType.fileOffer,
    FrameType.fileAccept,
    FrameType.fileReject,
    FrameType.fileData,
    FrameType.fileDone,
    FrameType.fileCancel,
    FrameType.xferDone,
    FrameType.ping,
    FrameType.pong,
    FrameType.bye,
  }.contains(type);

  /// Debug rendering that never dumps a whole payload.
  @override
  String toString() =>
      'Frame($type, ${header.length} fields, ${payload?.length ?? 0} bytes)';
}

/// Encodes frames and decodes them again — design.md §4.2.
///
/// The wire form is `uint32 BE headerLen | JSON header | payload`, where the
/// payload length is `header.size`. `headerLen` is capped at [kMaxFrameHeader]
/// so a corrupt or hostile length cannot make the receiving side allocate
/// unbounded memory before it knows whether the stream is even sane.
abstract final class FrameCodec {
  /// Serialises [frame] into the bytes to write to a socket.
  ///
  /// Throws [FrameException] if the frame exceeds a limit. This is a programming
  /// error on the sending side rather than a peer's fault — the receiver would
  /// drop the connection — so it surfaces loudly instead of being sent.
  static Uint8List encode(Frame frame) {
    final Uint8List? payload = frame.payload;
    if (payload != null && payload.length > kMaxPayload) {
      throw FrameException(
        'payload of ${payload.length} bytes exceeds kMaxPayload $kMaxPayload',
      );
    }

    final Map<String, Object?> header = <String, Object?>{...frame.header};
    if (payload == null || payload.isEmpty) {
      // Omitted rather than written as 0: §4.2 says a frame with no payload
      // leaves the field out, and `size` is reserved for the length.
      header.remove(kFrameSizeKey);
    } else {
      header[kFrameSizeKey] = payload.length;
    }

    final List<int> headerBytes = utf8.encode(jsonEncode(header));
    if (headerBytes.length > kMaxFrameHeader) {
      throw FrameException(
        'header of ${headerBytes.length} bytes exceeds '
        'kMaxFrameHeader $kMaxFrameHeader',
      );
    }

    final int total =
        4 + headerBytes.length + (payload == null ? 0 : payload.length);
    final Uint8List out = Uint8List(total);
    final ByteData view = ByteData.view(out.buffer);
    view.setUint32(0, headerBytes.length, Endian.big);
    out.setRange(4, 4 + headerBytes.length, headerBytes);
    if (payload != null) {
      out.setRange(4 + headerBytes.length, total, payload);
    }
    return out;
  }
}

/// Reassembles frames from a byte stream that arrives in arbitrary pieces.
///
/// A socket hands over whatever the network delivered: half a frame, three
/// frames, or one frame split across a dozen reads. This holds the remainder
/// between calls so the caller can treat the stream as a sequence of frames
/// without any framing logic of its own.
class FrameDecoder {
  final _ByteQueue _buffer = _ByteQueue();
  final List<Frame> _ready = <Frame>[];

  /// Whether the stream has been declared unusable.
  ///
  /// Once set, the buffer is abandoned and further calls are refused: the bytes
  /// after a framing error cannot be trusted to be frame boundaries, so
  /// resynchronising would risk acting on whatever happens to look like a
  /// header. The connection is finished.
  bool get isBroken => _broken;

  bool _broken = false;

  /// Feeds [chunk] in and returns every frame that became complete.
  ///
  /// Returns an empty list when the chunk only advanced a partial frame.
  /// Throws [FrameException] if the stream cannot be a frame stream.
  List<Frame> add(List<int> chunk) {
    if (_broken) {
      throw const FrameException('decoder was declared broken by an earlier error');
    }
    _ready.clear();
    _buffer.add(chunk);
    try {
      _drain();
    } on FrameException {
      // The buffer is dropped here rather than kept for forensics: it may hold
      // a peer-controlled number of bytes, and the connection is over anyway.
      _broken = true;
      _buffer.clear();
      rethrow;
    }
    if (_ready.isEmpty) {
      return const <Frame>[];
    }
    final List<Frame> out = List<Frame>.of(_ready);
    _ready.clear();
    return out;
  }

  /// Drops everything buffered. Used when a connection is reset.
  void reset() {
    _buffer.clear();
    _ready.clear();
    _broken = false;
  }

  void _drain() {
    while (true) {
      if (_buffer.length < 4) {
        return;
      }
      final int headerLen = _buffer.uint32At(0);
      if (headerLen > kMaxFrameHeader) {
        throw FrameException(
          'header length $headerLen exceeds kMaxFrameHeader $kMaxFrameHeader',
        );
      }
      if (_buffer.length < 4 + headerLen) {
        return; // header still arriving
      }

      final Map<String, Object?> header = _parseHeader(headerLen);
      final Object? rawSize = header[kFrameSizeKey];
      int payloadLen = 0;
      if (rawSize != null) {
        if (rawSize is! int || rawSize < 0) {
          throw FrameException('"$kFrameSizeKey" must be a non-negative int');
        }
        if (rawSize > kMaxPayload) {
          throw FrameException(
            'payload of $rawSize bytes exceeds kMaxPayload $kMaxPayload',
          );
        }
        payloadLen = rawSize;
      }

      if (_buffer.length < 4 + headerLen + payloadLen) {
        return; // payload still arriving
      }

      final Uint8List? payload = payloadLen == 0
          ? null
          : _buffer.copy(4 + headerLen, payloadLen);
      _buffer.consume(4 + headerLen + payloadLen);
      _ready.add(Frame(header, payload: payload));
    }
  }

  Map<String, Object?> _parseHeader(int headerLen) {
    final Uint8List bytes = _buffer.copy(4, headerLen);
    final String text;
    try {
      text = utf8.decode(bytes);
    } on FormatException catch (error) {
      throw FrameException('header is not valid UTF-8: ${error.message}');
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException catch (error) {
      throw FrameException('header is not valid JSON: ${error.message}');
    }
    if (decoded is! Map<String, Object?>) {
      throw FrameException('header must be a JSON object, got ${decoded.runtimeType}');
    }

    final Object? type = decoded['type'];
    if (type is! String || type.isEmpty) {
      throw FrameException('header has no usable "type"');
    }
    return decoded;
  }
}

/// A growable byte buffer with a consume cursor.
///
/// `List<int>` would be simpler but costs a bounds-checked growable-array write
/// per byte, and `file_data` frames are 256 KB of payload each (§4.6). This
/// keeps one backing [Uint8List] and compacts only when it has to grow, so a
/// steady stream of frames reuses the same allocation instead of copying the
/// remainder forward on every consume.
class _ByteQueue {
  Uint8List _data = Uint8List(0);
  int _start = 0;
  int _end = 0;

  int get length => _end - _start;

  void add(List<int> chunk) {
    if (chunk.isEmpty) {
      return;
    }
    final int needed = length + chunk.length;
    if (needed > _data.length) {
      int capacity = _data.isEmpty ? 1024 : _data.length;
      while (capacity < needed) {
        capacity *= 2;
      }
      final Uint8List grown = Uint8List(capacity);
      grown.setRange(0, length, _data, _start);
      _data = grown;
      _end = length;
      _start = 0;
    }
    _data.setRange(_end, _end + chunk.length, chunk);
    _end += chunk.length;
  }

  /// Big-endian uint32 at [offset], which the caller has bounds-checked.
  int uint32At(int offset) {
    final int i = _start + offset;
    return (_data[i] << 24) |
        (_data[i + 1] << 16) |
        (_data[i + 2] << 8) |
        _data[i + 3];
  }

  /// A copy of [count] bytes at [offset]. A copy rather than a view: the
  /// backing store is reused and compacted, so a view would be silently
  /// rewritten under whoever holds it.
  Uint8List copy(int offset, int count) =>
      Uint8List.fromList(Uint8List.sublistView(_data, _start + offset, _start + offset + count));

  void consume(int count) {
    _start += count;
    if (_start >= _end) {
      _start = 0;
      _end = 0;
    }
  }

  void clear() {
    _data = Uint8List(0);
    _start = 0;
    _end = 0;
  }
}
