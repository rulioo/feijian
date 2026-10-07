import 'dart:convert';

import '../constants.dart';
import '../models/manifest_entry.dart';
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
    this.xferId,
  });

  final ConnectionRole role;
  final String deviceId;
  final String name;
  final DeviceType deviceType;
  final DeviceIcon icon;

  /// Which transfer a `role: data` connection belongs to — design.md §4.3.
  ///
  /// The `file_data` frames carry an `xferId` too, but the first thing a
  /// receiver sees on a data socket is this `hello`, and nothing in it used to
  /// say which file the socket was for. A peer may have up to
  /// `kMaxConcurrentXfers` transfers running at once, so the receiver would have
  /// had to buffer frames from an unattributed socket and wait for a `file_data`
  /// to guess — and a sender that opened the connection and then stalled would
  /// leave a socket nobody could account for.
  ///
  /// Null on control connections, and null is also what an older peer sends, so
  /// the field is additive: §4.3's rule that unknown fields are ignored keeps
  /// both directions working across versions.
  final String? xferId;

  /// The peer's TCP listen port, so a reply keeps working after it moves off
  /// the default.
  final int port;

  /// Protocol version, so a future mismatch can be reported rather than
  /// producing confusing failures deeper in.
  final int version;

  /// Capabilities this build supports. Unknown values are ignored and passed
  /// through, which is what lets a newer peer advertise one harmlessly.
  final List<String> caps;

  /// The same identity, answering [request].
  ///
  /// Needed on the accepting side: we must answer a `hello` with one of our own,
  /// and two things about that answer come from the request rather than from us.
  /// The **role**, because one listening socket serves both kinds and only the
  /// request says which this connection is. And the **transfer**, because a peer
  /// opens a data socket for one specific transfer and has to get its own
  /// `xferId` back to recognise the connection it asked for — a `hello` with the
  /// right role and no transfer would leave the dialler unable to tell its data
  /// connection from any other socket that happened to answer.
  ///
  /// Our own [xferId] is deliberately not used: it is null on every control
  /// connection, and echoing it at a peer that asked about a different transfer
  /// would be worse than saying nothing.
  HelloPayload answering(HelloPayload request) {
    return HelloPayload(
      role: request.role,
      deviceId: deviceId,
      name: name,
      deviceType: deviceType,
      icon: icon,
      port: port,
      version: version,
      caps: caps,
      xferId: request.xferId,
    );
  }

  /// The same identity, asking for [role] on behalf of [xferId].
  HelloPayload forTransfer(String xferId) {
    return HelloPayload(
      role: ConnectionRole.data,
      deviceId: deviceId,
      name: name,
      deviceType: deviceType,
      icon: icon,
      port: port,
      version: version,
      caps: caps,
      xferId: xferId,
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
      // Omitted rather than sent as null on a control connection, so its wire
      // form is byte-for-byte what it was before this field existed.
      if (xferId != null) 'xferId': xferId,
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

    // Optional, and absent from every control connection. A malformed one is
    // dropped rather than refused: the connection is still usable, and the
    // transfer layer will find nothing to attach it to and close it, which is
    // the same outcome with a clearer log line.
    final String? xferId = _string(frame, 'xferId');
    final String? usableXferId =
        (xferId == null || xferId.isEmpty || xferId.length > kMaxXferIdLength)
            ? null
            : xferId;

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
        xferId: usableXferId,
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

/// Why a receiver turned a `file_offer` down — design.md §4.3, §4.6.
///
/// A code rather than a sentence, because the reason is shown to *our* user and
/// has to come out of our own `.arb` file. Passing the peer's prose through
/// would put unlocalisable, attacker-chosen text in the UI, and would mean every
/// peer's phrasing had to be understood to be displayed.
///
/// An unrecognised code reads as [unknown]: a newer build may have added one,
/// and §4.3's rule is to carry on rather than refuse the frame.
enum RejectReason {
  /// The user pressed "Decline". The only one that is a decision rather than a
  /// failure.
  declined('declined'),

  /// Too many transfers in flight, or the disk is full.
  busy('busy'),

  /// This build cannot do what was offered. M4 sends and receives folders, so
  /// nothing refuses one for being a folder any more; what still ends here is
  /// §4.6 rule 5's manifest too large to send, refused whole rather than
  /// half-sent.
  unsupported('unsupported'),

  /// The offered file is gone on the sending side, or was never there.
  notFound('not_found'),

  /// The transfer was accepted and then abandoned — the user cancelled it, or
  /// the data connection never came up.
  cancelled('cancelled'),

  /// A code this build does not know.
  unknown('unknown');

  const RejectReason(this.wire);

  final String wire;

  static RejectReason fromWire(Object? value) {
    for (final RejectReason reason in RejectReason.values) {
      if (reason != RejectReason.unknown && reason.wire == value) {
        return reason;
      }
    }
    return RejectReason.unknown;
  }
}

/// `file_offer` — a sender proposing a transfer — design.md §4.3.
class FileOfferPayload {
  const FileOfferPayload({
    required this.xferId,
    required this.name,
    required this.totalSize,
    this.mime,
    this.isDir = false,
    this.sha256,
    this.mtime,
    this.files = const <ManifestEntry>[],
  });

  /// Names this transfer for the rest of its life. Every `file_data`,
  /// `file_accept` and `file_done` in it carries the same value.
  final String xferId;

  /// The file's name, as the sender has it. Never trusted as a path — see
  /// [SafeName], which is what turns this into something safe to create.
  final String name;

  /// Size in bytes, named `totalSize` and not `size` because `size` is the
  /// frame layer's own field (design.md §4.2).
  final int totalSize;

  final String? mime;

  /// A folder offer, which carries [files] as well as its own name and total
  /// size — design.md §4.6 rules 1 and 2.
  final bool isDir;

  /// What is inside the folder, in the order the sender means to send it.
  ///
  /// Empty for a plain file offer, and for a folder it is the whole transfer's
  /// description: the receiver builds every attachment row it will need from
  /// this list before it answers, so that accepting is a promise it can keep.
  ///
  /// The directories are in here too. An empty directory produces no file
  /// entries, so if §4.6 rule 4's "空目录也要创建" is to be kept there has to be
  /// an entry that says it exists.
  final List<ManifestEntry> files;

  /// Hex digest of the file, when the sender chose to compute one.
  final String? sha256;

  /// The file's modification time, milliseconds since the epoch, so a receiver
  /// can tell an interrupted transfer of *this* file from a different file that
  /// shares its name. Advisory, like every other timestamp off the wire.
  final int? mtime;

  /// How many of [files] are files rather than directories.
  ///
  /// Computed, not read. The header carries a `fileCount` and [toFrame] writes
  /// one, because §4.3 names the field and a peer is entitled to it — but a
  /// second count that can disagree with the manifest is a second answer to the
  /// same question, and nothing in this build has a use for a number it would
  /// first have to reconcile.
  int get fileCount =>
      files.where((ManifestEntry entry) => !entry.isDir).length;

  Frame toFrame() {
    return Frame.of(FrameType.fileOffer, <String, Object?>{
      'xferId': xferId,
      'name': name,
      'totalSize': totalSize,
      if (mime != null) 'mime': mime,
      // Omitted when false: a plain file offer is what every peer already
      // understands, and its wire form should not gain a field for a feature
      // it does not have.
      if (isDir) 'isDir': true,
      if (sha256 != null) 'sha256': sha256,
      if (mtime != null) 'mtime': mtime,
      // Written whenever this is a folder, **including when it is empty**. The
      // key's presence is how a receiver tells "a folder whose manifest I can
      // read" from "a folder offer carrying no manifest at all", and an empty
      // folder is a perfectly ordinary thing to send.
      if (isDir) 'fileCount': fileCount,
      if (isDir)
        'files': <Map<String, Object?>>[
          for (final ManifestEntry entry in files) entry.toJson(),
        ],
    });
  }

  static PayloadDecode<FileOfferPayload> from(Frame frame) {
    final PayloadDecode<String> xferId = _xferId(frame);
    if (!xferId.isSuccess) {
      return PayloadDecode<FileOfferPayload>.failure(xferId.reason!);
    }

    final String? name = _string(frame, 'name');
    if (name == null || name.isEmpty) {
      return const PayloadDecode<FileOfferPayload>.failure('missing "name"');
    }
    if (name.length > kMaxFileNameLength) {
      return const PayloadDecode<FileOfferPayload>.failure('"name" too long');
    }

    final int? totalSize = _int(frame, 'totalSize');
    if (totalSize == null || totalSize < 0) {
      // `is! int` already covers a peer whose JSON writes it as a float or a
      // string, and a negative size has no meaning to fall back to. Unlike a
      // timestamp, there is no sensible default: guessing here would mean
      // writing a file to a length the sender never agreed to.
      return const PayloadDecode<FileOfferPayload>.failure(
        '"totalSize" must be a non-negative int',
      );
    }

    // Anything not exactly `true` is a plain file. A peer that writes
    // `"isDir": "yes"` means "something I thought was true", and treating
    // that as a folder would refuse an ordinary file transfer.
    final bool isDir = frame.header['isDir'] == true;

    List<ManifestEntry> files = const <ManifestEntry>[];
    if (isDir) {
      final PayloadDecode<List<ManifestEntry>> manifest = _manifest(frame);
      if (!manifest.isSuccess) {
        return PayloadDecode<FileOfferPayload>.failure(manifest.reason!);
      }
      files = manifest.value!;
    }

    return PayloadDecode<FileOfferPayload>.success(
      FileOfferPayload(
        xferId: xferId.value!,
        name: name,
        totalSize: totalSize,
        mime: _bounded(frame, 'mime', kMaxMimeLength),
        isDir: isDir,
        sha256: _digest(frame, 'sha256'),
        mtime: _positive(frame, 'mtime'),
        files: files,
      ),
    );
  }
}

/// Reads a folder's manifest — design.md §4.3's `files`.
///
/// Strict where the optional display fields are not, because nothing here is
/// display-only: a `relPath` is where a file will be created and a `size` is how
/// many bytes will be written to it. An entry this build cannot make sense of
/// fails the whole offer rather than being dropped, for the reason §4.6 rule 5
/// gives about a truncated manifest — a folder that arrives looking complete
/// while missing files is worse than one that does not arrive at all.
///
/// The byte ceiling is checked on the encoded list before any entry is parsed,
/// which is where §4.6 rule 5's 256 KB lives for a receiver: a peer is welcome
/// to offer a folder, and not welcome to spend a megabyte of header doing it.
PayloadDecode<List<ManifestEntry>> _manifest(Frame frame) {
  final Object? raw = frame.header['files'];
  if (raw is! List) {
    // Absent or the wrong shape. A folder offer has to carry a manifest: there
    // is nothing else in the frame that says what is inside the folder.
    return const PayloadDecode<List<ManifestEntry>>.failure('missing "files"');
  }

  final int bytes = utf8.encode(jsonEncode(raw)).length;
  if (bytes > kMaxManifestBytes) {
    return PayloadDecode<List<ManifestEntry>>.failure(
      '"files" is $bytes bytes, over the $kMaxManifestBytes byte limit',
    );
  }

  final List<ManifestEntry> entries = <ManifestEntry>[];
  for (final Object? item in raw) {
    if (item is! Map) {
      return const PayloadDecode<List<ManifestEntry>>.failure(
        'a manifest entry is not an object',
      );
    }

    final Object? relPath = item['relPath'];
    if (relPath is! String || relPath.isEmpty) {
      return const PayloadDecode<List<ManifestEntry>>.failure(
        'a manifest entry has no "relPath"',
      );
    }
    if (utf8.encode(relPath).length > kMaxRelPathLength) {
      return const PayloadDecode<List<ManifestEntry>>.failure(
        'a manifest "relPath" is too long',
      );
    }

    final Object? size = item['size'];
    if (size is! int || size < 0) {
      return const PayloadDecode<List<ManifestEntry>>.failure(
        'a manifest "size" must be a non-negative int',
      );
    }

    final Object? mtime = item['mtime'];
    if (mtime != null && (mtime is! int || mtime <= 0)) {
      return const PayloadDecode<List<ManifestEntry>>.failure(
        'a manifest "mtime" must be a positive int',
      );
    }

    // Anything not exactly `true` is a file, the same rule the offer's own
    // `isDir` follows and for the same reason: a peer that writes
    // `"isDir": "yes"` means "something I thought was true", and refusing the
    // whole folder over it loses a transfer that is otherwise perfectly
    // describable. The mistake still surfaces — a sender that called a
    // directory a file sends no bytes for it, and a file that turns out to have
    // children fails when the receiver tries to create them underneath.
    entries.add(ManifestEntry(
      relPath: relPath,
      size: size,
      mtime: mtime as int?,
      isDir: item['isDir'] == true,
    ));
  }

  return PayloadDecode<List<ManifestEntry>>.success(
    List<ManifestEntry>.unmodifiable(entries),
  );
}

/// `file_accept` — the receiver agreeing to a `file_offer` — design.md §4.3.
class FileAcceptPayload {
  const FileAcceptPayload({required this.xferId, this.resumeFrom = 0});

  final String xferId;

  /// The offset the sender should start at, because the receiver already holds
  /// that many bytes. Always 0 in this build: resuming needs the `transfer` row
  /// to tell an interrupted transfer from a different file with the same name
  /// (design.md §4.6.1), and that is not wired up yet.
  final int resumeFrom;

  Frame toFrame() {
    return Frame.of(FrameType.fileAccept, <String, Object?>{
      'xferId': xferId,
      'resumeFrom': resumeFrom,
    });
  }

  static PayloadDecode<FileAcceptPayload> from(Frame frame) {
    final PayloadDecode<String> xferId = _xferId(frame);
    if (!xferId.isSuccess) {
      return PayloadDecode<FileAcceptPayload>.failure(xferId.reason!);
    }
    final Object? raw = frame.header['resumeFrom'];
    // Absent means "from the beginning", which is the only thing a peer that
    // does not send the field can mean. Present but nonsensical is different:
    // a negative or non-integer offset would have us seek into a file at a
    // position that does not exist, so it is refused rather than defaulted.
    if (raw != null && (raw is! int || raw < 0)) {
      return const PayloadDecode<FileAcceptPayload>.failure(
        '"resumeFrom" must be a non-negative int',
      );
    }
    return PayloadDecode<FileAcceptPayload>.success(
      FileAcceptPayload(xferId: xferId.value!, resumeFrom: raw as int? ?? 0),
    );
  }
}

/// `file_reject` — the receiver turning a `file_offer` down — design.md §4.3.
class FileRejectPayload {
  const FileRejectPayload({
    required this.xferId,
    this.reason = RejectReason.declined,
  });

  final String xferId;

  /// Why, as a code the receiving UI turns into its own words. A missing or
  /// unrecognised code reads as [RejectReason.unknown] rather than as a
  /// decline: "the peer said no for a reason I did not understand" and "the
  /// user pressed Decline" are different things to show someone.
  final RejectReason reason;

  Frame toFrame() {
    return Frame.of(FrameType.fileReject, <String, Object?>{
      'xferId': xferId,
      'reason': reason.wire,
    });
  }

  static PayloadDecode<FileRejectPayload> from(Frame frame) {
    final PayloadDecode<String> xferId = _xferId(frame);
    if (!xferId.isSuccess) {
      return PayloadDecode<FileRejectPayload>.failure(xferId.reason!);
    }
    return PayloadDecode<FileRejectPayload>.success(
      FileRejectPayload(
        xferId: xferId.value!,
        reason: RejectReason.fromWire(_string(frame, 'reason')),
      ),
    );
  }
}

/// `file_done`, `file_cancel` and `xfer_done` — design.md §4.3.
///
/// One class for three frame types, because they differ in what they mean and
/// not in what they carry. Three identical parse-and-serialise pairs would be
/// three copies of the same field check.
///
/// `file_data` deliberately has no class here: the only thing that reads one is
/// `TransferReceiver`, which checks more than a payload reader would — that the
/// chunk starts exactly where the file has got to, and that it does not overrun
/// the offered size. A second parser here would be a second answer to the same
/// question.
class TransferRefPayload {
  const TransferRefPayload({required this.xferId, this.relPath});

  final String xferId;

  /// Which file inside a folder this is about.
  ///
  /// §4.6 rule 3 gives every file in a folder its own data connection, so "this
  /// one landed" and "stop this one" both have to name one: a `file_done` that
  /// said only `xferId` would be a receipt for a folder, and the sender — which
  /// is waiting before it opens the *next* file's connection — would have no way
  /// to tell a receipt for the file it just sent from a stray one.
  ///
  /// Null for a transfer that is a single file, which is not inside anything.
  final String? relPath;

  Frame toFrame(String type) => Frame.of(type, <String, Object?>{
        'xferId': xferId,
        // Omitted rather than written as null, like every other optional field
        // here: a single-file transfer's frames are byte-for-byte the ones M3
        // sent, which is what keeps an older peer able to read them.
        if (relPath != null) 'relPath': relPath,
      });

  static PayloadDecode<TransferRefPayload> from(Frame frame) {
    final PayloadDecode<String> xferId = _xferId(frame);
    if (!xferId.isSuccess) {
      return PayloadDecode<TransferRefPayload>.failure(xferId.reason!);
    }

    final Object? relPath = frame.header['relPath'];
    if (relPath != null) {
      if (relPath is! String ||
          relPath.isEmpty ||
          utf8.encode(relPath).length > kMaxRelPathLength) {
        return const PayloadDecode<TransferRefPayload>.failure(
          '"relPath" must be a non-empty string within the limit',
        );
      }
    }

    return PayloadDecode<TransferRefPayload>.success(
      TransferRefPayload(xferId: xferId.value!, relPath: relPath as String?),
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

/// Reads the `xferId` every transfer frame must carry.
///
/// Shared because the bound is what matters, not the frame: an unbounded id
/// from the network would be stored, echoed back and used as a map key, and
/// nothing else in the header can be reached before this check passes.
PayloadDecode<String> _xferId(Frame frame) {
  final String? value = _string(frame, 'xferId');
  if (value == null || value.isEmpty) {
    return const PayloadDecode<String>.failure('missing "xferId"');
  }
  if (value.length > kMaxXferIdLength) {
    return const PayloadDecode<String>.failure('"xferId" too long');
  }
  return PayloadDecode<String>.success(value);
}

/// An optional string field, dropped rather than refused when it is too long.
///
/// Every field this serves is display-only — a MIME type decides which icon a
/// bubble gets and nothing else — so the useful answer to an absurd one is
/// "none", not "this offer is malformed".
String? _bounded(Frame frame, String key, int max) {
  final String? value = _string(frame, key);
  if (value == null || value.isEmpty || value.length > max) {
    return null;
  }
  return value;
}

/// An optional checksum, dropped unless it is a well-formed SHA-256 hex digest.
///
/// Verifying it is not this build's job yet, but a value that could not be a
/// digest is worse than no value: it would be stored, shown, and later compared
/// against a real one as though the two were the same kind of thing.
String? _digest(Frame frame, String key) {
  final String? value = _string(frame, key);
  if (value == null || value.length != 64) {
    return null;
  }
  for (final int unit in value.codeUnits) {
    final bool hex = (unit >= 0x30 && unit <= 0x39) || // 0-9
        (unit >= 0x61 && unit <= 0x66); // a-f
    if (!hex) {
      return null;
    }
  }
  return value;
}

/// An optional positive integer, or null. Zero is treated as absent: an
/// unset `mtime` is written as 0 by more than one file system API, and the
/// epoch is not a modification time anyone wants to see.
int? _positive(Frame frame, String key) {
  final int? value = _int(frame, key);
  return (value == null || value <= 0) ? null : value;
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
