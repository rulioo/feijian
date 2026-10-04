import '../constants.dart';
import '../models/peer.dart';
import 'frame_codec.dart';

/// The outcome of reading a payload off a frame.
///
/// Parsing never throws. Frames arrive from the network, so a malformed one is
/// an ordinary event to be logged and skipped, not an exception to unwind a
/// socket callback with — same contract as `AnnounceDecode` on the discovery
/// side. A caller that gets [failure] ignores the frame; `§4.3` only requires
/// dropping the *connection* for framing errors, not for a payload it cannot
/// make sense of.
class PayloadDecode<T extends Object> {
  const PayloadDecode.success(T this.value) : reason = null;

  const PayloadDecode.failure(this.reason) : value = null;

  final T? value;
  final String? reason;

  bool get isSuccess => value != null;
}

/// What a connection is for — design.md §4.4.
///
/// One TCP port carries both, told apart by the `role` in the first `hello`.
/// A `data` connection exists for the length of one file transfer and is then
/// closed; a `control` one is kept alive as long as the peer is reachable.
enum ConnectionRole {
  control('control'),
  data('data');

  const ConnectionRole(this.wire);

  final String wire;

  static ConnectionRole? fromWire(Object? value) {
    for (final ConnectionRole role in ConnectionRole.values) {
      if (role.wire == value) {
        return role;
      }
    }
    return null;
  }
}

/// `hello` — the first frame on every connection — design.md §4.3.
///
/// Carries the same identity fields as an ANNOUNCE, because a connection can
/// arrive from a peer we have not heard on the discovery channel yet, or whose
/// address has changed since we last did.
class HelloPayload {
  const HelloPayload({
    required this.role,
    required this.deviceId,
    required this.name,
    required this.deviceType,
    required this.icon,
    required this.port,
    required this.version,
    this.caps = const <String>[],
  });

  final ConnectionRole role;
  final String deviceId;
  final String name;
  final DeviceType deviceType;
  final DeviceIcon icon;

  /// The peer's TCP listen port, so a reply keeps working after it moves off
  /// the default.
  final int port;

  /// Protocol version, so a future mismatch can be reported rather than
  /// producing confusing failures deeper in.
  final int version;

  /// Capabilities this build supports. Unknown values are ignored and passed
  /// through, which is what lets a newer peer advertise one harmlessly.
  final List<String> caps;

  /// The same identity asking for a different [ConnectionRole].
  ///
  /// Needed on the accepting side: we must answer a `hello` with one of our own,
  /// and the role we answer with has to be the role the peer asked for. Our own
  /// listening socket does not know which it will be until the first frame
  /// arrives, so the role is decided there rather than at configuration time.
  HelloPayload withRole(ConnectionRole role) {
    if (role == this.role) {
      return this;
    }
    return HelloPayload(
      role: role,
      deviceId: deviceId,
      name: name,
      deviceType: deviceType,
      icon: icon,
      port: port,
      version: version,
      caps: caps,
    );
  }

  Frame toFrame() {
    return Frame.of(FrameType.hello, <String, Object?>{
      'role': role.wire,
      'deviceId': deviceId,
      'name': name,
      'device': deviceType.wire,
      'icon': icon.wire,
      'port': port,
      'version': version,
      'caps': caps,
    });
  }

  static PayloadDecode<HelloPayload> from(Frame frame) {
    final ConnectionRole? role = ConnectionRole.fromWire(frame.header['role']);
    if (role == null) {
      return const PayloadDecode<HelloPayload>.failure('unknown "role"');
    }
    final String? deviceId = _string(frame, 'deviceId');
    if (deviceId == null || deviceId.isEmpty) {
      return const PayloadDecode<HelloPayload>.failure('missing "deviceId"');
    }
    if (deviceId.length > kMaxDeviceIdLength) {
      return const PayloadDecode<HelloPayload>.failure('"deviceId" too long');
    }
    final String? name = _string(frame, 'name');
    if (name == null || name.isEmpty) {
      return const PayloadDecode<HelloPayload>.failure('missing "name"');
    }
    if (name.length > kMaxDeviceNameLength) {
      return const PayloadDecode<HelloPayload>.failure('"name" too long');
    }
    final int? port = _int(frame, 'port');
    if (port == null || port < 1 || port > 65535) {
      return const PayloadDecode<HelloPayload>.failure('"port" out of range');
    }
    final int? version = _int(frame, 'version');
    if (version == null || version < 1) {
      return const PayloadDecode<HelloPayload>.failure('missing "version"');
    }

    return PayloadDecode<HelloPayload>.success(
      HelloPayload(
        role: role,
        deviceId: deviceId,
        name: name,
        // Unknown platform or icon is not a reason to refuse a connection:
        // both are display-only, and the defaults already mean "unknown".
        deviceType: DeviceType.fromWire(_string(frame, 'device')),
        icon: DeviceIcon.fromWire(_string(frame, 'icon')),
        port: port,
        version: version,
        caps: _stringList(frame, 'caps'),
      ),
    );
  }
}

/// `msg` — a text message — design.md §4.3.
class MessagePayload {
  const MessagePayload({
    required this.msgId,
    required this.ts,
    required this.text,
    this.replyTo,
  });

  /// UUIDv4, unique across the whole network, and the key the receiver dedupes
  /// on (design.md §4.5). Re-sends deliberately reuse it.
  final String msgId;

  /// When the sender wrote it.
  ///
  /// Milliseconds since the epoch, matching the `message.created_at` column
  /// (design.md §5.1). Note the discovery datagram uses *seconds* for the same
  /// `ts` name — that one is squeezed into an MTU budget, this one is not.
  ///
  /// Advisory only: §4.5 sorts by the *local* timestamp, never the peer's,
  /// because two consumer devices routinely disagree about the time.
  final DateTime ts;

  final String text;

  /// The `msgId` this one answers, for threading a reply.
  final String? replyTo;

  Frame toFrame() {
    return Frame.of(FrameType.msg, <String, Object?>{
      'msgId': msgId,
      'ts': ts.millisecondsSinceEpoch,
      'text': text,
      if (replyTo != null) 'replyTo': replyTo,
    });
  }

  static PayloadDecode<MessagePayload> from(Frame frame) {
    final String? msgId = _string(frame, 'msgId');
    if (msgId == null || msgId.isEmpty) {
      return const PayloadDecode<MessagePayload>.failure('missing "msgId"');
    }
    final String? text = _string(frame, 'text');
    if (text == null) {
      return const PayloadDecode<MessagePayload>.failure('missing "text"');
    }
    // A guard against filling the local database from the network, not a
    // product limit — a chat message is orders of magnitude smaller than this.
    if (text.length > kMaxMessageTextLength) {
      return const PayloadDecode<MessagePayload>.failure('"text" too long');
    }
    return PayloadDecode<MessagePayload>.success(
      MessagePayload(
        msgId: msgId,
        ts: _timestamp(frame, 'ts'),
        text: text,
        replyTo: _string(frame, 'replyTo'),
      ),
    );
  }
}

/// `msg_ack` — the receiver confirming it has the message — design.md §4.5.
class MsgAckPayload {
  const MsgAckPayload({required this.msgId, required this.ts});

  final String msgId;
  final DateTime ts;

  Frame toFrame() {
    return Frame.of(FrameType.msgAck, <String, Object?>{
      'msgId': msgId,
      'ts': ts.millisecondsSinceEpoch,
    });
  }

  static PayloadDecode<MsgAckPayload> from(Frame frame) {
    final String? msgId = _string(frame, 'msgId');
    if (msgId == null || msgId.isEmpty) {
      return const PayloadDecode<MsgAckPayload>.failure('missing "msgId"');
    }
    return PayloadDecode<MsgAckPayload>.success(
      MsgAckPayload(msgId: msgId, ts: _timestamp(frame, 'ts')),
    );
  }
}

/// `ping` and `pong`, which differ only in their `type` — design.md §4.3.
class HeartbeatPayload {
  const HeartbeatPayload({required this.ts});

  final DateTime ts;

  Frame toFrame(String type) {
    return Frame.of(type, <String, Object?>{'ts': ts.millisecondsSinceEpoch});
  }

  static PayloadDecode<HeartbeatPayload> from(Frame frame) {
    return PayloadDecode<HeartbeatPayload>.success(
      HeartbeatPayload(ts: _timestamp(frame, 'ts')),
    );
  }
}

// --- Field readers ----------------------------------------------------------
//
// Absent is not the same as wrong: a missing optional field yields a default,
// while a field that is present but of the wrong type yields null so the caller
// can reject the frame. That distinction is what keeps a malformed peer from
// being read as a valid one with defaults.

String? _string(Frame frame, String key) {
  final Object? value = frame.header[key];
  return value is String ? value : null;
}

int? _int(Frame frame, String key) {
  final Object? value = frame.header[key];
  return value is int ? value : null;
}

List<String> _stringList(Frame frame, String key) {
  final Object? value = frame.header[key];
  if (value is! List) {
    return const <String>[];
  }
  return value.whereType<String>().toList(growable: false);
}

/// Reads a millisecond timestamp, falling back to the local clock.
///
/// `ts` is advisory (§4.5), so a missing or nonsensical one must not reject an
/// otherwise good message; the local clock is a better answer than dropping it.
/// The epoch fallback covers a peer whose clock is unset.
DateTime _timestamp(Frame frame, String key) {
  final int? raw = _int(frame, key);
  if (raw == null || raw <= 0) {
    return DateTime.now();
  }
  final DateTime parsed = DateTime.fromMillisecondsSinceEpoch(raw);
  // A peer claiming a date far outside anything plausible is broken, not
  // informative — clamp to now rather than propagating it into sorting.
  final Duration drift = DateTime.now().difference(parsed).abs();
  if (drift > kFrameMaxClockSkew) {
    return DateTime.now();
  }
  return parsed;
}
