import 'dart:async';
import 'dart:io';

import 'package:feijian/core/discovery/announce.dart';
import 'package:feijian/core/discovery/discovery_service.dart';
import 'package:feijian/core/models/peer.dart';
import 'package:flutter_test/flutter_test.dart';

/// These tests drive the real socket path — a genuine UDP datagram is posted at
/// the service and the resulting peer table is asserted on. Only the interface
/// enumeration is incidental: on a machine with a real NIC the service also
/// sends its announces onto the LAN, which is harmless (it is our own protocol
/// on our own port) but worth knowing when reading a packet capture.
const Peer _self = Peer(
  id: 'self-id',
  name: 'Test-Box',
  deviceType: DeviceType.windows,
  icon: DeviceIcon.desktop,
  lastPort: 24250,
);

/// Hands out a distinct port for each service, chosen *below* the Windows
/// ephemeral range (49152-65535).
///
/// Asking the OS for a free port with `bind(0)` looks tidier but is a trap
/// here: it draws from the same pool the fake peer's `bind(0)` uses, and when
/// both land on the same number the failure is silent. The service binds the
/// wildcard address and the fake peer binds loopback, and Windows delivers a
/// datagram to the more specific binding — so the peer's own sends go to
/// itself and the service waits forever for packets that were never lost.
/// Staying below the pool makes the collision impossible rather than unlikely.
Future<int> _servicePort() async {
  for (int candidate = 24000 + _portCursor++; candidate < 25000; candidate++) {
    try {
      final RawDatagramSocket probe = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        candidate,
      );
      probe.close();
      return candidate;
    } on SocketException {
      // Taken by something else; try the next one.
    }
  }
  throw StateError('no free port below the ephemeral range');
}

int _portCursor = 0;

/// A stand-in peer: a plain socket we can post datagrams from and read replies
/// on.
class _FakePeer {
  _FakePeer(this.socket) {
    socket.listen((RawSocketEvent event) {
      if (event != RawSocketEvent.read) {
        return;
      }
      Datagram? datagram;
      while ((datagram = socket.receive()) != null) {
        received.add(datagram!);
      }
    });
  }

  static Future<_FakePeer> bind() async =>
      _FakePeer(await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0));

  final RawDatagramSocket socket;
  final List<Datagram> received = <Datagram>[];
  final List<String> sendLog = <String>[];

  int get port => socket.port;

  Future<void> send(AnnouncePacket packet, int toPort) =>
      sendRaw(packet.encode(), toPort);

  /// Posts one datagram, retrying if the platform refuses it.
  ///
  /// The retry is the point of this method. `RawDatagramSocket.send` reports a
  /// dropped datagram as a 0-byte write rather than by throwing, and Windows
  /// does drop them: measured on a real NIC, about 4% of four sends made back
  /// to back never left the machine, and 1ms of gap removed the loss. For a
  /// test double that is fatal — the datagram simply never arrives, and the
  /// assertion that was waiting for it fails 15s later pointing at the wrong
  /// thing.
  ///
  /// So rather than leaving a gap at every call site, the write is checked and
  /// retried here, and a datagram that cannot be sent at all throws instead of
  /// letting the test hang. A genuine fault now fails immediately and says so.
  Future<void> sendRaw(List<int> bytes, int toPort) async {
    for (int attempt = 0; attempt < 5; attempt++) {
      final int written;
      try {
        written = socket.send(bytes, InternetAddress.loopbackIPv4, toPort);
      } on Object catch (error) {
        sendLog.add('${bytes.length}B->$toPort threw $error');
        throw StateError('the fake peer could not send: $error');
      }
      sendLog.add('${bytes.length}B->$toPort wrote $written');
      if (written == bytes.length) {
        return;
      }
      // Refused. A short pause is what lets the OS accept the next attempt.
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    throw StateError(
      'the fake peer could not send ${bytes.length} bytes to port $toPort '
      'in 5 attempts: ${sendLog.join(' ; ')}',
    );
  }

  void close() => socket.close();
}

/// A datagram as a real peer would send it.
///
/// [port] must be a port that is actually being read. The service answers an
/// announce by unicasting back to the advertised port, and a reply sent to a
/// dead port draws an ICMP port-unreachable, which Windows then surfaces as a
/// `SocketException` on an unrelated later socket call — a confusing failure
/// several tests away from its cause.
AnnouncePacket _announce({
  String id = 'peer-1',
  String name = 'Bob-PC',
  int? port,
  DateTime? ts,
  AnnounceType type = AnnounceType.announce,
}) {
  final bool full = type == AnnounceType.announce;
  return AnnouncePacket(
    type: type,
    id: id,
    ts: ts ?? DateTime.now().toUtc(),
    name: full ? name : null,
    deviceType: full ? DeviceType.windows : null,
    icon: full ? DeviceIcon.desktop : null,
    os: full ? 'Windows 11' : null,
    port: port,
  );
}

/// Polls until [condition] holds, so the tests never depend on a fixed sleep.
///
/// The timeout is far larger than a loopback round trip needs, because it only
/// ever elapses in the pathological case: while `flutter test` is compiling
/// five files at once, a cold first run can starve this isolate for seconds. A
/// genuine fault still fails the test — the datagram simply never arrives — so
/// the generous window costs nothing and removes a false failure.
Future<void> _waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 15),
  String? reason,
  String Function()? diagnostics,
}) async {
  final DateTime deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail(
        'timed out waiting${reason == null ? '' : ' for $reason'}'
        '${diagnostics == null ? '' : '\n${diagnostics()}'}',
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  late int port;
  late DiscoveryService service;
  late _FakePeer peer;
  late List<String> logs;

  /// Every socket the service has bound, in order.
  ///
  /// The service's own sockets are private, and a test needs to reach one to
  /// close it — which is the only way to reproduce a latched socket without a
  /// network that produces an ICMP port-unreachable on demand. So the binder is
  /// the seam, and it hands out real sockets bound exactly as the default does.
  late List<RawDatagramSocket> bound;

  /// The socket the service listens on. One per service, on the discovery port.
  Iterable<RawDatagramSocket> listeners() => bound.where(
        (RawDatagramSocket s) => s.address.address == '0.0.0.0' && s.port == port,
      );

  /// Sockets bound to the wildcard on some other port — the one that answers.
  Iterable<RawDatagramSocket> answerers() => bound.where(
        (RawDatagramSocket s) => s.address.address == '0.0.0.0' && s.port != port,
      );

  /// The per-interface senders: one per usable address, so a real address.
  ///
  /// Empty on a machine with no usable interface, where the service falls back
  /// to the routing table — which is the point of the fallback, and the reason
  /// tests that need a sender say so rather than assuming one.
  Iterable<RawDatagramSocket> senders() => bound.where(
        (RawDatagramSocket s) => s.address.address != '0.0.0.0',
      );

  Future<void> startService() async {
    port = await _servicePort();
    logs = <String>[];
    bound = <RawDatagramSocket>[];
    service = DiscoveryService(
      discoveryPort: port,
      onLog: logs.add,
      bind: (InternetAddress address, int atPort) async {
        final RawDatagramSocket socket = await RawDatagramSocket.bind(
          address,
          atPort,
          reuseAddress: true,
        );
        bound.add(socket);
        return socket;
      },
    );
    service.updateSelf(_self);
    await service.start();
    addTearDown(service.dispose);
  }

  setUp(() async {
    peer = await _FakePeer.bind();
    addTearDown(peer.close);
  });

  test('announces onto the wire as soon as it starts', () async {
    await startService();

    expect(service.isRunning, isTrue);
    expect(listeners(), hasLength(1));
    // A device with no usable interface still sends via the routing table
    // rather than going mute, so the answering socket exists either way.
    expect(answerers(), isNotEmpty);
    expect(service.table.isEmpty, isTrue);
  });

  test('learns a peer from a datagram and reports the change', () async {
    await startService();
    final List<void> notifications = <void>[];
    final StreamSubscription<void> sub = service.changes.listen(notifications.add);
    addTearDown(sub.cancel);

    await peer.send(_announce(port: peer.port), port);

    await _waitUntil(
      () => service.table.length == 1,
      reason: 'the announce to be received',
    );

    final Peer discovered = service.table['peer-1']!;
    expect(discovered.name, 'Bob-PC');
    expect(discovered.deviceType, DeviceType.windows);
    // The peer's own listen port travels on the wire, so a peer that moved off
    // the default is still reachable.
    expect(discovered.lastPort, peer.port);
    // The address comes from the datagram, not from the packet body.
    expect(discovered.lastIp, '127.0.0.1');
    expect(discovered.isOnline, isTrue);
    expect(notifications, isNotEmpty);
  });

  test('ignores its own announce coming back off the network', () async {
    await startService();

    await peer.send(
      _announce(id: _self.id, name: 'Test-Box', port: peer.port),
      port,
    );
    // Followed by a real peer, so the assertion cannot pass by simply being
    // too early.
    await peer.send(_announce(port: peer.port), port);

    await _waitUntil(() => service.table.length == 1, reason: 'the real peer');
    expect(service.table[_self.id], isNull);
    expect(service.table['peer-1'], isNotNull);
  });

  test('drops a peer immediately on bye', () async {
    await startService();
    await peer.send(_announce(port: peer.port), port);
    await _waitUntil(() => service.table.length == 1, reason: 'the peer');

    await peer.send(_announce(type: AnnounceType.bye), port);

    await _waitUntil(
      () => service.table.isEmpty,
      reason: 'the goodbye to be honoured',
    );
  });

  test('answers a probe with a unicast announce on the prober\'s port',
      () async {
    await startService();

    await peer.send(
      _announce(type: AnnounceType.probe, port: peer.port),
      port,
    );

    await _waitUntil(
      () => peer.received.isNotEmpty,
      reason: 'the reply to the probe',
    );

    final AnnouncePacket reply = AnnouncePacket.decode(
      peer.received.first.data,
      now: DateTime.now().toUtc(),
    ).packet!;
    expect(reply.type, AnnounceType.announce);
    expect(reply.id, _self.id);
    expect(reply.name, 'Test-Box');
    // Addressed to the port from the probe, not to the datagram's source port.
    expect(reply.port, _self.lastPort);
  });

  test('a probe is not mistaken for a device and added to the list', () async {
    await startService();

    await peer.send(_announce(type: AnnounceType.probe, port: peer.port), port);
    await _waitUntil(() => peer.received.isNotEmpty, reason: 'the reply');

    // A probe carries no name or platform, so there is nothing to list.
    expect(service.table.isEmpty, isTrue);
  });

  test('survives junk on the discovery port and logs why', () async {
    await startService();

    // Unrelated software broadcasting on the discovery port is a real
    // possibility.
    await peer.sendRaw(<int>[0xde, 0xad, 0xbe, 0xef], port);
    await peer.sendRaw('not json at all'.codeUnits, port);
    // Then a good announce, to prove the bad ones did not kill the loop.
    await peer.send(_announce(port: peer.port), port);

    await _waitUntil(
      () => service.table.length == 1,
      reason: 'the real peer',
      diagnostics: () => '  port=$port peerPort=${peer.port}\n'
          '  table=${service.table.length} running=${service.isRunning}\n'
          '  senders=${service.senderAddresses}\n'
          '  logs=${logs.join(' | ')}\n'
          '  sends=${peer.sendLog.join(' ; ')}\n'
          '  peer received ${peer.received.length} datagrams',
    );
    expect(logs, isNotEmpty);
  });

  test('refuses to start before it knows who it is', () async {
    final DiscoveryService fresh = DiscoveryService(discoveryPort: await _servicePort());
    addTearDown(fresh.dispose);

    expect(fresh.start, throwsStateError);
  });

  test('stop says goodbye, releases the port, and is idempotent', () async {
    await startService();

    await service.stop();
    expect(service.isRunning, isFalse);
    expect(service.senderAddresses, isEmpty);

    // The port is free again, which is the real assertion — a leaked socket
    // would break every later start on the same port.
    final RawDatagramSocket rebound = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      port,
    );
    rebound.close();

    await service.stop(); // must not throw
  });

  test('rescan is safe before start and after stop', () async {
    final DiscoveryService fresh = DiscoveryService(discoveryPort: await _servicePort());
    addTearDown(fresh.dispose);
    fresh.updateSelf(_self);

    fresh.rescan(); // before start
    await fresh.start();
    fresh.rescan();
    await fresh.stop();
    fresh.rescan(); // after stop
  });

  // --- Recovering from a socket that has latched -----------------------------
  //
  // The failure these cover is the one that made the device list empty itself
  // after a few minutes and never fill again, with a refresh button that did
  // nothing. An ICMP port-unreachable latches a UDP socket on Windows: every
  // later write returns 0, nothing clears it but closing the socket, and the
  // app goes silent until the process is restarted. Closing a socket behind the
  // service's back is what that looks like from the inside.

  test('answers a probe from a socket of its own, not the listener', () async {
    await startService();

    expect(listeners(), hasLength(1));
    expect(
      answerers(),
      isNotEmpty,
      reason: 'a second wildcard socket, for answers — sharing the listener '
          'would let one stale peer stop this device answering probes for good',
    );

    await peer.send(_announce(type: AnnounceType.probe, port: peer.port), port);
    await _waitUntil(() => peer.received.isNotEmpty, reason: 'the reply');

    // The reply arrived AND the listener was never a sender, which is the whole
    // point: an error drawn on the answer path cannot reach the listening path.
    expect(listeners(), hasLength(1));
  });

  test('a socket that stops accepting writes is replaced', () async {
    await startService();

    final RawDatagramSocket answering = answerers().first;
    // Counting *answerers*, not every socket that gets bound. A sender is
    // replaced under the same counter, and on a loaded machine ordinary UDP
    // loss can reach that limit too (§4.1.1 measured ~4% of burst sends
    // dropped) — so waiting on "some socket was bound" would let a sender's
    // replacement satisfy the wait and then fail the log assertion below for a
    // reason that has nothing to do with the answer path. Only this one grows
    // when the answering socket is the one replaced.
    final int answerersBefore = answerers().length;
    answering.close();

    for (int i = 0; i < 3; i++) {
      await peer.send(
        _announce(type: AnnounceType.probe, port: peer.port),
        port,
      );
    }

    await _waitUntil(
      () => answerers().length > answerersBefore,
      reason: 'the dead socket to be replaced',
      diagnostics: () => '  logs=${logs.join(' | ')}',
    );
    expect(
      logs.any((String line) => line.contains('replaced the socket answering')),
      isTrue,
      reason: 'and to say so — silence is what made this take a bug report and '
          'an afternoon to find\n  logs=${logs.join(' | ')}',
    );

    // The replacement works: an answer goes out on it.
    peer.received.clear();
    await peer.send(_announce(type: AnnounceType.probe, port: peer.port), port);
    await _waitUntil(
      () => peer.received.isNotEmpty,
      reason: 'a reply on the replacement socket',
      diagnostics: () => '  logs=${logs.join(' | ')}',
    );
  });

  test('a sender retired mid-announce does not break the announce', () async {
    await startService();
    final int senderCount = senders().length;
    if (senderCount == 0) {
      // No usable interface: the service is on its routing-table fallback and
      // there is no per-interface sender to retire. Nothing to assert here, and
      // the other tests still cover that path.
      return;
    }
    final int bindsBefore = bound.length;

    for (final RawDatagramSocket socket in senders()) {
      socket.close();
    }

    // One announce is two writes per sender (multicast and broadcast), so the
    // third write retires a socket — and it is retired *while* the loop that is
    // writing to it walks the list. That used to throw
    // `ConcurrentModificationError` out of the middle of the announce, killing
    // the sends to every interface after the first, and (through the timer and
    // the unawaited refresh) it landed as an unhandled async error rather than
    // anywhere near its cause.
    //
    // `updateSelf` is the way in because it announces synchronously: a rename
    // that threw would throw here, in the test, and not three tests later.
    for (int i = 0; i < 4; i++) {
      expect(
        () => service.updateSelf(
          Peer(
            id: _self.id,
            name: 'Test-Box $i',
            deviceType: DeviceType.windows,
            icon: DeviceIcon.desktop,
            lastPort: port,
          ),
        ),
        returnsNormally,
      );
    }

    await _waitUntil(
      () => bound.length > bindsBefore,
      reason: 'the dead senders to be replaced',
      diagnostics: () =>
          '  answerers=${answerers().length} senders=${senders().length}\n'
          '  logs=${logs.join(' | ')}',
    );
    expect(
      logs.any((String line) => line.contains('replaced the sender on')),
      isTrue,
      reason: 'and to say so',
    );
  });

  test('rescan binds fresh sockets and leaves discovery working', () async {
    await startService();
    // The answering socket, because rebuilding it is specific to a refresh: a
    // sender replacement is triggered by refused writes, which is the other
    // heading in this group. Waiting on "any new socket" would accept one of
    // those and the test would pass without a rescan having done anything.
    final int answerersBefore = answerers().length;

    // What the refresh button does. It has to replace the sockets rather than
    // re-announce on them, because a latched socket is the usual reason the
    // list stopped changing and writing to it again is a no-op.
    service.rescan();

    await _waitUntil(
      () => answerers().length > answerersBefore,
      reason: 'the sockets to be rebuilt',
      diagnostics: () => '  logs=${logs.join(' | ')}',
    );

    peer.received.clear();
    await peer.send(_announce(type: AnnounceType.probe, port: peer.port), port);
    await _waitUntil(
      () => peer.received.isNotEmpty,
      reason: 'a reply after the rebuild',
      diagnostics: () => '  logs=${logs.join(' | ')}',
    );
  });

  test('rescan rebuilds the listening socket, not just the sending ones', () async {
    // The bug this pins down, in the user's words: after the phone had been
    // off the network for a long stretch, neither Refresh nor Rescan would find
    // the PC again — only killing the app would. The refresh rebuilt the
    // senders and left the listener alone, so the multicast membership never
    // came back, and a membership does not survive its interface going down.
    //
    // Restarting worked because `start` joins the group; nothing else did,
    // because nothing else ever joined twice.
    await startService();
    expect(listeners(), hasLength(1));
    final RawDatagramSocket first = listeners().single;

    service.rescan();

    await _waitUntil(
      () => listeners().length == 2,
      reason: 'a second listener to be bound',
      diagnostics: () => '  logs=${logs.join(' | ')}',
    );
    expect(
      listeners().last,
      isNot(same(first)),
      reason: 'a replacement socket, not another copy of the same one',
    );
    expect(
      logs.any(
        (String line) => line.contains('rejoined the group'),
      ),
      isTrue,
      reason: 'and to say that the receive path was repaired',
    );

    // Still receiving on the new socket. Closing the old one cannot be asserted
    // directly: `send` on a closed RawDatagramSocket returns 0 rather than
    // throwing, and there is no `isClosed` to ask. What matters is that the
    // service is listening again, which this shows by getting a datagram that
    // only a live listener on this port could have handled.
    peer.received.clear();
    await peer.send(_announce(port: peer.port), port);
    await _waitUntil(
      () => service.table.length == 1,
      reason: 'a peer learned after the listener was rebuilt',
      diagnostics: () => '  logs=${logs.join(' | ')}',
    );
  });

  test('a stop that lands mid-rebind leaves no socket open behind it', () async {
    // `_rebindAll` crosses several awaits — enumerating interfaces, cancelling
    // the old subscription, binding the replacement — and `stop()` can land in
    // any of them. A socket bound *after* the service stopped is one nothing
    // will ever close, and the next `start()` would find its own port taken.
    //
    // The window is hit deliberately rather than hoped for: the injected binder
    // waits, so `stop()` arrives while the replacement is still being bound.
    final int slowPort = await _servicePort();
    final List<String> slowLogs = <String>[];
    final List<RawDatagramSocket> slowBound = <RawDatagramSocket>[];
    final DiscoveryService slow = DiscoveryService(
      discoveryPort: slowPort,
      onLog: slowLogs.add,
      bind: (InternetAddress address, int atPort) async {
        await Future<void>.delayed(const Duration(milliseconds: 80));
        final RawDatagramSocket socket = await RawDatagramSocket.bind(
          address,
          atPort,
          reuseAddress: true,
        );
        slowBound.add(socket);
        return socket;
      },
    );
    addTearDown(slow.dispose);
    slow.updateSelf(_self);
    await slow.start();
    final int afterStart = slowBound.length;

    slow.rescan();
    await slow.stop();
    // Long enough for every bind the refresh started to have completed.
    await Future<void>.delayed(const Duration(milliseconds: 500));

    expect(
      slowBound.length,
      greaterThan(afterStart),
      reason: 'the rebind really did run — otherwise this proves nothing',
    );

    // `send` on a closed RawDatagramSocket returns 0; on an open one it returns
    // the byte count. That asymmetry is the only way to ask, since there is no
    // `isClosed` — and it is the same silent-0 behaviour the announce path is
    // written around. A non-zero result is proof of a leak; a zero is taken at
    // face value, which can only ever miss one, never invent one.
    final List<RawDatagramSocket> leaked = <RawDatagramSocket>[
      for (final RawDatagramSocket socket in slowBound)
        if (socket.send(<int>[0], InternetAddress('127.0.0.1'), 9) > 0) socket,
    ];
    expect(
      leaked,
      isEmpty,
      reason: 'stop() closed everything the refresh had already bound\n'
          '  logs=${slowLogs.join(' | ')}',
    );
  });
}
