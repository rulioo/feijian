import 'package:feijian/core/models/message.dart';
import 'package:feijian/core/models/peer.dart';
import 'package:feijian/data/dao/message_dao.dart';
import 'package:feijian/data/database.dart';
import 'package:feijian/data/repository/chat_repository.dart';
import 'package:feijian/data/repository/peer_repository.dart';
import 'package:feijian/data/repository/settings_repository.dart';
import 'package:flutter_test/flutter_test.dart';

/// The repository layer: rows in, domain types out — design.md §5.1, §5.2.
///
/// What is worth checking here is the conversion and the transaction, neither of
/// which the DAO tests cover: that a stored message comes back as the same
/// `Message` value, that a peer's runtime-only port is not resurrected from the
/// database, and that a duplicate leaves the unread badge alone.
void main() {
  late AppDatabase db;
  late PeerRepository peers;
  late ChatRepository chat;
  late SettingsRepository settings;

  setUp(() {
    db = AppDatabase.memory();
    peers = PeerRepository(db);
    chat = ChatRepository(db);
    settings = SettingsRepository(db);
  });

  tearDown(() => db.close());

  final DateTime t0 = DateTime.fromMillisecondsSinceEpoch(1700000000000);
  DateTime at(int ms) => t0.add(Duration(milliseconds: ms));

  Peer announced({
    String id = 'peer-1',
    String name = 'Laptop',
    DeviceType type = DeviceType.windows,
    DeviceIcon icon = DeviceIcon.desktop,
    String? os = 'Windows 11',
    String? ip = '192.168.1.20',
    int? port,
  }) {
    return Peer(
      id: id,
      name: name,
      deviceType: type,
      icon: icon,
      os: os,
      lastIp: ip,
      lastPort: port,
      isOnline: true,
    );
  }

  group('PeerRepository', () {
    test('an announce round-trips into a Peer', () async {
      await peers.recordAnnounce(
        announced(icon: DeviceIcon.laptop, port: 24250),
        at: t0,
      );

      final Peer stored = (await peers.byId('peer-1'))!;
      expect(stored.name, 'Laptop');
      expect(stored.deviceType, DeviceType.windows);
      expect(stored.icon, DeviceIcon.laptop);
      expect(stored.os, 'Windows 11');
      expect(stored.lastIp, '192.168.1.20');
      expect(stored.lastSeen, t0);
      expect(stored.isTrusted, isFalse);
    });

    test('a peer read back is never online and has no port', () async {
      // Both are runtime facts about the current LAN session. A port recovered
      // from the database would be where the peer listened last time, and
      // dialling it after a restart is how a connect hangs for two seconds
      // (§4.4.1) against an address nobody is listening on.
      await peers.recordAnnounce(announced(port: 24250), at: t0);

      final Peer stored = (await peers.byId('peer-1'))!;
      expect(stored.lastPort, isNull);
      expect(stored.isOnline, isFalse);
    });

    test('an unknown stored icon falls back by device type', () async {
      // The row could have been written by a build with more icons, or edited by
      // hand. A phone showing a desktop icon is a worse failure than a guess.
      await peers.recordAnnounce(
        announced(type: DeviceType.android, icon: DeviceIcon.phone),
        at: t0,
      );
      await db.customStatement(
        "UPDATE peer SET icon = 'wallpaper' WHERE id = 'peer-1'",
      );

      expect((await peers.byId('peer-1'))!.icon, DeviceIcon.phone);
    });

    test('announces accumulate into one row per device', () async {
      await peers.recordAnnounce(announced(), at: t0);
      await peers.recordAnnounce(
        announced(name: 'Living room laptop', ip: '192.168.1.44'),
        at: at(5000),
      );

      final List<Peer> all = await peers.known();
      expect(all, hasLength(1));
      expect(all.single.name, 'Living room laptop');
      expect(all.single.lastSeen, at(5000));
    });

    test('trust survives an announce, and forgetting keeps the history',
        () async {
      await peers.recordAnnounce(announced(), at: t0);
      await peers.setTrusted('peer-1', true);
      await peers.recordAnnounce(announced(), at: at(1000));
      expect((await peers.trusted()).single.id, 'peer-1');

      await chat.saveOutgoing(
        msgId: 'm1',
        peerId: 'peer-1',
        text: 'hello',
        now: t0,
      );
      expect(await peers.forget('peer-1'), 1);
      expect(await peers.byId('peer-1'), isNull);
      expect(await chat.page('peer-1'), hasLength(1));
    });

    test('renaming is stored but the device has the last word', () async {
      await peers.recordAnnounce(announced(), at: t0);
      await peers.rename('peer-1', 'Dave’s laptop');
      expect((await peers.byId('peer-1'))!.name, 'Dave’s laptop');

      // The device renames itself; from here the row says what the device says.
      await peers.recordAnnounce(announced(name: 'DAVE-PC'), at: at(1000));
      expect((await peers.byId('peer-1'))!.name, 'DAVE-PC');
    });
  });

  group('ChatRepository', () {
    test('an outgoing message comes back as the same Message', () async {
      final Message sent = await chat.saveOutgoing(
        msgId: 'm1',
        peerId: 'peer-1',
        text: '你好 world 🎉',
        now: t0,
      );

      expect(sent.status, MessageStatus.pending);
      expect(sent.direction, MessageDirection.outgoing);
      expect(sent.createdAt, t0);

      final Message stored = (await chat.page('peer-1')).single;
      expect(stored, sent, reason: 'value equality, field for field');
    });

    test('sending bumps the conversation so the list can sort by it', () async {
      await chat.saveOutgoing(
        msgId: 'm1',
        peerId: 'peer-1',
        text: 'hi',
        now: t0,
      );
      expect(await peers.count(), 0, reason: 'no peer row was needed');
      final ConversationRow row =
          (await MessageDao(db).conversationFor('peer-1'))!;
      expect(row.lastMsgAt, t0.millisecondsSinceEpoch);
      expect(row.unreadCount, 0, reason: 'our own message is not unread');
    });

    test('a first incoming message creates the conversation and the badge',
        () async {
      final bool isNew = await chat.storeIncoming(
        msgId: 'm1',
        peerId: 'peer-1',
        text: '在吗',
        now: t0,
      );

      expect(isNew, isTrue);
      expect(await chat.unreadCount('peer-1'), 1);
      expect((await chat.page('peer-1')).single.status, MessageStatus.received);
    });

    test('a re-sent message is refused, and does not count again', () async {
      // §4.5: the peer retries because it never saw an ack. The second copy is
      // not a new message, and counting it would inflate the badge every time a
      // message crossed a flaky connection.
      Future<bool> deliver() => chat.storeIncoming(
            msgId: 'm1',
            peerId: 'peer-1',
            text: '在吗',
            now: t0,
          );

      expect(await deliver(), isTrue);
      expect(await deliver(), isFalse);
      expect(await chat.unreadCount('peer-1'), 1);
      expect(await chat.page('peer-1'), hasLength(1));
    });

    test('reading clears the badge but keeps the messages', () async {
      await chat.storeIncoming(msgId: 'm1', peerId: 'peer-1', text: '一', now: t0);
      await chat.storeIncoming(
        msgId: 'm2',
        peerId: 'peer-1',
        text: '二',
        now: at(1),
      );
      expect(await chat.unreadCount('peer-1'), 2);

      await chat.markRead('peer-1');
      expect(await chat.unreadCount('peer-1'), 0);
      expect(await chat.page('peer-1'), hasLength(2));
    });

    test('history pages backwards, newest first, without repeating', () async {
      for (int i = 0; i < 5; i++) {
        await chat.saveOutgoing(
          msgId: 'm$i',
          peerId: 'peer-1',
          text: '$i',
          // Two of these land in the same millisecond, as a burst flushed from
          // the offline queue would.
          now: at(i ~/ 2),
        );
      }

      final List<Message> first = await chat.page('peer-1', limit: 2);
      expect(
        first.map((Message m) => m.id),
        <String>['m4', 'm3'],
        reason: 'newest first, ties broken by id descending',
      );

      final List<Message> second = await chat.page(
        'peer-1',
        before: ChatRepository.cursorBefore(first),
        limit: 2,
      );
      expect(second.map((Message m) => m.id), <String>['m2', 'm1']);

      final List<Message> third = await chat.page(
        'peer-1',
        before: ChatRepository.cursorBefore(second),
        limit: 2,
      );
      expect(third.map((Message m) => m.id), <String>['m0']);

      expect(ChatRepository.cursorBefore(<Message>[]), isNull);
    });

    test('the conversation preview is the newest message', () async {
      expect(await chat.lastMessage('peer-1'), isNull);

      await chat.saveOutgoing(
        msgId: 'm1',
        peerId: 'peer-1',
        text: 'older',
        now: t0,
      );
      await chat.storeIncoming(
        msgId: 'm2',
        peerId: 'peer-1',
        text: 'newer',
        now: at(10),
      );

      expect((await chat.lastMessage('peer-1'))!.text, 'newer');
    });

    test('three messages written in the same millisecond keep their order',
        () async {
      // Not a contrived clock: `created_at` *is* a millisecond, and a queue
      // flushing after a reconnect writes its whole backlog inside one. The
      // order used to fall through to `id` — a random v4 UUID — so the three
      // came out in a different order run to run, and the peer displayed them
      // shuffled. Passing the same `now` every time is how that is tested
      // without waiting for the clock to cooperate.
      for (final String text in <String>['一', '二', '三']) {
        await chat.saveOutgoing(
          msgId: 'm-$text',
          peerId: 'peer-1',
          text: text,
          now: t0,
        );
      }

      expect(
        (await chat.pendingFor('peer-1')).map((Message m) => m.text),
        <String>['一', '二', '三'],
        reason: 'oldest first — the order they are re-sent in',
      );
      expect(
        (await chat.page('peer-1')).map((Message m) => m.text),
        <String>['三', '二', '一'],
        reason: 'and newest first on the page, which is that order reversed',
      );
    });

    test('a burst of incoming messages keeps its order too', () async {
      // The receiving side of the same collision: an incoming message is
      // stamped with the *receiver's* clock (§4.5), so a burst that arrives
      // together lands in one millisecond no matter how far apart it was typed.
      for (final String text in <String>['一', '二', '三']) {
        await chat.storeIncoming(
          msgId: 'm-$text',
          peerId: 'peer-1',
          text: text,
          now: t0,
        );
      }

      expect(
        (await chat.page('peer-1')).map((Message m) => m.text),
        <String>['三', '二', '一'],
        reason: 'newest first, so the conversation reads in arrival order',
      );
    });

    test('the resend queue is per peer, oldest first, and survives a restart',
        () async {
      // Written out of chronological order on purpose, so that "sorted by
      // time" and "sorted by when it was stored" cannot both pass. The skew is
      // *across* conversations rather than inside one, because a message can no
      // longer be stored behind its conversation's newest — that is what makes
      // same-millisecond messages orderable at all (see ChatRepository._orderedAt).
      await chat.saveOutgoing(
        msgId: 'other',
        peerId: 'peer-2',
        text: 'elsewhere',
        now: at(1500),
      );
      await chat.saveOutgoing(
        msgId: 'm1',
        peerId: 'peer-1',
        text: 'first',
        now: at(1000),
      );
      await chat.saveOutgoing(
        msgId: 'm2',
        peerId: 'peer-1',
        text: 'second',
        now: at(2000),
      );
      // One that did get through, so it must not be re-sent.
      await chat.setStatus('m2', MessageStatus.delivered, deliveredAt: at(3000));

      expect(
        (await chat.pendingFor('peer-1')).map((Message m) => m.id),
        <String>['m1'],
      );
      expect(
        (await chat.allPending()).map((Message m) => m.id),
        <String>['m1', 'other'],
        reason: 'oldest first across peers, for the sweep after a restart',
      );
    });

    test('a message the peer received stops being owed', () async {
      await chat.saveOutgoing(
        msgId: 'm1',
        peerId: 'peer-1',
        text: 'hi',
        now: t0,
      );

      expect(await chat.setStatus('m1', MessageStatus.sent), isTrue);
      expect(await chat.setStatus(
        'm1',
        MessageStatus.delivered,
        deliveredAt: at(50),
      ), isTrue);
      // A resend's timeout firing after the ack arrived.
      expect(await chat.setStatus('m1', MessageStatus.sent), isFalse);

      final Message stored = (await chat.page('peer-1')).single;
      expect(stored.status, MessageStatus.delivered);
      expect(stored.deliveredAt, at(50));
      expect(await chat.pendingFor('peer-1'), isEmpty);
    });

    test('retrying a failed message puts it back in the queue fresh', () async {
      await chat.saveOutgoing(
        msgId: 'm1',
        peerId: 'peer-1',
        text: 'hi',
        now: t0,
      );
      await chat.setStatus('m1', MessageStatus.failed, retryCount: 3);
      expect((await chat.page('peer-1')).single.canRetry, isTrue);

      expect(await chat.requeue('m1'), isTrue);
      final Message requeued = (await chat.page('peer-1')).single;
      expect(requeued.status, MessageStatus.pending);
      expect(
        requeued.retryCount,
        0,
        reason: 'the user asking again is a fresh decision, not attempt four',
      );
      expect(await chat.pendingFor('peer-1'), hasLength(1));
    });

    test('a draft round-trips, and is separate from the messages', () async {
      expect(await chat.draftFor('peer-1'), isNull);
      await chat.saveOutgoing(
        msgId: 'm1',
        peerId: 'peer-1',
        text: 'sent',
        now: t0,
      );

      await chat.setDraft('peer-1', 'half typed…');
      expect(await chat.draftFor('peer-1'), 'half typed…');

      await chat.setDraft('peer-1', null);
      expect(await chat.draftFor('peer-1'), isNull);
    });

    test('a draft survives in a conversation with no messages yet', () async {
      // The first message anyone types to a newly discovered device: the
      // conversation row does not exist until a message is stored, and the
      // round-trip above only ever ran after one was — which is how a draft
      // written into a plain `UPDATE` of a missing row went unnoticed.
      await chat.setDraft('peer-1', 'half typed…');

      expect(await chat.draftFor('peer-1'), 'half typed…');
      expect(
        await chat.page('peer-1'),
        isEmpty,
        reason: 'a draft is not a message and must not appear in the history',
      );
      expect(await chat.lastMessage('peer-1'), isNull);
      expect(
        await chat.unreadByPeer(),
        containsPair('peer-1', 0),
        reason: 'nor may it ring the unread badge',
      );
    });

    test('an empty draft is stored as no draft at all', () async {
      await chat.setDraft('peer-1', 'typed');
      await chat.setDraft('peer-1', '');

      expect(
        await chat.draftFor('peer-1'),
        isNull,
        reason: 'an empty string would put an empty composer in front of a '
            'conversation that has nothing to restore',
      );
    });

    test('deleting a message leaves the conversation summary alone', () async {
      await chat.saveOutgoing(
        msgId: 'm1',
        peerId: 'peer-1',
        text: 'hi',
        now: t0,
      );
      expect(await chat.deleteMessage('m1'), 1);
      expect(await chat.page('peer-1'), isEmpty);
      expect(await chat.lastMessage('peer-1'), isNull);
    });

    test('clearing the history keeps the device and the draft', () async {
      // §6.3's 「删除本地记录」 at conversation scope. The row that survives is
      // the point: the conversation still exists, so the device stays in the
      // list and the half-typed message in the composer is still there after a
      // restart — a draft is not history.
      await chat.saveOutgoing(
        msgId: 'm1',
        peerId: 'peer-1',
        text: 'one',
        now: t0,
      );
      await chat.storeIncoming(
        msgId: 'm2',
        peerId: 'peer-1',
        text: '二',
        now: at(1),
      );
      await chat.setDraft('peer-1', 'half typed…');
      expect(await chat.unreadCount('peer-1'), 1);

      expect(await chat.clearHistory('peer-1'), 2);

      expect(await chat.page('peer-1'), isEmpty);
      expect(
        await chat.lastMessage('peer-1'),
        isNull,
        reason: 'the list previews the newest message, and there is none',
      );
      expect(await chat.unreadCount('peer-1'), 0);
      expect(await chat.draftFor('peer-1'), 'half typed…');
      expect(
        await MessageDao(db).conversationFor('peer-1'),
        isNotNull,
        reason: 'clearing history is not forgetting the device',
      );
    });

    test('clearing one conversation leaves the others alone', () async {
      await chat.saveOutgoing(
        msgId: 'm1',
        peerId: 'peer-1',
        text: 'here',
        now: t0,
      );
      await chat.saveOutgoing(
        msgId: 'm2',
        peerId: 'peer-2',
        text: 'elsewhere',
        now: at(1),
      );

      expect(await chat.clearHistory('peer-1'), 1);
      expect(await chat.page('peer-1'), isEmpty);
      expect(await chat.page('peer-2'), hasLength(1));
      expect(await chat.lastMessage('peer-2'), isNotNull);
    });

    test('clearing history cancels a message the peer is still owed', () async {
      // A `pending` row is a debt to the peer (§5.2). Deleting it is how the
      // user calls the send off, so it must not come back on the next flush.
      await chat.saveOutgoing(
        msgId: 'm1',
        peerId: 'peer-1',
        text: 'never mind',
        now: t0,
      );
      expect(await chat.pendingFor('peer-1'), hasLength(1));

      await chat.clearHistory('peer-1');

      expect(await chat.pendingFor('peer-1'), isEmpty);
      expect(await chat.allPending(), isEmpty);
    });
  });

  group('SettingsRepository', () {
    test('typed values round-trip', () async {
      await settings.putString(SettingKeys.displayName, '书房的电脑');
      await settings.putBool(SettingKeys.notificationsEnabled, false);
      await settings.putInt(SettingKeys.listenPort, 24250);

      expect(await settings.getString(SettingKeys.displayName), '书房的电脑');
      expect(await settings.getBool(SettingKeys.notificationsEnabled), isFalse);
      expect(await settings.getInt(SettingKeys.listenPort), 24250);
    });

    test('a missing key reads as null, not as a default', () async {
      // The caller decides the default: only it knows whether an unset port
      // means "pick one" or "use 24250".
      expect(await settings.getString('nope'), isNull);
      expect(await settings.getBool('nope'), isNull);
      expect(await settings.getInt('nope'), isNull);
    });

    test('a value that does not parse reads as unset', () async {
      // Startup reads settings; a hand-edited file must not stop it.
      await settings.putString(SettingKeys.listenPort, 'twenty-four thousand');
      await settings.putString(SettingKeys.notificationsEnabled, 'yes');

      expect(await settings.getInt(SettingKeys.listenPort), isNull);
      expect(await settings.getBool(SettingKeys.notificationsEnabled), isNull);
    });

    test('an enum is read back by its wire value', () async {
      await settings.putString(
        SettingKeys.deviceIcon,
        DeviceIcon.laptop.wire,
      );

      expect(
        await settings.getEnum(
          SettingKeys.deviceIcon,
          (String raw) => DeviceIcon.values
              .where((DeviceIcon i) => i.wire == raw)
              .firstOrNull,
        ),
        DeviceIcon.laptop,
      );
      expect(
        await settings.getEnum(
          'nope',
          (String raw) => DeviceIcon.values
              .where((DeviceIcon i) => i.wire == raw)
              .firstOrNull,
        ),
        isNull,
      );
    });

    test('writing the same key twice updates rather than failing', () async {
      await settings.putInt(SettingKeys.listenPort, 1);
      await settings.putInt(SettingKeys.listenPort, 2);

      expect(await settings.getInt(SettingKeys.listenPort), 2);
      expect(await settings.all(), hasLength(1));
    });

    test('a whole form is written as one unit', () async {
      await settings.putAll(<String, String>{
        SettingKeys.displayName: 'Study PC',
        SettingKeys.listenPort: '24250',
        SettingKeys.languageCode: 'en',
      });

      expect(await settings.all(), hasLength(3));
      expect(await settings.remove(SettingKeys.languageCode), 1);
      expect(await settings.all(), hasLength(2));
    });
  });
}
