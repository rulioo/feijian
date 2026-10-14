import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../core/constants.dart';
import '../core/models/manifest_entry.dart';
import '../core/models/transfer.dart';
import '../core/protocol/frame_codec.dart';
import '../core/protocol/payloads.dart';
import '../core/transfer/folder_layout.dart';
import '../core/transfer/folder_manifest.dart';
import '../core/transfer/outgoing_file.dart';
import '../core/transfer/safe_name.dart';
import '../core/transfer/transfer_receiver.dart';
import '../core/transfer/transfer_tuning.dart';
import '../core/transport/connection_manager.dart';
import '../core/transport/connection_state.dart';
import '../core/transport/control_connection.dart';
import '../data/repository/transfer_repository.dart';

/// Why a transfer cannot start, said in the terms the caller can act on.
///
/// A refusal is thrown rather than stored, because it happens before there is a
/// transfer to store: no connection, no room, no readable file. Once a transfer
/// row exists the outcome is recorded on it instead — the chat shows a failed
/// bubble, and nothing needs to catch anything.
class TransferException implements Exception {
  const TransferException(this.message, {this.reason = RejectReason.busy});

  final String message;

  /// The code to send if this refusal ever has to go on the wire.
  final RejectReason reason;

  @override
  String toString() => 'TransferException: $message';
}

/// What [TransferService.sendFolder] made of a folder: the task it started, and
/// how much of the folder is not in it.
///
/// A folder is the only thing offered here whose contents are **read** rather
/// than named, and the walk can describe only what it can read and what is
/// really a file or a directory. A link, or a file that vanished between the
/// listing and the stat, is therefore neither sent nor failed — it is simply
/// **left out** of the offer, and the other end never hears of it. A folder that
/// arrives one file short with no explanation is the outcome worth avoiding, so
/// the count comes back beside the task for the caller to say out loud.
///
/// Beside it rather than on it: [Transfer] is persisted and is about the bytes
/// that are moving, and this is about bytes that are not, which no retry or
/// resume would ever need. `0` is the ordinary case — everything in the folder
/// was describable.
class FolderOffer {
  const FolderOffer({required this.transfer, required this.skipped});

  /// The task, which is what this call returned before there was anything else
  /// to say about it.
  final Transfer transfer;

  /// How many things inside the folder were left out, and why — see
  /// [FolderManifest.skipped].
  final int skipped;
}

/// Runs file transfers between the wire and the database — design.md §4.6.
///
/// This is the layer the byte classes deliberately do not know about. The pieces
/// underneath each answer one question and none of the others: `OutgoingFile`
/// reads a file in chunks, `TransferReceiver` writes them, `FrameSink` proves the
/// cadence, and `ConnectionManager` hands over a socket belonging to one
/// `xferId`. What none of them can see is the *conversation* — that an offer is
/// answered by a person, that the answer decides which socket gets opened, that a
/// cancelled transfer must leave no `.part` behind, and that every one of those
/// steps writes a row.
///
/// The handshake travels on the control connection and the bytes on a data
/// connection of their own (§4.6), so this class is subscribed to two streams and
/// is the only thing that knows they belong together.
///
/// **Frames on a data connection are handled strictly in order.** A `file_data`
/// frame's whole meaning is its offset, and the receiver checks that offset
/// against how far the file has got. Two handlers running at once would both read
/// the same "so far" and the second would be rejected as out of order — which is
/// a bug that only shows up on a fast link, and reads as a corrupt transfer.
/// Every incoming chunk therefore goes through one chain (see [_Incoming.attach]).
class TransferService {
  TransferService({
    required ConnectionManager manager,
    required TransferRepository transfers,
    required Future<Directory> Function() downloadDirectory,
    this.tuning = const TransferTuning(),
    DateTime Function()? clock,
    void Function(String message)? onLog,
    Future<bool> Function({
      required String path,
      required String name,
      required String? mime,
    })? publishImage,
  })  : _manager = manager,
        _transfers = transfers,
        _downloadDirectory = downloadDirectory,
        _clock = clock ?? DateTime.now,
        _onLog = onLog,
        _publishImage = publishImage {
    // Subscribed in the constructor, not when the first transfer is asked for
    // (§4.4.2): an offer can arrive at any moment, and the pool closes a data
    // connection nobody is listening for — so a transfer layer that waited to be
    // needed would refuse every transfer until after the first one.
    _subscriptions.addAll(<StreamSubscription<Object?>>[
      _manager.transferFrames.listen(
        (IncomingTransferFrame incoming) =>
            unawaited(_onTransferFrame(incoming)),
      ),
      _manager.dataConnections.listen(_onDataConnection),
      // §5.2 rule 5: a file the peer was not there to be offered is owed, not
      // failed, and the moment it can be paid is the moment that peer is back.
      // The same connection event the text queue is flushed on, from the layer
      // that owns the file rows — the two queues are read from the same database
      // and neither has to know about the other.
      _manager.peerConnected.listen(
        (String peerId) => unawaited(_offerOwed(peerId)),
      ),
    ]);
  }

  final ConnectionManager _manager;
  final TransferRepository _transfers;

  /// The timings and sizes in force. Every one of them is a real value in
  /// production and a small one under test — see [TransferTuning].
  final TransferTuning tuning;

  /// Where received files land. A callback rather than a path, so this class
  /// never has to know that Android and Windows disagree about what a Downloads
  /// folder is — and so a test can point it at a temporary directory.
  final Future<Directory> Function() _downloadDirectory;

  final DateTime Function() _clock;
  final void Function(String message)? _onLog;

  /// Publishes a received picture where the user can find it — §7.1.
  ///
  /// Injected for the same reason [_downloadDirectory] is: this class owns the
  /// moment the picture lands, and nothing else does, but how to put a file in
  /// front of the user is a platform question with no answer on Windows and two
  /// wrong answers on Android below API 29. Null means publishing is off, which
  /// is what every test that is not about this gets.
  final Future<bool> Function({
    required String path,
    required String name,
    required String? mime,
  })? _publishImage;

  final List<StreamSubscription<Object?>> _subscriptions =
      <StreamSubscription<Object?>>[];

  final Map<String, _Outgoing> _outgoing = <String, _Outgoing>{};
  final Map<String, _Incoming> _incoming = <String, _Incoming>{};

  /// Every `xferId` that is currently ours, in either direction.
  ///
  /// Claimed synchronously, before any of the work an offer sets off. Storing an
  /// offer involves the database, and a peer that sent the same offer twice
  /// would otherwise have both copies pass the "do we know this transfer?" check
  /// before either had finished writing it — two rows under one primary key,
  /// and an exception from the second insert.
  final Set<String> _known = <String>{};

  final StreamController<Transfer> _changes =
      StreamController<Transfer>.broadcast();
  final StreamController<Transfer> _offers =
      StreamController<Transfer>.broadcast();

  bool _disposed = false;
  bool _started = false;

  /// Every transfer that changed: progress, an answer, an ending.
  ///
  /// Carries the [Transfer] itself rather than an id, unlike
  /// `LanService.messagesChanged`. Progress does not live in the database — it
  /// is written every couple of megabytes at most — so a listener told to "look
  /// again" would read a row that is seconds stale, and the progress bar would
  /// move in 2 MB steps.
  Stream<Transfer> get changes => _changes.stream;

  /// Offers that have arrived and are waiting for an answer.
  ///
  /// Nothing is received until [accept] is called — an offer that ends in
  /// neither [accept] nor [decline] is answered by [_onOfferExpired] when the
  /// peer gives up. Who does the accepting is not this class's business: §6.4's
  /// `confirmBeforeReceiving` decides whether a human is asked, and when it is
  /// off `OfferListener` accepts on the user's behalf the moment the offer
  /// arrives. Either way the engine waits for an answer, which is what keeps a
  /// silent auto-accept from being a special case deeper down.
  Stream<Transfer> get offers => _offers.stream;

  /// Transfers moving right now, in the order they began.
  List<Transfer> get active => <Transfer>[
        ..._outgoing.values.map((_Outgoing o) => o.transfer),
        ..._incoming.values.map((_Incoming i) => i.transfer),
      ];

  /// Records that a previous run was interrupted, and emits what it found.
  ///
  /// A process killed mid-transfer leaves rows saying `transferring` and a
  /// socket that no longer exists. Nothing will ever move them again — the
  /// objects that held their senders died with the process — so a progress bar
  /// that read them would sit at 40% forever. Marking them failed at startup is
  /// the honest thing, and it is also what makes the row reusable: a transfer
  /// that failed can be started again, one that is "still running" cannot.
  Future<void> start() async {
    if (_started || _disposed) {
      return;
    }
    _started = true;
    try {
      final List<Transfer> interrupted = await _transfers.unfinished();
      for (final Transfer transfer in interrupted) {
        await _transfers.end(
          transfer.id,
          state: TransferState.failed,
          now: _clock(),
        );
        _emit(transfer.copyWith(state: TransferState.failed));
      }
      if (interrupted.isNotEmpty) {
        _log('${interrupted.length} interrupted transfer(s) marked failed');
      }
    } on Object catch (error, stack) {
      // A database that cannot be swept is not a reason to refuse transfers for
      // the rest of the session; the rows stay as they are and the next start
      // tries again.
      _log('could not sweep interrupted transfers: $error\n$stack');
    }
  }

  // --- Sending ---------------------------------------------------------------

  /// Offers [file] to [peerId].
  ///
  /// Returns as soon as the offer is on the wire, with the transfer row already
  /// written — §4.4.1's rule for messages applies unchanged to files: the file
  /// is durable and visible first, and what happens next happens in the
  /// background. The caller gets a [Transfer] to render, not a future that
  /// completes when a gigabyte has moved.
  ///
  /// Throws [TransferException] when there is nothing to wait for: the peer has
  /// no connection, [kMaxConcurrentXfers] are already running, or the file
  /// cannot be read.
  Future<Transfer> sendFile({
    required String peerId,
    required File file,
    String? mime,
  }) async {
    if (_disposed) {
      throw const TransferException('the transfer service has been disposed');
    }
    if (_activeCount >= kMaxConcurrentXfers) {
      throw const TransferException(
        'too many transfers are already running',
        reason: RejectReason.busy,
      );
    }

    final int totalSize;
    try {
      totalSize = await file.length();
    } on FileSystemException catch (error) {
      throw TransferException(
        'cannot read ${file.path}: ${error.message}',
        reason: RejectReason.notFound,
      );
    }

    final String xferId = const Uuid().v4();
    _known.add(xferId);

    final Transfer transfer = await _transfers.beginOutgoing(
      xferId: xferId,
      peerId: peerId,
      fileName: _baseName(file),
      totalSize: totalSize,
      mime: mime,
      localPath: file.path,
      now: _clock(),
    );

    final _Outgoing outgoing = _Outgoing(
      transfer: transfer,
      file: file,
      fileName: _baseName(file),
      totalSize: totalSize,
      mime: mime,
    );
    _outgoing[xferId] = outgoing;
    _emit(transfer);

    unawaited(_runSend(outgoing));
    return transfer;
  }

  /// Offers a whole folder to [peerId] — design.md §4.6's folder rules.
  ///
  /// The manifest is walked and offered once, and then the files go **one at a
  /// time**, each on a data connection of its own. Sequential rather than
  /// parallel, deliberately: rule 3 gives every file in the folder the same
  /// `xferId`, so two of its connections open at once would be two streams with
  /// the same name on them, and the receiver could not tell which file a socket
  /// belongs to until a frame arrived on it — by which time it has already had
  /// to choose where to write. Sending them in the manifest's order (which is
  /// `relPath` order) costs wall-clock on a big folder and buys an ordering both
  /// ends can rely on; `kMaxConcurrentXfers` still lets several folders move at
  /// once.
  ///
  /// Throws [TransferException] for [sendFile]'s reasons, and for one more:
  /// a folder holding more than [kMaxManifestBytes] of manifest is refused
  /// whole — §4.6 rule 5, better said than half-sent.
  ///
  /// A folder that fails part way through keeps what landed: see
  /// [TransferRepository.finishFile]. `failed` here means the task, not the
  /// files, and the ones already across are on disk and openable.
  ///
  /// The other half of "better said than half-sent" is [FolderOffer.skipped]:
  /// the manifest may hold less than the folder does, and the caller is the only
  /// one who can tell the user so.
  Future<FolderOffer> sendFolder({
    required String peerId,
    required Directory directory,
  }) async {
    if (_disposed) {
      throw const TransferException('the transfer service has been disposed');
    }
    if (_activeCount >= kMaxConcurrentXfers) {
      throw const TransferException(
        'too many transfers are already running',
        reason: RejectReason.busy,
      );
    }

    final FolderManifest manifest;
    try {
      manifest = await FolderManifest.walk(directory);
    } on FolderTooLargeException catch (error) {
      // Named from the path rather than the manifest: the walk threw before
      // there was one to ask, and a refusal that cannot say which folder it is
      // refusing is a dialog the user cannot act on.
      throw TransferException(
        '${_baseNameOf(directory.path)} has more than '
        '${error.limit} bytes of file list',
        reason: RejectReason.unsupported,
      );
    } on FileSystemException catch (error) {
      throw TransferException(
        'cannot read ${directory.path}: ${error.message}',
        reason: RejectReason.notFound,
      );
    }

    final String xferId = const Uuid().v4();
    _known.add(xferId);

    final Transfer transfer = await _transfers.beginOutgoingFolder(
      xferId: xferId,
      peerId: peerId,
      folderName: manifest.name,
      folderPath: directory.path,
      entries: manifest.entries,
      now: _clock(),
    );

    final _Outgoing outgoing = _Outgoing(
      transfer: transfer,
      folder: manifest,
      fileName: manifest.name,
      totalSize: manifest.totalSize,
    );
    _outgoing[xferId] = outgoing;
    _emit(transfer);

    unawaited(_runSendFolder(outgoing));
    return FolderOffer(transfer: transfer, skipped: manifest.skipped);
  }

  /// Sends a file again after an attempt at it ended — §6.3's retry.
  ///
  /// A **new transfer, not a resumption**. §4.6's `resumeFrom` is the field for
  /// picking a stopped pair of byte streams back up, and it is deliberately still
  /// `0` everywhere (§4.6.1) — what is retried here is an attempt that is *over*,
  /// with the peer's half of it gone and its `.part`, if there was one, already
  /// deleted by §4.6's cancellation rule. So the offer goes out under a new
  /// `xferId` and the receiver sees an ordinary offer.
  ///
  /// That is also why this is not §5.2's offline re-send, which puts *the same*
  /// `file_offer` on the wire again. Unifying the two is M4's, and it needs a
  /// receiver that tolerates a repeat: today's answers a second offer for an id
  /// it already knows by saying nothing and letting the sender time out.
  ///
  /// [peerId] is the caller's to supply. Unlike [cancelAttachment] there is no
  /// live transfer here to read it from — the attempt being retried has ended,
  /// and the conversation the user is looking at is the one that knows.
  ///
  /// Throws [TransferException] for [sendFile]'s reasons, and for one more: the
  /// file behind the attachment may have moved or been deleted since the attempt
  /// this replaces. §5.2 asks for that to be *said* rather than failed silently,
  /// which is what [RejectReason.notFound] carries up to the page.
  Future<Transfer> retryAttachment({
    required String peerId,
    required String attachmentId,
  }) async {
    if (_disposed) {
      throw const TransferException('the transfer service has been disposed');
    }
    if (_activeCount >= kMaxConcurrentXfers) {
      throw const TransferException(
        'too many transfers are already running',
        reason: RejectReason.busy,
      );
    }

    final Attachment? previous = await _transfers.attachmentById(attachmentId);
    if (previous == null) {
      throw TransferException(
        'no attachment $attachmentId',
        reason: RejectReason.notFound,
      );
    }

    final String? path = previous.localPath;
    if (path == null) {
      throw TransferException(
        '${previous.fileName} has no path on this device',
        reason: RejectReason.notFound,
      );
    }
    final int totalSize;
    try {
      totalSize = await File(path).length();
    } on FileSystemException catch (error) {
      throw TransferException(
        'cannot read $path: ${error.message}',
        reason: RejectReason.notFound,
      );
    }
    if (totalSize != previous.size) {
      // Not the file that was offered. Re-sending it under the old size would
      // stop short or overrun what the receiver agreed to; re-sending it under
      // the new one would hand the peer different bytes under a name it may
      // already have half of, while the card went on showing the old size. A
      // file that has changed is a different file, and the way to send a
      // different file is a new message — which is what the user can do, once
      // this says so instead of failing quietly in the background.
      throw TransferException(
        '${previous.fileName} is $totalSize bytes now, not ${previous.size}',
        reason: RejectReason.unknown,
      );
    }

    final String xferId = const Uuid().v4();
    _known.add(xferId);

    final Transfer transfer = await _transfers.beginRetry(
      xferId: xferId,
      peerId: peerId,
      messageId: previous.messageId,
      attachmentId: attachmentId,
      fileName: previous.fileName,
      totalSize: totalSize,
      mime: previous.mime,
      now: _clock(),
    );

    final _Outgoing outgoing = _Outgoing(
      transfer: transfer,
      file: File(path),
      // The name the peer was offered the first time, not one re-derived from
      // the path: the attachment is the record of what was sent, and a file the
      // user has since renamed in place is still the file that was offered.
      fileName: previous.fileName,
      totalSize: totalSize,
      mime: previous.mime,
    );
    _outgoing[xferId] = outgoing;
    _emit(transfer);

    unawaited(_runSend(outgoing));
    return transfer;
  }

  /// Offers [peerId] everything it was away for — §5.2 rule 5.
  ///
  /// The queue is the database, read rather than remembered, for the reason
  /// §5.2 rule 2 gives about messages: a process that dies with a file owed
  /// finds it owed again on the next start, which is rule 6 without a line of
  /// recovery code. What "owed" means is on the rows too — an outgoing transfer
  /// still reading `pending` has never had its offer on the wire.
  ///
  /// Oldest first, and no more at once than [kMaxConcurrentXfers]: the peer
  /// refuses the fourth offer with `busy`, and a `busy` rejection is an ending,
  /// so a re-offer that ignored the cap would fail the very transfers it came to
  /// save. What is left over stays owed and is offered when one of the transfers
  /// this started finishes ([_releaseOutgoing]).
  Future<void> _offerOwed(String peerId) async {
    // A pre-filter rather than a guard, and deliberately kept as one: a drain
    // that ran with no connection would build an [_Outgoing] per owed transfer
    // and each would come straight back owed (see [_runSend]), so the rows are
    // right either way and this only saves a read and a few file stats. No test
    // can tell the difference, which is what makes it a pre-filter.
    if (_disposed || !_manager.isConnected(peerId)) {
      return;
    }
    final List<Transfer> owed = await _transfers.owedOutgoing(peerId);
    for (final Transfer transfer in owed) {
      // Asked again per transfer, because the drain outlives the event that
      // started it: a folder's re-offer is two reads and an offer, and a peer
      // can be gone by the time the file after it has been stat-ed.
      if (_disposed || !_manager.isConnected(peerId)) {
        return;
      }
      if (_activeCount >= kMaxConcurrentXfers) {
        _log('${owed.length} transfer(s) still owed to $peerId, '
            '$kMaxConcurrentXfers already running');
        return;
      }
      // Claimed synchronously, before the first await, because two drains can
      // overlap: a connection coming up and a transfer finishing are
      // independent events that both call this. Two `_Outgoing`s under one
      // `xferId` would put two offers on the wire for one transfer — the peer
      // refuses the second (it has the id already), and the sender, waiting for
      // an answer to it, would end a transfer that is going perfectly well.
      if (!_claim(transfer.id)) {
        continue;
      }
      await _reoffer(transfer);
    }
  }

  /// Puts one owed transfer back on the wire, under the ids it already has.
  ///
  /// The same `xferId` and the same message, because §5.2 rule 5 asks for *the
  /// same* `file_offer` to be sent again: nothing was ever agreed to, so there
  /// is nothing to renegotiate, and the receiver's dedupe by `msgId` is what
  /// makes a repeat indistinguishable from a first delivery at the other end.
  Future<void> _reoffer(Transfer owed) async {
    final String? messageId = owed.messageId;
    if (messageId == null) {
      await _abandon(owed, 'it has no message to be offered under');
      return;
    }

    final Attachment? file = await _transfers.attachmentFor(owed.id);
    if (file != null) {
      await _reofferFile(owed, file);
      return;
    }
    await _reofferFolder(owed, messageId);
  }

  Future<void> _reofferFile(Transfer owed, Attachment file) async {
    final String? path = file.localPath;
    if (path == null) {
      await _abandon(owed, '${file.fileName} has no path on this device');
      return;
    }

    final int size;
    try {
      size = await File(path).length();
    } on FileSystemException catch (error) {
      // §5.2 rule 5's other half: the file is no longer there to be read, so the
      // message stops being owed and becomes a failure the user can see. The
      // words for it are the ones [retryAttachment] and the card's own Open and
      // Save as already say when the path behind them is gone — the ✗ is what
      // the bubble shows, and this is why pressing it says "no longer on this
      // device" rather than failing again in the same silence.
      await _abandon(owed, '${file.fileName} is gone: ${error.message}');
      return;
    }
    if (size != file.size) {
      // Not the file that was offered. The card shows the size it was offered
      // with, and the peer would be told a different one — one of the two is a
      // lie either way, so this takes the answer [retryAttachment] already gives
      // a file that changed under it: send it as a new message instead.
      await _abandon(owed, '${file.fileName} is $size bytes now, not ${file.size}');
      return;
    }

    final _Outgoing outgoing = _Outgoing(
      transfer: owed,
      file: File(path),
      fileName: file.fileName,
      totalSize: size,
      mime: file.mime,
    );
    _outgoing[owed.id] = outgoing;
    unawaited(_runSend(outgoing));
  }

  /// Rebuilds a folder's offer from the rows that describe it.
  ///
  /// Not from a fresh walk of the directory: §5.2 rule 5 re-sends *the offer the
  /// user made*, and a folder that has gained files since would otherwise be
  /// offered as something the card — which lists the attachment rows — does not
  /// describe. What that costs is empty directories: they carry no bytes, so
  /// §4.6 rule 4 leaves them with no row to be rebuilt from, and a second offer
  /// of a folder holding one arrives without it. Files are unaffected, since the
  /// receiver creates each one's parents on the way (FolderLayout.fileTarget).
  Future<void> _reofferFolder(Transfer owed, String messageId) async {
    final List<Attachment> rows =
        await _transfers.attachmentsForMessage(messageId);
    final List<ManifestEntry> entries = <ManifestEntry>[
      for (final Attachment row in rows)
        if (row.relPath != null)
          ManifestEntry(relPath: row.relPath!, size: row.size),
    ];

    final String? name = await _transfers.messageBody(messageId);
    if (name == null || name.isEmpty) {
      await _abandon(owed, 'the folder it was offering has no name left');
      return;
    }

    final FolderManifest manifest =
        FolderManifest(name: name, entries: entries);
    final _Outgoing outgoing = _Outgoing(
      transfer: owed,
      folder: manifest,
      fileName: manifest.name,
      totalSize: manifest.totalSize,
    );
    _outgoing[owed.id] = outgoing;
    unawaited(_runSendFolder(outgoing));
  }

  /// Gives up on a transfer the peer was never told about — §5.2 rule 5.
  ///
  /// No `file_cancel` goes out, unlike [_endOutgoing]: that frame exists to stop
  /// a peer that is holding a `.part` open for bytes that are not coming, and
  /// this peer has never heard this `xferId`. The ending is written here instead,
  /// which is what moves the message to `failed` and the card to the ✗.
  ///
  /// The id is released as well as ended: nothing is in flight under it, so
  /// holding it would leave the id claimed for the rest of the session. The row
  /// is `failed` now, so the next drain does not find it owed either.
  Future<void> _abandon(Transfer owed, String why) async {
    _log('${owed.id}: not offered again — $why');
    _release(owed.id);
    await _transfers.end(owed.id, state: TransferState.failed, now: _clock());
    _emit(owed.copyWith(state: TransferState.failed));
  }

  Future<void> _runSend(_Outgoing outgoing) async {
    try {
      final bool offered = _manager.sendTransfer(
        outgoing.transfer.peerId,
        FileOfferPayload(
          xferId: outgoing.transfer.id,
          name: outgoing.fileName,
          totalSize: outgoing.totalSize,
          mime: outgoing.mime,
          mtime: await _modifiedAt(outgoing.file!),
        ).toFrame(),
      );
      if (!offered) {
        // §5.2 rule 5: there is nobody to ask, which is not the same as being
        // refused. The row is left `pending` — the state that says exactly this
        // — and [_offerOwed] offers it again when that peer's control
        // connection is back. Failing it here, as this did before M4, turned a
        // phone that stepped out of range for two seconds into a file the user
        // had to pick and drag a second time.
        _log('${outgoing.transfer.id}: kept for later, '
            '${outgoing.transfer.peerId} is not connected');
        return;
      }
      final DateTime now = _clock();
      // Written before the answer is waited for, so that a process killed in
      // the next second does not come back believing nobody was ever asked —
      // that row is this transfer's claim on the peer, and the peer may still
      // be holding the offer.
      await _transfers.markOffered(outgoing.transfer.id, now: now);
      outgoing.advance(TransferState.offered, now);
      _emit(outgoing.transfer);

      final _Answer answer =
          await outgoing.answer.future.timeout(tuning.offerTimeout);
      switch (answer) {
        case _Cancelled():
          // Already recorded by [cancel]; the map entry is gone.
          return;
        case _Rejected(:final RejectReason reason):
          await _endOutgoing(
            outgoing,
            reason == RejectReason.declined
                ? TransferState.declined
                : TransferState.failed,
          );
          return;
        case _Accepted(:final int resumeFrom):
          await _sendBytes(outgoing, resumeFrom);
      }
    } on TimeoutException {
      if (outgoing.ended) {
        return;
      }
      _log('${outgoing.transfer.id}: the peer never answered the offer');
      await _endOutgoing(outgoing, TransferState.failed);
    } on _Aborted {
      // The transfer is over and its outcome is already written — by [cancel],
      // or by the peer's `file_cancel`. Nothing to record.
    } on Object catch (error, stack) {
      if (outgoing.ended) {
        // A cancel landed while this step was in flight. The user's decision is
        // the outcome; a rejected write from a socket they just closed is not
        // news, and overwriting `cancelled` with `failed` would offer them a
        // retry for something they stopped on purpose.
        return;
      }
      _log('${outgoing.transfer.id} failed: $error\n$stack');
      await _endOutgoing(outgoing, TransferState.failed);
    } finally {
      await _releaseOutgoing(outgoing);
    }
  }

  /// The part of sending that needs the data connection.
  ///
  /// Separated from [_runSend] because everything before it is a conversation
  /// and everything here is bytes: the socket is opened, filled, and — in the
  /// success case — deliberately left open until the receipt comes back, since a
  /// `file_done` on the control connection can overtake the last `file_data` on
  /// the data connection, and closing early would discard the tail.
  Future<void> _sendBytes(_Outgoing outgoing, int resumeFrom) async {
    final ControlConnection? data = await _manager.connectData(
      outgoing.transfer.peerId,
      xferId: outgoing.transfer.id,
    );
    if (data == null) {
      throw const TransferException(
        'could not open a data connection to the peer',
      );
    }
    if (outgoing.cancelled) {
      await data.close();
      throw const _Aborted();
    }
    outgoing.data = data;

    final File source = outgoing.file!;
    final OutgoingFile handle = await OutgoingFile.open(
      source,
      from: resumeFrom,
      chunkSize: tuning.chunkSize,
    );
    outgoing.handle = handle;
    if (handle.totalSize != outgoing.totalSize) {
      // The file changed between the offer and this read. Sending the new length
      // would overrun the size the receiver agreed to, and sending the old one
      // would stop short. Neither is a transfer; say so.
      throw TransferException(
        '${outgoing.fileName} changed size after it was offered '
        '(${handle.totalSize} bytes, offered as ${outgoing.totalSize})',
      );
    }

    outgoing.advance(TransferState.transferring, _clock());
    _emit(outgoing.transfer);

    try {
      await handle.pump(
        data,
        xferId: outgoing.transfer.id,
        onProgress: (int sent, int total) {
          if (outgoing.cancelled) {
            // Unreachable while the socket is open — [cancel] closes it and the
            // next `send` fails — but a cancel that lands between two chunks
            // should stop here rather than send one more.
            throw const _Aborted();
          }
          _onSent(outgoing, sent, total);
        },
      );
    } finally {
      // Closed here rather than after the receipt: the read is over, and a file
      // handle held open on a transfer nobody is waiting for is a handle the
      // user cannot move or delete.
      await handle.close();
      outgoing.handle = null;
    }

    if (outgoing.cancelled) {
      throw const _Aborted();
    }

    _manager.sendTransfer(
      outgoing.transfer.peerId,
      TransferRefPayload(xferId: outgoing.transfer.id)
          .toFrame(FrameType.fileDone),
    );

    // The receipt is what makes this honest. Everything up to here says the
    // bytes reached the peer's socket; only its `file_done` says they were
    // renamed into place under a real name — and for a file the user is waiting
    // for, that is the difference between "sent" and "here".
    await outgoing.receipt.future.timeout(tuning.receiptTimeout);
    if (outgoing.cancelled) {
      throw const _Aborted();
    }

    await _transfers.finish(
      outgoing.transfer.id,
      localPath: source.path,
      now: _clock(),
    );
    outgoing.advance(TransferState.done, _clock(),
        bytesDone: outgoing.totalSize);
    _emit(outgoing.transfer);
    _log('${outgoing.transfer.id}: sent ${outgoing.fileName}');
  }

  /// The conversation half of sending a folder, then the files.
  ///
  /// Structured exactly like [_runSend]: offer, wait for a person, act. What is
  /// different is only what comes after the answer — a loop instead of one file.
  Future<void> _runSendFolder(_Outgoing outgoing) async {
    try {
      final FolderManifest manifest = outgoing.folder!;
      final bool offered = _manager.sendTransfer(
        outgoing.transfer.peerId,
        FileOfferPayload(
          xferId: outgoing.transfer.id,
          name: manifest.name,
          totalSize: manifest.totalSize,
          // The manifest, once, on the control connection. The files that follow
          // name themselves with a `relPath`; nothing else describes them.
          isDir: true,
          files: manifest.entries,
        ).toFrame(),
      );
      if (!offered) {
        // Owed, not failed, for the reason [_runSend] gives — and it matters
        // more here: §6.3.3's card offers a failed folder no retry, because a
        // retry would have to re-read a source the card does not hold. So a
        // folder refused by a peer that was merely away used to be a folder the
        // user could only send again by finding it a second time.
        _log('${outgoing.transfer.id}: kept for later, '
            '${outgoing.transfer.peerId} is not connected');
        return;
      }
      final DateTime now = _clock();
      await _transfers.markOffered(outgoing.transfer.id, now: now);
      outgoing.advance(TransferState.offered, now);
      _emit(outgoing.transfer);

      final _Answer answer =
          await outgoing.answer.future.timeout(tuning.offerTimeout);
      switch (answer) {
        case _Cancelled():
          return;
        case _Rejected(:final RejectReason reason):
          await _endOutgoing(
            outgoing,
            reason == RejectReason.declined
                ? TransferState.declined
                : TransferState.failed,
          );
          return;
        case _Accepted():
          // `resumeFrom` is ignored: §4.6.1 defers resuming, and a folder's
          // resume would have to be per file anyway — one number cannot say
          // where each of a thousand files had got to.
          break;
      }

      // Keyed by the **wire** relPath, which is what a `file_done` receipt
      // carries back and what `ManifestEntry.relPath` holds. The rows were
      // written from these same entries in this same order, so a lookup that
      // misses would be a bug in the repository rather than a peer's doing —
      // and a file whose row is missing still gets sent, because refusing to
      // send what the user asked for is the worse answer to that.
      //
      // The row is also where each file's **path on this disk** comes from.
      // `root_path` plus the entry's `relPath` would give the same string —
      // that is how the row was written — but only the row survives to a
      // re-offer, and a folder that was owed to a peer that was away is sent by
      // this same loop on the strength of it.
      final List<Attachment> rows = await _transfers.attachmentsForMessage(
        outgoing.transfer.messageId!,
      );
      final Map<String, Attachment> byPath = <String, Attachment>{
        for (final Attachment row in rows)
          if (row.relPath != null) row.relPath!: row,
      };

      outgoing.advance(TransferState.transferring, _clock(), bytesDone: 0);
      _emit(outgoing.transfer);

      bool failed = false;
      for (final ManifestEntry entry in manifest.entries) {
        if (entry.isDir) {
          // A directory carries no bytes and gets no data connection: §4.6 rule
          // 4 has the receiver rebuild it from the manifest itself, which it
          // does before it answers — so by the time the first file arrives its
          // directory is already there.
          continue;
        }
        if (outgoing.cancelled) {
          throw const _Aborted();
        }
        try {
          final Attachment? row = byPath[entry.relPath];
          final String? path = row?.localPath;
          if (path == null) {
            // Nothing on this device to read for this entry. Thrown inside the
            // try so it costs this file and not the folder: the other files are
            // still worth sending, and the card counts this one as lost.
            throw TransferException('${entry.relPath} has no path on this device');
          }
          await _sendFolderFile(outgoing, entry, File(path), row);
        } on _Aborted {
          rethrow;
        } on Object catch (error) {
          // One file that will not go is not the folder that will not go. The
          // rest are still worth sending — they may be the ones the user wanted
          // — and the task ends `failed`, which is what the card shows and what
          // the files already on the receiver's disk are deliberately not
          // overwritten to say (#5.1.1).
          failed = true;
          _log('${outgoing.transfer.id}: ${entry.relPath} failed: $error');
          _manager.sendTransfer(
            outgoing.transfer.peerId,
            TransferRefPayload(
              xferId: outgoing.transfer.id,
              relPath: entry.relPath,
            ).toFrame(FrameType.fileCancel),
          );
          await _releaseOutgoingFile(outgoing);
        }
      }

      if (outgoing.cancelled) {
        throw const _Aborted();
      }

      // The task's end, said once. §4.3 gives `xfer_done` to the whole task, and
      // this is the moment it is true: every file has been answered for one way
      // or the other.
      _manager.sendTransfer(
        outgoing.transfer.peerId,
        TransferRefPayload(xferId: outgoing.transfer.id)
            .toFrame(FrameType.xferDone),
      );

      if (failed) {
        await _endOutgoing(outgoing, TransferState.failed);
        return;
      }
      await _transfers.finish(
        outgoing.transfer.id,
        now: _clock(),
      );
      outgoing.advance(
        TransferState.done,
        _clock(),
        bytesDone: outgoing.totalSize,
      );
      _emit(outgoing.transfer);
      _log('${outgoing.transfer.id}: sent ${manifest.fileCount} file(s)');
    } on TimeoutException {
      if (outgoing.ended) {
        return;
      }
      _log('${outgoing.transfer.id}: the peer never answered the offer');
      await _endOutgoing(outgoing, TransferState.failed);
    } on _Aborted {
      // Over and recorded, by [cancel] or the peer's `file_cancel`.
    } on Object catch (error, stack) {
      if (outgoing.ended) {
        return;
      }
      _log('${outgoing.transfer.id} failed: $error\n$stack');
      await _endOutgoing(outgoing, TransferState.failed);
    } finally {
      await _releaseOutgoing(outgoing);
    }
  }

  /// Sends one file of a folder, and waits for its receipt.
  ///
  /// The shape of [_sendBytes] with three differences, all of them from being
  /// one of several: the socket belongs to this file and is closed at the end of
  /// it, the frames carry the file's `relPath`, and the ending marks the *file*
  /// done rather than the transfer — `xfer_done` is the task's.
  ///
  /// **The file is opened and checked before the socket is.** That ordering is
  /// what keeps a file this side cannot send from looking, at the other end,
  /// like a transfer that stopped: a data connection that arrives and then
  /// closes with no frames on it is exactly what a sender that died looks like,
  /// and the receiver fails the whole task on one — correctly, since it has no
  /// other way to tell. Opening first means a file that will not go leaves only
  /// a `file_cancel` naming it, and the folder carries on.
  Future<void> _sendFolderFile(
    _Outgoing outgoing,
    ManifestEntry entry,
    File file,
    Attachment? attachment,
  ) async {
    final OutgoingFile handle = await OutgoingFile.open(
      file,
      chunkSize: tuning.chunkSize,
    );
    outgoing.handle = handle;

    try {
      if (handle.totalSize != entry.size) {
        // Changed between the walk and this read. The receiver's row for this
        // file says the size that was offered, and sending a different number of
        // bytes under it would either stop short or overrun what it agreed to.
        throw TransferException(
          '${entry.relPath} changed size after it was offered '
          '(${handle.totalSize} bytes, offered as ${entry.size})',
        );
      }

      final ControlConnection? data = await _manager.connectData(
        outgoing.transfer.peerId,
        xferId: outgoing.transfer.id,
      );
      if (data == null) {
        throw const TransferException(
          'could not open a data connection to the peer',
        );
      }
      if (outgoing.cancelled) {
        await data.close();
        throw const _Aborted();
      }
      outgoing.data = data;
      outgoing.currentRelPath = entry.relPath;
      outgoing.receipt = Completer<void>();

      await handle.pump(
        data,
        xferId: outgoing.transfer.id,
        relPath: entry.relPath,
        onProgress: (int sent, int total) {
          if (outgoing.cancelled) {
            throw const _Aborted();
          }
          _onSentFolderFile(outgoing, sent, total);
        },
      );
    } finally {
      await handle.close();
      outgoing.handle = null;
    }

    if (outgoing.cancelled) {
      throw const _Aborted();
    }

    _manager.sendTransfer(
      outgoing.transfer.peerId,
      TransferRefPayload(
        xferId: outgoing.transfer.id,
        relPath: entry.relPath,
      ).toFrame(FrameType.fileDone),
    );

    // This file's receipt, not the task's. §4.3's `relPath` on a `file_done` is
    // what makes that distinction possible at all, and getting it wrong here
    // would let the second file's bytes be read as the first file's answer.
    await outgoing.receipt.future.timeout(tuning.receiptTimeout);
    if (outgoing.cancelled) {
      throw const _Aborted();
    }

    if (attachment != null) {
      await _transfers.finishFile(attachment.id, localPath: file.path);
    }
    outgoing.folderSent += entry.size;
    outgoing.advance(
      TransferState.transferring,
      _clock(),
      bytesDone: outgoing.folderSent,
    );
    outgoing.lastPercent =
        _folderPercent(outgoing.folderSent, outgoing.totalSize);
    _emit(outgoing.transfer);
    _log('${outgoing.transfer.id}: sent ${entry.relPath}');
    await _releaseOutgoingFile(outgoing);
  }

  /// Records progress within the file being sent, against the folder's total.
  ///
  /// The percentage the user watches is the folder's, not the file's: a card
  /// that showed each file's own progress would walk 0→100 once per file, which
  /// on a thousand-file folder is a thousand complete-looking transfers.
  void _onSentFolderFile(_Outgoing outgoing, int sent, int total) {
    final int done = outgoing.folderSent + sent;
    outgoing.advance(
      TransferState.transferring,
      _clock(),
      bytesDone: done,
    );

    final int percent = _folderPercent(done, outgoing.totalSize);
    if (percent != outgoing.lastPercent) {
      outgoing.lastPercent = percent;
      _emit(outgoing.transfer);
    }

    if (done >= outgoing.persisted + tuning.persistEvery) {
      outgoing.persisted = done;
      _persistQuietly(
        outgoing.transfer.id,
        _transfers.recordProgress(
          outgoing.transfer.id,
          state: TransferState.transferring,
          bytesDone: done,
        ),
      );
    }
  }

  /// How far along a folder is, as the percentage a card shows.
  ///
  /// The folder's, not the file's, and the same arithmetic on both ends: a
  /// number [done] of [total] bytes. A card that followed the file would walk
  /// 0→100 once per file, which on a thousand-file folder is a thousand
  /// complete-looking transfers.
  ///
  /// A total of zero is a folder of nothing but empty directories or empty
  /// files. There is no progress to show, and 100 is the honest answer to "how
  /// much of nothing is left".
  static int _folderPercent(int done, int total) =>
      total <= 0 ? 100 : (done * 100) ~/ total;

  /// Closes the socket and handle of the file just sent.
  ///
  /// Separate from [_releaseOutgoing], which lets go of the whole transfer: a
  /// folder opens one socket per file, and holding them all until the end would
  /// be a folder's worth of open connections.
  Future<void> _releaseOutgoingFile(_Outgoing outgoing) async {
    final OutgoingFile? handle = outgoing.handle;
    outgoing.handle = null;
    await handle?.close();
    final ControlConnection? data = outgoing.data;
    outgoing.data = null;
    outgoing.currentRelPath = null;
    await data?.close();
  }

  /// Records progress as the file is read.
  ///
  /// Two cadences, deliberately different. The emitted [Transfer] changes at most
  /// a hundred times per transfer, because that is the resolution a progress bar
  /// can show and a rebuild per 256 KB chunk is a rebuild per 256 KB chunk. The
  /// row is written every [TransferTuning.persistEvery], because that is about
  /// surviving a crash, not about what the user sees.
  void _onSent(_Outgoing outgoing, int sent, int total) {
    outgoing.advance(
      TransferState.transferring,
      _clock(),
      bytesDone: sent,
    );

    final int percent = total == 0 ? 100 : (sent * 100) ~/ total;
    if (percent != outgoing.lastPercent) {
      outgoing.lastPercent = percent;
      _emit(outgoing.transfer);
    }

    if (sent >= outgoing.persisted + tuning.persistEvery) {
      outgoing.persisted = sent;
      _persistQuietly(
        outgoing.transfer.id,
        _transfers.recordProgress(
          outgoing.transfer.id,
          state: TransferState.transferring,
          bytesDone: sent,
        ),
      );
    }
  }

  // --- Receiving -------------------------------------------------------------

  Future<void> _onOffer(IncomingTransferFrame incoming) async {
    final PayloadDecode<FileOfferPayload> decoded =
        FileOfferPayload.from(incoming.frame);
    if (!decoded.isSuccess) {
      _log('bad file_offer from ${incoming.peerId}: ${decoded.reason}');
      return;
    }
    final FileOfferPayload offer = decoded.value!;

    if (!_claim(offer.xferId)) {
      // Either a duplicate offer for a transfer we are already running, or a
      // peer that reused an id. Answering again would put two writers on one
      // row; saying nothing leaves the peer to its own timeout, which is the
      // right outcome for an offer we cannot attribute.
      _log('${offer.xferId}: an offer for a transfer we already know');
      return;
    }

    if (_activeCount >= kMaxConcurrentXfers) {
      _release(offer.xferId);
      _log('${offer.xferId}: refusing, $kMaxConcurrentXfers already running');
      _reject(incoming.peerId, offer.xferId, RejectReason.busy);
      return;
    }

    // A folder offer whose manifest is missing was already refused by the
    // decoder (`payloads.dart`'s `_manifest` fails on an absent `files`), so an
    // empty `files` here means an empty folder — a real thing to send, and the
    // shape that breaks anything assuming a folder has files in it.
    final Transfer transfer;
    try {
      transfer = offer.isDir
          ? await _transfers.beginIncomingFolder(
              xferId: offer.xferId,
              peerId: incoming.peerId,
              folderName: offer.name,
              entries: offer.files,
              now: _clock(),
            )
          : await _transfers.beginIncoming(
              xferId: offer.xferId,
              peerId: incoming.peerId,
              fileName: offer.name,
              totalSize: offer.totalSize,
              mime: offer.mime,
              now: _clock(),
            );
    } on Object catch (error, stack) {
      _release(offer.xferId);
      _log('could not store the offer from ${incoming.peerId}: $error\n$stack');
      _reject(incoming.peerId, offer.xferId, RejectReason.notFound);
      return;
    }

    if (_disposed) {
      _release(offer.xferId);
      return;
    }
    _incoming[offer.xferId] = _Incoming(transfer: transfer, offer: offer);
    _emit(transfer);
    if (!_offers.isClosed) {
      _offers.add(transfer);
    }
  }

  /// Agrees to an offer, and starts writing.
  ///
  /// The file is opened *before* the acceptance goes out. A `file_accept` is a
  /// promise to be able to write the bytes, and the receiver can fail to keep it
  /// for reasons that have nothing to do with the network — no free name, no
  /// permission, no disk. Discovering that after saying yes leaves the sender
  /// pumping a file into a transfer that is already lost.
  Future<void> accept(String xferId) async {
    final _Incoming? entry = _incoming[xferId];
    if (entry == null || entry.decided || _disposed) {
      return;
    }
    entry.decided = true;

    if (entry.isFolder) {
      await _acceptFolder(entry);
      return;
    }

    final TransferReceiver receiver;
    try {
      final Directory directory = await _downloadDirectory();
      receiver = await TransferReceiver.begin(
        directory: directory,
        xferId: xferId,
        rawName: entry.offer.name,
        totalSize: entry.offer.totalSize,
      );
    } on Object catch (error) {
      // A refusal, not a failure: nothing was agreed to, so the peer is still
      // waiting for an answer and deserves one rather than a minute of silence.
      _log('$xferId: cannot receive into the download folder: $error');
      _reject(entry.transfer.peerId, xferId, RejectReason.notFound);
      await _failIncoming(entry, RejectReason.notFound, sendCancel: false);
      return;
    }

    entry.receiver = receiver;
    entry.advance(TransferState.transferring, _clock(),
        tempPath: receiver.partPath);
    await _transfers.recordTempPath(xferId, receiver.partPath);
    _emit(entry.transfer);

    // `resumeFrom: 0` always — §4.6.1 defers resuming until the `transfer` row
    // is what decides it. It is now, so the three lines this needs are a lookup
    // by name, size and mtime against an unfinished row; they are deliberately
    // not written yet, because a wrong match joins two different files into one
    // that is the right length and the wrong contents.
    final bool sent = _manager.sendTransfer(
      entry.transfer.peerId,
      FileAcceptPayload(xferId: xferId).toFrame(),
    );
    if (!sent) {
      _log('$xferId: accepted, but the peer is no longer connected');
      await _failIncoming(entry, RejectReason.cancelled, sendCancel: false);
    }
  }

  /// Agrees to a folder, having first built everything it will be written into.
  ///
  /// **Every directory in the manifest is created here, before the acceptance
  /// goes out** — §4.6 rule 4, and the same promise [accept] makes for a single
  /// file: saying yes is a claim to be able to write, and a claim discovered to
  /// be false after the sender has started pumping leaves it writing into a
  /// transfer that is already lost. A folder is also where that promise is
  /// cheapest to check, because the tree is described in advance and nothing has
  /// been read yet.
  ///
  /// **One `relPath` that names nothing this device will create refuses the
  /// whole folder** — §4.6 rule 5, and `FolderLayout` is what decides it. Not
  /// per file: a folder that arrives with three of its nine files and no
  /// explanation is worse than one that never arrived, because the user cannot
  /// tell it apart from a folder that only ever had three.
  ///
  /// **The folder merges into an existing directory of the same name.** A second
  /// transfer of `holiday` lands in the same `holiday`, and every file inside is
  /// resolved to a free name of its own (`f0.bin`, then `f0 (1).bin`), so
  /// nothing is ever overwritten. Numbering the folder itself would be the
  /// tidier-looking of the two and would mean two directories claiming to be the
  /// same folder the message names; the files are what must not collide, and
  /// they do not.
  Future<void> _acceptFolder(_Incoming entry) async {
    final String xferId = entry.transfer.id;
    try {
      final Directory downloads = await _downloadDirectory();
      final Directory root = Directory(
        '${downloads.path}${Platform.pathSeparator}'
        '${SafeName.fileName(entry.offer.name)}',
      );
      root.createSync(recursive: true);
      entry.root = root;

      // The rows written when the offer was stored, keyed by the `relPath` the
      // sender is about to put on every one of this file's frames. That string
      // is the only thing that says which file a data connection is delivering:
      // every file of a folder shares one `xferId` (§4.6 rule 3).
      final String? messageId = entry.transfer.messageId;
      if (messageId == null) {
        throw StateError('a folder offer with no message row');
      }
      for (final Attachment row
          in await _transfers.attachmentsForMessage(messageId)) {
        final String? relPath = row.relPath;
        if (relPath != null) {
          entry.byPath[relPath] = row;
        }
      }

      for (final ManifestEntry item in entry.offer.files) {
        final String relPath = item.relPath;
        if (item.isDir) {
          if (FolderLayout.createDirectory(root, relPath) == null) {
            throw FileSystemException('unusable path in the manifest', relPath);
          }
          continue;
        }
        if (FolderLayout.fileTarget(root, relPath) == null) {
          throw FileSystemException('unusable path in the manifest', relPath);
        }
        // One file, one chance to land. The row was written when the offer was
        // stored, so a miss here is the repository's doing rather than a peer's
        // — but a file the sender is about to send and we have no row for would
        // be bytes written with nowhere to record them.
        final Attachment? row = entry.byPath[relPath];
        if (row == null) {
          throw FileSystemException('no attachment for a manifest file', relPath);
        }
        // Everything still owing an outcome. A file leaves this set when it
        // lands or when the sender writes it off, and the folder is over when
        // the set is empty.
        entry.expected.add(relPath);
      }
    } on Object catch (error) {
      _log('$xferId: cannot receive this folder: $error');
      _reject(entry.transfer.peerId, xferId, RejectReason.notFound);
      await _failIncoming(entry, RejectReason.notFound, sendCancel: false);
      return;
    }

    entry.advance(TransferState.transferring, _clock());
    _emit(entry.transfer);

    // `tempPath` is deliberately not recorded for a folder. §5.1's column is one
    // path for one transfer, and a folder's files are written one at a time,
    // each into its own `.part` under its own directory. Writing the first
    // file's would make the row point at a file that is long gone.
    final bool sent = _manager.sendTransfer(
      entry.transfer.peerId,
      FileAcceptPayload(xferId: xferId).toFrame(),
    );
    if (!sent) {
      _log('$xferId: accepted, but the peer is no longer connected');
      await _failIncoming(entry, RejectReason.cancelled, sendCancel: false);
      return;
    }

    // A folder of empty directories, and nothing else. There is no file to
    // wait for and no socket coming, so the task is over the moment it is
    // agreed to — and the directories above are already on disk, which is the
    // whole of what such a folder carries (§4.6 rule 4).
    if (entry.expected.isEmpty) {
      await _endFolder(entry);
    }
  }

  /// Turns an offer down, in the peer's language rather than ours.
  ///
  /// [decided] is the guard, and it is the same one [accept] uses: an offer is
  /// answered **once**, and the first answer is the one that counts. Without it
  /// a decline arriving after an accept — two buttons on one card, a dialog and
  /// a bubble both on screen — would end a *running* transfer: the sender is
  /// sent `file_reject` for a file it is halfway through writing, the row says
  /// `declined`, and the `.part` is dropped where it lies because only [cancel]
  /// deletes it. §4.6's 取消后无残留 broken by a second tap.
  Future<void> decline(
    String xferId, {
    RejectReason reason = RejectReason.declined,
  }) async {
    final _Incoming? entry = _incoming[xferId];
    if (entry == null || entry.decided || _disposed) {
      return;
    }
    entry.decided = true;
    await _transfers.end(
      xferId,
      state: reason == RejectReason.declined
          ? TransferState.declined
          : TransferState.failed,
      now: _clock(),
    );
    _reject(entry.transfer.peerId, xferId, reason);
    await _releaseIncoming(entry);
    _emit(entry.transfer.copyWith(state: TransferState.declined));
  }

  /// Gives up on a transfer, in either direction.
  ///
  /// Terminal and not a failure: the user asked for this, so the UI offers no
  /// retry — and the other end is told with `file_cancel` so it stops reading a
  /// file nobody is writing to.
  Future<void> cancel(String xferId) async {
    final _Outgoing? outgoing = _outgoing[xferId];
    if (outgoing != null) {
      await _cancelOutgoing(outgoing);
      return;
    }
    final _Incoming? incoming = _incoming[xferId];
    if (incoming != null) {
      // The `.part` goes with it, and so does the socket. §4.6's cancellation
      // rule is about what is left on disk — a half-received file the user asked
      // to stop is nothing — but the socket is the other half of stopping: the
      // sender is still pumping into it, and a receiver that merely stopped
      // reading would have those frames buffered in memory, one file's worth,
      // for a transfer both ends have already given up on.
      await _stopIncoming(incoming, tellPeer: true, closeData: true);
    }
  }

  /// Stops the transfer behind [attachmentId], if one is still running.
  ///
  /// The UI knows messages and attachments; the wire knows only `xferId`, and
  /// the two are different ids — §5.1 makes the attachment id local, minted
  /// where its row is written, and the `xferId` is the peer's name for the same
  /// attempt. This is the one place they are joined, and it is a scan of the
  /// few transfers that are live at once rather than a third map to keep in
  /// step with the other two.
  ///
  /// A transfer in neither map has already ended. Cancelling one of those is
  /// nothing to do — the row already says how it went, and `cancel` is not a
  /// way to edit history.
  Future<void> cancelAttachment(String attachmentId) async {
    final String? xferId = _xferIdFor(attachmentId);
    if (xferId != null) {
      await cancel(xferId);
    }
  }

  /// Agrees to the offer behind [attachmentId] — see [cancelAttachment] for why
  /// this goes through a lookup rather than taking an `xferId` directly.
  ///
  /// Nothing happens for an id the service is not holding: an offer that
  /// expired before the user pressed the button, or one answered from the
  /// dialog a moment earlier. The bubble is rebuilt from the row either way,
  /// and answering twice is not a thing that can be undone.
  Future<void> acceptAttachment(String attachmentId) async {
    final String? xferId = _xferIdFor(attachmentId);
    if (xferId != null) {
      await accept(xferId);
    }
  }

  /// Turns down the offer behind [attachmentId]. The same lookup as
  /// [acceptAttachment], and the same silence for an id that is already gone.
  Future<void> declineAttachment(String attachmentId) async {
    final String? xferId = _xferIdFor(attachmentId);
    if (xferId != null) {
      await decline(xferId);
    }
  }

  /// The `xferId` of the live transfer carrying [attachmentId], or null.
  String? _xferIdFor(String attachmentId) {
    for (final _Outgoing outgoing in _outgoing.values) {
      if (outgoing.transfer.attachmentId == attachmentId) {
        return outgoing.transfer.id;
      }
    }
    for (final _Incoming entry in _incoming.values) {
      if (entry.transfer.attachmentId == attachmentId) {
        return entry.transfer.id;
      }
    }
    return null;
  }

  /// Stops a receive, whichever end asked for it.
  ///
  /// Two callers need the same thing — the user's cancel, and the peer's
  /// `file_cancel` — so they share the telling, the deleting and the row, and
  /// they share the one thing that has to be refused.
  Future<void> _stopIncoming(
    _Incoming entry, {
    required bool tellPeer,
    required bool closeData,
  }) async {
    if (entry.finished) {
      // Every byte is in and the file is being installed, so there is no longer
      // an ending to choose: the install is past the point where it can be
      // called off, and a cancel honouring itself here would write `cancelled`
      // over a transfer that is about to be `done` and leave a file the app
      // calls cancelled sitting whole in the user's inbox. It reads the same
      // from the peer's side — a cancel that arrives after the last byte cannot
      // mean anything about bytes already held.
      //
      // A folder is the one case where that is not the end of the story. What is
      // past the point of no return is one *file*, and the files behind it have
      // not been fetched — a cancel that let those arrive would be a cancel that
      // did nothing at all, on a folder of a thousand. So it is recorded, and
      // [_finishFolderFile] ends the task when the install lands. Recorded and
      // not acted on, because the install is the one thing here that must be let
      // finish.
      if (entry.isFolder) {
        entry.stopping = true;
      }
      return;
    }
    entry.cancelled = true;
    if (tellPeer) {
      _manager.sendTransfer(
        entry.transfer.peerId,
        TransferRefPayload(xferId: entry.transfer.id)
            .toFrame(FrameType.fileCancel),
      );
    }
    await _endIncoming(
      entry,
      TransferState.cancelled,
      cancelFile: true,
      closeData: closeData,
    );
    _emit(entry.transfer.copyWith(state: TransferState.cancelled));
  }

  Future<void> _cancelOutgoing(_Outgoing outgoing) async {
    outgoing.cancelled = true;
    if (!outgoing.answer.isCompleted) {
      outgoing.answer.complete(const _Cancelled());
    }
    if (!outgoing.receipt.isCompleted) {
      // Completed rather than failed: [_sendBytes] is the only thing waiting on
      // it, and it checks [cancelled] immediately afterwards. Completing with an
      // error instead would be an unhandled future error whenever the cancel
      // lands before anything is waiting at all — which is the common case, a
      // cancel during the offer.
      outgoing.receipt.complete();
    }
    // Closing the data socket is what stops a transfer already in flight: the
    // read loop is `send`-ing into it, and its next write fails. That is §4.6's
    // "cancel = destroy the socket", and it costs nothing to also do when the
    // transfer has not reached that point yet.
    final ControlConnection? data = outgoing.data;
    if (data != null) {
      outgoing.data = null;
      await data.close();
    }
    _manager.sendTransfer(
      outgoing.transfer.peerId,
      TransferRefPayload(xferId: outgoing.transfer.id)
          .toFrame(FrameType.fileCancel),
    );
    await _endOutgoing(outgoing, TransferState.cancelled);
    _log('${outgoing.transfer.id}: cancelled');
  }

  // --- Frames from the peer --------------------------------------------------

  Future<void> _onTransferFrame(IncomingTransferFrame incoming) async {
    if (_disposed) {
      return;
    }
    final Frame frame = incoming.frame;
    switch (frame.type) {
      case FrameType.fileOffer:
        await _onOffer(incoming);
        return;

      case FrameType.fileAccept:
        final PayloadDecode<FileAcceptPayload> decoded =
            FileAcceptPayload.from(frame);
        if (!decoded.isSuccess) {
          _log('bad file_accept from ${incoming.peerId}: ${decoded.reason}');
          return;
        }
        _outgoing[decoded.value!.xferId]?.reply(
          _Accepted(decoded.value!.resumeFrom),
        );
        return;

      case FrameType.fileReject:
        final PayloadDecode<FileRejectPayload> decoded =
            FileRejectPayload.from(frame);
        if (!decoded.isSuccess) {
          _log('bad file_reject from ${incoming.peerId}: ${decoded.reason}');
          return;
        }
        _outgoing[decoded.value!.xferId]?.reply(
          _Rejected(decoded.value!.reason),
        );
        return;

      case FrameType.fileDone:
        await _onFileDone(incoming);
        return;

      case FrameType.fileCancel:
        await _onFileCancel(incoming);
        return;

      case FrameType.xferDone:
        // The end of a whole transfer *task* — a folder, in M4. Nothing to do
        // with it: both ends count their own files, and the last `file_done` or
        // `file_cancel` is what tells each of them the task is over. It is the
        // statement of an ending rather than the means of one, and this side
        // sends its own for exactly that reason.
        return;

      default:
        _log('unhandled "${frame.type}" from ${incoming.peerId}');
        return;
    }
  }

  /// `file_done` means two different things, one per direction.
  ///
  /// From a receiver it is a receipt: "the file is renamed into place". From a
  /// sender it is a notice: "every byte is on the wire", which matters only for
  /// the one case the byte count cannot cover — a zero-byte file has no chunks,
  /// so its receiver would otherwise wait forever for a last chunk that is never
  /// coming (§4.6.1).
  ///
  /// The two directions are told apart by which map holds the id, and both are
  /// reachable at once because the receipt and the notice are sent
  /// independently.
  Future<void> _onFileDone(IncomingTransferFrame incoming) async {
    final PayloadDecode<TransferRefPayload> decoded =
        TransferRefPayload.from(incoming.frame);
    if (!decoded.isSuccess) {
      _log('bad file_done from ${incoming.peerId}: ${decoded.reason}');
      return;
    }
    final String xferId = decoded.value!.xferId;

    final _Outgoing? outgoing = _outgoing[xferId];
    if (outgoing != null) {
      if (decoded.value!.relPath != outgoing.currentRelPath) {
        // A receipt for a file that is not the one in flight. §4.3 puts
        // `relPath` on `file_done` for exactly this: a folder's files share an
        // `xferId`, so without the check the answer to the second file would be
        // read as the answer to the first — and the sender would open the third
        // file's connection while the second was still being written.
        _log('$xferId: file_done for '
            '"${decoded.value!.relPath ?? 'another file'}" while '
            '"${outgoing.currentRelPath ?? 'none'}" is in flight');
        return;
      }
      if (!outgoing.receipt.isCompleted) {
        outgoing.receipt.complete();
      }
      return;
    }

    final _Incoming? entry = _incoming[xferId];
    if (entry != null) {
      await _onIncomingFileDone(entry, decoded.value!.relPath);
      return;
    }
    _log('$xferId: file_done for a transfer we are not running');
  }

  /// The sender's notice that it has put every byte of one file on the wire,
  /// arriving on the control connection while the bytes themselves travel on
  /// another.
  ///
  /// For a single file this is the whole of it, and it is the only signal a
  /// zero-byte file ever sends (§4.6.1). A folder needs two more things from it,
  /// both of them the same fact: **the notice is the only frame that ever names
  /// a file with no bytes in it.** A file with bytes names itself on its first
  /// `file_data` — and it is usually already installed by the time this arrives,
  /// because the chunk that completed it came first and finished it on the byte
  /// count. That is the ordinary path through here, and it ends with nothing to
  /// do.
  Future<void> _onIncomingFileDone(_Incoming entry, String? relPath) async {
    if (!entry.isFolder) {
      await _maybeFinishIncoming(entry);
      return;
    }
    if (entry.receiver != null) {
      if (relPath != entry.currentRelPath) {
        // A notice for a file that is not the one in flight. Every file of a
        // folder shares an `xferId`, so without this the sender's word about
        // the second file would be read as the first file being whole — and an
        // empty second file would be installed as the first file's bytes.
        _log('${entry.transfer.id}: file_done for '
            '"${relPath ?? 'another file'}" while '
            '"${entry.currentRelPath ?? 'none'}" is in flight');
        return;
      }
      await _maybeFinishIncoming(entry);
      return;
    }
    if (relPath == null || !entry.expected.contains(relPath)) {
      // Nothing left to do for this file. Either it landed from its last chunk,
      // or it was written off — and in both cases the sender's word arrives
      // after the fact.
      return;
    }
    if (await _folderFileOf(entry, relPath) == null) {
      return;
    }
    await _maybeFinishIncoming(entry);
  }

  Future<void> _onFileCancel(IncomingTransferFrame incoming) async {
    final PayloadDecode<TransferRefPayload> decoded =
        TransferRefPayload.from(incoming.frame);
    if (!decoded.isSuccess) {
      _log('bad file_cancel from ${incoming.peerId}: ${decoded.reason}');
      return;
    }
    final String xferId = decoded.value!.xferId;

    final _Outgoing? outgoing = _outgoing[xferId];
    if (outgoing != null) {
      outgoing.cancelled = true;
      if (!outgoing.answer.isCompleted) {
        outgoing.answer.complete(const _Cancelled());
      }
      if (!outgoing.receipt.isCompleted) {
        outgoing.receipt.complete();
      }
      await _endOutgoing(outgoing, TransferState.cancelled);
      return;
    }

    final _Incoming? entry = _incoming[xferId];
    if (entry == null) {
      return;
    }
    if (entry.isFolder) {
      await _onFolderFileCancel(entry, decoded.value!.relPath);
      return;
    }
    // A transfer that was only ever an offer has nothing on disk to remove,
    // and no receiver to cancel. The peer is not told: it is the one that said
    // so, and the socket is already going at its end.
    await _stopIncoming(entry, tellPeer: false, closeData: false);
  }

  /// The sender's giving up on one file of a folder.
  ///
  /// **The folder goes on.** §4.6 rule 3 makes one file's failure that file's,
  /// and the sender has already moved to the next one — so an ending here that
  /// took the task with it would drop the files that are still coming, which are
  /// the ones the user asked for and the sender is still willing to send. The
  /// task ends `failed` when the last file has an outcome, and the files that
  /// did land stay on disk (§5.1.1).
  Future<void> _onFolderFileCancel(_Incoming entry, String? relPath) async {
    if (relPath == null || !entry.expected.remove(relPath)) {
      // A file with no outcome was named... by a frame that has none to give it.
      // Nothing to change, and nothing to fail the task over: it is one frame,
      // and the sender's count is what ends the folder.
      _log('${entry.transfer.id}: file_cancel for '
          '"${relPath ?? 'no file'}" changes nothing');
      return;
    }
    entry.anyFailed = true;
    // The attachment is deliberately left alone here. The folder's ending is
    // what writes off every file that has no outcome
    // ([TransferRepository.end] → `endPendingAttachments`), and it is the one
    // that can do it completely: `done` is never overwritten, so this file
    // reading `offered` for the rest of the task costs a card nothing, while a
    // second writer here would be a second place the rule lives.
    _log('${entry.transfer.id}: $relPath was given up on');

    if (entry.expected.isEmpty) {
      await _endFolder(entry);
    }
  }

  // --- The data connection ---------------------------------------------------

  /// Claims an accepted `role: data` socket for the transfer that asked for it.
  ///
  /// Anything else is closed here, because the pool deliberately will not: a
  /// data connection arrives without anyone asking for it, and one that matches
  /// no transfer has no other owner who would ever close it (§4.4.2).
  void _onDataConnection(DataConnection data) {
    final _Incoming? entry = _incoming[data.xferId];
    // `decided` rather than a receiver, and a folder is why: a folder's offer
    // says nothing about which of its files a socket is for — that is the first
    // `file_data` frame's `relPath`, so there is nothing to build a receiver
    // from until one arrives. Asking for a receiver here would refuse every
    // folder's every socket.
    if (_disposed || entry == null || !entry.decided) {
      _log('${data.xferId}: refusing an unclaimed data connection');
      unawaited(data.connection.close());
      return;
    }
    if (entry.data != null) {
      // A second socket for one transfer. Only one of them can be the sender's
      // data connection; taking both would split the file between them.
      _log('${data.xferId}: refusing a second data connection');
      unawaited(data.connection.close());
      return;
    }
    entry.attach(
      data.connection,
      onFrame: (Frame frame) => _onDataFrame(entry, frame),
      onClosed: () => unawaited(_onDataClosed(entry)),
    );
  }

  /// Handles one chunk, in order — see the class doc for why the order matters.
  Future<void> _onDataFrame(_Incoming entry, Frame frame) async {
    if (entry.finished || entry.cancelled) {
      return;
    }
    if (frame.type != FrameType.fileData) {
      // The only frames a sender puts on a data connection are file_data. A
      // control frame here means it has lost track of which socket it is
      // writing to, and the bytes it meant to send are not in this one.
      _log('${entry.transfer.id}: "${frame.type}" on a data connection');
      await _failIncoming(entry, RejectReason.cancelled);
      return;
    }

    TransferReceiver? receiver = entry.receiver;
    if (receiver == null) {
      if (!entry.isFolder) {
        // A single file's receiver is built when the user accepts, before the
        // acceptance goes out — so a chunk with nothing to write it into is a
        // sender that did not wait for one.
        _log('${entry.transfer.id}: a chunk arrived before the file was accepted');
        return;
      }
      // A folder's receiver is built from the first frame of each file, because
      // the `relPath` in this frame is the only thing that says which file this
      // socket is delivering (§4.6 rule 3).
      receiver = await _folderFileOf(entry, frame.header['relPath'] as String?);
      if (receiver == null) {
        return;
      }
    }

    try {
      await receiver.accept(frame);
    } on FileReceiveException catch (error) {
      // Out of order, over the declared size, or a full disk. All of them mean
      // the bytes on disk cannot be trusted to become the file that was offered.
      _log('${entry.transfer.id}: ${error.message}');
      await _failIncoming(entry, RejectReason.cancelled);
      return;
    }

    // The folder's count, not the file's: the row is the *task* (§5.1.1), and a
    // card reading the file's bytes would drop back to zero at every file.
    final int done = entry.isFolder
        ? entry.landed + receiver.received
        : receiver.received;
    entry.advance(TransferState.transferring, _clock(), bytesDone: done);
    final int percent = entry.isFolder
        ? _folderPercent(done, entry.offer.totalSize)
        : (receiver.totalSize == 0
            ? 100
            : (receiver.received * 100) ~/ receiver.totalSize);
    if (percent != entry.lastPercent) {
      entry.lastPercent = percent;
      _emit(entry.transfer);
    }
    if (done >= entry.persisted + tuning.persistEvery) {
      entry.persisted = done;
      _persistQuietly(
        entry.transfer.id,
        _transfers.recordProgress(
          entry.transfer.id,
          state: TransferState.transferring,
          bytesDone: done,
        ),
      );
    }

    await _maybeFinishIncoming(entry);
  }

  /// Starts writing one file of a folder, named by the `relPath` that has just
  /// turned up on its first frame.
  ///
  /// A folder's bytes arrive as a sequence of files sharing one `xferId`, each
  /// on a connection of its own, and nothing before the first `file_data` says
  /// which file a connection carries — hence a receiver built here rather than
  /// when the user accepted.
  ///
  /// Null means **do not proceed**, and there are two reasons for it that read
  /// the same to the caller and differently in the log:
  ///
  /// * the file already has an outcome, so there is nothing to do. This is the
  ///   ordinary case for a file with bytes: its last chunk finished it, and the
  ///   sender's `file_done` for the same file is still on its way.
  /// * the name is not one of this folder's files at all, which is a sender that
  ///   has lost track of what it offered. The transfer is failed, because the
  ///   bytes on this socket have nowhere to go and the ones that follow would
  ///   be guessed at.
  /// The receipt for the folder file [relPath], built if this is the first
  /// thing to ask for one.
  ///
  /// A folder's file can be started from two places, and they arrive on two
  /// different connections: the first `file_data` of it, on the data connection,
  /// and the sender's `file_done` for it — the only thing that ever comes for a
  /// file of no bytes — on the control connection. Neither can be answered by a
  /// receipt built earlier, because nothing before either of them names the
  /// file.
  ///
  /// Building one takes several awaits (the directories, then the `.part`), and
  /// [entry] is only told about it at the end. Both callers used to pass the
  /// "is anything in flight?" check inside that window and build two receipts
  /// over one `.part`; the file the second one still holds cannot then be
  /// renamed into place, and the transfer fails on a disk error that is really a
  /// race. So the second caller waits for the first instead of repeating it.
  ///
  /// Only one file of a folder is ever in flight, so a claim already in progress
  /// is necessarily a claim for this file.
  Future<TransferReceiver?> _folderFileOf(_Incoming entry, String? relPath) async {
    final Completer<TransferReceiver?>? pending = entry.starting;
    if (pending != null) {
      return pending.future;
    }
    final Completer<TransferReceiver?> claim = Completer<TransferReceiver?>();
    entry.starting = claim;
    TransferReceiver? receiver;
    try {
      receiver = await _beginFolderFile(entry, relPath);
    } finally {
      entry.starting = null;
      claim.complete(receiver);
    }
    return receiver;
  }

  Future<TransferReceiver?> _beginFolderFile(
    _Incoming entry,
    String? relPath,
  ) async {
    if (relPath == null) {
      _log('${entry.transfer.id}: a folder chunk with no relPath');
      await _failIncoming(entry, RejectReason.cancelled);
      return null;
    }
    if (!entry.expected.contains(relPath)) {
      if (entry.byPath.containsKey(relPath)) {
        _log('${entry.transfer.id}: $relPath has already been answered for');
        return null;
      }
      _log('${entry.transfer.id}: $relPath is not a file of this folder');
      await _failIncoming(entry, RejectReason.cancelled);
      return null;
    }
    final Directory? root = entry.root;
    final Attachment? row = entry.byPath[relPath];
    if (root == null || row == null) {
      _log('${entry.transfer.id}: no place for $relPath');
      await _failIncoming(entry, RejectReason.cancelled);
      return null;
    }

    // The path was resolved and its directories created when the folder was
    // accepted, so a null here is this device changing under us — a file where
    // a directory has to be, or the folder itself deleted mid-transfer.
    final FolderTarget? target = FolderLayout.fileTarget(root, relPath);
    if (target == null) {
      _log('${entry.transfer.id}: $relPath names nowhere writable any more');
      await _failIncoming(entry, RejectReason.cancelled);
      return null;
    }

    final TransferReceiver receiver;
    try {
      receiver = await TransferReceiver.begin(
        directory: target.directory,
        xferId: entry.transfer.id,
        rawName: target.name,
        totalSize: row.size,
        // The **wire** value, not the sanitised one: the receiver refuses a
        // chunk whose `relPath` is not this one, and the sender writes the name
        // it offered on every chunk (§4.6 rule 3).
        relPath: relPath,
      );
    } on Object catch (error) {
      _log('${entry.transfer.id}: cannot write $relPath: $error');
      await _failIncoming(entry, RejectReason.cancelled);
      return null;
    }
    entry.receiver = receiver;
    entry.currentRelPath = relPath;
    return receiver;
  }

  /// Finishes a receive whose bytes have all arrived.
  ///
  /// The test is the byte count, not `eof` and not the sender's `file_done`
  /// (§4.6.1): a zero-byte file has no data frames at all, so anything waiting
  /// for a last chunk waits forever. `eof` is recorded by the receiver and never
  /// read here.
  ///
  /// Called after every chunk and again when the sender says it is finished.
  /// Both are needed: the chunk that completes the file usually arrives before
  /// the notice, since they travel on different connections — but for a
  /// zero-byte file the notice is the only thing that ever comes.
  Future<void> _maybeFinishIncoming(_Incoming entry) async {
    final TransferReceiver? receiver = entry.receiver;
    if (receiver == null || entry.finished || entry.cancelled) {
      return;
    }
    if (receiver.received != receiver.totalSize) {
      return;
    }
    entry.finished = true;

    final String path;
    try {
      path = await receiver.complete();
    } on Object catch (error) {
      _log('${entry.transfer.id}: could not finish the file: $error');
      await _failIncoming(entry, RejectReason.cancelled);
      return;
    }

    if (entry.isFolder) {
      await _finishFolderFile(entry, receiver, path);
      return;
    }

    await _transfers.finish(entry.transfer.id, localPath: path, now: _clock());
    entry.advance(
      TransferState.done,
      _clock(),
      bytesDone: receiver.totalSize,
    );
    _emit(entry.transfer);
    _log('${entry.transfer.id}: received into $path');

    // The receipt. Sent before the socket is closed, because it is the only
    // thing that tells the sender its file landed — and the sender is holding
    // its own socket open waiting for exactly this.
    _manager.sendTransfer(
      entry.transfer.peerId,
      TransferRefPayload(xferId: entry.transfer.id).toFrame(FrameType.fileDone),
    );
    // The sender has nothing left to send; it will close its end when the
    // receipt arrives. This side is done with the socket either way.
    await _releaseIncoming(entry, closeData: true);

    // Deliberately last, deliberately not awaited. The transfer is over in every
    // sense that matters — the bytes are on disk, the row says `done`, the
    // sender has its receipt — and a copy into the gallery is not part of
    // receiving the file. Holding this future open would stall the chain that
    // processes data frames strictly in order (see the class doc), which for a
    // folder would stop the next file's chunks behind a copy of the last one's.
    unawaited(_publishToGallery(entry, path));
  }

  /// Copies a received picture into the system gallery, if it is one and if
  /// there is anywhere to put it — §7.1.
  ///
  /// Only single files. A folder of photographs would flatten its structure into
  /// one album and pour hundreds of entries into it, which is not what "put the
  /// picture I was sent into my photos" asked for, and a folder keeps its own
  /// arrangement under the download directory where the whole tree is visible.
  /// Lifting this restriction means calling this from [_finishFolderFile], whose
  /// `row` already carries the name and mime this has to look up.
  ///
  /// Failing is logged and nothing else. The alternative — marking a completed
  /// transfer failed because a second copy of it could not be written — would
  /// turn a cosmetic problem into a lie about the user's file.
  Future<void> _publishToGallery(_Incoming entry, String path) async {
    final Future<bool> Function({
      required String path,
      required String name,
      required String? mime,
    })? publish = _publishImage;
    if (publish == null) {
      return;
    }

    // Null for a folder, which is the case this deliberately does not handle:
    // a folder's files are its attachments, and it has none of its own.
    final String? attachmentId = entry.transfer.attachmentId;
    if (attachmentId == null) {
      return;
    }

    // Everything below is inside the try, the database read included. Nothing
    // awaits this future — that is the point of it — so anything that escapes
    // here is an unhandled error in the zone rather than a failed transfer, and
    // the case that produces one is not exotic: disposing the service closes the
    // database, and a publish that was already in flight then reads a closed
    // one.
    String name = 'the file';
    try {
      final Attachment? row = await _transfers.attachmentById(attachmentId);
      if (row == null || !row.isGalleryImage) {
        return;
      }
      name = row.fileName;
      // Non-null for everything that got past the check above:
      // `galleryExtensions` is derived from [Attachment.galleryMimes]'s keys, so
      // a format that passes one is a format the other has a type for.
      final String? mime = row.galleryMime;
      final bool published = await publish(path: path, name: name, mime: mime);
      if (published) {
        _log('${entry.transfer.id}: $name is in the gallery');
      }
    } on Object catch (error) {
      _log('${entry.transfer.id}: could not add $name to the gallery: $error');
    }
  }

  /// Ends one file of a folder that has landed, and then the task if it was the
  /// last one.
  ///
  /// Three endings are different from a single file's, and all three come from
  /// the same fact — the transfer outlives the file:
  ///
  /// * the **row that says `done`** is the file's attachment, not the transfer.
  ///   The task's row is still `transferring`, because it is (§5.1.1).
  /// * the **socket closed** is this file's. The sender opens a new one for the
  ///   next file, and that one has to find the transfer ready to take it.
  /// * the **receipt carries the `relPath`**, because one `xferId` covers every
  ///   file in the folder and the sender is waiting to hear about *this* one.
  Future<void> _finishFolderFile(
    _Incoming entry,
    TransferReceiver receiver,
    String path,
  ) async {
    final String relPath = entry.currentRelPath!;
    final Attachment? row = entry.byPath[relPath];
    if (row != null) {
      await _transfers.finishFile(row.id, localPath: path);
    }
    entry.expected.remove(relPath);
    entry.landed += receiver.totalSize;
    _log('${entry.transfer.id}: received $relPath into $path');

    _manager.sendTransfer(
      entry.transfer.peerId,
      TransferRefPayload(xferId: entry.transfer.id, relPath: relPath)
          .toFrame(FrameType.fileDone),
    );

    // Before the next file's socket can be offered, this one has to be gone.
    // The sender opens it the moment the receipt above reaches it, and the
    // arrival would otherwise be refused as a second connection for a transfer
    // that is only between files.
    await entry.detach(closeData: true);
    entry.receiver = null;
    entry.currentRelPath = null;
    // Per file, not per task: the next file goes through the same install, and
    // a `finished` left standing would make [cancel] refuse to stop it.
    entry.finished = false;

    if (entry.expected.isEmpty) {
      // Everything has an outcome, so a stop requested a moment ago has nothing
      // left to stop: the folder is what it is, and calling it `cancelled` would
      // be a card that hides a folder that arrived whole.
      await _endFolder(entry);
      return;
    }
    if (entry.stopping) {
      // This file landed whole and stays — §4.6's 取消后无残留 is about a half
      // of something, and this is not a half of anything. What the cancel stops
      // is the files behind it, and the sender has to be told, because it is
      // about to open the next one's connection.
      _manager.sendTransfer(
        entry.transfer.peerId,
        TransferRefPayload(xferId: entry.transfer.id)
            .toFrame(FrameType.fileCancel),
      );
      await _endIncoming(entry, TransferState.cancelled, closeData: true);
      _emit(entry.transfer.copyWith(state: TransferState.cancelled));
      _log('${entry.transfer.id}: stopped, $relPath and '
          '${entry.expected.length} file(s) behind it not fetched');
      return;
    }
    entry.advance(TransferState.transferring, _clock(), bytesDone: entry.landed);
    final int percent = _folderPercent(entry.landed, entry.offer.totalSize);
    if (percent != entry.lastPercent) {
      entry.lastPercent = percent;
      _emit(entry.transfer);
    }
  }

  /// Ends a folder whose every file has an outcome, landed or written off.
  ///
  /// A failed *task* keeps its files. §5.1.1 has the repository end the
  /// attachments that had not already landed, and the ones that did are on disk
  /// under their own names — a card saying `failed` beside nine files the user
  /// can open is telling the truth about the task, and the alternative is a
  /// transfer that deletes work it successfully did.
  Future<void> _endFolder(_Incoming entry) async {
    // The task's end, said once. Both ends count their own files, so neither
    // needs this frame to know the task is over; it is the statement of one,
    // which is what §4.3 gives it to the whole-task case.
    _manager.sendTransfer(
      entry.transfer.peerId,
      TransferRefPayload(xferId: entry.transfer.id).toFrame(FrameType.xferDone),
    );

    if (entry.anyFailed) {
      await _endIncoming(
        entry,
        TransferState.failed,
        cancelFile: true,
        closeData: true,
      );
      _emit(entry.transfer.copyWith(state: TransferState.failed));
      _log('${entry.transfer.id}: the folder failed, ${entry.landed} bytes kept');
      return;
    }
    await _transfers.finish(entry.transfer.id, now: _clock());
    entry.advance(TransferState.done, _clock(), bytesDone: entry.landed);
    _emit(entry.transfer);
    _log('${entry.transfer.id}: the folder arrived, ${entry.landed} bytes');
    // There is no file in flight to cancel — the folder ended because the last
    // one landed — but the socket it landed on is still here, and the transfer
    // is not something the service should go on holding.
    await _releaseIncoming(entry, closeData: true);
  }

  /// A data connection ended before the file was whole.
  ///
  /// The normal ending — the receiver closed it after finishing — is filtered
  /// out by the state check, so anything arriving here is a transfer that
  /// stopped: the peer closed the app, the Wi-Fi dropped, or the sender died
  /// mid-file.
  Future<void> _onDataClosed(_Incoming entry) async {
    if (entry.finished || entry.cancelled || _disposed) {
      return;
    }
    _log('${entry.transfer.id}: the data connection ended '
        'at ${entry.receiver?.received} of ${entry.receiver?.totalSize}');
    await _failIncoming(entry, RejectReason.cancelled);
  }

  // --- Outcomes --------------------------------------------------------------

  Future<void> _failIncoming(
    _Incoming entry,
    RejectReason reason, {
    bool sendCancel = true,
  }) async {
    // `finished` is deliberately not part of this. It means "every byte is in
    // and the file is being installed", and an install that *fails* — a rename
    // onto a name the file system refuses, a volume that filled up between the
    // last chunk and it — is a failure to report like any other. Reading it as
    // "too late to fail" left the row saying `transferring` forever, holding a
    // slot, behind a bar stuck at 100%.
    //
    // `cancelled` is what makes this idempotent, and it is the only thing that
    // has to be: every path that ends a transfer sets it, and a second call
    // finds nothing left to end.
    if (entry.cancelled) {
      return;
    }
    entry.cancelled = true;
    if (sendCancel) {
      // The peer is still writing; it has to be told to stop.
      _manager.sendTransfer(
        entry.transfer.peerId,
        TransferRefPayload(xferId: entry.transfer.id)
            .toFrame(FrameType.fileCancel),
      );
    }
    // The socket goes too, when there is one: the sender is still writing into
    // it, and `file_cancel` alone would leave it pumping until its next write
    // failed for a reason it cannot see.
    await _endIncoming(
      entry,
      TransferState.failed,
      cancelFile: true,
      closeData: true,
    );
    _emit(entry.transfer.copyWith(state: TransferState.failed));
    _log('${entry.transfer.id}: failed (${reason.wire})');
  }

  Future<void> _endOutgoing(_Outgoing outgoing, TransferState state) async {
    if (outgoing.ended) {
      return;
    }
    outgoing.ended = true;
    await _transfers.end(
      outgoing.transfer.id,
      state: state,
      now: _clock(),
    );
    outgoing.advance(state, _clock());
    _emit(outgoing.transfer);
    if (state == TransferState.failed) {
      // Only a failure leaves the peer still working on this transfer without
      // knowing: a decline came *from* it, and a cancel is either the user's —
      // told explicitly by [_cancelOutgoing] — or the peer's. A failure is ours,
      // and it is holding a `.part` open for a file that is not coming.
      _manager.sendTransfer(
        outgoing.transfer.peerId,
        TransferRefPayload(xferId: outgoing.transfer.id)
            .toFrame(FrameType.fileCancel),
      );
    }
  }

  Future<void> _releaseOutgoing(_Outgoing outgoing) async {
    _outgoing.remove(outgoing.transfer.id);
    _release(outgoing.transfer.id);
    await _releaseOutgoingFile(outgoing);

    if (outgoing.transfer.state == TransferState.done) {
      // A slot has just been freed by work that finished, and §5.2 rule 5's
      // queue may hold more than the cap let [_offerOwed] start at once — the
      // case being four files dropped on a phone that was away, where the
      // fourth would otherwise sit owed until the next disconnect.
      //
      // Only a **done** transfer re-triggers this. An attempt that came
      // straight back owed must not offer itself again, or a socket that says
      // it is up and refuses every write would spin here; one that failed has
      // an ending of its own to show for it.
      unawaited(_offerOwed(outgoing.transfer.peerId));
    }
  }

  /// Lets go of an incoming transfer and only then records how it ended.
  ///
  /// The order is the whole point. A row reading `cancelled` or `failed` is a
  /// promise that nothing of this transfer is left on disk — 取消后无残留 — and
  /// the row is what everything else reads: the UI, the next run's sweep, the
  /// tests. Writing it first turns that promise into a race against a `.part`
  /// that is still on its way out, which is visible whenever the caller's next
  /// step is quicker than the delete. It was: the receiver's cancel wrote the
  /// row, and a test that waited for the row could still see `big.bin.part`
  /// sitting in the folder.
  ///
  /// The row is written even when the cleanup throws. A transfer stuck in
  /// `transferring` is worse than one whose `.part` outlived it, because the
  /// row is what a retry, a sweep and the UI all start from.
  Future<void> _endIncoming(
    _Incoming entry,
    TransferState state, {
    bool cancelFile = false,
    bool closeData = false,
  }) async {
    // Made inert before anything is awaited, so that a frame or a socket event
    // still in flight for this transfer finds an entry that will do nothing with
    // it. It is the same flag [cancel] and a failed receive set, and here it
    // means the third thing it has to: this transfer is over, whoever ended it.
    entry.cancelled = true;
    try {
      await _releaseIncoming(
        entry,
        cancelFile: cancelFile,
        closeData: closeData,
      );
    } finally {
      await _transfers.end(
        entry.transfer.id,
        state: state,
        now: _clock(),
      );
    }
  }

  Future<void> _releaseIncoming(
    _Incoming entry, {
    bool cancelFile = false,
    bool closeData = false,
  }) async {
    _incoming.remove(entry.transfer.id);
    _release(entry.transfer.id);
    await entry.detach(closeData: closeData);
    if (cancelFile) {
      // Removes the `.part`. The finished file, if there is one, is under its
      // real name by now and is not this method's to touch.
      await entry.receiver?.cancel();
    }
  }

  // --- Small things ----------------------------------------------------------

  /// Takes ownership of [xferId], reporting whether it was free.
  bool _claim(String xferId) {
    if (_known.contains(xferId)) {
      return false;
    }
    _known.add(xferId);
    return true;
  }

  void _release(String xferId) => _known.remove(xferId);

  int get _activeCount => _outgoing.length + _incoming.length;

  void _reject(String peerId, String xferId, RejectReason reason) {
    _manager.sendTransfer(
      peerId,
      FileRejectPayload(xferId: xferId, reason: reason).toFrame(),
    );
  }

  void _emit(Transfer transfer) {
    if (!_changes.isClosed) {
      _changes.add(transfer);
    }
  }

  /// The last path component, which is what the peer is offered.
  ///
  /// The peer reduces it further with `SafeName`; sending anything but the name
  /// would offer it a path from a file system it cannot see.
  static String _baseName(File file) => _baseNameOf(file.path);

  /// The same, for a path we have no [File] for — a folder the walk refused
  /// before it produced a name.
  static String _baseNameOf(String path) {
    final int cut = path.lastIndexOf(RegExp(r'[/\\]'));
    return cut < 0 ? path : path.substring(cut + 1);
  }

  static Future<int?> _modifiedAt(File file) async {
    try {
      return (await file.lastModified()).millisecondsSinceEpoch;
    } on FileSystemException {
      // Advisory (§4.3): a receiver uses it to tell one interrupted transfer of
      // a name from another file of the same name. Not worth failing an offer
      // over, and not worth a second read of the directory.
      return null;
    }
  }

  /// Writes a checkpoint without making the caller wait for it.
  ///
  /// Progress is the one thing here that is allowed to be lost: it is written
  /// for a crash nobody is expecting, and a transfer that is moving must not
  /// stall on a disk write. A failure is logged and dropped — the next
  /// checkpoint is a couple of megabytes away, and the final one is
  /// [TransferRepository.finish], which is awaited.
  void _persistQuietly(String xferId, Future<int> write) {
    unawaited(write.then((int _) {}).catchError((Object error) {
      _log('$xferId: progress write failed: $error');
    }));
  }

  void _log(String message) {
    _onLog?.call('xfer: $message');
    debugPrint('[xfer] $message');
  }

  /// Ends every subscription and leaves nothing open. Not reusable after.
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;

    for (final StreamSubscription<Object?> subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();

    for (final _Outgoing outgoing in List<_Outgoing>.of(_outgoing.values)) {
      outgoing.cancelled = true;
      if (!outgoing.answer.isCompleted) {
        outgoing.answer.complete(const _Cancelled());
      }
      if (!outgoing.receipt.isCompleted) {
        // Completed rather than failed, for the reason [_cancelOutgoing] gives
        // in full: the only thing that ever waits on the receipt is the send
        // that is already unwinding, and one that never got as far as waiting —
        // an offer nobody has answered, which is the state most transfers are
        // in when the service is torn down — would take the error straight to
        // the zone as an unhandled future error. The outcome is written by
        // whoever ended the transfer; if nobody did, the startup sweep finds
        // the rows (§5.1).
        outgoing.receipt.complete();
      }
      await _releaseOutgoing(outgoing);
    }
    for (final _Incoming entry in List<_Incoming>.of(_incoming.values)) {
      await entry.detach(closeData: true);
      await entry.receiver?.cancel();
    }
    _incoming.clear();
    _known.clear();

    await _changes.close();
    await _offers.close();
  }
}

/// The peer's answer to an offer, or the news that there will not be one.
sealed class _Answer {
  const _Answer();
}

class _Accepted extends _Answer {
  const _Accepted(this.resumeFrom);

  final int resumeFrom;
}

class _Rejected extends _Answer {
  const _Rejected(this.reason);

  final RejectReason reason;
}

/// The transfer was given up on by one of the two users.
class _Cancelled extends _Answer {
  const _Cancelled();
}

/// Internal unwinding: this transfer is over, and its outcome is already
/// recorded. Distinct from an error, which is a failure nobody asked for.
class _Aborted implements Exception {
  const _Aborted();

  @override
  String toString() => '_Aborted';
}

/// One transfer we are sending.
///
/// Two shapes share this class, because everything about them is the same except
/// what they are made of: a single file ([file]) and a folder ([folder]). The
/// fields a folder does not use stay null rather than being pushed into a
/// subclass, so that the code paths that are genuinely shared — the offer, the
/// answer, the cancel, the release — stay shared.
///
/// A folder holds no root directory here. Its files are read from the paths on
/// their attachment rows, which is the one record of where they are that
/// survives to §5.2's re-offer; a directory handed in at send time would exist
/// only for the first attempt.
class _Outgoing {
  _Outgoing({
    required this.transfer,
    this.file,
    this.folder,
    required this.fileName,
    required this.totalSize,
    this.mime,
  });

  Transfer transfer;

  /// The one file being sent, or null when [folder] is what is being sent.
  final File? file;

  /// What is inside the folder, or null for a single file.
  final FolderManifest? folder;

  final String fileName;
  final int totalSize;
  final String? mime;

  /// Completed by `file_accept`, `file_reject`, or a cancel.
  final Completer<_Answer> answer = Completer<_Answer>();

  /// Completed by the receiver's `file_done` for the file in flight.
  ///
  /// Replaced rather than reused between a folder's files: a receipt is an
  /// answer about one file, and a completed future that a later file re-awaited
  /// would let the second file finish on the first file's answer.
  Completer<void> receipt = Completer<void>();

  ControlConnection? data;
  OutgoingFile? handle;

  /// Which file of the folder is in flight, by the `relPath` its frames carry.
  /// Null for a single file, and null between a folder's files.
  String? currentRelPath;

  /// Bytes of the folder's files that have been sent and receipted. The file in
  /// flight is added to it for the progress the card shows.
  int folderSent = 0;

  bool cancelled = false;
  bool ended = false;

  /// Whether this is a folder rather than one file.
  bool get isFolder => folder != null;

  /// The last percentage put on the wire to the UI, and the last byte count
  /// written to the database. Separate because they answer different questions.
  int lastPercent = -1;
  int persisted = 0;

  void advance(TransferState state, DateTime now, {int? bytesDone}) {
    transfer = transfer.copyWith(
      state: state,
      bytesDone: bytesDone,
      updatedAt: now,
    );
  }

  /// Completes [answer] once, whatever the peer said and whoever heard it.
  void reply(_Answer result) {
    if (!answer.isCompleted) {
      answer.complete(result);
    }
  }
}

/// One transfer we are receiving.
///
/// Like [_Outgoing], one class for two shapes: a single file, and a folder that
/// arrives as a sequence of single files sharing one `xferId` (§4.6 rule 3).
/// The difference is that a folder is not finished when its file is: [receiver]
/// and [data] are per file and come and go, while the entry itself lives until
/// every file in [expected] has landed or failed.
class _Incoming {
  _Incoming({required this.transfer, required this.offer});

  Transfer transfer;
  final FileOfferPayload offer;

  TransferReceiver? receiver;
  ControlConnection? data;

  /// The folder's own directory under the download root, for a folder offer.
  ///
  /// Null for a single file, which lands in the download root itself. Every
  /// `relPath` in the manifest is resolved under this.
  Directory? root;

  /// The attachment behind each file of the folder, keyed by the **wire**
  /// `relPath` — the same string the `file_data` frames carry, which is the only
  /// thing that says which file a socket is delivering.
  final Map<String, Attachment> byPath = <String, Attachment>{};

  /// The `relPath` of the file being written, if one is.
  String? currentRelPath;

  /// Bytes of the folder's files that have landed. The file in flight is added
  /// to it, the same way [_Outgoing.folderSent] accumulates on the other side.
  int landed = 0;

  /// How many of the folder's files have no outcome yet — landed, or failed and
  /// ruled out. Empty means the task is over.
  final Set<String> expected = <String>{};

  /// Whether any file of the folder failed. The task ends `failed` if so, while
  /// the files that did land stay on disk (#5.1.1).
  bool anyFailed = false;

  /// The receipt being built for a folder's next file right now, if one is.
  ///
  /// Held by [_TransferService._folderFileOf], and the reason it exists is in
  /// the doc there: two connections can ask for the same file's receipt at
  /// once, and only one of them may build it.
  Completer<TransferReceiver?>? starting;

  /// The user asked to stop a folder while one of its files was being
  /// installed.
  ///
  /// The one window a folder has that a single file does not: the file in the
  /// installer is past the point where a cancel can mean anything, but the files
  /// behind it have not been fetched. Handled by [_finishFolderFile] when the
  /// install lands, because the install is the one thing that has to be let
  /// finish.
  bool stopping = false;

  /// Whether this is a folder rather than one file.
  bool get isFolder => offer.isDir;
  StreamSubscription<Frame>? _frames;
  StreamSubscription<ConnectionClosedReason>? _closed;

  /// Frames are handled one at a time, in the order they arrived.
  ///
  /// A `file_data` frame is checked against how far the file has got, so two
  /// handlers running at once would both read the same offset and the second
  /// would be rejected as out of order — on a fast link, where chunks arrive
  /// faster than they are written. Chaining keeps the order the stream promised.
  Future<void> _queue = Future<void>.value();

  bool decided = false;
  bool finished = false;
  bool cancelled = false;

  int lastPercent = -1;
  int persisted = 0;

  void advance(
    TransferState state,
    DateTime now, {
    int? bytesDone,
    String? tempPath,
  }) {
    transfer = transfer.copyWith(
      state: state,
      bytesDone: bytesDone,
      tempPath: tempPath,
      updatedAt: now,
    );
  }

  void attach(
    ControlConnection connection, {
    required void Function(Frame frame) onFrame,
    required void Function() onClosed,
  }) {
    data = connection;
    _frames = connection.frames.listen((Frame frame) {
      _queue = _queue.then((void _) => onFrame(frame)).catchError((
        Object error,
        StackTrace stack,
      ) {
        // Never breaks the chain: one bad frame must not stop the ones behind
        // it, and the error is already reported by whoever handled it.
        debugPrint('[xfer] data frame failed: $error\n$stack');
      });
    });
    _closed =
        connection.closed.listen((ConnectionClosedReason _) => onClosed());
  }

  /// Lets go of the socket this transfer is holding.
  ///
  /// **The fields are cleared before anything is awaited**, which for a folder
  /// is the whole point: the sender opens the next file's connection the moment
  /// the receipt for this one reaches it, and a socket still recorded here
  /// would have that arrival refused as a second connection to a transfer that
  /// is only between files. The mirror of [_Outgoing]'s release, and for the
  /// same reason.
  ///
  /// Closing is ours to do even though the sender will close its end too: it
  /// closes when the receipt arrives, and the receipt may never arrive.
  Future<void> detach({bool closeData = false}) async {
    final StreamSubscription<Frame>? frames = _frames;
    final StreamSubscription<ConnectionClosedReason>? closed = _closed;
    final ControlConnection? connection = data;
    _frames = null;
    _closed = null;
    data = null;
    await frames?.cancel();
    await closed?.cancel();
    if (closeData) {
      await connection?.close();
    }
  }
}
