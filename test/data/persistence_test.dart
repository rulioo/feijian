import 'dart:io';

import 'package:feijian/core/models/message.dart';
import 'package:feijian/core/models/peer.dart';
import 'package:feijian/data/database.dart';
import 'package:feijian/data/repository/chat_repository.dart';
import 'package:feijian/data/repository/peer_repository.dart';
import 'package:flutter_test/flutter_test.dart';

/// What survives the app being closed and opened again — design.md §11's
/// 「重启后历史仍在」.
///
/// On a real file, because that is the whole question. An in-memory database
/// passes every assertion here while writing nothing to disk at all, so only
/// closing the file and opening the same path again can show that a conversation
/// is durable — and durability is the only thing that makes a message safe to
/// acknowledge (§4.5).
void main() {
  /// When the conversation happened, fixed so the expected order is the one
  /// written here rather than the one the test clock produced.
  final DateTime t0 = DateTime(2026, 1, 2, 9);

  late Directory dir;
  late File file;
  late AppDatabase db;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('feijian_persistence_');
    file = File('${dir.path}${Platform.pathSeparator}feijian.sqlite');
    db = AppDatabase.file(file);
  });

  tearDown(() async {
    await db.close();
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
  });

  /// Closes the database and opens the same file again, the way a restart does.
  Future<void> restart() async {
    await db.close();
    db = AppDatabase.file(file);
  }

  test('a conversation is still there after a restart', () async {
    const String peerId = 'peer-bob';
    ChatRepository chat = ChatRepository(db, clock: () => t0);

    await PeerRepository(db).recordAnnounce(
      const Peer(
        id: peerId,
        name: 'Bob-PC',
        deviceType: DeviceType.android,
        icon: DeviceIcon.phone,
        os: 'Android 14',
        lastIp: '192.168.1.105',
        lastPort: 24250,
        isOnline: true,
      ),
      at: t0,
    );
    await chat.saveOutgoing(
      msgId: 'out-1',
      peerId: peerId,
      text: '在吗 🙂',
      now: t0,
    );
    await chat.storeIncoming(
      msgId: 'in-1',
      peerId: peerId,
      text: 'Hi there',
      now: t0.add(const Duration(minutes: 1)),
    );
    await chat.storeIncoming(
      msgId: 'in-2',
      peerId: peerId,
      text: '第二条',
      now: t0.add(const Duration(minutes: 2)),
    );
    await chat.setStatus(
      'out-1',
      MessageStatus.delivered,
      deliveredAt: t0.add(const Duration(seconds: 30)),
    );
    // Deliberately left `pending`, which is what the offline queue of §5.2 is a
    // list of — a message owed to a peer that was never there to take it.
    await chat.saveOutgoing(
      msgId: 'out-2',
      peerId: peerId,
      text: 'third',
      now: t0.add(const Duration(minutes: 3)),
    );
    await chat.setDraft(peerId, '打了一半');

    await restart();
    chat = ChatRepository(db, clock: () => t0);

    final List<Message> rows = await chat.page(peerId);
    expect(
      rows.map((Message m) => m.text).toList(),
      <String>['third', '第二条', 'Hi there', '在吗 🙂'],
      reason: 'newest first, both directions, and the text is unchanged',
    );
    expect(rows.last.status, MessageStatus.delivered);
    expect(
      rows.last.deliveredAt,
      isNotNull,
      reason: 'when it was acknowledged is part of the record',
    );
    expect(rows.first.status, MessageStatus.pending);
    expect(
      rows.first.direction,
      MessageDirection.outgoing,
      reason: 'whose message it is has to survive too',
    );

    // §5.2 item 6: the queue is read from the database, so what was owed before
    // the app closed is still owed after it opens.
    expect(
      (await chat.pendingFor(peerId)).map((Message m) => m.id).toList(),
      <String>['out-2'],
    );
    expect(await chat.draftFor(peerId), '打了一半');
    expect(
      await chat.unreadCount(peerId),
      2,
      reason: 'the badge is still owed to the user, not reset by a restart',
    );

    final Peer? bob = await PeerRepository(db).byId(peerId);
    expect(bob?.name, 'Bob-PC');
    expect(bob?.lastIp, '192.168.1.105');
    expect(
      bob?.lastPort,
      isNull,
      reason: 'the table stores no port — a peer on a non-default one is '
          'reached by the port it announces, not the one last remembered',
    );
  });

  test('a restart does not append to what is already there', () async {
    const String peerId = 'peer-bob';
    ChatRepository chat = ChatRepository(db);

    await chat.saveOutgoing(
      msgId: 'out-1',
      peerId: peerId,
      text: 'once',
      now: t0,
    );
    await restart();
    // A repository holds the database it was built with, so reopening the file
    // means building one against the connection that is actually open.
    chat = ChatRepository(db);

    // The migration runs on an existing file too, and `createAll` on a database
    // that already has the tables would either throw or wipe them. One row is
    // the proof that neither happened.
    expect(await chat.page(peerId), hasLength(1));
    expect(await PeerRepository(db).count(), 0);
  });
}
