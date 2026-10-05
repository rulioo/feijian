import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../core/models/message.dart';
import '../../core/models/transfer.dart';
import '../dao/message_dao.dart';
import '../dao/transfer_dao.dart';
import '../database.dart';

/// What the transfer service stores, in the terms it thinks in — design.md §5.1.
///
/// One file transfer writes **four** rows: a `message` (the bubble in the chat),
/// an `attachment` (what was sent), a `transfer` (this attempt at sending it),
/// and the conversation bump that puts the peer at the top of the device list.
/// They go in together or not at all, and that is the reason this class exists
/// rather than the service reaching for three DAOs in sequence: a half-written
/// transfer is a message bubble with nothing behind it, or a transfer row whose
/// `file_data` frames have nowhere to land.
///
/// Pure Dart — no Flutter, and nothing about sockets. The session layer decides
/// *when* to write; this decides what a write means.
class TransferRepository {
  TransferRepository(this._db, {DateTime Function()? clock})
      : _messages = MessageDao(_db),
        _transfers = TransferDao(_db),
        _clock = clock ?? DateTime.now;

  final AppDatabase _db;
  final MessageDao _messages;
  final TransferDao _transfers;
  final DateTime Function() _clock;

  /// Begins a transfer we are sending.
  ///
  /// [xferId] is the only id the caller supplies, because it is the only one
  /// that goes on the wire. The message and attachment ids are local (§5.1's
  /// `attachment` note) and are minted here, where the rows that carry them are
  /// written.
  ///
  /// The message starts `pending`, the same as a queued text message: nothing
  /// has left this device yet, and the bubble's job at this instant is to say so.
  /// It is not in the §5.2 offline queue, which [MessageDao.pendingFor] confines
  /// to text — a file is delivered by the transfer layer or not at all.
  Future<Transfer> beginOutgoing({
    required String xferId,
    required String peerId,
    required String fileName,
    required int totalSize,
    String? mime,
    String? localPath,
    required DateTime now,
  }) {
    return _begin(
      xferId: xferId,
      peerId: peerId,
      fileName: fileName,
      totalSize: totalSize,
      mime: mime,
      localPath: localPath,
      now: now,
      direction: MessageDirection.outgoing,
      state: TransferState.pending,
      messageStatus: MessageStatus.pending,
    );
  }

  /// Stores an offer that has arrived and is waiting for the user.
  ///
  /// The state is `offered` rather than `transferring`, because nothing has been
  /// agreed to yet — the bytes cannot move until `file_accept` goes out, and a
  /// progress bar over a transfer the user has not seen is a progress bar over
  /// nothing.
  ///
  /// The message is `pending` on this side too, and for once that word is exact:
  /// the peer's file is pending our decision. It becomes `received` when the
  /// bytes land and `failed` if they never do.
  Future<Transfer> beginIncoming({
    required String xferId,
    required String peerId,
    required String fileName,
    required int totalSize,
    String? mime,
    required DateTime now,
  }) {
    return _begin(
      xferId: xferId,
      peerId: peerId,
      fileName: fileName,
      totalSize: totalSize,
      mime: mime,
      localPath: null,
      now: now,
      direction: MessageDirection.incoming,
      state: TransferState.offered,
      messageStatus: MessageStatus.pending,
    );
  }

  /// Begins another attempt at a file whose earlier attempt ended — §6.3's
  /// retry.
  ///
  /// A **new** `transfer` row beside the old one, not a rewrite of it. `xferId`
  /// is the row's primary key *and* the peer's name for the attempt, so "the
  /// same transfer, tried again" is not a thing the schema can say: a second
  /// attempt is a second id, and the rows are where attempts accumulate. The
  /// message and the attachment are deliberately **not** duplicated — they are
  /// *what* was sent, and a retry sends the same file again rather than a second
  /// one. Keeping them is what keeps the chat one bubble and one card; the
  /// alternative is a conversation that grows a new file bubble every time the
  /// network hiccups.
  ///
  /// The message goes back to `pending` with the attachment. A row still reading
  /// `failed` behind a card whose bar has started moving is the two halves of one
  /// attempt disagreeing on screen — and the footer's icon is drawn from the
  /// message, so it would go on offering a retry for a retry already running.
  ///
  /// The caller has the attachment in hand and passes what it read, rather than
  /// this reading it again: the two would be two reads of one row, and the
  /// service has already had to look at it to find the file.
  Future<Transfer> beginRetry({
    required String xferId,
    required String peerId,
    required String messageId,
    required String attachmentId,
    required String fileName,
    required int totalSize,
    String? mime,
    required DateTime now,
  }) async {
    final int at = now.millisecondsSinceEpoch;

    await _db.transaction(() async {
      await _transfers.insertTransfer(TransfersCompanion.insert(
        id: xferId,
        peerId: peerId,
        direction: MessageDirection.outgoing.wire,
        state: TransferState.pending.wire,
        bytesTotal: totalSize,
        updatedAt: at,
        messageId: Value<String?>(messageId),
        attachmentId: Value<String?>(attachmentId),
      ));
      await _transfers.updateAttachment(
        attachmentId,
        state: TransferState.pending.wire,
        // Back to zero, not left where the last attempt stopped. A bar that
        // starts at 40% and climbs to 100% reads as a transfer that resumed, and
        // this one is offering every byte again.
        transferred: 0,
      );
      await _messages.setStatus(messageId, MessageStatus.pending.wire);
    });

    return Transfer(
      id: xferId,
      messageId: messageId,
      attachmentId: attachmentId,
      peerId: peerId,
      direction: MessageDirection.outgoing,
      state: TransferState.pending,
      bytesTotal: totalSize,
      updatedAt: now,
    );
  }

  Future<Transfer> _begin({
    required String xferId,
    required String peerId,
    required String fileName,
    required int totalSize,
    required String? mime,
    required String? localPath,
    required DateTime now,
    required MessageDirection direction,
    required TransferState state,
    required MessageStatus messageStatus,
  }) async {
    final String messageId = const Uuid().v4();
    final String attachmentId = const Uuid().v4();
    final int at = now.millisecondsSinceEpoch;

    await _db.transaction(() async {
      final ConversationRow conversation =
          await _messages.ensureConversation(peerId, now: at);
      // The same rule every other message write obeys (§5.2.1): two messages in
      // one millisecond have no defined order until this pushes the second one
      // past the first.
      final int created = _messages.nextCreatedAt(conversation, at);

      await _messages.insertMessage(MessagesCompanion.insert(
        id: messageId,
        conversationId: conversation.id,
        peerId: peerId,
        direction: direction.wire,
        type: MessageType.file.wire,
        // A file message has no body: the name and the size live on the
        // attachment, and a copy of them here would be a second version of the
        // truth to keep in step.
        body: const Value<String?>(null),
        status: messageStatus.wire,
        createdAt: created,
      ));
      await _messages.bumpConversation(
        conversation.id,
        lastMsgAt: created,
        // An offer nobody has looked at yet is unread. Our own send is not.
        unread: direction == MessageDirection.incoming,
      );

      await _transfers.insertAttachment(AttachmentsCompanion.insert(
        id: attachmentId,
        messageId: messageId,
        fileName: fileName,
        size: totalSize,
        state: state.wire,
        mime: Value<String?>(mime),
        localPath: Value<String?>(localPath),
      ));

      await _transfers.insertTransfer(TransfersCompanion.insert(
        id: xferId,
        peerId: peerId,
        direction: direction.wire,
        state: state.wire,
        bytesTotal: totalSize,
        updatedAt: at,
        messageId: Value<String?>(messageId),
        attachmentId: Value<String?>(attachmentId),
      ));
    });

    return Transfer(
      id: xferId,
      messageId: messageId,
      attachmentId: attachmentId,
      peerId: peerId,
      direction: direction,
      state: state,
      bytesTotal: totalSize,
      updatedAt: now,
    );
  }

  Future<Transfer?> byId(String xferId) async {
    final TransferRow? row = await _transfers.byId(xferId);
    return row == null ? null : _toTransfer(row);
  }

  /// The attachment behind [xferId], for a UI that wants the name and the path.
  Future<Attachment?> attachmentFor(String xferId) async {
    final TransferRow? transfer = await _transfers.byId(xferId);
    final String? id = transfer?.attachmentId;
    if (id == null) {
      return null;
    }
    final AttachmentRow? row = await _transfers.attachmentById(id);
    return row == null ? null : _toAttachment(row);
  }

  /// The attachment with this id, for a retry.
  ///
  /// The other way round from [attachmentFor]: what the chat page renders from
  /// is the attachment, and the `xferId` of an attempt that has ended is a name
  /// nothing on screen still carries.
  Future<Attachment?> attachmentById(String attachmentId) async {
    final AttachmentRow? row = await _transfers.attachmentById(attachmentId);
    return row == null ? null : _toAttachment(row);
  }

  /// The attachment behind each of [messageIds], keyed by message id.
  ///
  /// One query for a whole page of chat, because that is how the chat page asks
  /// for it: fifty bubbles are rendered at once and a file bubble needs its
  /// attachment to have anything to draw. Text messages are simply absent from
  /// the map — a lookup that misses is the same answer as a null.
  Future<Map<String, Attachment>> attachmentsForMessages(
    Iterable<String> messageIds,
  ) async {
    final List<AttachmentRow> rows =
        await _transfers.attachmentsForMessages(messageIds);
    return <String, Attachment>{
      for (final AttachmentRow row in rows) row.messageId: _toAttachment(row),
    };
  }

  /// Moves a transfer along, without ending it.
  ///
  /// Called on a checkpoint rather than per chunk: the drift row is the durable
  /// record, and a 1 GB file would write it four thousand times. The in-memory
  /// [Transfer] the UI watches is where per-chunk progress lives.
  Future<int> recordProgress(
    String xferId, {
    required TransferState state,
    required int bytesDone,
    String? tempPath,
    DateTime? now,
  }) async {
    final int at = (now ?? _clock()).millisecondsSinceEpoch;
    return _db.transaction(() async {
      final TransferRow? row = await _transfers.byId(xferId);
      final int changed = await _transfers.updateTransfer(
        xferId,
        state: state.wire,
        bytesDone: bytesDone,
        tempPath: tempPath,
        updatedAt: at,
      );
      final String? attachmentId = row?.attachmentId;
      if (attachmentId != null) {
        await _transfers.updateAttachment(
          attachmentId,
          state: state.wire,
          transferred: bytesDone,
        );
      }
      return changed;
    });
  }

  /// Records the `.part` a receiving transfer is filling.
  ///
  /// Written as soon as the file is opened, before a byte has moved, because it
  /// is the thing a resume needs (§4.6.1) and the moment it is known is the
  /// moment the name is chosen — which is also the moment a crash would lose it.
  Future<void> recordTempPath(String xferId, String tempPath) {
    return _transfers.updateTransfer(
      xferId,
      tempPath: tempPath,
      updatedAt: _clock().millisecondsSinceEpoch,
    );
  }

  /// Marks a transfer finished, and its attachment with it.
  ///
  /// [localPath] is where the bytes are on this device: the received file for an
  /// incoming transfer, the file we read for an outgoing one — set in both cases
  /// so that clicking the message later either opens the file or fails knowing
  /// which path was tried.
  Future<void> finish(
    String xferId, {
    String? localPath,
    required DateTime now,
  }) async {
    await _end(
      xferId,
      state: TransferState.done,
      messageStatus: MessageStatus.delivered,
      localPath: localPath,
      now: now,
    );
  }

  /// Marks a transfer ended without the file arriving.
  ///
  /// [state] is `failed`, `cancelled` or `declined` — three different things to
  /// the user that all mean the same thing to the rows: the bytes are not coming
  /// and the attachment is not openable.
  Future<void> end(
    String xferId, {
    required TransferState state,
    required DateTime now,
    String? localPath,
  }) async {
    assert(
      state == TransferState.failed ||
          state == TransferState.cancelled ||
          state == TransferState.declined,
      'end() is for endings that are not completion; use finish() for done',
    );
    await _end(
      xferId,
      state: state,
      // A transfer that did not happen leaves a message that says so, which is
      // what the red exclamation in the chat list is for (§4.5). `cancelled` is
      // the user's own decision and reads no better as a failure than the frame
      // it came from, so it is shown as a failure too — the alternative would be
      // a sixth message status for one case.
      messageStatus: MessageStatus.failed,
      localPath: localPath,
      now: now,
    );
  }

  Future<void> _end(
    String xferId, {
    required TransferState state,
    required MessageStatus messageStatus,
    required DateTime now,
    String? localPath,
  }) async {
    final int at = now.millisecondsSinceEpoch;
    await _db.transaction(() async {
      final TransferRow? row = await _transfers.byId(xferId);
      if (row == null) {
        return;
      }
      final bool done = state == TransferState.done;
      await _transfers.updateTransfer(
        xferId,
        state: state.wire,
        // A completed transfer has moved every byte by definition, and writing
        // that here rather than trusting the last checkpoint means a transfer
        // that finished inside one checkpoint interval — anything under 2 MB,
        // which is most files — does not read `done` at 0 of 900 bytes. An
        // *unfinished* one keeps the count it stopped at: that is the record of
        // how far the attempt got, and what a retry would not have to redo.
        bytesDone: done ? row.bytesTotal : null,
        updatedAt: at,
      );

      final String? attachmentId = row.attachmentId;
      if (attachmentId != null) {
        await _transfers.updateAttachment(
          attachmentId,
          state: state.wire,
          localPath: localPath,
          transferred: done ? row.bytesTotal : null,
        );
      }

      final String? messageId = row.messageId;
      if (messageId != null) {
        // `delivered` here means "the peer has this file", which is what the
        // tick in the chat means for every other message too. The §4.5
        // state machine's ack rules are about `msg` frames and do not apply:
        // nothing acks a file message, its transfer does.
        await _messages.setStatus(
          messageId,
          messageStatus.wire,
          deliveredAt: messageStatus == MessageStatus.delivered ? at : null,
        );
      }
    });
  }

  /// Transfers that were still moving, in a previous run of the app.
  ///
  /// Read at startup, because a process that was killed mid-transfer leaves rows
  /// saying `transferring` and a socket that no longer exists. Nothing will ever
  /// move them again — the map that held their senders is gone — so a progress
  /// bar reading them would sit at 40% forever, and the honest thing to show is
  /// that the attempt failed.
  Future<List<Transfer>> unfinished() async {
    final List<TransferRow> rows = await _transfers.inStates(<String>[
      TransferState.pending.wire,
      TransferState.offered.wire,
      TransferState.transferring.wire,
    ]);
    return rows.map(_toTransfer).toList(growable: false);
  }

  Transfer _toTransfer(TransferRow row) {
    return Transfer(
      id: row.id,
      messageId: row.messageId,
      attachmentId: row.attachmentId,
      peerId: row.peerId,
      direction: MessageDirection.fromWire(row.direction),
      state: TransferState.fromWire(row.state),
      bytesDone: row.bytesDone,
      bytesTotal: row.bytesTotal,
      tempPath: row.tempPath,
      updatedAt: DateTime.fromMillisecondsSinceEpoch(row.updatedAt),
    );
  }

  Attachment _toAttachment(AttachmentRow row) {
    return Attachment(
      id: row.id,
      messageId: row.messageId,
      fileName: row.fileName,
      relPath: row.relPath,
      size: row.size,
      mime: row.mime,
      localPath: row.localPath,
      thumbPath: row.thumbPath,
      sha256: row.sha256,
      state: TransferState.fromWire(row.state),
      transferred: row.transferred,
    );
  }
}
