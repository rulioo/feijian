import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../core/constants.dart';
import '../core/models/transfer.dart';
import '../core/protocol/frame_codec.dart';
import '../core/protocol/payloads.dart';
import '../core/transfer/outgoing_file.dart';
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
  })  : _manager = manager,
        _transfers = transfers,
        _downloadDirectory = downloadDirectory,
        _clock = clock ?? DateTime.now,
        _onLog = onLog {
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

  /// Offers that have arrived and are waiting for the user to decide.
  ///
  /// Nothing is received until [accept] is called: §9.2 makes confirmation the
  /// default for file transfers, and the settings that relax it — trusted
  /// devices, images under a size — are M5's. Every offer therefore ends in
  /// either [accept] or [decline], and one that ends in neither is answered by
  /// [_onOfferExpired] when the peer gives up.
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

  Future<void> _runSend(_Outgoing outgoing) async {
    try {
      final bool offered = _manager.sendTransfer(
        outgoing.transfer.peerId,
        FileOfferPayload(
          xferId: outgoing.transfer.id,
          name: outgoing.fileName,
          totalSize: outgoing.totalSize,
          mime: outgoing.mime,
          mtime: await _modifiedAt(outgoing.file),
        ).toFrame(),
      );
      if (!offered) {
        // The peer's control connection went away between the check in
        // [sendFile] and here. Nothing was offered, so nothing is owed.
        throw const TransferException('the peer is no longer connected');
      }
      outgoing.advance(TransferState.offered, _clock());
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

    final OutgoingFile handle = await OutgoingFile.open(
      outgoing.file,
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
      localPath: outgoing.file.path,
      now: _clock(),
    );
    outgoing.advance(TransferState.done, _clock(),
        bytesDone: outgoing.totalSize);
    _emit(outgoing.transfer);
    _log('${outgoing.transfer.id}: sent ${outgoing.fileName}');
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

    if (offer.isDir) {
      // Folders are M4. The field is parsed today so that this refusal names what
      // was actually offered rather than reporting a malformed frame.
      _release(offer.xferId);
      _log('${offer.xferId}: refusing a folder offer');
      _reject(incoming.peerId, offer.xferId, RejectReason.unsupported);
      return;
    }

    final Transfer transfer;
    try {
      transfer = await _transfers.beginIncoming(
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
        // The end of a whole transfer *task* — a folder, in M4. A single file
        // has one transfer and ends at `file_done`, so there is nothing for this
        // to add yet; it is handled rather than logged as unknown because a
        // newer peer is entitled to send it (§4.3).
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
      if (!outgoing.receipt.isCompleted) {
        outgoing.receipt.complete();
      }
      return;
    }

    final _Incoming? entry = _incoming[xferId];
    if (entry != null) {
      await _maybeFinishIncoming(entry);
      return;
    }
    _log('$xferId: file_done for a transfer we are not running');
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
    if (entry != null) {
      // A transfer that was only ever an offer has nothing on disk to remove,
      // and no receiver to cancel. The peer is not told: it is the one that said
      // so, and the socket is already going at its end.
      await _stopIncoming(entry, tellPeer: false, closeData: false);
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
    if (_disposed || entry == null || entry.receiver == null) {
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
    final TransferReceiver? receiver = entry.receiver;
    if (receiver == null || entry.finished || entry.cancelled) {
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

    try {
      await receiver.accept(frame);
    } on FileReceiveException catch (error) {
      // Out of order, over the declared size, or a full disk. All of them mean
      // the bytes on disk cannot be trusted to become the file that was offered.
      _log('${entry.transfer.id}: ${error.message}');
      await _failIncoming(entry, RejectReason.cancelled);
      return;
    }

    entry.advance(
      TransferState.transferring,
      _clock(),
      bytesDone: receiver.received,
    );
    final int percent = receiver.totalSize == 0
        ? 100
        : (receiver.received * 100) ~/ receiver.totalSize;
    if (percent != entry.lastPercent) {
      entry.lastPercent = percent;
      _emit(entry.transfer);
    }
    if (receiver.received >= entry.persisted + tuning.persistEvery) {
      entry.persisted = receiver.received;
      _persistQuietly(
        entry.transfer.id,
        _transfers.recordProgress(
          entry.transfer.id,
          state: TransferState.transferring,
          bytesDone: receiver.received,
        ),
      );
    }

    await _maybeFinishIncoming(entry);
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
    if (entry.finished || entry.cancelled) {
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
    final OutgoingFile? handle = outgoing.handle;
    outgoing.handle = null;
    await handle?.close();
    final ControlConnection? data = outgoing.data;
    outgoing.data = null;
    await data?.close();
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
  static String _baseName(File file) {
    final String path = file.path;
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
class _Outgoing {
  _Outgoing({
    required this.transfer,
    required this.file,
    required this.fileName,
    required this.totalSize,
    required this.mime,
  });

  Transfer transfer;
  final File file;
  final String fileName;
  final int totalSize;
  final String? mime;

  /// Completed by `file_accept`, `file_reject`, or a cancel.
  final Completer<_Answer> answer = Completer<_Answer>();

  /// Completed by the receiver's `file_done`.
  final Completer<void> receipt = Completer<void>();

  ControlConnection? data;
  OutgoingFile? handle;

  bool cancelled = false;
  bool ended = false;

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
class _Incoming {
  _Incoming({required this.transfer, required this.offer});

  Transfer transfer;
  final FileOfferPayload offer;

  TransferReceiver? receiver;
  ControlConnection? data;
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

  Future<void> detach({bool closeData = false}) async {
    await _frames?.cancel();
    _frames = null;
    await _closed?.cancel();
    _closed = null;
    final ControlConnection? connection = data;
    data = null;
    if (closeData) {
      await connection?.close();
    }
  }
}
