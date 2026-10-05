import 'dart:io';

import 'package:feijian/core/protocol/payloads.dart';
import 'package:feijian/core/transport/connection_manager.dart';
import 'package:feijian/core/transport/connection_state.dart';
import 'package:feijian/core/transport/feijian_server.dart';
import 'package:feijian/core/transport/transport_tuning.dart';
import 'package:flutter_test/flutter_test.dart';

import 'transport_harness.dart';

const String kIdA = 'device-aaa';
const String kIdB = 'device-bbb';

late List<String> logs;

ConnectionManager managerFor(String deviceId) {
  return ConnectionManager(
    selfHello: helloFor(deviceId),
    port: 0,
    tuning: testTuning,
    onLog: logs.add,
  );
}

MessagePayload message(String msgId, [String text = 'hi']) => MessagePayload(
      msgId: msgId,
      ts: DateTime(2026, 10, 4, 12),
      text: text,
    );

/// Two managers, connected, with the streams subscribed before the handshake so
/// nothing is missed.
class Peers {
  Peers(this.a, this.b);

  final ConnectionManager a;
  final ConnectionManager b;

  final List<IncomingMessage> toB = <IncomingMessage>[];
  final List<IncomingMessage> toA = <IncomingMessage>[];
  final List<MessageDelivered> deliveredToA = <MessageDelivered>[];
  final List<MessageDeliveryFailed> failedAtA = <MessageDeliveryFailed>[];
  final List<PeerConnectionLost> lostAtA = <PeerConnectionLost>[];
  final List<PeerConnectionLost> lostAtB = <PeerConnectionLost>[];

  Future<void> dispose() async {
    await a.dispose();
    await b.dispose();
  }
}

/// Starts two managers and connects them. [dialBothWays] makes both dial at the
/// same moment, which is the race §4.4 exists to resolve.
Future<Peers> connectedPeers({bool dialBothWays = false}) async {
  final Peers peers = Peers(managerFor(kIdA), managerFor(kIdB));
  await peers.a.start();
  await peers.b.start();

  peers.a.incoming.listen(peers.toA.add);
  peers.b.incoming.listen(peers.toB.add);
  peers.a.delivered.listen(peers.deliveredToA.add);
  peers.a.deliveryFailed.listen(peers.failedAtA.add);
  peers.a.peerLost.listen(peers.lostAtA.add);
  peers.b.peerLost.listen(peers.lostAtB.add);

  peers.a.requireConnection(
    kIdB,
    address: InternetAddress.loopbackIPv4,
    port: peers.b.boundPort!,
  );
  if (dialBothWays) {
    peers.b.requireConnection(
      kIdA,
      address: InternetAddress.loopbackIPv4,
      port: peers.a.boundPort!,
    );
  }

  await waitUntil(
    () => peers.a.isConnected(kIdB) && peers.b.isConnected(kIdA),
    describe: 'both managers to see each other',
  );
  return peers;
}

void main() {
  setUp(() => logs = <String>[]);

  group('message exchange', () {
    test('a message reaches the peer and its ack comes back', () async {
      final Peers peers = await connectedPeers();
      addTearDown(peers.dispose);

      expect(peers.a.sendMessage(kIdB, message('m1', '你好 world 🎉')), isTrue);
      await waitUntil(() => peers.toB.isNotEmpty, describe: 'the message to arrive');

      expect(peers.toB.single.payload.msgId, 'm1');
      // Non-ASCII survives the round trip: the frame header is JSON, and this
      // is the whole point of the product for its users.
      expect(peers.toB.single.payload.text, '你好 world 🎉');

      expect(peers.b.sendAck(kIdA, 'm1'), isTrue);
      await waitUntil(
        () => peers.deliveredToA.isNotEmpty,
        describe: 'the ack to be recorded',
      );
      expect(peers.deliveredToA.single.msgId, 'm1');
      expect(peers.a.pendingAckCount, 0);
    });

    test('the peer can reply on the same connection', () async {
      final Peers peers = await connectedPeers();
      addTearDown(peers.dispose);

      expect(peers.b.sendMessage(kIdA, message('reply')), isTrue);
      await waitUntil(() => peers.toA.isNotEmpty, describe: 'the reply to arrive');
      expect(peers.toA.single.peerId, kIdB);
    });

    test('a peer that dialled us is reachable without us dialling it', () async {
      // Half of all conversations start this way: the other side clicks first.
      final ConnectionManager a = managerFor(kIdA);
      final ConnectionManager b = managerFor(kIdB);
      addTearDown(() async {
        await a.dispose();
        await b.dispose();
      });
      await a.start();
      await b.start();

      a.requireConnection(
        kIdB,
        address: InternetAddress.loopbackIPv4,
        port: b.boundPort!,
      );
      await waitUntil(() => b.isConnected(kIdA), describe: 'b to accept the dial');

      // b never called requireConnection, so it has to have learned where a is
      // from the connection itself.
      expect(b.sendMessage(kIdA, message('unsolicited reply')), isTrue);
    });

    test('sending with no connection reports failure instead of queueing', () async {
      final ConnectionManager a = managerFor(kIdA);
      addTearDown(a.dispose);
      await a.start();

      // The message stays the caller's: the pool deliberately does not hold a
      // queue, because the durable copy of it is a database row, not a frame.
      expect(a.sendMessage(kIdB, message('m1')), isFalse);
      expect(a.pendingAckCount, 0);
      expect(a.sendAck(kIdB, 'm1'), isFalse);
    });
  });

  group('acknowledgement (design.md §4.5)', () {
    test('an unacknowledged message is resent, then reported failed', () async {
      final Peers peers = await connectedPeers();
      addTearDown(peers.dispose);

      // The receiver never acks — as if it crashed between reading the frame
      // and writing the row.
      peers.a.sendMessage(kIdB, message('m1'));

      await waitUntil(
        () => peers.failedAtA.isNotEmpty,
        describe: 'the message to be given up on',
      );

      expect(peers.failedAtA.single.msgId, 'm1');
      expect(peers.failedAtA.single.attempts, testTuning.maxRetries);
      // Each retry reuses the msgId, which is what lets the receiver dedupe the
      // copies while still acking every one of them.
      await waitUntil(
        () => peers.toB.length >= testTuning.maxRetries + 1,
        describe: 'every attempt to arrive',
      );
      expect(
        peers.toB.map((IncomingMessage m) => m.payload.msgId).toSet(),
        <String>{'m1'},
      );
      expect(peers.a.pendingAckCount, 0, reason: 'nothing left pending');
    });

    test('an ack that arrives after giving up still counts as delivered', () async {
      // The message did arrive; only the ack was slow. Showing a permanent ⚠ for
      // it would be a lie the user could see.
      final Peers peers = await connectedPeers();
      addTearDown(peers.dispose);

      peers.a.sendMessage(kIdB, message('m1'));
      await waitUntil(
        () => peers.failedAtA.isNotEmpty,
        describe: 'the message to be given up on',
      );

      peers.b.sendAck(kIdA, 'm1');
      await waitUntil(
        () => peers.deliveredToA.isNotEmpty,
        describe: 'the late ack to be accepted',
      );
      expect(peers.deliveredToA.single.msgId, 'm1');
    });

    test('an ack for a message we never sent is ignored', () async {
      final Peers peers = await connectedPeers();
      addTearDown(peers.dispose);

      peers.b.sendAck(kIdA, 'never-existed');
      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(peers.deliveredToA, isEmpty);
      expect(logs.any((String l) => l.contains('unknown msgId')), isTrue);
    });

    test('a resend of the same msgId does not double-track it', () async {
      // The offline queue reuses the original id after a reconnect (§5.2), so
      // the pool has to treat it as the same message rather than arming a
      // second timer for it.
      final Peers peers = await connectedPeers();
      addTearDown(peers.dispose);

      peers.a.sendMessage(kIdB, message('m1'));
      peers.a.sendMessage(kIdB, message('m1'));
      expect(peers.a.pendingAckCount, 1);

      peers.b.sendAck(kIdA, 'm1');
      await waitUntil(
        () => peers.deliveredToA.isNotEmpty,
        describe: 'the ack to be recorded',
      );
      expect(peers.failedAtA, isEmpty);
    });
  });

  group('duplicate connections (design.md §4.4)', () {
    test('both sides dialling at once leaves one working connection', () async {
      final Peers peers = await connectedPeers(dialBothWays: true);
      addTearDown(peers.dispose);

      // Give the losers time to be closed and any reconnect to happen.
      await Future<void>.delayed(const Duration(milliseconds: 250));

      // The rule — the connection opened by the smaller device id wins — has to
      // be computed identically on both ends. If it were not, each side would
      // keep the socket the other discarded and both would end up with nothing.
      expect(peers.a.connectedPeers, <String>{kIdB});
      expect(peers.b.connectedPeers, <String>{kIdA});

      expect(peers.a.sendMessage(kIdB, message('after-dedupe')), isTrue);
      await waitUntil(
        () => peers.toB.isNotEmpty,
        describe: 'a message to flow on the surviving connection',
      );
      expect(peers.b.sendMessage(kIdA, message('back')), isTrue);
      await waitUntil(
        () => peers.toA.isNotEmpty,
        describe: 'a reply to flow on the surviving connection',
      );
    });

    test('a manager never dials a device claiming its own id', () async {
      // Two installs sharing a device id — a restored backup, a cloned config —
      // must not connect to each other: the peer id is the dedupe key, so a
      // self-connection would make every rule keyed on it ambiguous.
      final ConnectionManager a = managerFor(kIdA);
      final ConnectionManager twin = managerFor(kIdA);
      addTearDown(() async {
        await a.dispose();
        await twin.dispose();
      });
      await a.start();
      await twin.start();

      a.requireConnection(
        kIdA,
        address: InternetAddress.loopbackIPv4,
        port: twin.boundPort!,
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(a.isConnected(kIdA), isFalse);
      expect(twin.connectedPeers, isEmpty);
    });
  });

  group('reconnecting', () {
    test('a dial that fails is retried until the peer appears', () async {
      // The peer is not listening yet, which is what a machine still booting
      // looks like. The pool must keep trying rather than giving up at the first
      // refusal.
      final int port = await freePort();
      final ConnectionManager a = managerFor(kIdA);
      addTearDown(a.dispose);
      await a.start();

      a.requireConnection(kIdB, address: InternetAddress.loopbackIPv4, port: port);
      await waitUntil(
        () => logs.any((String l) => l.contains('could not reach')),
        describe: 'the first attempt to fail',
      );

      final FeijianServer late = FeijianServer(
        selfHello: helloFor(kIdB),
        port: port,
        tuning: testTuning,
      );
      await late.start();
      addTearDown(late.dispose);

      await waitUntil(
        () => a.isConnected(kIdB),
        describe: 'a retry to succeed once the peer is listening',
      );
    });

    test('a peer that comes back after a drop is reconnected to', () async {
      final Peers peers = await connectedPeers();
      addTearDown(peers.dispose);

      // Kill b's listener and connections without a goodbye, the way a crash or
      // a Wi-Fi drop looks.
      await peers.b.stop();
      await waitUntil(
        () => peers.lostAtA.isNotEmpty,
        describe: 'a to notice b is gone',
      );

      // b comes back on a different port, as a fresh bind would give it.
      final FeijianServer restarted = FeijianServer(
        selfHello: helloFor(kIdB),
        port: 0,
        tuning: testTuning,
      );
      await restarted.start();
      addTearDown(restarted.dispose);

      // Telling a where b now lives is what an announce does in the real app.
      peers.a.requireConnection(
        kIdB,
        address: InternetAddress.loopbackIPv4,
        port: restarted.boundPort!,
      );
      await waitUntil(
        () => peers.a.isConnected(kIdB),
        describe: 'a to reconnect at the new address',
      );
      expect(peers.a.sendMessage(kIdB, message('after-reconnect')), isTrue);
    });

    test('a peer that said goodbye is still retried, not forgotten', () async {
      // The peer closed the app. It will probably open it again, and waiting for
      // a fresh announce would mean the conversation stalls until the next one.
      final Peers peers = await connectedPeers();
      addTearDown(peers.dispose);

      // Cleared *before* the goodbye, not after seeing it. `_onClosed` schedules
      // the retry and logs it in the same synchronous block that reports the
      // loss, so by the time the `peerLost` event has been delivered — one
      // microtask later — the line is already here, and clearing then would
      // delete the very thing being waited for.
      //
      // Worth spelling out because it went unnoticed for a while: this used to
      // pass anyway, on a second `retrying` logged when the retry failed. The
      // retry dials `kDiscoveryPort` (the hello's port wins over the port that
      // was dialled), so all it took to turn this test red was something
      // listening on 24250 — the app itself, or the Windows build left running
      // after a manual check. A test must not depend on that port being free.
      logs.clear();
      peers.b.disconnect(kIdA);

      await waitUntil(
        () => peers.lostAtA.isNotEmpty,
        describe: 'a to see the goodbye',
      );
      expect(
        peers.lostAtA.single.reason,
        anyOf(
          ConnectionClosedReason.remoteBye,
          ConnectionClosedReason.localBye,
        ),
      );

      // The state-level half of the same claim, and the one with no timing in
      // it at all: the peer is still one the manager wants to reach.
      expect(peers.a.isWanted(kIdB), isTrue);
      await waitUntil(
        () => logs.any((String l) => l.contains('retrying')),
        describe: 'a retry to be scheduled despite the goodbye',
      );
    });

    test('releasing a peer stops the retry loop', () async {
      final int port = await freePort();
      final ConnectionManager a = managerFor(kIdA);
      addTearDown(a.dispose);
      await a.start();

      a.requireConnection(kIdB, address: InternetAddress.loopbackIPv4, port: port);
      await waitUntil(
        () => logs.any((String l) => l.contains('retrying')),
        describe: 'the retry loop to start',
      );

      // What happens when a peer is removed from the device list: a device that
      // has left the network must not be dialled every thirty seconds forever.
      await a.release(kIdB);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      logs.clear();
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(logs.where((String l) => l.contains('could not reach')), isEmpty);
      expect(a.isWanted(kIdB), isFalse);
    });
  });

  group('Add by IP (design.md §4.1)', () {
    test('reaches a device that never announced, and returns what it is', () async {
      final ConnectionManager a = managerFor(kIdA);
      final ConnectionManager b = managerFor(kIdB);
      addTearDown(a.dispose);
      addTearDown(b.dispose);
      await a.start();
      await b.start();

      // No discovery, no announce, no prior knowledge of the id — which is the
      // whole point: behind AP isolation this is the only way to learn it.
      final DialResult result = await a.connectToAddress(
        InternetAddress.loopbackIPv4,
        port: b.boundPort!,
      );

      expect(result.isConnected, isTrue);
      expect(result.problem, isNull);
      expect(result.hello!.deviceId, kIdB);
      expect(result.hello!.name, kIdB);

      // And it is a first-class peer from here on: announces would land on the
      // same entry, and a message goes out over this connection.
      expect(a.isConnected(kIdB), isTrue);
      expect(a.isWanted(kIdB), isTrue);
      expect(a.sendMessage(kIdB, message('after-add')), isTrue);
    });

    test('reports nothing answered when no one is listening', () async {
      final int port = await freePort();
      final ConnectionManager a = managerFor(kIdA);
      addTearDown(a.dispose);
      await a.start();

      final DialResult result =
          await a.connectToAddress(InternetAddress.loopbackIPv4, port: port);

      expect(result.isConnected, isFalse);
      expect(result.problem, DialProblem.unreachable);
      expect(result.hello, isNull);
    });

    test('reports this device when the address is our own', () async {
      final ConnectionManager a = managerFor(kIdA);
      addTearDown(a.dispose);
      await a.start();

      // Reachable, and not a peer: a user who mistyped their own address out of
      // the list needs to hear that, not "nothing answered".
      final DialResult result = await a.connectToAddress(
        InternetAddress.loopbackIPv4,
        port: a.boundPort!,
      );

      expect(result.isConnected, isFalse);
      expect(result.problem, DialProblem.thisDevice);
    });

    test('a peer that hangs up during the handshake reports unreachable', () async {
      // A raw listener that accepts the socket and then drops it, without ever
      // sending a `hello`. The dial gets a connection and no peer out of it, and
      // the advice for the user is the same as for a port with nothing on it.
      final ServerSocket rude = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(rude.close);
      rude.listen((Socket socket) => socket.destroy());

      final ConnectionManager a = managerFor(kIdA);
      addTearDown(a.dispose);
      await a.start();

      final DialResult result = await a.connectToAddress(
        InternetAddress.loopbackIPv4,
        port: rude.port,
      );

      expect(result.isConnected, isFalse);
      expect(result.problem, DialProblem.unreachable);
    });

    test('gives up on a port that accepts but never greets', () async {
      // What a different program holding the port looks like. The handshake
      // timeout is set far beyond the dial timeout here, so the only thing that
      // can end this is `connectToAddress`'s own `timeout` — otherwise the test
      // would pass on the connection's timer and never cover the parameter.
      final ServerSocket silent = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(silent.close);
      silent.listen((Socket socket) => addTearDown(socket.destroy));

      final ConnectionManager a = ConnectionManager(
        selfHello: helloFor(kIdA),
        port: 0,
        tuning: const TransportTuning(
          handshakeTimeout: Duration(seconds: 30),
          idleTimeout: Duration(seconds: 30),
          connectTimeout: Duration(seconds: 5),
          closeFlushTimeout: Duration(milliseconds: 500),
          ackTimeout: Duration(seconds: 1),
          maxRetries: 1,
          backoff: <Duration>[Duration(milliseconds: 40)],
        ),
        onLog: logs.add,
      );
      addTearDown(a.dispose);
      await a.start();

      final DialResult result = await a.connectToAddress(
        InternetAddress.loopbackIPv4,
        port: silent.port,
        timeout: const Duration(milliseconds: 200),
      );

      expect(result.isConnected, isFalse);
      expect(result.problem, DialProblem.unreachable);
    });

    test('a dial to a peer we are already connected to is not a failure', () async {
      final Peers peers = await connectedPeers();
      addTearDown(peers.dispose);

      // §4.4 keeps one socket per peer, so this dial loses the tie-break and is
      // closed. The device is still reached, by the socket that was kept, and
      // telling the user "could not add" for a device that is plainly connected
      // would be the wrong answer to the question they asked.
      final DialResult result = await peers.a.connectToAddress(
        InternetAddress.loopbackIPv4,
        port: peers.b.boundPort!,
      );

      expect(result.isConnected, isTrue);
      expect(result.hello!.deviceId, kIdB);
      expect(peers.a.isConnected(kIdB), isTrue);
    });
  });

  group('shutdown', () {
    test('stopping announces the goodbye so the peer notices at once', () async {
      // Without the flush before teardown the peer would only find out when its
      // ninety-second idle timeout expired.
      final Peers peers = await connectedPeers();
      addTearDown(peers.dispose);

      await peers.a.stop();

      await waitUntil(
        () => peers.lostAtB.isNotEmpty,
        describe: 'b to be told a has gone',
      );
      expect(
        peers.lostAtB.single.reason,
        ConnectionClosedReason.remoteBye,
      );
      expect(peers.lostAtB.single.peerId, kIdA);
    });

    test('stopping twice is harmless', () async {
      final ConnectionManager a = managerFor(kIdA);
      addTearDown(a.dispose);
      await a.start();
      await a.stop();
      await a.stop();
      expect(a.boundPort, isNull);
    });
  });
}
