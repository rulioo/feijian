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

    test('a peer with no connection leaves the file owed, not failed', () async {
      // Never introduced. The offer has nowhere to go — and §5.2 rule 5 says
      // that is a debt, not a failure: the bubble shows a clock, the peer is
      // asked the moment it is back, and the user never has to find the file a
      // second time.
      final File source = await a.fileOf('lonely.bin', bytesOf(1024));
      final Transfer sent =
          await a.service.sendFile(peerId: b.id, file: source);

      await waitUntil(
        () => a.service.active.isEmpty,
        describe: 'the attempt to fold up',
      );
      expect((await a.transfers.byId(sent.id))!.state, TransferState.pending);
      expect(
        (await a.chat.page(b.id)).single.status,
        MessageStatus.pending,
        reason: 'a clock, not a red cross',
      );
      expect(await b.transfers.byId(sent.id), isNull,
          reason: 'nothing was offered, so nothing is on the other side');
    });
  });

  group('a file for a peer that is away (§5.2 rule 5)', () {
    test('stops being owed the moment its offer is on the wire', () async {
      // Everything below rests on this: the queue is read off the rows, so an
      // offer that has gone out has to leave `pending` behind in the same
      // breath. A row that still read `pending` with its offer in flight would
      // be offered a second time by the next announce — the peer refuses the
      // duplicate it already has, and the sender, waiting for an answer to *it*,
      // ends a transfer that is going perfectly well.
      await a.connectTo(b);
      final File source = await a.fileOf('unanswered.bin', bytesOf(2048));
      final Transfer sent =
          await a.service.sendFile(peerId: b.id, file: source);

      // Left unanswered on purpose, so the state is read while it is the truth
      // rather than in the instant before the receipt lands.
      final Transfer offered = await b.nextOffer();
      expect(offered.id, sent.id);
      await a.reachState(sent.id, TransferState.offered,
          describe: 'the offer to be recorded as sent');

      expect(await a.transfers.owedOutgoing(b.id), isEmpty);
      expect(a.service.active, hasLength(1));
    });

    test('goes, under its own xferId, when that peer comes back', () async {
      final Uint8List content = bytesOf(64 * 1024, seed: 7);
      final File source = await a.fileOf('later.bin', content);
      final Transfer sent =
          await a.service.sendFile(peerId: b.id, file: source);
      await waitUntil(
        () => a.service.active.isEmpty,
        describe: 'the file to be owed',
      );

      await a.connectTo(b);

      // The same transfer, not a new one: §5.2 rule 5 re-sends *the offer the
      // peer never got*, so the user's bubble keeps its identity and its clock
      // turns into a tick.
      final Transfer offered = await b.nextOffer();
      expect(offered.id, sent.id);
      expect(offered.direction, MessageDirection.incoming);

      await b.service.accept(offered.id);
      await a.reachState(sent.id, TransferState.done,
          describe: 'the owed file to cross');
      expect(await b.inboxFile('later.bin'), content);
      expect(
        (await a.chat.page(b.id)).single.status,
        MessageStatus.delivered,
      );
    });

    test('is written off, and says so, when the file is gone', () async {
      final File source = await a.fileOf('vanishes.bin', bytesOf(1024));
      final Transfer sent =
          await a.service.sendFile(peerId: b.id, file: source);
      await waitUntil(
        () => a.service.active.isEmpty,
        describe: 'the file to be owed',
      );
      await source.delete();

      await a.connectTo(b);
      await a.reachState(sent.id, TransferState.failed,
          describe: 'the give-up');

      // Nothing was offered, so nothing has to be taken back: the peer has
      // never heard this `xferId`, and a `file_cancel` naming it would be a
      // frame about a transfer it cannot know about.
      expect(b.offers, isEmpty);
      expect(await b.transfers.byId(sent.id), isNull);

      final Attachment? attachment = await a.transfers.attachmentFor(sent.id);
      expect(attachment!.state, TransferState.failed);
      expect(
        (await a.chat.page(b.id)).single.status,
        MessageStatus.failed,
        reason: 'the bubble can say why when it is pressed',
      );
    });

    test('is written off when the file has changed since it was picked',
        () async {
      final File source = await a.fileOf('grew.bin', bytesOf(1024));
      final Transfer sent =
          await a.service.sendFile(peerId: b.id, file: source);
      await waitUntil(
        () => a.service.active.isEmpty,
        describe: 'the file to be owed',
      );
      await source.writeAsBytes(bytesOf(4096, seed: 2), flush: true);

      await a.connectTo(b);
      await a.reachState(sent.id, TransferState.failed,
          describe: 'the give-up');
      expect(b.offers, isEmpty);
    });

    test('is written off when the row it came from has no path at all',
        () async {
      // Reachable through the repository, the way `retryAttachment`'s own
      // no-path test reaches it: `beginOutgoing` takes a nullable path. There is
      // nothing to read a file from, and handing the empty string to `File`
      // would fail as whatever the platform makes of that rather than as this.
      final Transfer orphan = await a.transfers.beginOutgoing(
        xferId: 'nopath',
        peerId: b.id,
        fileName: 'nopath.bin',
        totalSize: 1024,
        localPath: null,
        now: DateTime.now(),
      );

      await a.connectTo(b);
      await a.reachState(orphan.id, TransferState.failed,
          describe: 'the give-up');
      expect(b.offers, isEmpty);
    });

    test('a folder away from its peer goes whole when that peer is back',
        () async {
      // A folder is the case §5.2 rule 5 matters most for: §6.3.3's card offers
      // a failed folder no retry, so before M4 a folder aimed at a phone that
      // was momentarily away could only be sent again by finding it by hand.
      final Directory folder = await a.folderOf('photos', <String, List<int>>{
        'one.txt': bytesOf(2048, seed: 1),
        'sub/two.txt': bytesOf(3072, seed: 2),
      });
      final Transfer sent =
          await a.service.sendFolder(peerId: b.id, directory: folder);
      await waitUntil(
        () => a.service.active.isEmpty,
        describe: 'the folder to be owed',
      );
      final Transfer owed = (await a.transfers.byId(sent.id))!;
      expect(owed.state, TransferState.pending);
      expect(
        await a.transfers.attachmentsForMessage(owed.messageId!),
        hasLength(2),
        reason: 'the files are still on the rows the re-offer rebuilds from',
      );

      await a.connectTo(b);

      final Transfer offered = await b.nextOffer();
      expect(offered.id, sent.id);
      await a.reachState(sent.id, TransferState.offered,
          describe: 'the offer to be recorded as sent');
      expect(await a.transfers.owedOutgoing(b.id), isEmpty,
          reason: 'a folder in flight is not a folder still owed');
      await b.service.accept(offered.id);
      await a.reachState(sent.id, TransferState.done,
          describe: 'the owed folder to cross');
      expect(await b.inboxFile('photos/one.txt'), bytesOf(2048, seed: 1));
      expect(await b.inboxFile('photos/sub/two.txt'), bytesOf(3072, seed: 2));
    });

    test('offers no more at once than the peer will take, then the rest',
        () async {
      // Four files dropped on a phone that is away, and §4.6's ceiling of three.
      // The fourth must not be offered while three are out — the peer answers a
      // fourth with `busy`, and a `busy` is an ending — so it waits for one of
      // the three to finish, which is what the release hook is for.
      final List<File> sources = <File>[
        for (int i = 0; i < kMaxConcurrentXfers + 1; i++)
          await a.fileOf('many$i.bin', bytesOf(4096, seed: i)),
      ];
      final List<Transfer> sent = <Transfer>[
        for (final File source in sources)
          await a.service.sendFile(peerId: b.id, file: source),
      ];
      await waitUntil(
        () => a.service.active.isEmpty,
        describe: 'all four to be owed',
      );

      // Answering as they arrive: four offers queued at a receiver that nobody
      // is sitting in front of would leave the last one waiting for a person.
      final StreamSubscription<Transfer> answers =
          b.service.offers.listen((Transfer offer) {
        unawaited(b.service.accept(offer.id));
      });
      addTearDown(answers.cancel);

      await a.connectTo(b);
      for (final Transfer transfer in sent) {
        await a.reachState(transfer.id, TransferState.done,
            describe: '${transfer.id} to cross');
      }
      expect(await b.inbox.list().toList(), hasLength(kMaxConcurrentXfers + 1));
      // Draining the queue is triggered by each transfer that finishes as well
      // as by the connection, so it runs several times over one backlog — and
      // every one of those runs reads the same rows. One offer per transfer is
      // the property that has to survive that.
      expect(
        b.offers.map((Transfer offer) => offer.id).toSet(),
        hasLength(b.offers.length),
        reason: 'one offer each, however many times the queue was drained',
      );
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

  group('a folder crossing', () {
    test('arrives as a tree, one message and one card per file', () async {
      await a.connectTo(b);
      final Directory source = await a.folderOf('holiday', <String, List<int>>{
        'beach.jpg': bytesOf(40 * 1024, seed: 11),
        'notes.txt': bytesOf(300, seed: 12),
        'sub/deep.bin': bytesOf(9 * 1024, seed: 13),
        // No bytes in it, and the one thing a file-by-file transfer cannot
        // learn from a file: §4.6 rule 4 rebuilds it from the manifest.
        'empty/': <int>[],
      });

      final Transfer sent =
          await a.service.sendFolder(peerId: b.id, directory: source);
      final Transfer offered = await b.nextOffer();
      expect(offered.id, sent.id);
      expect(offered.state, TransferState.offered);
      expect(offered.isIncoming, isTrue);
      expect(offered.bytesTotal, 40 * 1024 + 300 + 9 * 1024);

      await b.service.accept(offered.id);
      await b.reachState(offered.id, TransferState.done,
          describe: 'the folder to arrive');
      await a.reachState(sent.id, TransferState.done,
          describe: 'the sender to be told');

      // The tree, rebuilt — the two files under `sub` and the empty directory
      // included.
      final Directory landed = Directory(
        '${b.inbox.path}${Platform.pathSeparator}holiday',
      );
      expect(await treeIn(landed), <String, bool>{
        'beach.jpg': false,
        'notes.txt': false,
        'sub': true,
        'sub/deep.bin': false,
        'empty': true,
      });
      expect(
        await File('${landed.path}${Platform.pathSeparator}sub'
                '${Platform.pathSeparator}deep.bin')
            .readAsBytes(),
        bytesOf(9 * 1024, seed: 13),
      );

      // One message for the folder, one attachment per *file*.
      final List<Message> chat = await b.chat.page(a.id);
      expect(chat.single.type, MessageType.folder);
      expect(chat.single.text, 'holiday',
          reason: 'a folder message carries the name and nothing else — the '
              'size and the files live on the attachments');
      expect(chat.single.status, MessageStatus.delivered);

      final List<Attachment> files =
          await b.transfers.attachmentsForMessage(chat.single.id);
      expect(files.map((Attachment f) => f.relPath),
          <String>['beach.jpg', 'notes.txt', 'sub/deep.bin'],
          reason: 'one per file, in the order the folder shows them — and none '
              'for the empty directory, which has no bytes to describe');
      expect(files.every((Attachment f) => f.state == TransferState.done),
          isTrue);
      expect(files.every((Attachment f) => f.transferred == f.size), isTrue);

      // The ending is the task's, and §5.1.1 gives it no attachment to carry it.
      final Map<String, Transfer> tasks =
          await b.transfers.tasksForMessages(<String>[chat.single.id]);
      expect(tasks[chat.single.id]!.attachmentId, isNull);
      expect(tasks[chat.single.id]!.state, TransferState.done);

      // Nothing left running on either side, and nothing on disk but the files.
      expect(a.service.active, isEmpty);
      expect(b.service.active, isEmpty);
      expect(await a.transfers.unfinished(), isEmpty);
      expect(await b.transfers.unfinished(), isEmpty);
    });

    test('two files of one name in different places land apart', () async {
      // The case the per-file `relPath` exists for: §4.6 rule 3 gives every file
      // in a folder the same `xferId`, so a receiver that keyed on the id alone
      // would write the second of these over the first — a file of the right
      // length that neither side ever sent.
      await a.connectTo(b);
      final Uint8List first = bytesOf(6 * 1024, seed: 21);
      final Uint8List second = bytesOf(6 * 1024, seed: 22);
      final Directory source = await a.folderOf('two', <String, List<int>>{
        'a/same.bin': first,
        'b/same.bin': second,
      });

      final Transfer sent =
          await a.service.sendFolder(peerId: b.id, directory: source);
      await b.service.accept((await b.nextOffer()).id);
      await b.reachState(sent.id, TransferState.done,
          describe: 'both files to arrive');

      final String root = '${b.inbox.path}${Platform.pathSeparator}two';
      expect(await File('$root${Platform.pathSeparator}a'
              '${Platform.pathSeparator}same.bin').readAsBytes(),
          first);
      expect(await File('$root${Platform.pathSeparator}b'
              '${Platform.pathSeparator}same.bin').readAsBytes(),
          second);
    });

    test('a file of no bytes arrives on the notice alone', () async {
      // §4.6.1's zero-byte case, inside a folder: there is no chunk to carry a
      // `relPath`, so the sender's `file_done` is the only frame that ever names
      // the file — and the receiver has to build the file's sink from it.
      await a.connectTo(b);
      final Directory source = await a.folderOf('mixed', <String, List<int>>{
        'nothing.txt': <int>[],
        'something.txt': bytesOf(4096, seed: 31),
      });

      final Transfer sent =
          await a.service.sendFolder(peerId: b.id, directory: source);
      await b.service.accept((await b.nextOffer()).id);
      await b.reachState(sent.id, TransferState.done,
          describe: 'the empty file and the other one to arrive');

      final String root = '${b.inbox.path}${Platform.pathSeparator}mixed';
      expect(await File('$root${Platform.pathSeparator}nothing.txt').length(), 0);
      expect(
        await File('$root${Platform.pathSeparator}something.txt').readAsBytes(),
        bytesOf(4096, seed: 31),
      );
    });

    test('a folder of empty directories is a task with no files', () async {
      // A legal message with a task and zero attachments (§5.1.1), and the shape
      // that breaks anything assuming a folder has files in it: nothing is ever
      // sent after the acceptance, so the task ends on the acceptance itself.
      await a.connectTo(b);
      final Directory source = await a.folderOf('hollow', <String, List<int>>{
        'one/': <int>[],
        'one/two/': <int>[],
      });

      final Transfer sent =
          await a.service.sendFolder(peerId: b.id, directory: source);
      await b.service.accept((await b.nextOffer()).id);
      await b.reachState(sent.id, TransferState.done,
          describe: 'a folder with nothing in it to finish');
      await a.reachState(sent.id, TransferState.done,
          describe: 'the sender to hear the same');

      final Directory landed = Directory(
        '${b.inbox.path}${Platform.pathSeparator}hollow',
      );
      expect(await treeIn(landed), <String, bool>{'one': true, 'one/two': true});
      final Message message = (await b.chat.page(a.id)).single;
      expect(await b.transfers.attachmentsForMessage(message.id), isEmpty);
      expect(message.status, MessageStatus.delivered);
    });

    test('one file that changed under the sender is written off, the rest go',
        () async {
      // §4.6 rule 3's per-file ending, and the reason a folder keeps going: the
      // file `aaa.bin` is rewritten after the walk and before the acceptance, so
      // the sender's own size check refuses it — and the folder is still worth
      // sending, because `zzz.bin` is not.
      await a.connectTo(b);
      final Directory source = await a.folderOf('mixed', <String, List<int>>{
        'aaa.bin': bytesOf(4096, seed: 41),
        'zzz.bin': bytesOf(4096, seed: 42),
      });
      final Transfer sent =
          await a.service.sendFolder(peerId: b.id, directory: source);
      final Transfer offered = await b.nextOffer();

      // The walk has happened and the manifest is on the wire; the file behind
      // it changes before anything is read.
      await File('${source.path}${Platform.pathSeparator}aaa.bin')
          .writeAsBytes(bytesOf(2048, seed: 43), flush: true);

      await b.service.accept(offered.id);
      await b.reachState(offered.id, TransferState.failed,
          describe: 'the folder to end failed');
      await a.reachState(sent.id, TransferState.failed,
          describe: 'the sender to end failed too');

      final String root = '${b.inbox.path}${Platform.pathSeparator}mixed';
      expect(await treeIn(Directory(root)), <String, bool>{'zzz.bin': false});
      expect(await File('$root${Platform.pathSeparator}zzz.bin').readAsBytes(),
          bytesOf(4096, seed: 42));

      // The one that landed reads `done` and the one that did not reads
      // `failed`: a card that hid the file that arrived behind the task that
      // failed is the answer §5.1.1 exists to refuse.
      final Message message = (await b.chat.page(a.id)).single;
      final List<Attachment> files =
          await b.transfers.attachmentsForMessage(message.id);
      expect(
        <String, TransferState>{
          for (final Attachment file in files)
            file.relPath!: file.state,
        },
        <String, TransferState>{
          'aaa.bin': TransferState.failed,
          'zzz.bin': TransferState.done,
        },
      );
      expect(message.status, MessageStatus.failed);
      expect(b.service.active, isEmpty);
      expect(a.service.active, isEmpty);
    });

    test('a second folder of one name merges rather than numbering itself',
        () async {
      // The file names are what must not collide, and `IncomingFile` already
      // frees each of them. Numbering the folder instead would put two
      // directories on disk claiming to be the folder the message names.
      await a.connectTo(b);
      final Uint8List once = bytesOf(2048, seed: 51);
      final Uint8List twice = bytesOf(2048, seed: 52);

      final List<Uint8List> rounds = <Uint8List>[once, twice];
      for (int round = 0; round < rounds.length; round++) {
        final Directory source = await a.folderOf('again', <String, List<int>>{
          'note.txt': rounds[round],
        });
        final Transfer sent =
            await a.service.sendFolder(peerId: b.id, directory: source);
        await b.service.accept((await b.nextOffer(index: round)).id);
        await b.reachState(sent.id, TransferState.done,
            describe: 'folder ${round + 1} to arrive');
      }

      final Directory landed = Directory(
        '${b.inbox.path}${Platform.pathSeparator}again',
      );
      expect(await treeIn(landed), <String, bool>{
        'note.txt': false,
        'note (1).txt': false,
      });
      expect(await File('${landed.path}${Platform.pathSeparator}note.txt')
          .readAsBytes(), once);
      expect(await File('${landed.path}${Platform.pathSeparator}note (1).txt')
          .readAsBytes(), twice);
    });

    test('a folder that cannot be written is refused, not waited on', () async {
      // The destination is not touched until the user answers the offer — an
      // offer nobody has accepted must not create directories — so a folder
      // that cannot be written is found out at the moment of accepting, and the
      // sender is told there and then. What is being tested is the telling:
      // `file_reject` rather than silence, because silence is the sender's
      // offer timeout and a minute of a user watching nothing happen.
      await a.connectTo(b);
      final Directory source = await a.folderOf('doomed', <String, List<int>>{
        'f.bin': bytesOf(1024, seed: 61),
      });
      // The download root becomes a *file*, so nothing can be created under it.
      await b.inbox.delete(recursive: true);
      await File(b.inbox.path).writeAsBytes(<int>[0], flush: true);

      final Transfer sent =
          await a.service.sendFolder(peerId: b.id, directory: source);
      await b.service.accept((await b.nextOffer()).id);

      await b.reachState(sent.id, TransferState.failed,
          describe: 'the folder to be found unwritable');
      await a.reachState(sent.id, TransferState.failed,
          describe: 'the sender to hear the refusal');

      expect(await File(b.inbox.path).length(), 1,
          reason: 'nothing was written anywhere near it');
      expect(b.service.active, isEmpty);
      expect(a.service.active, isEmpty);
    });
  });

  group('stopping a folder', () {
    test('a folder stopped while a file is landing keeps what has landed',
        () async {
      // 取消后无残留 is about a *half* of something, and a file that landed whole
      // is not half of anything. What a cancel stops is the files behind it —
      // and this lands in the window a folder has that a single file does not:
      // the bytes of a file are all in and it is being renamed into place, so
      // the cancel cannot mean "throw this file away" without destroying
      // something the user asked for and that has already arrived.
      await a.connectTo(b);
      final Uint8List first = bytesOf(64 * 1024, seed: 71);
      final Directory source = await a.folderOf('pair', <String, List<int>>{
        'one.bin': first,
        'two.bin': bytesOf(64 * 1024, seed: 72),
      });

      final Transfer sent =
          await a.service.sendFolder(peerId: b.id, directory: source);
      final Transfer offered = await b.nextOffer();

      // The moment the first file is installed and no byte of the second has
      // been written: the task's byte count is exactly the first file's size.
      final Completer<void> cancel = Completer<void>();
      final StreamSubscription<Transfer> watch =
          b.service.changes.listen((Transfer transfer) {
        if (!cancel.isCompleted &&
            transfer.id == offered.id &&
            transfer.bytesDone == first.length) {
          cancel.complete();
        }
      });
      addTearDown(watch.cancel);

      await b.service.accept(offered.id);
      await cancel.future;
      await b.service.cancel(offered.id);

      await b.reachState(offered.id, TransferState.cancelled,
          describe: 'the folder to be stopped');
      await a.reachState(sent.id, TransferState.cancelled,
          describe: 'the sender to hear the stop');

      final Directory landed = Directory(
        '${b.inbox.path}${Platform.pathSeparator}pair',
      );
      expect(await treeIn(landed), <String, bool>{'one.bin': false},
          reason: 'the file that landed is not residue, and no .part is either');
      expect(await File('${landed.path}${Platform.pathSeparator}one.bin')
          .readAsBytes(), first);

      final Message message = (await b.chat.page(a.id)).single;
      final List<Attachment> files =
          await b.transfers.attachmentsForMessage(message.id);
      expect(
        <String, TransferState>{
          for (final Attachment file in files)
            file.relPath!: file.state,
        },
        <String, TransferState>{
          'one.bin': TransferState.done,
          'two.bin': TransferState.cancelled,
        },
      );
      // Waited for rather than asserted: the sender is still unwinding the
      // folder when the row reads `cancelled` — the file it was about to send
      // has to fail and be tidied first — so an immediate read of [active]
      // measures the test's own timing.
      await waitUntil(
        () => a.service.active.isEmpty && b.service.active.isEmpty,
        describe: 'both devices to let go of the folder',
      );
    });

    test('a folder turned down before it is accepted leaves nothing',
        () async {
      await a.connectTo(b);
      final Directory source = await a.folderOf('unwanted', <String, List<int>>{
        'f.bin': bytesOf(4096, seed: 81),
      });

      final Transfer sent =
          await a.service.sendFolder(peerId: b.id, directory: source);
      await b.service.decline((await b.nextOffer()).id);

      await b.reachState(sent.id, TransferState.declined,
          describe: 'the offer to be turned down');
      // `declined` on the sender too, exactly as a single file is — the refusal
      // says the user said no, which is not the same as an attempt that failed
      // and is the ending a retry has to keep apart from one. The *message* is
      // the failed thing there, since a bubble with nothing in it is what the
      // user sees and asks again from.
      await a.reachState(sent.id, TransferState.declined,
          describe: 'the sender to hear the refusal');

      expect(await pathsIn(b.inbox), isEmpty);
      expect(b.service.active, isEmpty);
      expect(a.service.active, isEmpty);
      expect((await a.chat.page(b.id)).single.status, MessageStatus.failed,
          reason: 'a declined folder leaves the sender a failed message');
    });
  });

  // A picture that has landed is in the app's private directory, which is
  // nowhere the user can reach it from. What this layer owns is the moment it
  // lands — it is the only thing that knows — so what is checked here is that
  // the moment is noticed with the right name and type, that it is noticed for
  // exactly the files that belong in a gallery, and that a gallery which says no
  // cannot damage a transfer that has already succeeded.
  //
  // Publishing is deliberately not awaited by the service, so a test cannot wait
  // on the call directly. Each of these waits on an observable that can only
  // happen *after* it — and the cases expecting no call prove it by running a
  // picture in the same test and waiting for that one to arrive.
  group('a received picture goes to the gallery (§7.1)', () {
    test('a photograph is published under its own name and type', () async {
      final _Gallery gallery = _Gallery();
      final _Device receiver =
          await _Device.start(id: 'device-eee', gallery: gallery);
      addTearDown(receiver.dispose);
      await a.connectTo(receiver);

      final Uint8List content = bytesOf(24 * 1024, seed: 41);
      final File source = await a.fileOf('holiday.jpg', content);
      final Transfer sent = await a.service.sendFile(
        peerId: receiver.id,
        file: source,
        mime: 'image/jpeg',
      );
      await receiver.service.accept((await receiver.nextOffer()).id);
      await receiver.reachState(sent.id, TransferState.done,
          describe: 'the picture to land');

      await waitUntil(() => gallery.calls.isNotEmpty,
          describe: 'the gallery to be offered the picture');
      final _Published published = gallery.calls.single;
      expect(published.name, 'holiday.jpg');
      expect(published.mime, 'image/jpeg');
      // The path it was handed is the file that actually landed, so a copy taken
      // from it is the bytes that were sent — not a `.part`, and not a name
      // invented on the way.
      expect(published.path, endsWith('holiday.jpg'));
      expect(await File(published.path).readAsBytes(), content);
    });

    test('a photograph this app cannot draw is published too', () async {
      // The rule that has to differ from the one the chat uses to choose a
      // bubble: the chat cannot show a HEIC and says so with a file card, and
      // the phone's gallery displays it perfectly. A `.heic` left out here is
      // the picture an iPhone user most likely just sent.
      final _Gallery gallery = _Gallery();
      final _Device receiver =
          await _Device.start(id: 'device-fff', gallery: gallery);
      addTearDown(receiver.dispose);
      await a.connectTo(receiver);

      final File source =
          await a.fileOf('IMG_0421.HEIC', bytesOf(8 * 1024, seed: 42));
      final Transfer sent = await a.service.sendFile(
        peerId: receiver.id,
        file: source,
        mime: 'image/heic',
      );
      await receiver.service.accept((await receiver.nextOffer()).id);
      await receiver.reachState(sent.id, TransferState.done,
          describe: 'the photograph to land');

      await waitUntil(() => gallery.calls.isNotEmpty,
          describe: 'the gallery to be offered the photograph');
      expect(gallery.calls.single.name, 'IMG_0421.HEIC');
      expect(gallery.calls.single.mime, 'image/heic');
    });

    test('a document is not, and the picture after it still is', () async {
      final _Gallery gallery = _Gallery();
      final _Device receiver =
          await _Device.start(id: 'device-ggg', gallery: gallery);
      addTearDown(receiver.dispose);
      await a.connectTo(receiver);

      final Transfer notes = await a.service.sendFile(
        peerId: receiver.id,
        file: await a.fileOf('notes.txt', bytesOf(400, seed: 43)),
      );
      await receiver.service.accept((await receiver.nextOffer()).id);
      await receiver.reachState(notes.id, TransferState.done,
          describe: 'the document to land');

      // The second transfer is the barrier. The document's publish, if it were
      // going to happen, is scheduled before this one is even offered, so a
      // single call recorded by the time this arrives can only be the picture's.
      final Transfer photo = await a.service.sendFile(
        peerId: receiver.id,
        file: await a.fileOf('holiday.jpg', bytesOf(1024, seed: 44)),
        mime: 'image/jpeg',
      );
      await receiver.service.accept((await receiver.nextOffer(index: 1)).id);
      await receiver.reachState(photo.id, TransferState.done,
          describe: 'the picture to land');

      await waitUntil(() => gallery.calls.isNotEmpty,
          describe: 'the gallery to be offered the picture');
      expect(gallery.calls, hasLength(1),
          reason: 'the document was not published');
      expect(gallery.calls.single.name, 'holiday.jpg');
    });

    test('a folder is left alone, whatever is inside it', () async {
      // A folder of photographs published file by file would flatten the tree
      // into one album and pour hundreds of entries into it. The folder keeps
      // its own arrangement under the download directory, which is where the
      // whole shape of it is visible.
      final _Gallery gallery = _Gallery();
      final _Device receiver =
          await _Device.start(id: 'device-hhh', gallery: gallery);
      addTearDown(receiver.dispose);
      await a.connectTo(receiver);

      final Directory folder = await a.folderOf('holiday', <String, List<int>>{
        'beach.jpg': bytesOf(6 * 1024, seed: 45),
        'sunset.png': bytesOf(6 * 1024, seed: 46),
      });
      final Transfer folderSent =
          await a.service.sendFolder(peerId: receiver.id, directory: folder);
      await receiver.service.accept((await receiver.nextOffer()).id);
      await receiver.reachState(folderSent.id, TransferState.done,
          describe: 'the folder to arrive');

      final Transfer photo = await a.service.sendFile(
        peerId: receiver.id,
        file: await a.fileOf('holiday.jpg', bytesOf(1024, seed: 47)),
        mime: 'image/jpeg',
      );
      await receiver.service.accept((await receiver.nextOffer(index: 1)).id);
      await receiver.reachState(photo.id, TransferState.done,
          describe: 'the picture to land');

      await waitUntil(() => gallery.calls.isNotEmpty,
          describe: 'the gallery to be offered the picture');
      expect(gallery.calls, hasLength(1),
          reason: 'neither picture inside the folder was published');
      expect(gallery.calls.single.name, 'holiday.jpg');
      expect(await treeIn(Directory('${receiver.inbox.path}'
              '${Platform.pathSeparator}holiday')),
          <String, bool>{'beach.jpg': false, 'sunset.png': false});
    });

    test('a gallery that fails does not make the transfer a failure', () async {
      // The bytes are on disk and the message says so. Reporting that transfer
      // as failed because a second copy of it could not be written would be a
      // lie about the user's file.
      final _Gallery gallery = _Gallery()
        ..throws = StateError('the gallery is not writable');
      final _Device receiver =
          await _Device.start(id: 'device-iii', gallery: gallery);
      addTearDown(receiver.dispose);
      await a.connectTo(receiver);

      final Uint8List content = bytesOf(4096, seed: 48);
      final File source = await a.fileOf('holiday.jpg', content);
      final Transfer sent = await a.service.sendFile(
        peerId: receiver.id,
        file: source,
        mime: 'image/jpeg',
      );
      await receiver.service.accept((await receiver.nextOffer()).id);
      await receiver.reachState(sent.id, TransferState.done,
          describe: 'the picture to land');

      await waitUntil(() => gallery.calls.isNotEmpty,
          describe: 'the gallery to have been asked');
      // It was asked and it refused, and none of that reached the row the user
      // is looking at.
      final Attachment? landed = await receiver.transfers.attachmentFor(sent.id);
      expect(landed!.state, TransferState.done);
      expect(await File(landed.localPath!).readAsBytes(), content);
      await receiver.reachState(sent.id, TransferState.done);
      expect(receiver.service.active, isEmpty);
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

/// Everything under [directory], `/`-separated and sorted, with `true` for a
/// directory — the shape of a folder on disk, which is what a folder transfer is
/// judged by.
///
/// Both kinds are in it because both are what a folder carries: §4.6 rule 4
/// makes a receiver rebuild the empty directories, and a tree that came back
/// without one is a tree that came back wrong.
Future<Map<String, bool>> treeIn(Directory directory) async {
  final List<FileSystemEntity> entities =
      await directory.list(recursive: true).toList();
  final String prefix = directory.path.endsWith(Platform.pathSeparator)
      ? directory.path
      : '${directory.path}${Platform.pathSeparator}';
  final List<MapEntry<String, bool>> entries = <MapEntry<String, bool>>[
    for (final FileSystemEntity entity in entities)
      MapEntry<String, bool>(
        entity.path
            .substring(prefix.length)
            .replaceAll(Platform.pathSeparator, '/'),
        entity is Directory,
      ),
  ]..sort((MapEntry<String, bool> a, MapEntry<String, bool> b) =>
      a.key.compareTo(b.key));
  return Map<String, bool>.fromEntries(entries);
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

/// Stands in for the platform's gallery: records what it was asked to publish,
/// and can be made to refuse.
///
/// A recording callback rather than a mock of the method channel, for the same
/// reason the rest of this file uses real sockets — what is worth checking is
/// that the transfer layer notices the moment and passes the right three things
/// on, and none of that is a property of the channel underneath.
class _Gallery {
  final List<_Published> calls = <_Published>[];

  /// What [publish] answers, and what it throws instead of answering.
  bool answer = true;
  Object? throws;

  Future<bool> publish({
    required String path,
    required String name,
    required String? mime,
  }) async {
    calls.add(_Published(path, name, mime));
    final Object? failure = throws;
    if (failure != null) {
      throw failure;
    }
    return answer;
  }
}

/// One call to [_Gallery.publish], kept whole so a test can name which part of
/// it is wrong.
class _Published {
  _Published(this.path, this.name, this.mime);

  final String path;
  final String name;
  final String? mime;
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
    _Gallery? gallery,
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
      // Null on every device that is not testing this, which is the same thing
      // as off — and closer to the platforms where there is no gallery to put a
      // file in than a stub that always says yes would be.
      publishImage: gallery?.publish,
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

  /// Waits for this device's [index]th offer to arrive.
  ///
  /// Indexed rather than "the newest one", because [offers] keeps every offer
  /// this device has had: a device offered two folders still has both, and
  /// `first` would hand the second test the first offer again — which reads as
  /// the *sender* stalling, since the offer that was accepted twice never
  /// moves.
  Future<Transfer> nextOffer({int index = 0, Duration timeout = patience}) {
    return waitForValue<Transfer?>(
      () async => offers.length <= index ? null : offers[index],
      (Transfer? offer) => offer != null,
      describe: index == 0
          ? 'an offer to arrive'
          : 'offer ${index + 1} to arrive',
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

  /// What landed in [inbox] under a `/`-separated [relPath] — a folder's file
  /// as much as a single one.
  ///
  /// Read back rather than checked off by name: a transfer is judged by the
  /// bytes on the disk, and a file that arrived empty or half-written is the
  /// failure this whole layer exists to prevent.
  Future<Uint8List> inboxFile(String relPath) {
    final String local = relPath.replaceAll('/', Platform.pathSeparator);
    return File('${inbox.path}${Platform.pathSeparator}$local').readAsBytes();
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

  /// A folder of files in a temporary directory, for sending.
  ///
  /// [contents] is `relPath -> bytes`, `/`-separated, and a key ending in a
  /// separator is a directory rather than a file. That last one is not a
  /// convenience: an empty directory is a thing a folder carries and the walk
  /// has to be given one to prove it does.
  Future<Directory> folderOf(
    String name,
    Map<String, List<int>> contents,
  ) async {
    final Directory parent =
        await Directory.systemTemp.createTemp('feijian-src-$id-');
    _scratch.add(parent);
    final Directory root =
        Directory('${parent.path}${Platform.pathSeparator}$name');
    await root.create(recursive: true);
    for (final MapEntry<String, List<int>> item in contents.entries) {
      final String path = '${root.path}${Platform.pathSeparator}'
          '${item.key.replaceAll('/', Platform.pathSeparator)}';
      if (item.key.endsWith('/')) {
        await Directory(path).create(recursive: true);
        continue;
      }
      final File file = File(path);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(item.value, flush: true);
    }
    return root;
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
