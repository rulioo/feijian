import 'dart:io';

import 'package:feijian/core/models/manifest_entry.dart';
import 'package:feijian/core/models/message.dart';
import 'package:feijian/core/models/transfer.dart';
import 'package:feijian/data/dao/message_dao.dart';
import 'package:feijian/data/database.dart';
import 'package:feijian/data/repository/chat_repository.dart';
import 'package:feijian/data/repository/transfer_repository.dart';
import 'package:flutter_test/flutter_test.dart';
// For `Value` and `TransfersCompanion`, and only in the one test that writes a
// second attempt at a folder by hand: no shipped path produces two rows for one
// message yet, so this is the only way to ask the read path which one it picks.
import 'package:drift/drift.dart' show Value;

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

      // `offered` and `transferring` are attempts that were interrupted;
      // `done` and `failed` ended on their own and must survive untouched.
      expect(
        unfinished.map((Transfer t) => t.id),
        containsAll(<String>['xfer-running', 'xfer-offered']),
      );
      expect(unfinished, hasLength(2));
    });

    test('leaves a transfer the peer was never asked about alone', () async {
      // §5.2 rule 5: `pending` is not an attempt that died, it is a debt. A
      // file dropped on a phone that was away is still there to be offered
      // after a restart, and sweeping it would be this app forgetting a promise
      // it can still keep.
      await outgoing(xferId: 'xfer-owed', now: at(1));

      expect(await transfers.unfinished(), isEmpty);
      expect(
        (await transfers.owedOutgoing('peer-1')).map((Transfer t) => t.id),
        <String>['xfer-owed'],
      );
    });
  });

  group('what is owed (§5.2 rule 5)', () {
    test('is read off the message, not off the transfer', () async {
      // A deliberately backwards clock: `updated_at` says the second transfer
      // is the older one, and §5.2.1 says `created_at` is what orders a
      // conversation. The queue is drained in the order the user wrote it in,
      // so it reads the message.
      await outgoing(xferId: 'xfer-first', now: at(9));
      await outgoing(xferId: 'xfer-second', now: at(2));

      final List<Transfer> owed = await transfers.owedOutgoing('peer-1');
      expect(
        owed.map((Transfer t) => t.id),
        <String>['xfer-first', 'xfer-second'],
      );
    });

    test('is emptied one transfer at a time, as each offer goes out', () async {
      await outgoing(xferId: 'xfer-offered', now: at(1));
      await outgoing(xferId: 'xfer-owed', now: at(2));

      await transfers.markOffered('xfer-offered', now: at(3));

      expect(
        (await transfers.owedOutgoing('peer-1')).map((Transfer t) => t.id),
        <String>['xfer-owed'],
      );
    });

    test('holds nothing for a peer that is not the one being asked', () async {
      await outgoing(xferId: 'xfer-here', peerId: 'peer-1', now: at(1));
      await outgoing(xferId: 'xfer-elsewhere', peerId: 'peer-2', now: at(2));
      // An offer that has arrived is the other direction, and is never owed:
      // it is waiting for *us*.
      await incoming(xferId: 'xfer-incoming', now: at(3));

      expect(
        (await transfers.owedOutgoing('peer-1')).map((Transfer t) => t.id),
        <String>['xfer-here'],
      );
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

      final Map<String, List<Attachment>> found = await transfers
          .attachmentsForMessages(
              <String>[first.messageId!, second.messageId!]);

      expect(found, hasLength(2));
      expect(found[first.messageId]!.single.fileName, 'a.jpg');
      expect(found[second.messageId]!.single.fileName, 'b.pdf');
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

      final Map<String, List<Attachment>> found =
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

      final Map<String, List<Attachment>> found =
          await transfers.attachmentsForMessages(
        <String>['never-happened', file.messageId!],
      );

      expect(found.keys, <String>[file.messageId!]);
    });
  });

  group('a folder is one message and many attachments', () {
    /// The manifest a walk would produce, directories included, for a folder
    /// holding [files] under a subdirectory.
    List<ManifestEntry> manifest({
      List<int> sizes = const <int>[10, 20, 30],
      bool withDirectory = true,
    }) {
      return <ManifestEntry>[
        if (withDirectory)
          const ManifestEntry(relPath: 'sub', size: 0, isDir: true),
        for (int i = 0; i < sizes.length; i++)
          ManifestEntry(relPath: 'sub/f$i.bin', size: sizes[i]),
      ];
    }

    Future<Transfer> sendFolder({
      String xferId = 'xfer-folder',
      List<ManifestEntry>? entries,
      String folderName = 'holiday',
      String folderPath = '/home/me/holiday',
      DateTime? now,
    }) {
      return transfers.beginOutgoingFolder(
        xferId: xferId,
        peerId: 'peer-1',
        folderName: folderName,
        folderPath: folderPath,
        entries: entries ?? manifest(),
        now: now ?? at(0),
      );
    }

    Future<Transfer> receiveFolder({
      String xferId = 'xfer-in-folder',
      List<ManifestEntry>? entries,
      DateTime? now,
    }) {
      return transfers.beginIncomingFolder(
        xferId: xferId,
        peerId: 'peer-1',
        folderName: 'holiday',
        entries: entries ?? manifest(),
        now: now ?? at(0),
      );
    }

    test('one message, one attachment per file, one transfer for the task',
        () async {
      final Transfer transfer = await sendFolder();

      final Message message = (await chat.page('peer-1')).single;
      expect(message.type, MessageType.folder);
      expect(message.id, transfer.messageId);

      final List<Attachment> files =
          await transfers.attachmentsForMessage(transfer.messageId!);
      expect(files.map((Attachment a) => a.relPath), <String>[
        'sub/f0.bin',
        'sub/f1.bin',
        'sub/f2.bin',
      ]);
      expect(files.map((Attachment a) => a.size), <int>[10, 20, 30]);
      expect(files.map((Attachment a) => a.fileName), <String>[
        'f0.bin',
        'f1.bin',
        'f2.bin',
      ]);
    });

    test('the transfer belongs to the task, not to one of the files', () async {
      // §4.6 rule 3 gives every file in a folder the same `xferId`, so there is
      // no one attachment the attempt could name — and that null is also what
      // tells the two endings apart: `file_done` ends a file, `xfer_done` the
      // task.
      final Transfer transfer = await sendFolder();

      expect(transfer.attachmentId, isNull);
      expect(await transfers.attachmentFor(transfer.id), isNull);
      expect(transfer.bytesTotal, 60);
    });

    test('the folder name is the message body', () async {
      // A single file keeps its name on the attachment. A folder has no
      // attachment of its own to keep one on, and the receiver needs it: it is
      // the directory to create under the download root.
      final Transfer transfer = await sendFolder(folderName: 'holiday');

      final Message message = (await chat.page('peer-1')).single;
      expect(message.text, 'holiday');
      expect(message.id, transfer.messageId);
    });

    test('a single file still has no body at all', () async {
      await outgoing();

      expect((await chat.page('peer-1')).single.text, isNull);
    });

    test('directories get no attachment', () async {
      // They carry no bytes. The receiver rebuilds them from the manifest
      // itself — §4.6 rule 4 — so a row for one would be a file card for
      // something that is not a file.
      final Transfer transfer = await sendFolder();

      final List<Attachment> files =
          await transfers.attachmentsForMessage(transfer.messageId!);
      expect(files.map((Attachment a) => a.relPath), isNot(contains('sub')));
      expect(files, hasLength(3));
    });

    test('a folder of nothing but empty directories is still a folder',
        () async {
      // A real thing to send, and the shape that breaks anything assuming a
      // message with attachments: there are none here.
      final Transfer transfer = await sendFolder(
        entries: const <ManifestEntry>[
          ManifestEntry(relPath: 'empty', size: 0, isDir: true),
          ManifestEntry(relPath: 'also/empty', size: 0, isDir: true),
        ],
      );

      expect(transfer.bytesTotal, 0);
      expect(await transfers.attachmentsForMessage(transfer.messageId!),
          isEmpty);
      expect((await chat.page('peer-1')).single.type, MessageType.folder);
    });

    test('the sender records where each file is on this device', () async {
      final Transfer transfer = await sendFolder(folderPath: '/home/me/holiday');

      final List<Attachment> files =
          await transfers.attachmentsForMessage(transfer.messageId!);
      // Built from the folder's path and the entry's relPath, in this
      // platform's spelling — the relPath is `/`-separated by definition and a
      // local path is not, on Windows.
      expect(
        files.first.localPath,
        '/home/me/holiday${Platform.pathSeparator}sub'
        '${Platform.pathSeparator}f0.bin',
      );
    });

    test('the receiver records no path until a file lands', () async {
      // Where a file goes is decided when it is written, by `FolderLayout` under
      // the download root. A path guessed at offer time would be a prediction
      // the real one replaces.
      final Transfer transfer = await receiveFolder();

      final List<Attachment> files =
          await transfers.attachmentsForMessage(transfer.messageId!);
      expect(files, hasLength(3));
      expect(files.every((Attachment a) => a.localPath == null), isTrue);
      expect(files.every((Attachment a) => a.state == TransferState.offered),
          isTrue);
      expect(transfer.state, TransferState.offered);
    });

    test('a folder in the page brings all of its files, not the last one',
        () async {
      // The regression this shape exists for: a map keyed by message id holding
      // a single attachment keeps whichever row the query returned last, so a
      // folder of nine files would show one of them and call it the folder.
      final Transfer folder = await sendFolder();
      final Transfer plain = await outgoing(xferId: 'x9', fileName: 'a.jpg');

      final Map<String, List<Attachment>> found =
          await transfers.attachmentsForMessages(
              <String>[folder.messageId!, plain.messageId!]);

      expect(found[folder.messageId], hasLength(3));
      expect(found[plain.messageId], hasLength(1));
    });

    test('a folder reads back in path order, not the order it was written in',
        () async {
      // The order comes from the two queries and from nowhere else. A card that
      // listed a folder's files in whatever order the rows came back would
      // reshuffle itself between a fresh open and a refresh — and the sender
      // walks a manifest into sorted order, so the writer's order and the
      // reader's would agree by accident until the first caller that did not.
      final Transfer transfer = await sendFolder(
        entries: const <ManifestEntry>[
          ManifestEntry(relPath: 'sub/z.bin', size: 1),
          ManifestEntry(relPath: 'sub/a.bin', size: 2),
          ManifestEntry(relPath: 'sub/m.bin', size: 3),
        ],
      );

      final List<Attachment> files =
          await transfers.attachmentsForMessage(transfer.messageId!);
      expect(files.map((Attachment a) => a.fileName),
          <String>['a.bin', 'm.bin', 'z.bin']);

      final Map<String, List<Attachment>> page = await transfers
          .attachmentsForMessages(<String>[transfer.messageId!]);
      expect(page[transfer.messageId]!.map((Attachment a) => a.fileName),
          <String>['a.bin', 'm.bin', 'z.bin']);
    });

    test('a folder of empty directories is in the page as no entry at all',
        () async {
      final Transfer folder = await sendFolder(
        entries: const <ManifestEntry>[
          ManifestEntry(relPath: 'empty', size: 0, isDir: true),
        ],
      );

      final Map<String, List<Attachment>> found = await transfers
          .attachmentsForMessages(<String>[folder.messageId!]);

      // Absent, exactly as a text message is: the lookup that misses and the
      // lookup that finds nothing are the same answer.
      expect(found, isEmpty);
    });
  });

  group('a folder ends file by file and then all at once', () {
    List<ManifestEntry> threeFiles = const <ManifestEntry>[
      ManifestEntry(relPath: 'a.bin', size: 10),
      ManifestEntry(relPath: 'b.bin', size: 20),
      ManifestEntry(relPath: 'c.bin', size: 30),
    ];

    Future<Transfer> folder({String xferId = 'xfer-folder'}) {
      return transfers.beginIncomingFolder(
        xferId: xferId,
        peerId: 'peer-1',
        folderName: 'holiday',
        entries: threeFiles,
        now: at(0),
      );
    }

    Future<List<Attachment>> filesOf(Transfer transfer) =>
        transfers.attachmentsForMessage(transfer.messageId!);

    test('a landed file is marked done and given its path', () async {
      final Transfer transfer = await folder();
      final List<Attachment> files = await filesOf(transfer);

      await transfers.finishFile(files[1].id, localPath: '/dl/holiday/b.bin');

      final List<Attachment> after = await filesOf(transfer);
      expect(after[1].state, TransferState.done);
      expect(after[1].localPath, '/dl/holiday/b.bin');
      expect(after[1].progress, 1);
      // Its siblings are untouched: one file arriving is not the folder
      // arriving.
      expect(after[0].state, TransferState.offered);
      expect(after[2].state, TransferState.offered);
    });

    test('a finished file has moved all its bytes', () async {
      final Transfer transfer = await folder();
      final List<Attachment> files = await filesOf(transfer);

      await transfers.finishFile(files[2].id, localPath: '/dl/c.bin');

      // Read from the row rather than supplied by the caller, so it cannot
      // disagree with the size the offer was accepted against.
      expect((await filesOf(transfer))[2].transferred, 30);
    });

    test('finishing an unknown attachment is quiet', () async {
      // A `file_done` for a file whose row was cleared with the history.
      await transfers.finishFile('never-happened', localPath: '/dl/x');
    });

    test('a folder that fails leaves the files that landed alone', () async {
      // The one case that matters. A folder whose third file fails has two files
      // on disk the user can open, and a row saying `failed` is a card that
      // hides them.
      final Transfer transfer = await folder();
      final List<Attachment> files = await filesOf(transfer);
      await transfers.finishFile(files[0].id, localPath: '/dl/a.bin');
      await transfers.finishFile(files[1].id, localPath: '/dl/b.bin');

      await transfers.end(transfer.id,
          state: TransferState.failed, now: at(9));

      final List<Attachment> after = await filesOf(transfer);
      expect(after[0].state, TransferState.done);
      expect(after[1].state, TransferState.done);
      expect(after[2].state, TransferState.failed);
      // Where the landed files are is still written down.
      expect(after[0].localPath, '/dl/a.bin');
    });

    test('a folder that fails before anything lands marks them all', () async {
      final Transfer transfer = await folder();

      await transfers.end(transfer.id,
          state: TransferState.cancelled, now: at(9));

      final List<Attachment> after = await filesOf(transfer);
      expect(
        after.map((Attachment a) => a.state),
        everyElement(TransferState.cancelled),
      );
      expect(transfer.messageId, isNotNull);
      expect((await chat.page('peer-1')).single.status, MessageStatus.failed);
    });

    test('a folder that finishes leaves every file done', () async {
      final Transfer transfer = await folder();
      final List<Attachment> files = await filesOf(transfer);
      for (final Attachment file in files) {
        await transfers.finishFile(file.id, localPath: '/dl/${file.fileName}');
      }

      await transfers.finish(transfer.id, now: at(9));

      expect(
        (await filesOf(transfer)).map((Attachment a) => a.state),
        everyElement(TransferState.done),
      );
      final Transfer after = (await transfers.byId(transfer.id))!;
      expect(after.state, TransferState.done);
      expect(after.bytesDone, 60);
      expect((await chat.page('peer-1')).single.status, MessageStatus.delivered);
    });

    test('the task behind a folder is found by its message', () async {
      final Transfer transfer = await folder();
      // Give it a real byte count, the way the service does on a checkpoint.
      await transfers.recordProgress(
        transfer.id,
        state: TransferState.transferring,
        bytesDone: 25,
        now: at(3),
      );

      final Map<String, Transfer> tasks = await transfers.tasksForMessages(
        <String>[transfer.messageId!],
      );

      expect(tasks, hasLength(1));
      expect(tasks[transfer.messageId]!.id, transfer.id);
      // The number a folder's card has nowhere else to read: no single
      // attachment carries the whole task's progress.
      expect(tasks[transfer.messageId]!.bytesDone, 25);
      expect(tasks[transfer.messageId]!.bytesTotal, 60);
    });

    test('a single file is not a task', () async {
      // Its progress lives on its attachment, and answering here as well would
      // put the same bytes in two places in the state the chat page holds.
      final Transfer single = await transfers.beginIncoming(
        xferId: 'xfer-single',
        peerId: 'peer-1',
        fileName: 'report.pdf',
        totalSize: 100,
        now: at(0),
      );

      expect(
        await transfers.tasksForMessages(<String>[single.messageId!]),
        isEmpty,
      );
    });

    test('the newest attempt at a folder is the one that answers', () async {
      // A retry writes a second row rather than rewriting the first, so a
      // message can have more than one task transfer. The card must show the
      // attempt that is running, not the one that failed.
      final Transfer first = await folder();
      const String second = 'xfer-again';
      await db.into(db.transfers).insert(TransfersCompanion.insert(
            id: second,
            peerId: 'peer-1',
            direction: MessageDirection.incoming.wire,
            state: TransferState.transferring.wire,
            bytesTotal: 60,
            updatedAt: at(30).millisecondsSinceEpoch,
            messageId: Value<String?>(first.messageId),
          ));

      final Map<String, Transfer> tasks =
          await transfers.tasksForMessages(<String>[first.messageId!]);

      expect(tasks[first.messageId!]!.id, second);
    });

    test('a folder of empty directories still has a task', () async {
      // The one shape where a message has a task and no attachments at all, so
      // a card that read the task out of the attachments would find nothing.
      final Transfer transfer = await transfers.beginIncomingFolder(
        xferId: 'xfer-empty',
        peerId: 'peer-1',
        folderName: 'empty',
        entries: const <ManifestEntry>[
          ManifestEntry(relPath: 'a', size: 0, isDir: true),
        ],
        now: at(0),
      );

      expect(
        await transfers.attachmentsForMessage(transfer.messageId!),
        isEmpty,
      );
      expect(
        (await transfers.tasksForMessages(<String>[transfer.messageId!]))
            .keys,
        <String>[transfer.messageId!],
      );
    });

    test('an empty page of messages asks nothing', () async {
      expect(await transfers.tasksForMessages(const <String>[]), isEmpty);
    });

    test('an unpublished folder task is swept up at startup', () async {
      final Transfer transfer = await folder(xferId: 'xfer-running');

      expect(
        (await transfers.unfinished()).map((Transfer t) => t.id),
        contains('xfer-running'),
      );
      expect(transfer.state, TransferState.offered);
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
