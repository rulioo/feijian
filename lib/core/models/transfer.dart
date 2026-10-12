import 'message.dart';

/// One file attached to one message — design.md §5.1 `attachment`.
///
/// A list per message in the schema, because a transferred folder is one message
/// with many attachments. v1 sends one file per message, so in practice a
/// message has exactly one — but the model is the schema's, not the milestone's,
/// or adding folders later would mean rewriting everything that touches an
/// attachment.
///
/// Pure Dart, like [Message]: the progress and state rules are unit-testable
/// without a device.
class Attachment {
  const Attachment({
    required this.id,
    required this.messageId,
    required this.fileName,
    required this.size,
    required this.state,
    this.relPath,
    this.mime,
    this.localPath,
    this.thumbPath,
    this.sha256,
    this.transferred = 0,
  });

  /// Locally generated. Not on the wire: the sender names a transfer with
  /// `xferId` and a message with `msgId`, and the receiver mints its own
  /// attachment id when it stores the offer.
  final String id;

  final String messageId;

  /// The name as the sender has it, already made safe for a file system by
  /// `SafeName` on the receiving side. Displayed as-is.
  final String fileName;

  /// Path inside a transferred folder, for a folder transfer. Null for a single
  /// file, which has no structure to rebuild.
  final String? relPath;

  final int size;

  final String? mime;

  /// Where the file is on **this** device.
  ///
  /// §5.1 words this as "the path after receiving", which is the receiving half
  /// of the story. On the sending side it is the file being read, and it is
  /// stored for the same reason: an attachment whose bytes cannot be found has
  /// to say so rather than fail silently when someone clicks it.
  final String? localPath;

  /// Cached thumbnail, so the chat list does not decode full images.
  final String? thumbPath;

  final String? sha256;

  final TransferState state;

  /// Bytes moved so far, for [progress].
  final int transferred;

  /// How much of the file has moved, from 0 to 1.
  ///
  /// A zero-byte file is complete the moment it is agreed to, not stuck at 0 —
  /// which is what dividing by [size] without a special case would say. An
  /// unstarted transfer of a real file is 0.
  double get progress {
    if (state == TransferState.done) {
      return 1;
    }
    if (size == 0) {
      return 1;
    }
    final double ratio = transferred / size;
    return ratio < 0 ? 0 : (ratio > 1 ? 1 : ratio);
  }

  bool get isFinished =>
      state == TransferState.done ||
      state == TransferState.failed ||
      state == TransferState.cancelled ||
      state == TransferState.declined;

  /// Whether the bytes are here to be opened.
  bool get isOpenable => state == TransferState.done && localPath != null;

  /// Whether this is a picture this app can draw — §6.3's image bubble.
  ///
  /// Asked by the chat to decide between a thumbnail and a file card, so the
  /// answer has to be about what a thumbnail *is*, not about what the file
  /// claims to be. Hence the [extensions] list rather than "anything under
  /// `image/`": Flutter's decoders cover those six formats and no others, and
  /// a `.heic` straight off an iPhone or an `.svg` claiming `image/svg+xml`
  /// would answer yes and then render as a broken-image box — a card that at
  /// least names the file and offers to open it is the better answer for both.
  ///
  /// The mime type is consulted first and the extension second, which is the
  /// shared rule in [_matches].
  bool get isImage => _matches(extensions);

  /// Whether the system gallery should index this file.
  ///
  /// Deliberately *not* [isImage], and the difference is a real one: a `.heic`
  /// straight off an iPhone is false there and true here. The two questions only
  /// look alike. [isImage] asks "can this app draw it", and answers no for the
  /// formats Flutter cannot decode, because a broken-image box is worse than an
  /// honest file card. This asks "would the user expect to find it in their
  /// photos", and the phone's own gallery decodes HEIC perfectly well — so
  /// refusing to publish it would lose the pictures most likely to be sent,
  /// which are the ones the camera just took.
  ///
  /// The dividing line is instead: is this a *photograph someone took*. That
  /// keeps `svg` out (a drawing, and a vector one — see [galleryMimes]) and
  /// keeps `tiff` out with it, while letting in every format a phone camera
  /// writes.
  bool get isGalleryImage => _matches(galleryExtensions);

  /// The concrete mime type to hand MediaStore, or null when this file should
  /// not be published to the gallery at all.
  ///
  /// Concrete rather than `image/*` because MediaStore files the row by its
  /// `MIME_TYPE` column — that is what makes the gallery read the row as a
  /// picture rather than as a download — and the sender is not obliged to have
  /// told us one. Which it usually has not: `application/octet-stream` for a
  /// `.jpg` is the common case, so the extension is the fallback that does most
  /// of the work.
  String? get galleryMime {
    final String? subtype = _subtypeOf(mime);
    if (subtype != null && galleryMimes.containsKey(subtype)) {
      return 'image/$subtype';
    }
    final String? own = _extensionOf(fileName);
    return own == null ? null : galleryMimes[own];
  }

  /// The one rule behind [isImage] and [isGalleryImage]: the declared type if it
  /// names a format in [formats], otherwise the extension.
  ///
  /// Both halves are consulted because the two disagree often enough to matter —
  /// a `.jpg` offered as `application/octet-stream` is common, and so is a `.txt`
  /// renamed to `photo.jpg`. The declared type is checked first so a sender who
  /// knows better than the file name is believed.
  bool _matches(Set<String> formats) {
    final String? subtype = _subtypeOf(mime);
    if (subtype != null && formats.contains(subtype)) {
      return true;
    }
    final String? own = _extensionOf(fileName);
    return own != null && formats.contains(own);
  }

  /// The formats Flutter can decode on every platform it builds for.
  ///
  /// `bmp` and `gif` are in; `heic`, `avif`, `tiff` and `svg` are out. A format
  /// that decodes on one platform and not another would make the same message
  /// look different on the two ends of the same transfer, which is worse than
  /// not attempting the picture at all.
  static const Set<String> extensions = <String>{
    'png',
    'jpg',
    'jpeg',
    'gif',
    'webp',
    'bmp',
  };

  /// The formats worth publishing to the gallery, mapped to the mime type
  /// MediaStore needs written alongside each.
  ///
  /// A superset of [extensions]: everything this app can draw is a picture the
  /// user would expect in their photos, plus the three camera formats it cannot
  /// draw. `heic`/`heif` are what an iPhone sends, `avif` is where Android
  /// cameras and browsers are heading, and all three display fine in the gallery
  /// even though they show as a file card inside this app.
  ///
  /// `tiff` and `svg` are out. Both are pictures; neither is a photograph, and a
  /// gallery album full of scanned documents and icons is the complaint that
  /// gets a feature like this turned off.
  static const Map<String, String> galleryMimes = <String, String>{
    'png': 'image/png',
    'jpg': 'image/jpeg',
    'jpeg': 'image/jpeg',
    'gif': 'image/gif',
    'webp': 'image/webp',
    'bmp': 'image/bmp',
    'heic': 'image/heic',
    'heif': 'image/heif',
    'avif': 'image/avif',
  };

  /// [galleryMimes]'s keys, derived rather than written out a second time so the
  /// set of formats and their mime types cannot drift apart. [galleryMime] leans
  /// on that: it answers from the map alone, without first asking whether the
  /// format is in this set.
  static final Set<String> galleryExtensions = galleryMimes.keys.toSet();

  /// The format named by a declared mime type, lowercased and stripped of its
  /// parameters — or null when the declared type is not an image at all.
  ///
  /// Both cuts matter. `; charset=…` is common on anything that HAS been through
  /// a mime sniffer, and `image/svg+xml` is an SVG by the half before the `+` —
  /// which is why this is not `substring('image/'.length)` on the whole string.
  static String? _subtypeOf(String? raw) {
    if (raw == null) {
      return null;
    }
    final String type = raw.toLowerCase().split(';').first.trim();
    if (!type.startsWith('image/')) {
      return null;
    }
    return type.substring('image/'.length).split('+').first;
  }

  /// The text after the last dot, lowercased — or null when there is nothing
  /// after it, which is why this is not `split('.').last`.
  static String? _extensionOf(String value) {
    // A dot at index 0 is a hidden file's name, not an extension: `.gitignore`
    // has no type.
    final int dot = value.lastIndexOf('.');
    if (dot <= 0 || dot == value.length - 1) {
      return null;
    }
    return value.substring(dot + 1).toLowerCase();
  }

  Attachment copyWith({
    TransferState? state,
    int? transferred,
    String? localPath,
    String? thumbPath,
  }) {
    return Attachment(
      id: id,
      messageId: messageId,
      fileName: fileName,
      size: size,
      state: state ?? this.state,
      relPath: relPath,
      mime: mime,
      localPath: localPath ?? this.localPath,
      thumbPath: thumbPath ?? this.thumbPath,
      sha256: sha256,
      transferred: transferred ?? this.transferred,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Attachment &&
      other.id == id &&
      other.messageId == messageId &&
      other.fileName == fileName &&
      other.size == size &&
      other.state == state &&
      other.relPath == relPath &&
      other.mime == mime &&
      other.localPath == localPath &&
      other.thumbPath == thumbPath &&
      other.sha256 == sha256 &&
      other.transferred == transferred;

  @override
  int get hashCode => Object.hash(
        id,
        messageId,
        fileName,
        size,
        state,
        relPath,
        mime,
        localPath,
        thumbPath,
        sha256,
        transferred,
      );

  @override
  String toString() => 'Attachment($id, $fileName, $state, $transferred/$size)';
}

/// One transfer task — design.md §5.1 `transfer`.
///
/// Separate from [Attachment] because the two answer different questions. An
/// attachment is *what* was sent, and outlives the attempt: it is still there
/// when the file has landed and is being opened, and still there when the
/// transfer failed and only a name and a size remain. A transfer is *how* it is
/// being sent, and is what carries the byte count, the partial path and the
/// state machine that a retry or a resume needs.
class Transfer {
  const Transfer({
    required this.id,
    required this.peerId,
    required this.direction,
    required this.state,
    required this.bytesTotal,
    required this.updatedAt,
    this.messageId,
    this.attachmentId,
    this.bytesDone = 0,
    this.tempPath,
  });

  /// The `xferId` from the wire, so both ends name the same thing and a
  /// `file_data` frame can be attributed to a row without a lookup table.
  final String id;

  /// Null while an offer is being made before the message row exists. §5.1
  /// leaves the reference nullable precisely so a transfer can outlive a
  /// cleared history.
  final String? messageId;

  final String? attachmentId;

  final String peerId;

  /// `'in'` or `'out'`, from this device's point of view. Shares
  /// [MessageDirection] rather than having its own enum: the column holds the
  /// same two values with the same meaning, and a second enum would be a second
  /// thing to keep in step.
  final MessageDirection direction;

  final TransferState state;

  final int bytesDone;

  final int bytesTotal;

  /// The partial file.
  ///
  /// Set on the receiving side, where it names the `.part` file being filled —
  /// which is what a resume would continue from (§4.6.1). Null on the sending
  /// side: the file being read is whole, and it is named by the attachment.
  final String? tempPath;

  final DateTime updatedAt;

  bool get isIncoming => direction == MessageDirection.incoming;

  bool get isFinished =>
      state == TransferState.done ||
      state == TransferState.failed ||
      state == TransferState.cancelled ||
      state == TransferState.declined;

  /// Whether this row describes a transfer that could still be resumed.
  bool get isResumable =>
      !isFinished && state != TransferState.pending && bytesTotal > bytesDone;

  double get progress {
    if (state == TransferState.done) {
      return 1;
    }
    if (bytesTotal == 0) {
      return 1;
    }
    final double ratio = bytesDone / bytesTotal;
    return ratio < 0 ? 0 : (ratio > 1 ? 1 : ratio);
  }

  Transfer copyWith({
    TransferState? state,
    int? bytesDone,
    String? tempPath,
    String? messageId,
    String? attachmentId,
    DateTime? updatedAt,
  }) {
    return Transfer(
      id: id,
      peerId: peerId,
      direction: direction,
      state: state ?? this.state,
      bytesTotal: bytesTotal,
      updatedAt: updatedAt ?? this.updatedAt,
      messageId: messageId ?? this.messageId,
      attachmentId: attachmentId ?? this.attachmentId,
      bytesDone: bytesDone ?? this.bytesDone,
      tempPath: tempPath ?? this.tempPath,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Transfer &&
      other.id == id &&
      other.messageId == messageId &&
      other.attachmentId == attachmentId &&
      other.peerId == peerId &&
      other.direction == direction &&
      other.state == state &&
      other.bytesDone == bytesDone &&
      other.bytesTotal == bytesTotal &&
      other.tempPath == tempPath &&
      other.updatedAt == updatedAt;

  @override
  int get hashCode => Object.hash(
        id,
        messageId,
        attachmentId,
        peerId,
        direction,
        state,
        bytesDone,
        bytesTotal,
        tempPath,
        updatedAt,
      );

  @override
  String toString() =>
      'Transfer($id, ${direction.wire}, $state, $bytesDone/$bytesTotal)';
}

/// Where one transfer is in its journey — design.md §4.6, §5.1.
///
/// One enum for the `transfer.state` and `attachment.state` columns. They hold
/// the same progression seen from two angles, and two enums would mean two
/// `fromWire` tables that have to agree.
enum TransferState {
  /// Agreed to locally, or written while the peer is offline. Nothing is on the
  /// wire yet.
  pending('pending'),

  /// An offer has gone out and no answer has come back, or one has arrived and
  /// the user has not decided. Either way the next move is not ours.
  offered('offered'),

  /// Bytes are moving. `downloading` in §5.1's original wording, renamed so the
  /// same value reads correctly in both directions — a sender is not
  /// downloading.
  transferring('transferring'),

  done('done'),

  /// Something went wrong: the connection dropped, the file was unreadable, the
  /// peer's data connection never arrived. The UI offers a retry.
  failed('failed'),

  /// Either side gave up. Terminal, and *not* a failure — the user asked for
  /// this, so offering them a retry would be offering to undo their decision.
  cancelled('cancelled'),

  /// The receiver said no — §4.3's `file_reject`. Kept apart from [cancelled]
  /// because only one of the two ends can see the rejection frame, and the
  /// other has to be told which it was.
  declined('declined');

  const TransferState(this.wire);

  final String wire;

  /// Unknown values read as [failed].
  ///
  /// Every other default would be a lie in a different direction: [pending]
  /// would have the UI retry something whose state we could not read,
  /// [transferring] would show a progress bar that never moves, and [done] would
  /// offer a file that may not exist. A newer peer's state is a state this build
  /// cannot act on, and "it did not work" is the honest thing to say about it.
  static TransferState fromWire(String value) {
    return TransferState.values.firstWhere(
      (TransferState s) => s.wire == value,
      orElse: () => TransferState.failed,
    );
  }
}
