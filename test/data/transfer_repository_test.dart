import 'package:feijian/core/models/message.dart';
import 'package:feijian/core/models/transfer.dart';
import 'package:feijian/data/dao/message_dao.dart';
import 'package:feijian/data/database.dart';
import 'package:feijian/data/repository/chat_repository.dart';
import 'package:feijian/data/repository/transfer_repository.dart';
import 'package:flutter_test/flutter_test.dart';

/// What a file transfer writes, and — just as importantly — what it does not.
///
/// A transfer is four rows in one transaction, and the interesting failures are
/// all in the seams between them: a message bubble with no attachment behind it,
/// a transfer row under a message id that was never inserted, a file message
/// picked up by the *text* offline queue and sent to the peer as a blank
/// bubble. None of those are visible from the transfer service, which is why
/// they are checked here.
void main() {
  late AppDatabase db;
  late TransferRepository transfers;
  late ChatRepository chat;

  setUp(() {
    db = AppDatabase.memory();
    transfers = TransferRepository(db);
    chat = ChatRepository(db);
  });

  tearDown(() => db.close());

  final DateTime t0 = DateTime.fromMillisecondsSinceEpoch(1700000000000);
  DateTime at(int ms) => t0.add(Duration(milliseconds: ms));

  Future<Transfer> outgoing({
    String xferId = 'xfer-1',
    String peerId = 'peer-1',
    String fileName = 'holiday.jpg',
    int totalSize = 4096,
    String? mime = 'image/jpeg',
    String? localPath = r'C:\photos\holiday.jpg',
    DateTime? now,
  }) {
    return transfers.beginOutgoing(
      xferId: xferId,
      peerId: peerId,
      fileName: fileName,
      totalSize: totalSize,
      mime: mime,
      localPath: localPath,
      now: now ?? at(0),
    );
  }

  Future<Transfer> incoming({
    String xferId = 'xfer-2',
    String peerId = 'peer-1',
    String fileName = 'report.pdf',
    int totalSize = 8192,
    DateTime? now,
  }) {
    return transfers.beginIncoming(
      xferId: xferId,
      peerId: peerId,
      fileName: fileName,
      totalSize: totalSize,
      mime: 'application/pdf',
      now: now ?? at(0),
    );
  }

  group('beginning a transfer', () {
    test('writes the message, the attachment and the transfer together',
        () async {
      final Transfer transfer = await outgoing();

      expect(transfer.messageId, isNotNull);
      expect(transfer.attachmentId, isNotNull);
      expect(transfer.state, TransferState.pending);
      expect(transfer.bytesTotal, 4096);
      expect(transfer.bytesDone, 0);

      final MessageRow? message =
          await db.select(db.messages).getSingleOrNull();
      expect(message!.type, MessageType.file.wire);
      expect(message.direction, MessageDirection.outgoing.wire);
      expect(message.status, MessageStatus.pending.wire);
      // A file message carries no text: the name and the size are the
      // attachment's, and a copy here would be a second version of the truth.
      expect(message.body, isNull);
      expect(message.conversationId, MessageDao.conversationIdFor('peer-1'));

      final AttachmentRow? attachment =
          await db.select(db.attachments).getSingleOrNull();
      expect(attachment!.messageId, transfer.messageId);
      expect(attachment.fileName, 'holiday.jpg');
      expect(attachment.size, 4096);
      expect(attachment.mime, 'image/jpeg');
      expect(attachment.localPath, r'C:\photos\holiday.jpg');
      expect(attachment.state, TransferState.pending.wire);
    });

    test('an incoming offer starts as offered, and raises the unread badge',
        () async {
      final Transfer transfer = await incoming();

      expect(transfer.state, TransferState.offered);
      expect(transfer.direction, MessageDirection.incoming);

      final MessageRow message = await db.select(db.messages).getSingle();
      // Not `received`: nothing has arrived yet, only an offer. The word is the
      // honest one for "the peer's file is waiting on this device's answer".
      expect(message.status, MessageStatus.pending.wire);

      final ConversationRow conversation =
          await db.select(db.conversations).getSingle();
      expect(conversation.unreadCount, 1);

      final TransferRow row = await db.select(db.transfers).getSingle();
      expect(row.tempPath, isNull);
      expect(transfer.attachmentId, row.attachmentId);
    });

    test('our own send does not raise the unread badge', () async {
      await outgoing();
      final ConversationRow conversation =
          await db.select(db.conversations).getSingle();
      expect(conversation.unreadCount, 0);
    });

    test('a second transfer in the same millisecond sorts after the first',
        () async {
      // §5.2.1: two messages sharing a millisecond have no defined order, and
      // the chat page reads the file message through the same ordering as any
      // other. The second one has to be pushed past the first.
      await outingAndIncoming(transfers, at(0));

      final List<MessageRow> rows = await db.select(db.messages).get();
      expect(rows, hasLength(2));
      // File messages carry no body, so which row is which is read through the
      // attachment behind it.
      final Map<String, String> nameOf = <String, String>{
        for (final AttachmentRow a in await db.select(db.attachments).get())
          a.messageId: a.fileName,
      };
      final MessageRow first = rows[0];
      final MessageRow second = rows[1];
      final MessageRow earlier =
          first.createdAt < second.createdAt ? first : second;
      final MessageRow later =
          first.createdAt < second.createdAt ? second : first;

      // Distinct createdAt, and the one begun second is the one that reads
      // second — a same-millisecond tie would leave the chat page to break it
      // however the row order happened to come back.
      expect(earlier.createdAt, isNot(later.createdAt));
      expect(nameOf[earlier.id], 'a.txt');
      expect(nameOf[later.id], 'b.txt');
    });

    test('a file message is not in the text offline queue', () async {
      // The bug this guards: `pendingFor` selects every outgoing pending
      // message, and a file message that got in would be sent as a `msg` frame
      // carrying its empty body — a blank bubble on the peer, and a tick here
      // for a file still sitting on this disk.
      await outgoing();

      expect(await chat.pendingFor('peer-1'), isEmpty);
      expect(await chat.allPending(), isEmpty);
    });
  });

  group('finishing', () {
    test('records the file path on both rows and completes the message',
        () async {
      final Transfer transfer = await outgoing();
      await transfers.finish(
        transfer.id,
        localPath: r'C:\Downloads\Feijian\holiday.jpg',
        now: at(50),
      );

      final TransferRow row = await (db.select(db.transfers)
            ..where((Transfers t) => t.id.equals(transfer.id)))
          .getSingle();
      expect(row.state, TransferState.done.wire);
      // Not the last checkpoint: a transfer that finished between two of them
      // would otherwise read `done` at 0 of 4096 bytes.
      expect(row.bytesDone, 4096);

      final AttachmentRow attachment =
          await db.select(db.attachments).getSingle();
      expect(attachment.state, TransferState.done.wire);
      expect(attachment.transferred, 4096);
      expect(attachment.localPath, r'C:\Downloads\Feijian\holiday.jpg');

      final MessageRow message = await db.select(db.messages).getSingle();
      expect(message.status, MessageStatus.delivered.wire);
      expect(message.deliveredAt, at(50).millisecondsSinceEpoch);
    });

    test('a failure keeps how far it got, and fails the message', () async {
      final Transfer transfer = await outgoing();
      await transfers.recordProgress(
        transfer.id,
        state: TransferState.transferring,
        bytesDone: 3000,
      );
      await transfers.end(
        transfer.id,
        state: TransferState.failed,
        now: at(60),
      );

      final TransferRow row = await (db.select(db.transfers)
            ..where((Transfers t) => t.id.equals(transfer.id)))
          .getSingle();
      expect(row.state, TransferState.failed.wire);
      // The record of how far the attempt got, and what a retry would not have
      // to send again.
      expect(row.bytesDone, 3000);

      final MessageRow message = await db.select(db.messages).getSingle();
      expect(message.status, MessageStatus.failed.wire);
      expect(message.deliveredAt, isNull);
    });

    test('a decline is not a failure, and neither is a cancel', () async {
      final Transfer first = await incoming(xferId: 'xfer-a');
      await transfers.end(first.id, state: TransferState.declined, now: at(1));
      final Transfer second = await incoming(
        xferId: 'xfer-b',
        peerId: 'peer-2',
      );
      await transfers.end(second.id,
          state: TransferState.cancelled, now: at(2));

      final Map<String, String> states = <String, String>{
        for (final TransferRow row in await db.select(db.transfers).get())
          row.id: row.state,
      };
      expect(states['xfer-a'], TransferState.declined.wire);
      expect(states['xfer-b'], TransferState.cancelled.wire);
    });

    test('ending writes the temp path a resume would need', () async {
      final Transfer transfer = await incoming();
      await transfers.recordTempPath(transfer.id, r'C:\dl\report.pdf.part');

      final Transfer? read = await transfers.byId(transfer.id);
      expect(read!.tempPath, r'C:\dl\report.pdf.part');
    });
  });

  group('a retry', () {
    test('adds an attempt without adding a second bubble', () async {
      final Transfer first = await outgoing();
      await transfers.recordProgress(
        first.id,
        state: TransferState.transferring,
        bytesDone: 2048,
      );
      await transfers.end(first.id, state: TransferState.failed, now: at(10));

      final Transfer again = await transfers.beginRetry(
        xferId: 'xfer-2',
        peerId: 'peer-1',
        messageId: first.messageId!,
        attachmentId: first.attachmentId!,
        fileName: 'holiday.jpg',
        totalSize: 4096,
        mime: 'image/jpeg',
        now: at(20),
      );

      // A second row for the second attempt, with the first left alone: the
      // rows are where attempts accumulate, and how far the last one got is
      // worth keeping rather than rewriting.
      final Map<String, String> states = <String, String>{
        for (final TransferRow row in await db.select(db.transfers).get())
          row.id: row.state,
      };
      expect(states, <String, String>{
        'xfer-1': TransferState.failed.wire,
        'xfer-2': TransferState.pending.wire,
      });
      expect(again.state, TransferState.pending);
      expect(again.bytesDone, 0);

      // One message and one attachment, both back to waiting — the bubble is
      // the same bubble, and the bar starts over rather than resuming.
      final List<MessageRow> messages = await db.select(db.messages).get();
      expect(messages, hasLength(1));
      expect(messages.single.status, MessageStatus.pending.wire);
      expect(messages.single.id, first.messageId);

      final AttachmentRow attachment =
          await db.select(db.attachments).getSingle();
      expect(attachment.messageId, first.messageId);
      expect(attachment.state, TransferState.pending.wire);
      expect(attachment.transferred, 0);
      expect(
        attachment.localPath,
        r'C:\photos\holiday.jpg',
        reason: 'the file it is sending has not moved',
      );
    });

    test('does not put the file message in the text offline queue', () async {
      // The trap the retry avoids by being a transfer rather than a requeue:
      // `pendingFor` selects outgoing pending *text* messages, so a file message
      // put back to `pending` would look queued and never be sent.
      final Transfer first = await outgoing();
      await transfers.end(first.id, state: TransferState.failed, now: at(10));
      await transfers.beginRetry(
        xferId: 'xfer-2',
        peerId: 'peer-1',
        messageId: first.messageId!,
        attachmentId: first.attachmentId!,
        fileName: 'holiday.jpg',
        totalSize: 4096,
        now: at(20),
      );

      expect(await chat.pendingFor('peer-1'), isEmpty);
      expect(await chat.allPending(), isEmpty);
    });
  });

  group('the startup sweep', () {
    test('finds the transfers a killed process left behind', () async {
      await outgoing(xferId: 'xfer-running', now: at(1));
      await transfers.recordProgress(
        'xfer-running',
        state: TransferState.transferring,
        bytesDone: 100,
      );
      await incoming(xferId: 'xfer-offered', now: at(2));
      await outgoing(xferId: 'xfer-done', now: at(3));
      await transfers.finish('xfer-done', localPath: 'x', now: at(4));
      await outgoing(xferId: 'xfer-failed', now: at(5));
      await transfers.end('xfer-failed',
          state: TransferState.failed, now: at(6));
      await outgoing(xferId: 'xfer-pending', now: at(7));

      final List<Transfer> unfinished = await transfers.unfinished();

      // `pending`, `offered` and `transferring` are all "in flight"; `done` and
      // `failed` are not, and must survive the sweep untouched.
      expect(
        unfinished.map((Transfer t) => t.id),
        containsAll(<String>['xfer-running', 'xfer-offered', 'xfer-pending']),
      );
      expect(unfinished, hasLength(3));
    });
  });

  group('reading back', () {
    test('the attachment says where the file is and what it is called',
        () async {
      final Transfer transfer = await incoming(fileName: 'report.pdf');
      final Attachment? attachment = await transfers.attachmentFor(transfer.id);

      expect(attachment!.fileName, 'report.pdf');
      expect(attachment.size, 8192);
      expect(attachment.mime, 'application/pdf');
      expect(attachment.isFinished, isFalse);
      expect(attachment.isOpenable, isFalse);
      // Zero bytes of a real file is zero, not "complete because nothing has
      // gone wrong yet".
      expect(attachment.progress, 0);
    });

    test('an unknown transfer reads as nothing rather than throwing', () async {
      expect(await transfers.byId('nope'), isNull);
      expect(await transfers.attachmentFor('nope'), isNull);
    });

    test('a zero-byte transfer is complete the moment it is done', () async {
      final Transfer transfer = await outgoing(totalSize: 0);
      await transfers.finish(transfer.id, localPath: 'empty.txt', now: at(1));

      final Attachment? attachment = await transfers.attachmentFor(transfer.id);
      // The special case in `progress`: dividing by a zero size would say 0
      // forever, and an empty file that has arrived is not 0% of anything.
      expect(attachment!.progress, 1);
    });
  });

  group('the attachments behind a page of chat', () {
    test('every file message in the page is found, keyed by its message',
        () async {
      final Transfer first = await outgoing(xferId: 'x1', fileName: 'a.jpg');
      final Transfer second = await incoming(xferId: 'x2', fileName: 'b.pdf');

      final Map<String, Attachment> found = await transfers
          .attachmentsForMessages(
              <String>[first.messageId!, second.messageId!]);

      expect(found, hasLength(2));
      expect(found[first.messageId]!.fileName, 'a.jpg');
      expect(found[second.messageId]!.fileName, 'b.pdf');
    });

    test('a text message simply is not in the map', () async {
      // The chat page asks about every message it is about to render, and most
      // of them are text. Being absent is the answer to "is there a file here",
      // so a lookup that misses has to be affordable rather than an error.
      await chat.saveOutgoing(
        msgId: 'text-1',
        peerId: 'peer-1',
        text: 'no file here',
        now: at(0),
      );
      final Transfer file = await outgoing();

      final Map<String, Attachment> found =
          await transfers.attachmentsForMessages(
        <String>['text-1', file.messageId!],
      );

      expect(found.keys, <String>[file.messageId!]);
    });

    test('an empty page asks nothing and gets nothing', () async {
      // `IN ()` is not valid SQL, and the page is empty on every conversation
      // that holds only text — which is most of them, most of the time.
      expect(await transfers.attachmentsForMessages(const <String>[]), isEmpty);
    });

    test('a message that does not exist is left out rather than throwing',
        () async {
      final Transfer file = await outgoing();

      final Map<String, Attachment> found =
          await transfers.attachmentsForMessages(
        <String>['never-happened', file.messageId!],
      );

      expect(found.keys, <String>[file.messageId!]);
    });
  });
}

/// Two transfers begun in the same millisecond, to compare their timestamps.
Future<void> outingAndIncoming(
    TransferRepository transfers, DateTime now) async {
  await transfers.beginOutgoing(
    xferId: 'xfer-first',
    peerId: 'peer-1',
    fileName: 'a.txt',
    totalSize: 1,
    now: now,
  );
  await transfers.beginIncoming(
    xferId: 'xfer-second',
    peerId: 'peer-1',
    fileName: 'b.txt',
    totalSize: 1,
    now: now,
  );
}
