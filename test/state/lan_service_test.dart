import 'dart:async';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:feijian/core/constants.dart';
import 'package:feijian/core/discovery/peer_source.dart';
import 'package:feijian/core/models/message.dart';
import 'package:feijian/core/models/peer.dart';
import 'package:feijian/core/protocol/payloads.dart';
import 'package:feijian/core/transport/connection_manager.dart';
import 'package:feijian/data/database.dart';
import 'package:feijian/data/repository/chat_repository.dart';
import 'package:feijian/data/repository/peer_repository.dart';
import 'package:feijian/state/lan_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../core/transport_harness.dart';

/// Two devices talking to each other — the whole of M2 except the widgets.
///
/// Real sockets on loopback, real SQLite, two independent [LanService]s, and no
/// mocks anywhere: what these tests exercise is precisely the glue, and every
/// one of the interesting failures is in a seam between two real things — an ack
/// sent before the database write, a message sent before the connection exists,
/// a duplicate stored twice.
///
/// The clocks are real too. Nothing here depends on a timing that a loaded
/// machine could not meet: the assertions are "eventually", with a five second
/// ceiling (see `patience`).
void main() {
  late _Device a;
  late _Device b;

  // Two devices in one process means two `AppDatabase`s, which is the case
  // drift warns about — its advice is to silence the warning when you know the
  // databases are independent, and these are: separate in-memory SQLite
  // instances with no executor between them.
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  setUp(() async {
    a = await _Device.start(id: 'device-aaa', name: 'Laptop');
    b = await _Device.start(id: 'device-bbb', name: 'Phone');
  });

  tearDown(() async {
    await a.dispose();
    await b.dispose();
  });

  /// Introduces the two devices to each other, in both directions.
  Future<void> introduce() async {
    a.announce(b);
    b.announce(a);
    await waitUntil(
      () => a.service.isConnected(b.id),
      describe: 'a to connect to b',
    );
    await waitUntil(
      () => b.service.isConnected(a.id),
      describe: 'b to connect to a',
    );
  }

  /// The messages [device] holds with [other], newest first — the order a page
  /// comes back in.
  Future<List<Message>> historyOf(_Device device, _Device other) =>
      device.chat.page(other.id);

  group('text messages', () {
    test('cross the connection and are stored once', () async {
      await introduce();

      await a.service.sendText(peerId: b.id, text: '你好 world 🎉');

      final List<Message> received = await waitForValue(
        () => historyOf(b, a),
        (List<Message> rows) => rows.length == 1,
        describe: 'b to store the message',
      );
      expect(received.single.text, '你好 world 🎉');
      expect(received.single.direction, MessageDirection.incoming);
      expect(received.single.status, MessageStatus.received);
      expect(received.single.peerId, a.id);

      // The sender's copy advances to delivered, which only happens once the
      // receiver's ack comes back — and that ack follows the database write.
      final List<Message> sent = await waitForValue(
        () => historyOf(a, b),
        (List<Message> rows) =>
            rows.length == 1 && rows.single.status == MessageStatus.delivered,
        describe: 'a to see the message delivered',
      );
      expect(sent.single.text, '你好 world 🎉');
      expect(sent.single.direction, MessageDirection.outgoing);
    });

    test('travel in both directions at once', () async {
      // Both devices dial each other, so this also covers §4.4's tie-break
      // under load: after the duplicate connection is resolved, messages still
      // have to flow both ways.
      await introduce();

      await a.service.sendText(peerId: b.id, text: 'from the laptop');
      await b.service.sendText(peerId: a.id, text: '来自手机');

      // A conversation holds both directions, so "did it arrive" is asked of
      // the texts and never of a row count — the first row to appear is the
      // device's own outgoing message, which proves nothing about the wire.
      await waitForValue(
        () => historyOf(a, b),
        (List<Message> rows) =>
            rows.length == 2 && textsOf(rows).contains('来自手机'),
        describe: 'a to hold both sides of the conversation',
      );
      await waitForValue(
        () => historyOf(b, a),
        (List<Message> rows) =>
            rows.length == 2 && textsOf(rows).contains('from the laptop'),
        describe: 'b to hold both sides of the conversation',
      );

      expect(
        textsOf(await historyOf(a, b)).toSet(),
        <String>{'from the laptop', '来自手机'},
      );
      expect(
        textsOf(await historyOf(b, a)).toSet(),
        <String>{'from the laptop', '来自手机'},
      );
    });

    test('an empty message is refused without touching the database', () async {
      await introduce();

      expect(
        await a.service.sendText(peerId: b.id, text: '   '),
        isNull,
        reason: 'nothing to send',
      );
      expect(
        await a.service.sendText(peerId: b.id, text: '\n\t '),
        isNull,
        reason: 'a newline from a soft keyboard is not a message',
      );

      expect(await historyOf(a, b), isEmpty);
      expect(await historyOf(b, a), isEmpty);
    });

    test('a duplicate delivery is stored once and still acknowledged', () async {
      await introduce();

      final Message? first = await a.service.sendText(
        peerId: b.id,
        text: '只此一份',
      );
      final String msgId = first!.id;
      await waitForValue(
        () => historyOf(a, b),
        (List<Message> rows) =>
            rows.length == 1 && rows.single.status == MessageStatus.delivered,
        describe: 'the first copy to be delivered',
      );

      // The same frame again, as a sender's retry produces after an ack went
      // missing. Sent through the transport on purpose: this is about what a
      // repeated frame does to the receiver, not about the send path.
      expect(
        a.service.manager.sendMessage(
          b.id,
          MessagePayload(msgId: msgId, ts: first.createdAt, text: '只此一份'),
        ),
        isTrue,
      );

      // The second copy has to be acked too. The sender is retrying precisely
      // because it never saw an ack, and going quiet would leave it retrying
      // until it gave up on a message that arrived the first time.
      //
      // The count is the witness: the duplicate is the only frame in flight, so
      // it reaching zero means an ack came back for it. The alternative reasons
      // it could drop — the ack timeout, or the connection dying — both take
      // longer than this test is willing to wait.
      expect(
        a.service.manager.pendingAckCount,
        1,
        reason: 'the duplicate is in flight and unacknowledged',
      );
      await waitUntil(
        () => a.service.manager.pendingAckCount == 0,
        describe: 'the duplicate to be acknowledged',
      );

      expect(
        await historyOf(b, a),
        hasLength(1),
        reason: 'stored once, not twice',
      );
      expect(
        await b.chat.unreadCount(a.id),
        1,
        reason: 'a message we already have is not a new unread message',
      );
      expect(
        (await historyOf(a, b)).single.status,
        MessageStatus.delivered,
        reason: 'a duplicate ack does not undo a delivery',
      );
    });
  });

  group('the offline queue (§5.2)', () {
    test('holds a message until the peer appears, then delivers it', () async {
      // b is never announced, so a has nowhere to send to.
      await a.service.sendText(peerId: b.id, text: '写完这条我就关机');

      final List<Message> queued = await historyOf(a, b);
      expect(queued.single.status, MessageStatus.pending);
      expect(
        await historyOf(b, a),
        isEmpty,
        reason: 'nothing has been sent anywhere yet',
      );

      // b turns up. The announce alone has to be enough: the connection comes
      // up, and the queue is flushed on it.
      a.announce(b);
      b.announce(a);

      final List<Message> delivered = await waitForValue(
        () => historyOf(b, a),
        (List<Message> rows) => rows.length == 1,
        describe: 'the queued message to arrive once b appears',
      );
      expect(delivered.single.text, '写完这条我就关机');
      await waitForValue(
        () => historyOf(a, b),
        (List<Message> rows) =>
            rows.length == 1 && rows.single.status == MessageStatus.delivered,
        describe: 'the queued message to be acknowledged',
      );
    });

    test('flushes in the order it was written', () async {
      // Three messages typed while the peer is away. They must arrive in the
      // order they were written, not in the order a hash map happened to yield
      // them — the sender keeps one msgId per message, so reordering here is
      // reordering the conversation.
      for (final String text in <String>['一', '二', '三']) {
        await a.service.sendText(peerId: b.id, text: text);
      }

      a.announce(b);
      b.announce(a);

      final List<Message> received = await waitForValue(
        () => historyOf(b, a),
        (List<Message> rows) => rows.length == 3,
        describe: 'all three to arrive',
      );
      expect(
        textsOf(received),
        <String>['三', '二', '一'],
        reason: 'the page is newest first, so this is reverse arrival order',
      );
    });

    test('keeps what was typed while the link was down', () async {
      await introduce();
      await a.service.sendText(peerId: b.id, text: '在吗');
      await waitForValue(
        () => historyOf(b, a),
        (List<Message> rows) => rows.length == 1,
        describe: 'the first message to arrive',
      );

      // The link drops under the conversation — a peer that closed its lid, or
      // one that moved between access points. Whatever is typed in that window
      // has to come out on the other side of the reconnect, once.
      await a.service.manager.disconnect(b.id);
      await a.service.sendText(peerId: b.id, text: '还在吗');

      await waitForValue(
        () => historyOf(b, a),
        (List<Message> rows) => rows.length == 2,
        describe: 'both messages to arrive',
      );
      expect(
        textsOf(await historyOf(b, a)),
        <String>['还在吗', '在吗'],
        reason: 'nothing was reordered and nothing was sent twice',
      );
      expect(
        await a.chat.pendingFor(b.id),
        isEmpty,
        reason: 'a delivered message is not owed again after a reconnect',
      );
    });
  });

  group('announces', () {
    test('are recorded in the device list', () async {
      a.announce(b);

      final Peer? stored = await waitForValue<Peer?>(
        () => a.peers.byId(b.id),
        (Peer? peer) => peer != null,
        describe: 'b to be written to a\'s device list',
      );
      expect(stored, isNotNull);
      expect(stored!.name, 'Phone');
      expect(stored.deviceType, DeviceType.android);
      expect(stored.isOnline, isFalse, reason: 'liveness is runtime state');
      expect(stored.lastIp, '127.0.0.1');
    });

    test('do not summon a connection to an offline peer', () async {
      a.announceOffline(b.id);

      await waitForValue<Peer?>(
        () => a.peers.byId(b.id),
        (Peer? peer) => peer != null,
        describe: 'the offline peer to be written to the device list',
      );
      expect(
        a.service.isConnected(b.id),
        isFalse,
        reason: 'a peer that has gone quiet is not dialled',
      );
    });
  });
}

/// The text of every message in [rows].
///
/// Messages carry a nullable text because the `message` table also holds the
/// rows a file transfer will need in M3; a text message always has one.
List<String> textsOf(List<Message> rows) => rows
    .map((Message message) => message.text ?? '')
    .toList(growable: false);

/// One device: its database, its listener, and a stand-in for discovery.
class _Device {
  _Device({
    required this.id,
    required this.name,
    required this.port,
    required this.db,
    required this.chat,
    required this.peers,
    required this.service,
    required this.source,
  });

  final String id;
  final String name;
  final int port;
  final AppDatabase db;
  final ChatRepository chat;
  final PeerRepository peers;
  final LanService service;
  final _FakeAnnounces source;

  static Future<_Device> start({
    required String id,
    required String name,
  }) async {
    final AppDatabase db = AppDatabase.memory();
    final ChatRepository chat = ChatRepository(db);
    final PeerRepository peers = PeerRepository(db);
    final _FakeAnnounces source = _FakeAnnounces();
    final int port = await freePort();

    final LanService service = LanService(
      manager: ConnectionManager(
        port: port,
        selfHello: HelloPayload(
          role: ConnectionRole.control,
          deviceId: id,
          name: name,
          deviceType: DeviceType.windows,
          icon: DeviceIcon.desktop,
          port: port,
          version: kProtocolVersion,
        ),
      ),
      discovery: source,
      chat: chat,
      peers: peers,
      clock: DateTime.now,
    );
    await service.start();

    return _Device(
      id: id,
      name: name,
      port: port,
      db: db,
      chat: chat,
      peers: peers,
      service: service,
      source: source,
    );
  }

  Peer asPeer({required bool online}) {
    return Peer(
      id: id,
      name: name,
      // Deliberately not windows, so the stored device type is checked against
      // the announce rather than against a default that happens to match.
      deviceType: DeviceType.android,
      icon: DeviceIcon.phone,
      lastIp: '127.0.0.1',
      lastPort: port,
      isOnline: online,
    );
  }

  void announce(_Device other) => source.announce(other.asPeer(online: true));

  void announceOffline(String peerId) => source.announce(
        Peer(
          id: peerId,
          name: peerId,
          deviceType: DeviceType.windows,
          icon: DeviceIcon.desktop,
          lastIp: '127.0.0.1',
          isOnline: false,
        ),
      );

  Future<void> dispose() async {
    await service.dispose();
    await source.close();
    await db.close();
  }
}

/// A peer table with no sockets behind it.
///
/// The real `DiscoveryService` binds UDP 24250, which two of them in one test
/// process cannot do — and none of what these tests check is about discovery.
class _FakeAnnounces implements PeerSource {
  final StreamController<void> _changes = StreamController<void>.broadcast();
  final Map<String, Peer> _peers = <String, Peer>{};

  @override
  Stream<void> get changes => _changes.stream;

  @override
  List<Peer> get peers => _peers.values.toList(growable: false);

  void announce(Peer peer) {
    _peers[peer.id] = peer;
    if (!_changes.isClosed) {
      _changes.add(null);
    }
  }

  Future<void> close() => _changes.close();
}
