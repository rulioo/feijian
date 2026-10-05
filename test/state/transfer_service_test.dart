import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:feijian/core/constants.dart';
import 'package:feijian/core/models/message.dart';
import 'package:feijian/core/models/peer.dart';
import 'package:feijian/core/models/transfer.dart';
import 'package:feijian/core/protocol/payloads.dart';
import 'package:feijian/core/transfer/transfer_tuning.dart';
import 'package:feijian/core/transport/connection_manager.dart';
import 'package:feijian/data/database.dart';
import 'package:feijian/data/repository/chat_repository.dart';
import 'package:feijian/data/repository/transfer_repository.dart';
import 'package:feijian/state/transfer_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../core/transport_harness.dart';

/// A file crossing between two devices — the whole of M3's session layer.
///
/// Real sockets on loopback, real files on a real disk, real SQLite, two
/// independent [TransferService]s and no mocks: every failure worth catching
/// here lives in a seam between two real things — a `.part` that outlives the
/// transfer that was making it, a receipt that is sent before the file under it
/// has a name, a zero-byte file nobody ever finishes because the last chunk
/// never comes.
///
/// The sizes are small and the chunk size is a parameter, so a hundred-chunk
/// transfer runs in a fraction of a second and the chunk boundary cases are
/// reachable on purpose.
void main() {
  late _Device a;
  late _Device b;

  // Two devices in one process means two `AppDatabase`s, which is the case
  // drift warns about — its advice is to silence the warning when you know the
  // databases are independent, and these are.
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  setUp(() async {
    a = await _Device.start(id: 'device-aaa');
    b = await _Device.start(id: 'device-bbb');
  });

  tearDown(() async {
    await a.dispose();
    await b.dispose();
  });

  group('a file crossing', () {
    test('lands under its own name, byte for byte', () async {
      await a.connectTo(b);
      final Uint8List content = bytesOf(300 * 1024, seed: 3);
      final File source = await a.fileOf('holiday.jpg', content);

      final Transfer sent = await a.service.sendFile(
        peerId: b.id,
        file: source,
        mime: 'image/jpeg',
      );
      // The offer has to be storable and visible before the bytes are, so the
      // peer's side reads as a transfer waiting on a person.
      final Transfer offered = await b.nextOffer();
      expect(offered.id, sent.id, reason: 'both ends name one transfer');
      expect(offered.state, TransferState.offered);
      expect(offered.bytesTotal, content.length);
      expect(offered.isIncoming, isTrue);
      expect(sent.isIncoming, isFalse);

      await b.service.accept(offered.id);
      await b.reachState(offered.id, TransferState.done,
          describe: 'b to receive the file');
      await a.reachState(sent.id, TransferState.done,
          describe: 'a to hear that it landed');

      final Attachment? attachment =
          await b.transfers.attachmentFor(offered.id);
      expect(attachment!.fileName, 'holiday.jpg');
      expect(attachment.mime, 'image/jpeg');
      expect(attachment.localPath, endsWith('holiday.jpg'));
      expect(attachment.progress, 1);
      final File landed = File(attachment.localPath!);
      expect(await landed.exists(), isTrue);
      expect(await landed.readAsBytes(), content);

      // A whole file, and nothing else: no `.part` beside it.
      expect(await pathsIn(b.inbox), <String>[landed.path]);

      // Both bubbles say the file arrived, and the sending one's tick follows
      // the receiver's rename rather than its own last byte.
      expect((await a.chat.page(b.id)).single.status, MessageStatus.delivered);
      expect((await b.chat.page(a.id)).single.status, MessageStatus.delivered);
      expect((await a.chat.page(b.id)).single.type, MessageType.file);

      // Nothing is left running on either side.
      expect(a.service.active, isEmpty);
      expect(b.service.active, isEmpty);
      expect(await a.transfers.unfinished(), isEmpty);
      expect(await b.transfers.unfinished(), isEmpty);
    });

    test('a hundred chunks arrive in order and land identical', () async {
      // The case the frame queue exists for. Each `file_data` frame is checked
      // against how far the file has got, so two handlers running at once would
      // both read the same offset and the later one would be rejected as out of
      // order — which is a corruption report on a transfer that is perfectly
      // fine.
      final _Device sender = await _Device.start(
        id: 'device-ccc',
        tuning: const TransferTuning(
          chunkSize: 4096,
          persistEvery: 64 * 1024,
        ),
      );
      final _Device receiver = await _Device.start(
        id: 'device-ddd',
        tuning: const TransferTuning(
          chunkSize: 4096,
          persistEvery: 64 * 1024,
        ),
      );
      addTearDown(sender.dispose);
      addTearDown(receiver.dispose);
      await sender.connectTo(receiver);

      final Uint8List content = bytesOf(512 * 1024, seed: 29);
      final File source = await sender.fileOf('many.bin', content);
      final Transfer sent =
          await sender.service.sendFile(peerId: receiver.id, file: source);

      final Transfer offered = await receiver.nextOffer();
      await receiver.service.accept(offered.id);
      await receiver.reachState(offered.id, TransferState.done,
          describe: 'the many-chunk file to arrive');
      await sender.reachState(sent.id, TransferState.done,
          describe: 'the sender to be told');

      final Attachment? attachment =
          await receiver.transfers.attachmentFor(offered.id);
      expect(await File(attachment!.localPath!).readAsBytes(), content);

      // The checkpoint path ran more than once, and the last write is the whole
      // file rather than wherever the last checkpoint happened to land.
      final Transfer? row = await sender.transfers.byId(sent.id);
      expect(row!.bytesDone, content.length);
    });

    test('an empty file arrives complete on the sender\'s word alone',
        () async {
      // §4.6.1: a zero-byte file has no chunks, so a receiver that waits for a
      // last `file_data` waits forever. The sender's `file_done` is the only
      // thing that ever comes.
      await a.connectTo(b);
      final File source = await a.fileOf('empty.txt', Uint8List(0));

      final Transfer sent =
          await a.service.sendFile(peerId: b.id, file: source);
      final Transfer offered = await b.nextOffer();
      expect(offered.bytesTotal, 0);

      await b.service.accept(offered.id);
      await b.reachState(offered.id, TransferState.done,
          describe: 'the empty file to arrive');
      await a.reachState(sent.id, TransferState.done,
          describe: 'the sender to be told');

      final Attachment? attachment =
          await b.transfers.attachmentFor(offered.id);
      final File landed = File(attachment!.localPath!);
      expect(await landed.exists(), isTrue);
      expect(await landed.length(), 0);
      expect(attachment.progress, 1);
      expect(await pathsIn(b.inbox), hasLength(1),
          reason: 'the file, and not a .part');
    });
  });

  group('saying no', () {
    test('a decline is reported to the sender as a decline', () async {
      await a.connectTo(b);
      final File source = await a.fileOf('unwanted.bin', bytesOf(2048));

      final Transfer sent =
          await a.service.sendFile(peerId: b.id, file: source);
      final Transfer offered = await b.nextOffer();

      await b.service.decline(offered.id);

      // Declined, not failed: only one end of the handshake sees the rejection
      // frame, and the other has to be told which of the two it was.
      await a.reachState(sent.id, TransferState.declined,
          describe: 'a to hear the refusal');
      await b.reachState(offered.id, TransferState.declined,
          describe: 'b to have refused');
      expect(await pathsIn(b.inbox), isEmpty,
          reason: 'a refused file is never opened');
      expect(a.service.active, isEmpty);
      expect(b.service.active, isEmpty);
    });

    test('cancelling mid-transfer leaves nothing on disk', () async {
      // 取消后无残留, and the awkward half of it: the transfer is stopped while
      // bytes are still moving, so there is a `.part` on disk that has to go,
      // and a sender that has to be told to stop writing into a socket.
      final _Device sender = await _Device.start(
        id: 'device-ccc',
        tuning: const TransferTuning(chunkSize: 4096),
      );
      addTearDown(sender.dispose);
      await sender.connectTo(b);

      final File source =
          await sender.fileOf('big.bin', bytesOf(1024 * 1024, seed: 11));
      final Transfer sent =
          await sender.service.sendFile(peerId: b.id, file: source);
      final Transfer offered = await b.nextOffer();

      // Cancelled at the first sign of movement, which is a few frames into a
      // file of two hundred and fifty-six: the `.part` is on disk and the file
      // is nowhere near whole.
      final Completer<int> moved = Completer<int>();
      final StreamSubscription<Transfer> watching =
          b.service.changes.listen((Transfer transfer) {
        if (transfer.id == offered.id &&
            transfer.state == TransferState.transferring &&
            transfer.bytesDone > 0 &&
            !moved.isCompleted) {
          moved.complete(transfer.bytesDone);
          unawaited(b.service.cancel(transfer.id));
        }
      });
      addTearDown(watching.cancel);

      // The row and the folder are watched together, for as long as this takes,
      // rather than read once at the end. 取消后无残留 is a promise about every
      // moment a reader could look, not only about the last one: a row that
      // reads `cancelled` while `big.bin.part` is still in the folder is the
      // same broken promise whether it lasts a second or a millisecond, and a
      // single look at the end misses it whenever the delete happens to win.
      final List<String> caught = <String>[];
      bool polling = true;
      final Future<void> watchingRow = () async {
        while (polling) {
          final Transfer? row = await b.transfers.byId(offered.id);
          final bool over = row != null &&
              (row.state == TransferState.cancelled ||
                  row.state == TransferState.failed);
          if (over) {
            final List<String> left = await pathsIn(b.inbox);
            if (left.isNotEmpty) {
              caught.add('${row.state.wire} while $left');
            }
          }
          await Future<void>.delayed(Duration.zero);
        }
      }();
      addTearDown(() => polling = false);

      await b.service.accept(offered.id);
      final int atCancel = await moved.future.timeout(patience);
      expect(atCancel, greaterThan(0));
      expect(atCancel, lessThan(1024 * 1024),
          reason: 'stopped while bytes were still moving');

      await b.reachState(offered.id, TransferState.cancelled,
          describe: 'b to stop');
      await sender.reachState(sent.id, TransferState.cancelled,
          describe: 'the sender to be told to stop');

      polling = false;
      await watchingRow;
      expect(caught, isEmpty,
          reason: 'a finished transfer and its .part were on disk together');

      final List<String> left = await pathsIn(b.inbox);

      // There *was* a `.part`: the receiver named it when it was opened, and the
      // row says where. What the cancel has to prove is that it is not there any
      // more.
      final Transfer? stopped = await b.transfers.byId(offered.id);
      expect(stopped!.tempPath, endsWith('.part'));
      expect(left, isEmpty, reason: 'the .part goes with the transfer');
      expect(b.service.active, isEmpty);
      expect(sender.service.active, isEmpty);
    });

    test('a cancel landing on the last chunk does not discard the file',
        () async {
      // The same 取消后无残留 promise, at the one moment it is hard to keep: the
      // file is whole and the receiver is installing it, so the bytes are all
      // there but the transfer is not finished. The user pressing cancel now is
      // pressing it on a file they are about to have, and the honest answer is
      // that it is too late — the alternative is an inbox the app calls empty
      // holding a complete file, or a sender told its transfer failed when the
      // receiver kept every byte.
      //
      // The timing is exact rather than lucky: the receiver emits 100% before it
      // starts installing, and a broadcast stream delivers that emission on a
      // later turn, which is after the receiver has committed to finishing. So
      // the cancel lands inside the install every time.
      final _Device sender = await _Device.start(
        id: 'device-ccc',
        tuning: const TransferTuning(chunkSize: 64 * 1024),
      );
      addTearDown(sender.dispose);
      await sender.connectTo(b);

      final Uint8List content = bytesOf(1024 * 1024, seed: 5);
      final File source = await sender.fileOf('whole.bin', content);
      final Transfer sent =
          await sender.service.sendFile(peerId: b.id, file: source);
      final Transfer offered = await b.nextOffer();

      final Completer<void> atLastChunk = Completer<void>();
      final StreamSubscription<Transfer> watching =
          b.service.changes.listen((Transfer transfer) {
        if (transfer.id == offered.id &&
            transfer.state == TransferState.transferring &&
            transfer.bytesDone == transfer.bytesTotal &&
            !atLastChunk.isCompleted) {
          atLastChunk.complete();
          unawaited(b.service.cancel(transfer.id));
        }
      });
      addTearDown(watching.cancel);

      await b.service.accept(offered.id);
      await atLastChunk.future.timeout(patience);
      await b.reachState(offered.id, TransferState.done,
          describe: 'b to keep a file it already has');
      await sender.reachState(sent.id, TransferState.done,
          describe: 'the sender not to be told the transfer failed');

      final Attachment? attachment =
          await b.transfers.attachmentFor(offered.id);
      final String landed = attachment!.localPath!;
      expect(await File(landed).readAsBytes(), content);
      expect(await pathsIn(b.inbox), <String>[landed],
          reason: 'the file, and not a .part beside it');
    });
  });

  group('stopping by attachment', () {
    // The chat page has a message and an attachment; the wire has an `xferId`.
    // §5.1 makes them different ids — the attachment id is minted locally where
    // its row is written and never travels — so the button the user presses and
    // the transfer it has to stop are joined by a lookup, and that lookup is
    // what these cover.

    test('a sender cancels by the attachment id the page has', () async {
      await a.connectTo(b);
      final File source = await a.fileOf('unwanted.bin', bytesOf(2048));

      final Transfer sent =
          await a.service.sendFile(peerId: b.id, file: source);
      final Transfer offered = await b.nextOffer();

      expect(sent.attachmentId, isNotNull);
      expect(sent.attachmentId, isNot(sent.id),
          reason: 'the two ids are different things, which is the whole point '
              'of looking one up from the other');
      expect(offered.attachmentId, isNotNull);
      expect(offered.attachmentId, isNot(sent.attachmentId),
          reason: 'and each end mints its own');

      await a.service.cancelAttachment(sent.attachmentId!);

      await a.reachState(sent.id, TransferState.cancelled,
          describe: 'a to stop');
      await b.reachState(offered.id, TransferState.cancelled,
          describe: 'b to be told the offer is off');
      expect(await pathsIn(b.inbox), isEmpty);
      expect(a.service.active, isEmpty);
      expect(b.service.active, isEmpty);
    });

    test('a receiver turns down an offer by its own attachment id', () async {
      await a.connectTo(b);
      final File source = await a.fileOf('unwanted.bin', bytesOf(2048));

      final Transfer sent =
          await a.service.sendFile(peerId: b.id, file: source);
      final Transfer offered = await b.nextOffer();

      // Nothing has been agreed to, so there is no `.part` and no socket —
      // only a row that has to stop saying "waiting for your answer".
      await b.service.cancelAttachment(offered.attachmentId!);

      await b.reachState(offered.id, TransferState.cancelled,
          describe: 'b to have decided');
      await a.reachState(sent.id, TransferState.cancelled,
          describe: 'a to be told');
      expect(await pathsIn(b.inbox), isEmpty);
    });

    test('an attachment nothing is doing cannot rewrite a finished row',
        () async {
      await a.connectTo(b);
      final File source = await a.fileOf('wanted.bin', bytesOf(1024));
      final Transfer sent =
          await a.service.sendFile(peerId: b.id, file: source);
      final Transfer offered = await b.nextOffer();

      await b.service.accept(offered.id);
      await a.reachState(sent.id, TransferState.done, describe: 'the send');
      await b.reachState(offered.id, TransferState.done, describe: 'the file');

      // The bubble still has a cancel button for a frame after the transfer
      // finishes — the button is drawn from a row, and the row is a moment
      // behind. Pressing it must not turn a delivered file into a cancelled one.
      await a.service.cancelAttachment(sent.attachmentId!);
      await b.service.cancelAttachment(offered.attachmentId!);

      expect((await a.transfers.byId(sent.id))!.state, TransferState.done);
      expect((await b.transfers.byId(offered.id))!.state, TransferState.done);
    });

    test('an id that was never ours is nothing to do', () async {
      await a.service.cancelAttachment('no-such-attachment');
      await a.service.acceptAttachment('no-such-attachment');
      await a.service.declineAttachment('no-such-attachment');
      expect(a.service.active, isEmpty);
      expect(await a.db.select(a.db.transfers).get(), isEmpty);
    });

    test('a receiver accepts by its own attachment id', () async {
      await a.connectTo(b);
      final File source = await a.fileOf('wanted.bin', bytesOf(4096));
      final Transfer sent =
          await a.service.sendFile(peerId: b.id, file: source);
      final Transfer offered = await b.nextOffer();

      await b.service.acceptAttachment(offered.attachmentId!);

      await a.reachState(sent.id, TransferState.done,
          describe: 'the send to complete');
      await b.reachState(offered.id, TransferState.done,
          describe: 'the file to land');
      expect(await pathsIn(b.inbox), hasLength(1));
    });

    test('a receiver declines by its own attachment id', () async {
      await a.connectTo(b);
      final File source = await a.fileOf('unwanted.bin', bytesOf(4096));
      final Transfer sent =
          await a.service.sendFile(peerId: b.id, file: source);
      final Transfer offered = await b.nextOffer();

      await b.service.declineAttachment(offered.attachmentId!);

      // `declined` rather than `cancelled`, on both ends: the sender is told
      // which of the two happened, and only this end could see the refusal.
      await a.reachState(sent.id, TransferState.declined,
          describe: 'a to hear the refusal');
      await b.reachState(offered.id, TransferState.declined,
          describe: 'b to have refused');
      expect(await pathsIn(b.inbox), isEmpty,
          reason: 'a refused file is never opened');
    });

    test('a second answer to the same offer changes nothing', () async {
      // The dialog and the bubble offer the same two buttons, and a user who
      // answered one can still press the other before the row catches up.
      await a.connectTo(b);
      final File source = await a.fileOf('wanted.bin', bytesOf(4096));
      final Transfer sent =
          await a.service.sendFile(peerId: b.id, file: source);
      final Transfer offered = await b.nextOffer();

      await b.service.acceptAttachment(offered.attachmentId!);
      await b.service.declineAttachment(offered.attachmentId!);

      await a.reachState(sent.id, TransferState.done,
          describe: 'the send, still going');
      await b.reachState(offered.id, TransferState.done,
          describe: 'the file, still arriving');
    });
  });

  group('when it cannot work', () {
    test('an offer nobody answers ends as a failure on both sides', () async {
      // The sender's clock, not the receiver's: a transfer layer that waited for
      // an answer forever would hold a socket and a file handle on a file the
      // peer's user closed the app on.
      final _Device sender = await _Device.start(
        id: 'device-ccc',
        tuning: const TransferTuning(offerTimeout: Duration(milliseconds: 600)),
      );
      addTearDown(sender.dispose);
      await sender.connectTo(b);

      final File source = await sender.fileOf('ignored.bin', bytesOf(4096));
      final Transfer sent =
          await sender.service.sendFile(peerId: b.id, file: source);
      final Transfer offered = await b.nextOffer();

      await sender.reachState(sent.id, TransferState.failed,
          describe: 'the offer to time out',
          timeout: const Duration(seconds: 10));

      // b has not decided anything and has not been lied to: its row ends
      // cancelled, which is what "the peer gave up" means on this side.
      await b.reachState(offered.id, TransferState.cancelled,
          describe: 'b to be told the offer is off');
      expect(b.service.active, isEmpty);
      expect(sender.service.active, isEmpty);
      expect(await pathsIn(b.inbox), isEmpty);
    });

    test('an unreadable file is refused before anything is written', () async {
      await a.connectTo(b);
      final File missing =
          File('${a.inbox.path}${Platform.pathSeparator}gone.bin');

      await expectLater(
        a.service.sendFile(peerId: b.id, file: missing),
        throwsA(
          isA<TransferException>().having(
            (TransferException error) => error.reason,
            'reason',
            RejectReason.notFound,
          ),
        ),
      );

      // Nothing to show and nothing to show it on: no bubble, no row, and no
      // offer for the peer to answer.
      expect(await a.chat.page(b.id), isEmpty);
      expect(await a.db.select(a.db.transfers).get(), isEmpty);
      expect(a.service.active, isEmpty);
    });

    test('a peer with no connection fails rather than waiting', () async {
      // Never introduced. The offer has nowhere to go, and the honest outcome is
      // a failed bubble the user can retry rather than a transfer that sits at
      // pending until the app closes.
      final File source = await a.fileOf('lonely.bin', bytesOf(1024));
      final Transfer sent =
          await a.service.sendFile(peerId: b.id, file: source);

      await a.reachState(sent.id, TransferState.failed,
          describe: 'the send to fail');
      expect(await a.chat.page(b.id), hasLength(1),
          reason: 'the bubble stays, and says it did not work');
      expect(a.service.active, isEmpty);
    });
  });

  group('startup', () {
    test('a transfer a previous run left behind is marked failed', () async {
      // A killed process leaves a row saying `transferring` and a socket that
      // no longer exists. Nothing will ever move it again, so a progress bar
      // reading it would sit at 40% forever.
      final _Device device = await _Device.start(id: 'device-ccc');
      addTearDown(device.dispose);

      await device.transfers.beginOutgoing(
        xferId: 'stale-xfer',
        peerId: 'peer-gone',
        fileName: 'half.bin',
        totalSize: 8192,
        now: DateTime.now(),
      );
      await device.transfers.recordProgress(
        'stale-xfer',
        state: TransferState.transferring,
        bytesDone: 3240,
      );

      final List<Transfer> announced = <Transfer>[];
      final StreamSubscription<Transfer> watching = device.service.changes
          .where((Transfer t) => t.id == 'stale-xfer')
          .listen(announced.add);
      addTearDown(watching.cancel);

      await device.service.start();

      expect((await device.transfers.byId('stale-xfer'))!.state,
          TransferState.failed);
      expect(await device.transfers.unfinished(), isEmpty);
      await waitUntil(
        () => announced.any((Transfer t) => t.state == TransferState.failed),
        describe: 'the sweep to be announced to the UI',
      );
      // The bubble fails with it, and the failure is not a text message waiting
      // to be sent by the offline queue.
      expect((await device.chat.page('peer-gone')).single.status,
          MessageStatus.failed);
      expect(await device.chat.pendingFor('peer-gone'), isEmpty);
    });
  });

  group('retrying a file that did not get there', () {
    /// Ends an attempt on `a` by having `b` turn it down, and returns the
    /// transfer the sender is left holding.
    ///
    /// A decline is the cheapest ending that is entirely deterministic and
    /// entirely the *protocol's* — no timing, no sockets going away underneath
    /// the test — and it is the ending a retry has to get right anyway, since a
    /// refusal is exactly the case where a user wants to ask again.
    Future<Transfer> refusedBy(_Device from, _Device to, File source) async {
      final Transfer sent =
          await from.service.sendFile(peerId: to.id, file: source);
      final Transfer offered = await to.nextOffer();
      await to.service.decline(offered.id);
      return from.reachState(sent.id, TransferState.declined,
          describe: 'the refusal to reach the sender');
    }

    test('a retry is a new attempt on the same bubble', () async {
      await a.connectTo(b);
      final Uint8List content = bytesOf(64 * 1024, seed: 11);
      final File source = await a.fileOf('contract.pdf', content);

      final Transfer first = await refusedBy(a, b, source);
      final List<Message> before = await a.chat.page(b.id);
      expect(before, hasLength(1));
      expect(before.single.status, MessageStatus.failed,
          reason: 'a decline leaves the sender a failed message');

      final Transfer again = await a.service.retryAttachment(
        peerId: b.id,
        attachmentId: first.attachmentId!,
      );

      // A new attempt is a new id — the row's key *is* the peer's name for the
      // attempt — while the bubble it belongs to is the one that was already
      // there.
      expect(again.id, isNot(first.id));
      expect(again.messageId, first.messageId);
      expect(again.attachmentId, first.attachmentId);
      expect(again.state, TransferState.pending);

      final List<Message> after = await a.chat.page(b.id);
      expect(after, hasLength(1), reason: 'one file, one bubble');
      expect(after.single.id, before.single.id);
      expect(
        after.single.status,
        MessageStatus.pending,
        reason: 'the second attempt is owed, and the bubble says so',
      );

      // The peer is offered it again, under the new name, and this time says
      // yes. Nothing else about the exchange changes: it is an ordinary offer.
      await waitUntil(
        () => b.offers.length >= 2,
        describe: 'the second offer to arrive',
      );
      expect(b.offers[1].id, again.id);
      expect(b.offers[1].bytesTotal, content.length);

      await b.service.accept(again.id);
      await b.reachState(again.id, TransferState.done,
          describe: 'b to receive the file');
      await a.reachState(again.id, TransferState.done,
          describe: 'a to hear that it landed');

      final Attachment? landed = await b.transfers.attachmentFor(again.id);
      expect(await File(landed!.localPath!).readAsBytes(), content);
      expect((await a.chat.page(b.id)).single.status, MessageStatus.delivered);
      expect(a.service.active, isEmpty);
      expect(b.service.active, isEmpty);

      // The two ends do not agree on how many bubbles one file is, and this is
      // the price of a new `xferId`: the receiver has no memory of the first
      // attempt except its row, so it shows the refusal and the arrival as two
      // messages. §5.2's re-send of the *same* offer is the design that avoids
      // it, and it needs a receiver that tolerates a repeat offer — M4's.
      expect(await b.chat.page(a.id), hasLength(2));
    });

    test('a retry whose file is gone is refused rather than failed quietly',
        () async {
      await a.connectTo(b);
      final File source = await a.fileOf('gone.bin', bytesOf(4096));
      final Transfer first = await refusedBy(a, b, source);

      await source.delete();

      await expectLater(
        a.service.retryAttachment(
          peerId: b.id,
          attachmentId: first.attachmentId!,
        ),
        throwsA(isA<TransferException>().having(
          (TransferException e) => e.reason,
          'reason',
          RejectReason.notFound,
        )),
      );

      // Nothing was begun, and the bubble still says what happened — §5.2 asks
      // for the missing file to be said in words, not turned into a second
      // failure the user cannot tell from the first.
      expect(await a.transfers.unfinished(), isEmpty);
      expect(a.service.active, isEmpty);
      final List<Message> messages = await a.chat.page(b.id);
      expect(messages, hasLength(1));
      expect(messages.single.status, MessageStatus.failed);
    });

    test('a retry of a file that has changed since is refused', () async {
      await a.connectTo(b);
      final File source = await a.fileOf('draft.bin', bytesOf(4096));
      final Transfer first = await refusedBy(a, b, source);

      // The user edited the document between the two attempts. It is not the
      // file the peer was offered, and re-offering it under the old size would
      // stop short or overrun what the receiver agreed to.
      await source.writeAsBytes(bytesOf(8192, seed: 12), flush: true);

      await expectLater(
        a.service.retryAttachment(
          peerId: b.id,
          attachmentId: first.attachmentId!,
        ),
        throwsA(isA<TransferException>().having(
          (TransferException e) => e.reason,
          'reason',
          RejectReason.unknown,
        )),
      );
      expect(await a.transfers.unfinished(), isEmpty);
    });

    test('an attachment with no path here has nothing to send', () async {
      // Reachable through the repository — `beginOutgoing` takes a nullable
      // path — and it is the state a message whose file was never recorded
      // would be in. An empty path handed to `File` would fail as whatever the
      // platform makes of it.
      final Transfer orphan = await a.transfers.beginOutgoing(
        xferId: 'orphan',
        peerId: b.id,
        fileName: 'nopath.bin',
        totalSize: 1024,
        localPath: null,
        now: DateTime.now(),
      );

      await expectLater(
        a.service.retryAttachment(
          peerId: b.id,
          attachmentId: orphan.attachmentId!,
        ),
        throwsA(isA<TransferException>().having(
          (TransferException e) => e.reason,
          'reason',
          RejectReason.notFound,
        )),
      );
    });

    test('a retry waits its turn when the ceiling is full', () async {
      // Connected, so the three offers below are genuinely in flight rather
      // than failing for want of somewhere to go.
      await a.connectTo(b);

      // Three offers b never answers — an offer waiting on a person is a live
      // transfer, and the ceiling is three of them.
      for (int i = 0; i < kMaxConcurrentXfers; i++) {
        await a.service.sendFile(
          peerId: b.id,
          file: await a.fileOf('f$i.bin', bytesOf(1024, seed: i)),
        );
      }
      expect(a.service.active, hasLength(kMaxConcurrentXfers));

      // A transfer that ended earlier, so the ceiling is the only reason to
      // refuse it.
      final File source = await a.fileOf('later.bin', bytesOf(2048));
      final Transfer ended = await a.transfers.beginOutgoing(
        xferId: 'ended',
        peerId: b.id,
        fileName: 'later.bin',
        totalSize: 2048,
        localPath: source.path,
        now: DateTime.now(),
      );

      await expectLater(
        a.service.retryAttachment(
          peerId: b.id,
          attachmentId: ended.attachmentId!,
        ),
        throwsA(isA<TransferException>().having(
          (TransferException e) => e.reason,
          'reason',
          RejectReason.busy,
        )),
      );
      expect(a.service.active, hasLength(kMaxConcurrentXfers));
    });
  });
}

/// The paths in [directory], sorted — a `.part` left behind is the difference
/// between a cancel that cleaned up and one that did not.
Future<List<String>> pathsIn(Directory directory) async {
  final List<String> paths = <String>[
    await for (final FileSystemEntity entity in directory.list()) entity.path,
  ];
  return paths..sort();
}

/// Reproducible bytes, so a mismatch is a mismatch and not a seed.
///
/// Deliberately not a run of identical bytes: a transfer that dropped a chunk
/// and sent another one twice would still compare equal to a constant file if
/// the offsets happened to line up.
Uint8List bytesOf(int length, {int seed = 7}) {
  final Uint8List bytes = Uint8List(length);
  int state = seed;
  for (int i = 0; i < length; i++) {
    state = (state * 1103515245 + 12345) & 0x7fffffff;
    bytes[i] = state % 251;
  }
  return bytes;
}

/// One device: its database, its pool, its transfer layer, and a folder to
/// receive into.
///
/// There is no discovery here, and no `LanService`: what a transfer needs from
/// the layers below is a control connection, and dialling the address directly
/// is the shortest way to have one that is still the real thing.
class _Device {
  _Device._({
    required this.id,
    required this.port,
    required this.db,
    required this.chat,
    required this.transfers,
    required this.manager,
    required this.service,
    required this.inbox,
  });

  final String id;
  final int port;
  final AppDatabase db;
  final ChatRepository chat;
  final TransferRepository transfers;
  final ConnectionManager manager;
  final TransferService service;

  /// Where received files land. A real directory, so a test can look at what a
  /// cancel or a failure left behind.
  final Directory inbox;

  /// Every offer that has arrived, in order. Subscribed when the device starts,
  /// because the stream is broadcast and does not replay.
  final List<Transfer> offers = <Transfer>[];

  final List<Directory> _scratch = <Directory>[];
  final List<StreamSubscription<Object?>> _subscriptions =
      <StreamSubscription<Object?>>[];

  static Future<_Device> start({
    required String id,
    TransferTuning tuning = const TransferTuning(),
  }) async {
    final AppDatabase db = AppDatabase.memory();
    final int port = await freePort();
    final ChatRepository chat = ChatRepository(db);
    final TransferRepository transfers = TransferRepository(db);
    final Directory inbox =
        await Directory.systemTemp.createTemp('feijian-inbox-$id-');

    final ConnectionManager manager = ConnectionManager(
      port: port,
      selfHello: HelloPayload(
        role: ConnectionRole.control,
        deviceId: id,
        name: id,
        deviceType: DeviceType.windows,
        icon: DeviceIcon.desktop,
        // The port a peer dials for a data connection, so it has to be the one
        // this device is actually listening on.
        port: port,
        version: kProtocolVersion,
      ),
    );

    final TransferService service = TransferService(
      manager: manager,
      transfers: transfers,
      downloadDirectory: () async => inbox,
      tuning: tuning,
    );

    final _Device device = _Device._(
      id: id,
      port: port,
      db: db,
      chat: chat,
      transfers: transfers,
      manager: manager,
      service: service,
      inbox: inbox,
    );

    await manager.start();
    device._subscriptions.add(service.offers.listen(device.offers.add));
    return device;
  }

  /// Dials [other] the way Add-by-IP does — one dial, both ends.
  ///
  /// Both directions of the conversation travel on this one socket: frames are
  /// attributed to the peer by the connection they arrived on, so a device that
  /// was dialled answers on the connection it accepted.
  Future<void> connectTo(_Device other) async {
    final DialResult result = await manager.connectToAddress(
      InternetAddress.loopbackIPv4,
      port: other.port,
    );
    expect(result.isConnected, isTrue,
        reason: 'the two devices have to be introduced');
    await waitUntil(
      () => manager.isConnected(other.id),
      describe: 'the link to be usable',
    );
  }

  /// Waits for this device to be offered a file.
  Future<Transfer> nextOffer({Duration timeout = patience}) {
    return waitForValue<Transfer?>(
      () async => offers.isEmpty ? null : offers.first,
      (Transfer? offer) => offer != null,
      describe: 'an offer to arrive',
      timeout: timeout,
    ).then((Transfer? offer) => offer!);
  }

  /// Waits for [xferId] to reach [state], reading the row rather than a stream.
  Future<Transfer> reachState(
    String xferId,
    TransferState state, {
    String? describe,
    Duration timeout = patience,
  }) {
    return waitForValue<Transfer?>(
      () => transfers.byId(xferId),
      (Transfer? transfer) => transfer?.state == state,
      describe: describe ?? '$xferId to read ${state.wire}',
      timeout: timeout,
    ).then((Transfer? transfer) => transfer!);
  }

  /// A file of [bytes] in a temporary directory, for sending.
  Future<File> fileOf(String name, List<int> bytes) async {
    final Directory directory =
        await Directory.systemTemp.createTemp('feijian-src-$id-');
    _scratch.add(directory);
    final File file = File('${directory.path}${Platform.pathSeparator}$name');
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  Future<void> dispose() async {
    for (final StreamSubscription<Object?> subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    await service.dispose();
    await manager.dispose();
    for (final Directory directory in <Directory>[inbox, ..._scratch]) {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    }
    await db.close();
  }
}
