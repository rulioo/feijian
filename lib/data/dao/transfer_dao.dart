import 'package:drift/drift.dart';

import '../../core/models/message.dart';
import '../../core/models/transfer.dart';
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

  /// Inserts a folder's worth of attachments in one batch.
  ///
  /// A folder offer is one row per file, and a directory of photographs is
  /// thousands of them. One `insert` per row is one statement per row; a batch
  /// is one prepared statement run many times, and it is also what keeps the
  /// repository's transaction from being thousands of round trips inside it.
  ///
  /// An empty list is not special-cased. A folder of nothing but empty
  /// directories really has no attachments to write, and drift runs a batch of
  /// none as the nothing it is.
  Future<void> insertAttachments(List<AttachmentsCompanion> rows) {
    return _db.batch((Batch batch) => batch.insertAll(_db.attachments, rows));
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

  /// Every attachment of [messageId], in the order a folder shows them.
  ///
  /// A list rather than a single row, because §5.1 gives a message as many
  /// attachments as its folder has files. The `getSingleOrNull` this replaces
  /// would *throw* on such a message rather than answer — the schema has always
  /// allowed this shape, and only the milestone's one-file-per-message habit
  /// kept it from showing.
  ///
  /// Ordered by `rel_path`, which is the place inside the folder: it puts a
  /// folder's files in the order the user would see them in a file manager,
  /// and it is stable across reads, so a card that lists them does not reshuffle
  /// itself on every refresh. A single file has a null `rel_path` and one row,
  /// where the order is nothing to decide.
  Future<List<AttachmentRow>> attachmentsOfMessage(String messageId) {
    return (_db.select(_db.attachments)
          ..where((Attachments t) => t.messageId.equals(messageId))
          ..orderBy(<OrderingTerm Function(Attachments)>[
            (Attachments t) => OrderingTerm.asc(t.relPath),
          ]))
        .get();
  }

  /// Moves every attachment of [messageId] that has not already landed into
  /// [state], and returns how many moved.
  ///
  /// This is how a *folder* transfer ends: the folder is one task over many
  /// files, and the task's own row has no attachment to carry the ending
  /// (`attachment_id` is null by design — §4.6 rule 3). Marking the finished
  /// ones along with the rest would be the wrong answer in the one case that
  /// matters: a folder whose seventh file failed has six files on disk that the
  /// user can open, and a row saying `failed` is a card that hides them.
  ///
  /// So `done` is never overwritten. What an ending applies to is the work that
  /// had not happened yet.
  Future<int> endPendingAttachments(
    String messageId, {
    required String state,
  }) {
    return (_db.update(_db.attachments)
          ..where((Attachments t) =>
              t.messageId.equals(messageId) &
              t.state.equals(TransferState.done.wire).not()))
        .write(AttachmentsCompanion(state: Value<String>(state)));
  }

  /// The attachments behind [messageIds], in one query.
  ///
  /// A page of chat is fifty messages and every file bubble in it needs its
  /// attachment; asking one message at a time would be fifty round trips to
  /// render one scroll. The caller matches them up by `messageId`.
  ///
  /// Ordered by `(message_id, rel_path)` so that the caller's grouping keeps
  /// each folder's files in the order [attachmentsOfMessage] would give them —
  /// a card that listed a folder's files differently depending on which query
  /// filled it in would reshuffle itself between a fresh open and a refresh.
  ///
  /// Empty in, empty out. There is no early return for the empty page: the
  /// callers reach here with one — an empty conversation, a page of nothing but
  /// text — and drift runs `isIn` over an empty list as the falsehood it is,
  /// which the tests hold it to.
  Future<List<AttachmentRow>> attachmentsForMessages(
    Iterable<String> messageIds,
  ) {
    final List<String> ids = messageIds.toList(growable: false);
    return (_db.select(_db.attachments)
          ..where((Attachments t) => t.messageId.isIn(ids))
          ..orderBy(<OrderingTerm Function(Attachments)>[
            (Attachments t) => OrderingTerm.asc(t.messageId),
            (Attachments t) => OrderingTerm.asc(t.relPath),
          ]))
        .get();
  }

  /// The **task** transfers behind [messageIds], newest attempt first.
  ///
  /// Tasks are the transfers with `attachment_id` NULL — which is what a folder
  /// transfer is (§4.6 rule 3: every file in it shares an `xferId`, so no single
  /// attachment can own the attempt). A single file's attempt is left out
  /// deliberately: the attachment already carries its state and its byte count,
  /// and returning the row here would put the same bytes in two places in the
  /// state the chat page holds.
  ///
  /// Ordered by `updated_at DESC` so that the first row for a message is the
  /// newest attempt at it. A retry adds a row rather than rewriting one, and a
  /// card that showed the failed attempt while a retry ran would be reporting
  /// the past.
  Future<List<TransferRow>> taskTransfersForMessages(
    Iterable<String> messageIds,
  ) {
    final List<String> ids = messageIds.toList(growable: false);
    return (_db.select(_db.transfers)
          ..where((Transfers t) =>
              t.messageId.isIn(ids) & t.attachmentId.isNull())
          ..orderBy(<OrderingTerm Function(Transfers)>[
            (Transfers t) => OrderingTerm.desc(t.updatedAt),
          ]))
        .get();
  }

  /// Outgoing transfers of [peerId] that were never offered, oldest first.
  ///
  /// `pending` is the state a transfer is written in and the state it leaves the
  /// moment its offer is on the wire (`TransferRepository.markOffered`), so
  /// "still pending, and ours" is exactly the set the peer was not there to be
  /// asked about — §5.2 rule 5's queue, read rather than remembered.
  ///
  /// Ordered by the **message's** `created_at`, not the transfer's `updated_at`.
  /// §5.2.1 makes the former strictly increasing inside a conversation and
  /// nothing makes the latter so: two files dropped together can share a
  /// millisecond, and their order off this query would then be a coin toss —
  /// which is the flake §5.2.1 exists to have removed.
  Future<List<TransferRow>> owedOutgoing(String peerId) async {
    final JoinedSelectStatement<HasResultSet, dynamic> query = _db
        .select(_db.transfers)
        .join(<Join<HasResultSet, dynamic>>[
      innerJoin(
        _db.messages,
        _db.messages.id.equalsExp(_db.transfers.messageId),
        useColumns: false,
      ),
    ])
      ..where(_db.transfers.peerId.equals(peerId) &
          _db.transfers.direction.equals(MessageDirection.outgoing.wire) &
          _db.transfers.state.equals(TransferState.pending.wire))
      ..orderBy(<OrderingTerm>[
        OrderingTerm.asc(_db.messages.createdAt),
      ]);
    final List<TypedResult> rows = await query.get();
    return rows
        .map((TypedResult row) => row.readTable(_db.transfers))
        .toList(growable: false);
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
