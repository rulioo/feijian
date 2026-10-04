// `hide` because drift also exports `isNull`/`isNotNull` as query builders, and
// the matchers of the same name are what these tests mean by them.
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:feijian/data/dao/message_dao.dart';
import 'package:feijian/data/dao/peer_dao.dart';
import 'package:feijian/data/database.dart';
import 'package:flutter_test/flutter_test.dart';
// Prefixed: this is only here to name the error SQLite raises, and the package
// defines plenty of names that would collide with drift's.
import 'package:sqlite3/sqlite3.dart' as sqlite3;

/// The schema and the DAOs, against a real in-memory SQLite — design.md §5.1.
///
/// A real database rather than a mock, because the things worth checking here
/// are the ones only SQLite can answer: whether the `REFERENCES` clauses
/// actually cascade, whether `insertOrIgnore` really is idempotent, whether a
/// compound cursor returns a stable page. A fake would confirm the code calls
/// the methods it calls.
void main() {
  late AppDatabase db;
  late PeerDao peers;
  late MessageDao messages;

  setUp(() {
    db = AppDatabase.memory();
    peers = PeerDao(db);
    messages = MessageDao(db);
  });

  tearDown(() => db.close());

  /// The `CREATE TABLE` SQLite actually stored, for checking the column names
  /// the design document specifies.
  Future<String> schemaOf(String table) async {
    final QueryRow row = await db
        .customSelect(
          "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?",
          variables: <Variable<Object>>[Variable<String>(table)],
        )
        .getSingle();
    return row.read<String>('sql');
  }

  group('schema', () {
    test('every table from the design is created', () async {
      final List<QueryRow> tables = await db
          .customSelect(
            "SELECT name FROM sqlite_master WHERE type = 'table' "
            "AND name NOT LIKE 'sqlite_%' ORDER BY name",
          )
          .get();

      expect(
        tables.map((QueryRow r) => r.read<String>('name')),
        containsAll(<String>[
          'peer',
          'conversation',
          'message',
          'attachment',
          'transfer',
          'setting',
        ]),
      );
    });

    test('snake_case column names survive into the SQL', () async {
      // The Dart accessors are camelCase; `.named()` is what keeps the file
      // matching the design document, and getting one wrong is invisible until
      // someone reads the database by hand.
      final String peer = await schemaOf('peer');
      expect(peer, contains('device_type'));
      expect(peer, contains('last_ip'));
      expect(peer, contains('last_seen'));
      expect(peer, contains('is_trusted'));

      final String message = await schemaOf('message');
      expect(message, contains('conversation_id'));
      expect(message, contains('created_at'));
      expect(message, contains('delivered_at'));
      expect(message, contains('retry_count'));
      // `text` is the column name even though the Dart getter had to be called
      // something else to avoid shadowing drift's `text()` builder.
      expect(message, contains('text'));

      final String attachment = await schemaOf('attachment');
      expect(attachment, contains('file_name'));
      expect(attachment, contains('rel_path'));
      expect(attachment, contains('local_path'));
    });

    test('the history index is descending on created_at', () async {
      final QueryRow row = await db
          .customSelect(
            "SELECT sql FROM sqlite_master WHERE type = 'index' "
            "AND name = 'idx_message_conv'",
          )
          .getSingle();
      final String sql = row.read<String?>('sql') ?? '';
      expect(sql, contains('conversation_id'));
      expect(sql, contains('created_at DESC'));
    });

    test('foreign keys are enforced, not decorative', () async {
      // SQLite has them off by default, so this is really a test that
      // `beforeOpen` ran. Without it the cascade below silently does nothing
      // and attachments outlive the messages they belong to.
      await expectLater(
        db.customStatement(
          "INSERT INTO attachment (id, message_id, file_name, size, state) "
          "VALUES ('a1', 'no-such-message', 'x.txt', 1, 'pending')",
        ),
        throwsA(isA<sqlite3.SqliteException>()),
      );
    });

    test('deleting a message takes its attachments with it', () async {
      await peers.recordSeen(id: 'p1', name: 'Laptop', deviceType: 'windows');
      final ConversationRow conversation =
          await messages.ensureConversation('p1', now: 1000);
      await messages.insertMessage(MessagesCompanion.insert(
        id: 'm1',
        conversationId: conversation.id,
        peerId: 'p1',
        direction: 'in',
        type: 'file',
        status: 'received',
        createdAt: 1000,
      ));
      await db.into(db.attachments).insert(AttachmentsCompanion.insert(
            id: 'a1',
            messageId: 'm1',
            fileName: 'report.pdf',
            size: 4096,
            state: 'done',
          ));

      expect(await db.select(db.attachments).get(), hasLength(1));
      await messages.deleteById('m1');
      expect(await db.select(db.attachments).get(), isEmpty);
    });
  });

  group('PeerDao.recordSeen', () {
    test('creates a row and then updates it', () async {
      await peers.recordSeen(
        id: 'p1',
        name: 'Laptop',
        deviceType: 'windows',
        os: 'Windows 11',
        icon: 'laptop',
        lastIp: '192.168.1.20',
        lastSeen: 1000,
      );
      await peers.recordSeen(
        id: 'p1',
        name: 'Renamed Laptop',
        deviceType: 'windows',
        os: 'Windows 11 24H2',
        icon: 'desktop',
        lastIp: '192.168.1.21',
        lastSeen: 2000,
      );

      expect(await peers.count(), 1);
      final PeerRow row = (await peers.byId('p1'))!;
      expect(row.name, 'Renamed Laptop');
      expect(row.os, 'Windows 11 24H2');
      expect(row.lastIp, '192.168.1.21');
      expect(row.lastSeen, 2000);
    });

    test('does not undo the trust the user granted', () async {
      // Announces arrive every five seconds. If recording one reset
      // `is_trusted`, the setting would appear to work and then quietly revert.
      await peers.recordSeen(id: 'p1', name: 'Laptop', deviceType: 'windows');
      await peers.setTrusted('p1', true);

      await peers.recordSeen(id: 'p1', name: 'Laptop', deviceType: 'windows');

      expect((await peers.byId('p1'))!.isTrusted, isTrue);
      expect(await peers.trusted(), hasLength(1));
    });

    test('a peer that stops reporting an os clears it', () async {
      // Absent means "the peer does not say", and keeping a stale value would
      // show an OS the device no longer claims.
      await peers.recordSeen(
        id: 'p1',
        name: 'Laptop',
        deviceType: 'windows',
        os: 'Windows 11',
      );
      await peers.recordSeen(id: 'p1', name: 'Laptop', deviceType: 'unknown');

      final PeerRow row = (await peers.byId('p1'))!;
      expect(row.os, isNull);
      expect(row.deviceType, 'unknown');
    });

    test('forgetting a peer leaves the conversation behind', () async {
      // Losing a conversation because a device left the network is not what
      // "forget this device" means.
      await peers.recordSeen(id: 'p1', name: 'Laptop', deviceType: 'windows');
      final ConversationRow conversation =
          await messages.ensureConversation('p1', now: 1000);
      await messages.insertMessage(MessagesCompanion.insert(
        id: 'm1',
        conversationId: conversation.id,
        peerId: 'p1',
        direction: 'in',
        type: 'text',
        body: const Value<String>('hi'),
        status: 'received',
        createdAt: 1000,
      ));

      expect(await peers.forget('p1'), 1);
      expect(await peers.byId('p1'), isNull);
      expect(await messages.byId('m1'), isNotNull);
    });
  });

  group('MessageDao', () {
    Future<ConversationRow> conversation(String peerId) async {
      await peers.recordSeen(
        id: peerId,
        name: peerId,
        deviceType: 'windows',
      );
      return messages.ensureConversation(peerId, now: 1000);
    }

    test('a conversation is created once and reused', () async {
      final ConversationRow first = await conversation('p1');
      final ConversationRow again = await messages.ensureConversation('p1', now: 9999);

      expect(again.id, first.id);
      expect(again.createdAt, 1000, reason: 'the original creation time stands');
      expect(await db.select(db.conversations).get(), hasLength(1));
    });

    test('the first message either way creates the conversation', () async {
      // Nothing on the wire carries a conversation id, so the first thing that
      // happens on a new contact is a message arriving unsolicited.
      await peers.recordSeen(id: 'p9', name: 'Phone', deviceType: 'android');
      final ConversationRow row = await messages.ensureConversation('p9', now: 500);
      expect(row.id, MessageDao.conversationIdFor('p9'));
      expect(row.unreadCount, 0);
    });

    test('re-inserting the same msgId is refused and reported', () async {
      // This is what makes a retry in §4.5 harmless rather than a duplicate
      // bubble: the sender reuses the msgId, so the row collides.
      final ConversationRow c = await conversation('p1');
      MessagesCompanion incoming() => MessagesCompanion.insert(
            id: 'm1',
            conversationId: c.id,
            peerId: 'p1',
            direction: 'in',
            type: 'text',
            body: const Value<String>('你好'),
            status: 'received',
            createdAt: 1000,
          );

      expect(await messages.insertMessage(incoming()), isTrue);
      expect(await messages.insertMessage(incoming()), isFalse);
      expect(await messages.countIn(c.id), 1);
      expect((await messages.byId('m1'))!.body, '你好');
    });

    test('pages backwards through history without repeating or skipping', () async {
      final ConversationRow c = await conversation('p1');
      // Two messages share a millisecond, which is the normal case for a burst
      // flushed from the offline queue rather than a corner case.
      final List<(String, int)> history = <(String, int)>[
        ('m1', 1000),
        ('m2', 1000),
        ('m3', 1001),
        ('m4', 1002),
        ('m5', 1002),
      ];
      for (final (String id, int at) in history) {
        await messages.insertMessage(MessagesCompanion.insert(
          id: id,
          conversationId: c.id,
          peerId: 'p1',
          direction: 'in',
          type: 'text',
          status: 'received',
          createdAt: at,
        ));
      }

      final List<String> seen = <String>[];
      MessageCursor? cursor;
      for (int page = 0; page < 3; page++) {
        final List<MessageRow> rows =
            await messages.page(c.id, before: cursor, limit: 2);
        if (rows.isEmpty) {
          break;
        }
        seen.addAll(rows.map((MessageRow r) => r.id));
        cursor = MessageCursor(
          createdAt: rows.last.createdAt,
          id: rows.last.id,
        );
      }

      expect(seen, hasLength(history.length));
      expect(seen.toSet(), hasLength(history.length), reason: 'no repeats');
      // Newest first, and the tie between m1/m2 and between m4/m5 broken by id.
      expect(seen, <String>['m5', 'm4', 'm3', 'm2', 'm1']);
    });

    test('a page is scoped to its conversation', () async {
      final ConversationRow a = await conversation('p1');
      final ConversationRow b = await conversation('p2');
      await messages.insertMessage(MessagesCompanion.insert(
        id: 'in-a',
        conversationId: a.id,
        peerId: 'p1',
        direction: 'in',
        type: 'text',
        status: 'received',
        createdAt: 1,
      ));
      await messages.insertMessage(MessagesCompanion.insert(
        id: 'in-b',
        conversationId: b.id,
        peerId: 'p2',
        direction: 'in',
        type: 'text',
        status: 'received',
        createdAt: 2,
      ));

      final List<MessageRow> page = await messages.page(a.id);
      expect(page.map((MessageRow r) => r.id), <String>['in-a']);
    });

    test('pendingFor returns only what we still owe that peer, oldest first',
        () async {
      final ConversationRow c = await conversation('p1');
      Future<void> put(String id, String status, String direction, int at) {
        return messages.insertMessage(MessagesCompanion.insert(
          id: id,
          conversationId: c.id,
          peerId: 'p1',
          direction: direction,
          type: 'text',
          status: status,
          createdAt: at,
        ));
      }

      await put('owed-late', 'pending', 'out', 2000);
      await put('owed-early', 'pending', 'out', 1000);
      await put('already-sent', 'sent', 'out', 1500);
      await put('theirs', 'received', 'in', 1600);

      final List<MessageRow> owed = await messages.pendingFor('p1');
      expect(
        owed.map((MessageRow r) => r.id),
        <String>['owed-early', 'owed-late'],
        reason: 'oldest first, and nothing already sent or received',
      );
      expect(await messages.allPending(), hasLength(2));
    });

    test('a late ack cannot walk a delivered message back to sent', () async {
      final ConversationRow c = await conversation('p1');
      await messages.insertMessage(MessagesCompanion.insert(
        id: 'm1',
        conversationId: c.id,
        peerId: 'p1',
        direction: 'out',
        type: 'text',
        status: 'sent',
        createdAt: 1000,
      ));

      expect(await messages.setStatus('m1', 'delivered', deliveredAt: 1500), 1);
      // A resend's timeout firing after the ack arrived.
      expect(await messages.setStatus('m1', 'sent'), 0);

      final MessageRow row = (await messages.byId('m1'))!;
      expect(row.status, 'delivered');
      expect(row.deliveredAt, 1500);
    });

    test('a late ack is allowed to correct a failed message', () async {
      // The one transition the state machine allows backwards, because it is
      // the truth: the message did arrive, only the ack was slow.
      final ConversationRow c = await conversation('p1');
      await messages.insertMessage(MessagesCompanion.insert(
        id: 'm1',
        conversationId: c.id,
        peerId: 'p1',
        direction: 'out',
        type: 'text',
        status: 'failed',
        createdAt: 1000,
      ));

      expect(await messages.setStatus('m1', 'delivered', deliveredAt: 2000), 1);
      expect((await messages.byId('m1'))!.status, 'delivered');
    });

    test('an unrelated status change does not erase deliveredAt', () async {
      final ConversationRow c = await conversation('p1');
      await messages.insertMessage(MessagesCompanion.insert(
        id: 'm1',
        conversationId: c.id,
        peerId: 'p1',
        direction: 'out',
        type: 'text',
        status: 'sent',
        createdAt: 1000,
      ));
      await messages.setStatus('m1', 'delivered', deliveredAt: 1500);
      await messages.setStatus('m1', 'delivered', retryCount: 2);

      final MessageRow row = (await messages.byId('m1'))!;
      expect(row.deliveredAt, 1500, reason: 'still the time it arrived');
      expect(row.retryCount, 2);
    });

    test('last_msg_at only moves forward', () async {
      // An offline queue flushing after a reconnect inserts messages whose
      // timestamps are older than what is already in the conversation. Letting
      // those move `last_msg_at` backwards would drop the conversation down the
      // device list for no reason the user can see.
      final ConversationRow c = await conversation('p1');
      await messages.bumpConversation(c.id, lastMsgAt: 5000);
      await messages.bumpConversation(c.id, lastMsgAt: 3000);

      expect((await messages.conversationById(c.id))!.lastMsgAt, 5000);
    });

    test('unread counts only rise when asked', () async {
      final ConversationRow c = await conversation('p1');
      await messages.bumpConversation(c.id, lastMsgAt: 100, unread: true);
      await messages.bumpConversation(c.id, lastMsgAt: 200, unread: true);
      // Sending our own message does not add to our own unread badge.
      await messages.bumpConversation(c.id, lastMsgAt: 300);

      expect((await messages.conversationById(c.id))!.unreadCount, 2);

      await messages.markRead(c.id);
      expect((await messages.conversationById(c.id))!.unreadCount, 0);
    });

    test('a draft round-trips and can be cleared', () async {
      final ConversationRow c = await conversation('p1');
      await messages.setDraft('p1', 'half a thought', now: 1000);
      expect((await messages.conversationById(c.id))!.draft, 'half a thought');

      await messages.setDraft('p1', null, now: 1000);
      expect((await messages.conversationById(c.id))!.draft, isNull);
    });

    test('clearing a conversation takes its attachments and stops the preview',
        () async {
      final ConversationRow c = await conversation('p1');
      await messages.insertMessage(MessagesCompanion.insert(
        id: 'm1',
        conversationId: c.id,
        peerId: 'p1',
        direction: 'in',
        type: 'file',
        status: 'received',
        createdAt: 1000,
      ));
      await db.into(db.attachments).insert(AttachmentsCompanion.insert(
            id: 'a1',
            messageId: 'm1',
            fileName: 'report.pdf',
            size: 4096,
            state: 'done',
          ));
      await messages.bumpConversation(c.id, lastMsgAt: 1000, unread: true);

      expect(await messages.clearIn(c.id), 1);

      expect(await db.select(db.attachments).get(), isEmpty,
          reason: 'the cascade is what stops a transfer outliving its message');
      final ConversationRow after = (await messages.conversationById(c.id))!;
      expect(
        after.lastMsgAt,
        isNull,
        reason: 'a summary of messages that no longer exist',
      );
      expect(after.unreadCount, 0);
    });

    test('a draft needs no message to exist first', () async {
      // Typing the opening message to a device nobody has messaged yet is the
      // ordinary case, and the conversation row is created by the message that
      // follows it — so a draft has to be able to arrive before its own
      // conversation does, rather than updating a row that is not there.
      expect(await messages.conversationFor('p1'), isNull);

      await messages.setDraft('p1', 'first word', now: 1000);

      final ConversationRow? c = await messages.conversationFor('p1');
      expect(c, isNotNull);
      expect(c!.draft, 'first word');
      expect(c.peerId, 'p1');
      expect(
        c.createdAt,
        1000,
        reason: 'the conversation dates from the first thing said in it',
      );
      expect(
        c.lastMsgAt,
        isNull,
        reason: 'a draft is not a message and must not sort the list by it',
      );
      expect(c.unreadCount, 0);
    });
  });
}
