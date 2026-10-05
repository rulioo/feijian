import 'package:drift/drift.dart';

import '../database.dart';

/// Reads and writes the `transfer` and `attachment` tables — design.md §5.1.
///
/// The two are one DAO because they are written together and read together: a
/// transfer exists to move the file its attachment describes, and an attachment
/// is only ever in flight because a transfer row says so. Splitting them would
/// put that pair across two objects at every call site, the same reasoning as
/// [MessageDao] holding `message` and `conversation`.
///
/// Rows only. Turning them into [Transfer]/[Attachment] values, and deciding
/// which of them are written together, is [TransferRepository]'s job.
class TransferDao {
  TransferDao(this._db);

  final AppDatabase _db;

  Future<void> insertTransfer(TransfersCompanion row) {
    return _db.into(_db.transfers).insert(row);
  }

  Future<void> insertAttachment(AttachmentsCompanion row) {
    return _db.into(_db.attachments).insert(row);
  }

  /// The transfer named [id] — the wire's `xferId`.
  Future<TransferRow?> byId(String id) {
    return (_db.select(_db.transfers)..where((Transfers t) => t.id.equals(id)))
        .getSingleOrNull();
  }

  Future<AttachmentRow?> attachmentById(String id) {
    return (_db.select(_db.attachments)
          ..where((Attachments t) => t.id.equals(id)))
        .getSingleOrNull();
  }

  Future<AttachmentRow?> attachmentOfMessage(String messageId) {
    return (_db.select(_db.attachments)
          ..where((Attachments t) => t.messageId.equals(messageId)))
        .getSingleOrNull();
  }

  /// The attachments behind [messageIds], in one query.
  ///
  /// A page of chat is fifty messages and every file bubble in it needs its
  /// attachment; asking one message at a time would be fifty round trips to
  /// render one scroll. The caller matches them up by `messageId` — the list is
  /// returned unordered because the map it becomes has no order.
  ///
  /// Empty in, empty out, and never `IN ()`: that is not valid SQL, and the
  /// callers reach here with an empty page more often than they would like —
  /// a conversation with only text messages in it holds no ids worth asking
  /// about at all.
  Future<List<AttachmentRow>> attachmentsForMessages(
    Iterable<String> messageIds,
  ) {
    final List<String> ids = messageIds.toList(growable: false);
    if (ids.isEmpty) {
      return Future<List<AttachmentRow>>.value(const <AttachmentRow>[]);
    }
    return (_db.select(_db.attachments)
          ..where((Attachments t) => t.messageId.isIn(ids)))
        .get();
  }

  /// Transfers that were still moving when [states] was read, oldest first.
  ///
  /// Oldest first so a startup sweep reports them in the order they were begun,
  /// which is the order the user remembers starting them in.
  Future<List<TransferRow>> inStates(List<String> states) {
    return (_db.select(_db.transfers)
          ..where((Transfers t) => t.state.isIn(states))
          ..orderBy(<OrderingTerm Function(Transfers)>[
            (Transfers t) => OrderingTerm.asc(t.updatedAt),
          ]))
        .get();
  }

  /// Every transfer, newest first — the history a chat page reads.
  Future<List<TransferRow>> forPeer(String peerId) {
    return (_db.select(_db.transfers)
          ..where((Transfers t) => t.peerId.equals(peerId))
          ..orderBy(<OrderingTerm Function(Transfers)>[
            (Transfers t) => OrderingTerm.desc(t.updatedAt),
          ]))
        .get();
  }

  /// Writes a transfer's progress and state.
  ///
  /// Returns whether a row was there to change. A miss is not an error: a
  /// transfer cancelled while a chunk was in flight gets its `cancelled` write
  /// from the cancel path, and this one arriving afterwards finds nothing to do.
  Future<int> updateTransfer(
    String id, {
    String? state,
    int? bytesDone,
    String? tempPath,
    String? messageId,
    String? attachmentId,
    required int updatedAt,
  }) {
    return (_db.update(_db.transfers)..where((Transfers t) => t.id.equals(id)))
        .write(TransfersCompanion(
      state: state == null ? const Value.absent() : Value<String>(state),
      bytesDone:
          bytesDone == null ? const Value.absent() : Value<int>(bytesDone),
      tempPath:
          tempPath == null ? const Value.absent() : Value<String>(tempPath),
      messageId:
          messageId == null ? const Value.absent() : Value<String>(messageId),
      attachmentId: attachmentId == null
          ? const Value.absent()
          : Value<String>(attachmentId),
      updatedAt: Value<int>(updatedAt),
    ));
  }

  /// Writes an attachment's state and byte count.
  Future<int> updateAttachment(
    String id, {
    String? state,
    int? transferred,
    String? localPath,
    String? thumbPath,
  }) {
    return (_db.update(_db.attachments)
          ..where((Attachments t) => t.id.equals(id)))
        .write(AttachmentsCompanion(
      state: state == null ? const Value.absent() : Value<String>(state),
      transferred:
          transferred == null ? const Value.absent() : Value<int>(transferred),
      localPath:
          localPath == null ? const Value.absent() : Value<String>(localPath),
      thumbPath:
          thumbPath == null ? const Value.absent() : Value<String>(thumbPath),
    ));
  }
}
