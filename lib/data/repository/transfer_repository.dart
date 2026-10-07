import 'dart:io';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../core/models/manifest_entry.dart';
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
/// A **folder** writes the same four things in the same transaction, with two
/// differences that come from what a folder is. There is one attachment per
/// *file* rather than one per message, and there is still only **one** transfer
/// row — for the task, with `attachment_id` NULL. A folder's files share an
/// `xferId` (§4.6 rule 3), so no single attachment could own the attempt; the
/// wire's two endings, `file_done` per file and `xfer_done` for the task, land
/// on different rows because of it.
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
      type: MessageType.file,
      name: fileName,
      totalSize: totalSize,
      mime: mime,
      localPath: localPath,
      rootPath: null,
      files: null,
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
      type: MessageType.file,
      name: fileName,
      totalSize: totalSize,
      mime: mime,
      localPath: null,
      rootPath: null,
      files: null,
      now: now,
      direction: MessageDirection.incoming,
      state: TransferState.offered,
      messageStatus: MessageStatus.pending,
    );
  }

  /// Begins a folder we are sending — design.md §4.6.
  ///
  /// [entries] is the whole manifest, directories and all, in the order the
  /// files will be sent. The **directories are dropped here**: they carry no
  /// bytes, so they get no attachment, and the receiver rebuilds them from the
  /// manifest itself (§4.6 rule 4). Taking the manifest whole rather than asking
  /// the caller to filter is deliberate — the filtering is a rule about what an
  /// attachment is, so it belongs with the code that writes attachments.
  ///
  /// A folder holding nothing but empty directories is therefore a message with
  /// **no attachments at all** and still a transfer. That is a real thing a user
  /// can send, not a case to guard against.
  ///
  /// [folderPath] is where the folder is on **this** device. Each file's
  /// attachment records its own absolute path under it, so a file can be opened
  /// or read again after the bubble exists, the same reason a single file's
  /// attachment stores the path it was sent from.
  Future<Transfer> beginOutgoingFolder({
    required String xferId,
    required String peerId,
    required String folderName,
    required String folderPath,
    required List<ManifestEntry> entries,
    required DateTime now,
  }) {
    return _begin(
      xferId: xferId,
      peerId: peerId,
      type: MessageType.folder,
      name: folderName,
      totalSize: _totalOf(entries),
      mime: null,
      localPath: null,
      rootPath: folderPath,
      files: entries,
      now: now,
      direction: MessageDirection.outgoing,
      state: TransferState.pending,
      messageStatus: MessageStatus.pending,
    );
  }

  /// Stores a folder offer that has arrived and is waiting for the user.
  ///
  /// The receiving half of [beginOutgoingFolder], and the same shape: one
  /// message, one attachment per file, one `offered` transfer for the task. The
  /// files are stored before the user has agreed to anything because the offer
  /// *is* the list — the card says how many files and how large before the user
  /// decides, and there is nothing else to say it from.
  ///
  /// No `localPath` yet: where a file lands is decided when it is written, by
  /// `FolderLayout` under the download root, and a path guessed here would be
  /// the prediction the real one replaces.
  Future<Transfer> beginIncomingFolder({
    required String xferId,
    required String peerId,
    required String folderName,
    required List<ManifestEntry> entries,
    required DateTime now,
  }) {
    return _begin(
      xferId: xferId,
      peerId: peerId,
      type: MessageType.folder,
      name: folderName,
      totalSize: _totalOf(entries),
      mime: null,
      localPath: null,
      rootPath: null,
      files: entries,
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

  /// The one transaction every beginning goes through.
  ///
  /// [files] is what makes a beginning a folder: null for a single file, which
  /// gets one attachment named by [name], and a list of file entries for a
  /// folder, which gets one attachment each and no single owning attachment.
  Future<Transfer> _begin({
    required String xferId,
    required String peerId,
    required MessageType type,
    required String name,
    required int totalSize,
    required String? mime,
    required String? localPath,
    required String? rootPath,
    required List<ManifestEntry>? files,
    required DateTime now,
    required MessageDirection direction,
    required TransferState state,
    required MessageStatus messageStatus,
  }) async {
    final String messageId = const Uuid().v4();
    // Null for a folder: the transfer belongs to the task, and §4.6 rule 3 gives
    // every file in it the same `xferId` — so there is no one attachment for this
    // column to name.
    final String? attachmentId = files == null ? const Uuid().v4() : null;
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
        type: type.wire,
        // A file message has no body: the name and the size live on the
        // attachment, and a copy of them here would be a second version of the
        // truth to keep in step. A *folder* message has only the name, because
        // it has no attachment of its own to carry one — the attachments are the
        // files inside it, and the folder's own name is the one thing about the
        // transfer that would otherwise be nowhere.
        body: Value<String?>(files == null ? null : name),
        status: messageStatus.wire,
        createdAt: created,
      ));
      await _messages.bumpConversation(
        conversation.id,
        lastMsgAt: created,
        // An offer nobody has looked at yet is unread. Our own send is not.
        unread: direction == MessageDirection.incoming,
      );

      if (files == null) {
        await _transfers.insertAttachment(AttachmentsCompanion.insert(
          id: attachmentId!,
          messageId: messageId,
          fileName: name,
          size: totalSize,
          state: state.wire,
          mime: Value<String?>(mime),
          localPath: Value<String?>(localPath),
        ));
      } else {
        await _transfers.insertAttachments(<AttachmentsCompanion>[
          for (final ManifestEntry entry in files)
            if (!entry.isDir)
              AttachmentsCompanion.insert(
              id: const Uuid().v4(),
              messageId: messageId,
              // The peer's name for the file, verbatim — the same rule a single
              // file's `fileName` follows. `localPath` is where it really is,
              // which for a name this platform will not create is somewhere
              // else.
              fileName: entry.name,
              relPath: Value<String?>(entry.relPath),
              size: entry.size,
              state: state.wire,
              localPath: Value<String?>(
                rootPath == null ? null : _under(rootPath, entry.relPath),
              ),
            ),
        ]);
      }

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

  /// [relPath] as a path under [root], in this platform's spelling.
  ///
  /// `relPath` is `/`-separated by definition (§4.6) and the local path is not,
  /// on Windows, so the conversion happens once, here, rather than at every
  /// caller that wants to turn a manifest entry back into a file.
  static String _under(String root, String relPath) {
    return '$root${Platform.pathSeparator}'
        '${relPath.replaceAll('/', Platform.pathSeparator)}';
  }

  /// The bytes a folder's files add up to.
  ///
  /// Directories contribute nothing, and the caller does not pass them anyway —
  /// this is the manifest's own arithmetic, so that the number the card shows is
  /// the number the transfer row is measured against.
  static int _totalOf(List<ManifestEntry> files) {
    return files.fold(0, (int sum, ManifestEntry entry) => sum + entry.size);
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

  /// The attachments behind each of [messageIds], keyed by message id — a
  /// **list** per message, because a folder is one message with many.
  ///
  /// One query for a whole page of chat, because that is how the chat page asks
  /// for it: fifty bubbles are rendered at once and a file bubble needs its
  /// attachment to have anything to draw. Text messages are simply absent from
  /// the map — a lookup that misses is the same answer as an empty list.
  ///
  /// Each list is in the DAO's order (by `rel_path`, so a folder reads as a
  /// folder). A single file's list holds one row and a folder of empty
  /// directories holds none, which is why nothing here assumes a length.
  Future<Map<String, List<Attachment>>> attachmentsForMessages(
    Iterable<String> messageIds,
  ) async {
    final List<AttachmentRow> rows =
        await _transfers.attachmentsForMessages(messageIds);
    final Map<String, List<Attachment>> byMessage =
        <String, List<Attachment>>{};
    for (final AttachmentRow row in rows) {
      (byMessage[row.messageId] ??= <Attachment>[]).add(_toAttachment(row));
    }
    return byMessage;
  }

  /// The **folder task** behind each of [messageIds], keyed by message id.
  ///
  /// The read that makes a folder's progress survive a restart or a page the
  /// user scrolled away from. A single file's progress lives on its attachment,
  /// but a folder's belongs to no single file, so its own row is the only place
  /// it is written down — and without this the card would show a folder's files
  /// and no idea how far along the transfer was until the service happened to
  /// emit something.
  ///
  /// A message whose newest attempt was a retry gets the retried row, because
  /// the DAO orders newest first and the first row per message wins here.
  Future<Map<String, Transfer>> tasksForMessages(
    Iterable<String> messageIds,
  ) async {
    final List<TransferRow> rows =
        await _transfers.taskTransfersForMessages(messageIds);
    final Map<String, Transfer> byMessage = <String, Transfer>{};
    for (final TransferRow row in rows) {
      final String? messageId = row.messageId;
      if (messageId == null) {
        continue;
      }
      // Newest wins, and the query put it first — so this is `putIfAbsent` and
      // not an assignment, which would leave the *oldest* attempt in place.
      byMessage.putIfAbsent(messageId, () => _toTransfer(row));
    }
    return byMessage;
  }

  /// Every attachment of one message, in the DAO's order.
  ///
  /// For a bubble that is not being drawn from a page — the accept/decline
  /// listener, which has one offer in hand and needs all of its files before it
  /// can say how big the folder is.
  Future<List<Attachment>> attachmentsForMessage(String messageId) async {
    final List<AttachmentRow> rows =
        await _transfers.attachmentsOfMessage(messageId);
    return rows.map(_toAttachment).toList(growable: false);
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

  /// Marks one file of a folder as landed, and records where it is.
  ///
  /// The per-file half of a folder's ending. `file_done` is what triggers it, and
  /// it has to be written as each file arrives rather than when the task ends:
  /// a folder of ten thousand files that fails on the last one has nine thousand
  /// nine hundred and ninety-nine files on disk, and a card that could only say
  /// "failed" would be hiding all of them.
  ///
  /// The byte count is read from the row rather than passed in. A finished file
  /// has moved every byte it promised, and a caller that supplied the number
  /// would be supplying a second copy of it — one that could disagree with the
  /// size the offer was accepted against.
  Future<void> finishFile(String attachmentId, {required String localPath}) async {
    final AttachmentRow? row = await _transfers.attachmentById(attachmentId);
    if (row == null) {
      return;
    }
    await _transfers.updateAttachment(
      attachmentId,
      state: TransferState.done.wire,
      localPath: localPath,
      transferred: row.size,
    );
  }

  /// Records that an offer is on the wire — §5.2 rule 5's boundary.
  ///
  /// The one moment that changes what `pending` means. Before it the row says
  /// "this peer has never heard of this transfer", which is what makes it part
  /// of the queue that is offered again when the peer comes back; after it the
  /// peer is holding an offer, and the transfer's ending is its own business.
  /// [unfinished] is the other reader of that distinction.
  ///
  /// Only the transfer row moves. The attachment stays `pending` until bytes
  /// move, the same as it did before this existed — an offer is not progress.
  Future<void> markOffered(String xferId, {DateTime? now}) {
    return _transfers.updateTransfer(
      xferId,
      state: TransferState.offered.wire,
      updatedAt: (now ?? _clock()).millisecondsSinceEpoch,
    );
  }

  /// The transfers [peerId] was never offered, oldest first — §5.2 rule 5.
  ///
  /// Everything a re-offer needs is already on the rows: the `xferId` to offer
  /// under again, the message to re-read the folder's name from, and — for each
  /// file — the path it came from. Nothing here is remembered in memory, so a
  /// process that dies with a file owed finds it owed again on the next start.
  Future<List<Transfer>> owedOutgoing(String peerId) async {
    final List<TransferRow> rows = await _transfers.owedOutgoing(peerId);
    return rows.map(_toTransfer).toList(growable: false);
  }

  /// The body of [messageId], which for a folder is its name — §5.1.1.
  ///
  /// A folder's message carries nothing else: the files are attachments and the
  /// name is the one thing about the transfer that would otherwise be nowhere.
  /// A re-offer needs it, because the receiver creates the folder's directory
  /// from the name in the offer.
  Future<String?> messageBody(String messageId) async {
    final MessageRow? row = await _messages.byId(messageId);
    return row?.body;
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
      if (attachmentId == null && messageId != null) {
        // A folder: the ending belongs to the task, and the files are the
        // attachments under it. `localPath` is deliberately not passed — there
        // is no one file it could name, and each file's own path was written as
        // that file landed.
        await _transfers.endPendingAttachments(
          messageId,
          state: state.wire,
        );
      }
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
  ///
  /// `pending` is deliberately **not** in the list. It means the peer was never
  /// asked, which is not an attempt that died but a debt that has not been paid
  /// — §5.2 rule 5's queue, and the reason a file sent to a phone that was away
  /// is still there to be offered after the app is restarted. An attempt that
  /// really was interrupted is at `offered` or past it
  /// ([markOffered] is what puts it there).
  ///
  /// An incoming offer is written `offered` from the start, so a peer's offer
  /// nobody ever answered is still swept — correctly, since the sender will not
  /// be waiting at a socket it opened before the restart.
  Future<List<Transfer>> unfinished() async {
    final List<TransferRow> rows = await _transfers.inStates(<String>[
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
