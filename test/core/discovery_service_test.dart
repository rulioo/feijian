import 'dart:async';
import 'dart:io';

import 'package:feijian/core/constants.dart';
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

/// Watches what the service puts *on the wire*, decoded.
///
/// Every datagram is written twice, multicast and broadcast. The per-interface
/// senders switch multicast loopback off, so this socket only ever sees the
/// broadcast copy of each — which is enough, because the bytes are identical
/// and this decodes them back into packets rather than counting them, so a test
/// can ask *which kind* of message went out and not just how many.
///
/// **It has to join the multicast group, and skipping that is not a small
/// omission.** On Windows a send to a group with no local member draws an ICMP
/// port-unreachable, which latches the sending socket: every later write on it
/// returns 0 rather than throwing. Measured on this machine, an observer that
/// did not join saw the *first* probe and the *first* announce and then nothing
/// at all — the multicast write latched the sender, taking the broadcast copies
/// down with it, and the burst under test looked broken when it was working
/// exactly as designed. So this mirrors what a real peer does, and is also the
/// only way the test can see anything.
class _Wire {
  _Wire(this.socket) {
    socket.listen((RawSocketEvent event) {
      if (event != RawSocketEvent.read) {
        return;
      }
      Datagram? datagram;
      while ((datagram = socket.receive()) != null) {
        final AnnouncePacket? packet = AnnouncePacket.decode(
          datagram!.data,
          now: DateTime.now().toUtc(),
        ).packet;
        if (packet != null) {
          final DateTime at = DateTime.now();
          packets.add(packet);
          if (packet.type == AnnounceType.probe) {
            _probesAt.add(at);
          }
        }
      }
    });
  }

  static Future<_Wire> bind(int port) async {
    final RawDatagramSocket socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      port,
      reuseAddress: true,
    );
    socket.broadcastEnabled = true;

    // On every interface, as the service itself does — a join that fails on one
    // adapter (a VPN, a virtual switch) must not keep the others from working.
    final InternetAddress group = InternetAddress(kMulticastGroup);
    for (final NetworkInterface ni
        in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
      try {
        socket.joinMulticast(group, ni);
      } on SocketException {
        // Interface cannot do multicast; the remaining ones still count.
      }
    }
    return _Wire(socket);
  }

  final RawDatagramSocket socket;
  final List<AnnouncePacket> packets = <AnnouncePacket>[];

  /// When each probe arrived, so a test can ask whether the opening burst was
  /// *spread out* rather than merely repeated. See [probeSpan].
  final List<DateTime> _probesAt = <DateTime>[];

  int get probes =>
      packets.where((AnnouncePacket p) => p.type == AnnounceType.probe).length;

  /// Receipt time of the last probe minus the first.
  ///
  /// The measurement the opening-burst test actually rests on, and deliberately
  /// not a packet count. Counting cannot separate three rounds from one: this
  /// machine drops enough of a multicast burst that a healthy threeround burst
  /// and a single round both land in the low single digits, so a count
  /// assertion is a coin flip that fails on *correct* code. The span measures
  /// the property the burst exists for — the packets leaving at different
  /// moments — and it survives losing any individual datagram, because it needs
  /// only one survivor from the first round and one from the last.
  ///
  /// Measured here: three rounds 50ms apart span 102-108ms across 25 runs, and
  /// one round spans 0ms every time.
  Duration get probeSpan => _probesAt.length < 2
      ? Duration.zero
      : _probesAt.last.difference(_probesAt.first);

  int get announces => packets
      .where((AnnouncePacket p) => p.type == AnnounceType.announce)
      .length;

  /// What went out, for the failure message. A test that says "expected 3, got
  /// 1" without saying which is almost no help at all.
  String get summary =>
      packets.map((AnnouncePacket p) => p.type.name).join(',');

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
        (RawDatagramSocket s) =>
            s.address.address == '0.0.0.0' && s.port == port,
      );

  /// Sockets bound to the wildcard on some other port — the one that answers.
  Iterable<RawDatagramSocket> answerers() => bound.where(
        (RawDatagramSocket s) =>
            s.address.address == '0.0.0.0' && s.port != port,
      );

  /// The per-interface senders: one per usable address, so a real address.
  ///
  /// Empty on a machine with no usable interface, where the service falls back
  /// to the routing table — which is the point of the fallback, and the reason
  /// tests that need a sender say so rather than assuming one.
  Iterable<RawDatagramSocket> senders() => bound.where(
        (RawDatagramSocket s) => s.address.address != '0.0.0.0',
      );

  Future<void> startService({
    Duration silentPeerAfter = kSilentPeerRebindAfter,
  }) async {
    port = await _servicePort();
    logs = <String>[];
    bound = <RawDatagramSocket>[];
    service = DiscoveryService(
      discoveryPort: port,
      onLog: logs.add,
      silentPeerAfter: silentPeerAfter,
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
    final StreamSubscription<void> sub =
        service.changes.listen(notifications.add);
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
    final DiscoveryService fresh =
        DiscoveryService(discoveryPort: await _servicePort());
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

  test('rescan before a first start begins one, and after stop does not',
      () async {
    // Both halves of the same question, because they are the two ways of not
    // being started and they call for opposite answers. A service that has not
    // begun is exactly what the button is for; a service that was stopped on
    // purpose is not.
    final int freshPort = await _servicePort();
    final List<RawDatagramSocket> freshBound = <RawDatagramSocket>[];
    final DiscoveryService fresh = DiscoveryService(
      discoveryPort: freshPort,
      bind: (InternetAddress address, int atPort) async {
        final RawDatagramSocket socket = await RawDatagramSocket.bind(
          address,
          atPort,
          reuseAddress: true,
        );
        freshBound.add(socket);
        return socket;
      },
    );
    addTearDown(fresh.dispose);
    fresh.updateSelf(_self);
    expect(fresh.isHealthy, isFalse);

    fresh.rescan();
    await _waitUntil(
      () => fresh.isHealthy,
      reason: 'the rescan to start discovery from cold',
    );
    final int afterStart = freshBound.length;
    expect(afterStart, greaterThan(0));

    await fresh.stop();
    fresh.rescan();
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(fresh.isRunning, isFalse);
    expect(
      freshBound,
      hasLength(afterStart),
      reason: 'a stop is deliberate; a refresh button must not undo it',
    );
  });

  test('rescan starts a service whose start failed', () async {
    // The reported symptom, arriving through the one door the refresh path did
    // not open. `start` reports a port it cannot bind by throwing, the provider
    // that runs it at launch catches that and gives up, and `rescan` used to
    // return early on `!_started` — so **both** buttons were dead, the list
    // stayed empty for the life of the process, and only restarting the app
    // helped.
    final int failPort = await _servicePort();
    final List<String> failLogs = <String>[];
    final List<RawDatagramSocket> failBound = <RawDatagramSocket>[];
    bool refuse = true;

    final DiscoveryService flaky = DiscoveryService(
      discoveryPort: failPort,
      onLog: failLogs.add,
      bind: (InternetAddress address, int atPort) async {
        // Only the listener is refused. Refusing an ephemeral port would be a
        // different failure than the one a real machine produces.
        if (refuse && atPort == failPort) {
          throw const SocketException('discovery port already in use');
        }
        final RawDatagramSocket socket = await RawDatagramSocket.bind(
          address,
          atPort,
          reuseAddress: true,
        );
        failBound.add(socket);
        return socket;
      },
    );
    addTearDown(flaky.dispose);
    flaky.updateSelf(_self);

    await expectLater(flaky.start(), throwsA(isA<SocketException>()));
    expect(flaky.isRunning, isFalse);
    expect(flaky.isListening, isFalse);
    final int afterFailure = failBound.length;

    refuse = false;
    flaky.rescan();

    await _waitUntil(
      () => flaky.isHealthy,
      reason: 'the rescan to start discovery',
      diagnostics: () => '  logs=${failLogs.join(' | ')}',
    );
    expect(
      failLogs.any((String line) => line.contains('discovery was not running')),
      isTrue,
      reason: 'and to say so — a button that repairs something silently is how '
          'this took four builds to find\n  logs=${failLogs.join(' | ')}',
    );
    expect(failBound.length, greaterThan(afterFailure));

    // And it is a working service, not just a flag set: a datagram posted at it
    // is handled, which is the only sense in which "started" means anything.
    final _FakePeer probe = await _FakePeer.bind();
    addTearDown(probe.close);
    await probe.send(_announce(port: probe.port), failPort);
    await _waitUntil(
      () => flaky.table.length == 1,
      reason: 'a peer learned through the recovered service',
      diagnostics: () => '  logs=${failLogs.join(' | ')}',
    );
  });

  test('a disposed service stays disposed even if its start failed', () async {
    // The narrow case that a `_stopped` set *after* `stop`'s early return would
    // miss. A service whose start failed was never running, so `stop` has
    // nothing to close and returns at once — but it is still being told to end,
    // and `dispose` is about to close `changes`. A later rescan reading "not
    // started" as "never tried" would bind a full set of sockets behind that
    // closed stream: announcing, receiving, and reporting none of it.
    final int deadPort = await _servicePort();
    final List<RawDatagramSocket> deadBound = <RawDatagramSocket>[];
    // The port has to come free again, or the guard under test cannot be
    // reached: a binder that refuses forever would stop an unguarded rescan
    // from binding anything, and the test would pass without the guard there.
    bool portBusy = true;

    final DiscoveryService dead = DiscoveryService(
      discoveryPort: deadPort,
      bind: (InternetAddress address, int atPort) async {
        if (portBusy && atPort == deadPort) {
          throw const SocketException('discovery port already in use');
        }
        final RawDatagramSocket socket = await RawDatagramSocket.bind(
          address,
          atPort,
          reuseAddress: true,
        );
        deadBound.add(socket);
        return socket;
      },
    );
    dead.updateSelf(_self);
    await expectLater(dead.start(), throwsA(isA<SocketException>()));
    expect(dead.isRunning, isFalse);

    // Whatever was holding the port has let go — which is what makes the next
    // rescan *able* to succeed, and therefore able to leak.
    portBusy = false;
    await dead.dispose();
    final int afterDispose = deadBound.length;

    dead.rescan();
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(dead.isRunning, isFalse);
    expect(
      deadBound,
      hasLength(afterDispose),
      reason: 'sockets bound behind a closed `changes` stream are invisible '
          'and leaked',
    );
  });

  test('starting is reported even when the network is empty', () async {
    // `changes` used to mean "the table moved", and nothing else. A listener
    // that hears only about peers cannot tell "discovery is not running" from
    // "discovery is running and nobody is out there" — and the device list now
    // says which of those it is, so a start that succeeds onto a quiet network
    // has to be announced. Without this the "not running" warning would outlive
    // the fault that caused it and never come down.
    final DiscoveryService quiet = DiscoveryService(
      discoveryPort: await _servicePort(),
    );
    addTearDown(quiet.dispose);
    quiet.updateSelf(_self);

    final List<void> heard = <void>[];
    final StreamSubscription<void> sub = quiet.changes.listen(heard.add);
    addTearDown(sub.cancel);

    await quiet.start();
    await _waitUntil(
      () => heard.isNotEmpty,
      reason: 'the successful start to be reported to listeners',
    );

    expect(
      quiet.table.peers,
      isEmpty,
      reason: 'and there was genuinely nothing else to report',
    );
  });

  test('a rescan during a start does not begin a second one', () async {
    // `_started` only turns true at the *end* of a start, so the uncovered
    // window is the whole of launch — which is precisely when the provider
    // starts discovery and the app may be coming back to the foreground. Both
    // binds pass `reuseAddress`, so two overlapping starts would both succeed:
    // two listeners on the discovery port, one of them leaked, and the next
    // launch finding its own port taken.
    final int slowPort = await _servicePort();
    // Ports, recorded at bind time rather than sockets read later. A doubled
    // start has the service closing one of its own listeners, and asking a
    // closed socket for `.port` throws — which would fail this test on the way
    // to the assertion instead of letting the assertion say what went wrong.
    final List<int> slowBound = <int>[];
    final List<String> slowLogs = <String>[];
    final DiscoveryService slow = DiscoveryService(
      discoveryPort: slowPort,
      onLog: slowLogs.add,
      bind: (InternetAddress address, int atPort) async {
        await Future<void>.delayed(const Duration(milliseconds: 60));
        final RawDatagramSocket socket = await RawDatagramSocket.bind(
          address,
          atPort,
          reuseAddress: true,
        );
        slowBound.add(socket.port);
        return socket;
      },
    );
    addTearDown(slow.dispose);
    slow.updateSelf(_self);

    final Future<void> first = slow.start();
    slow.rescan();
    slow.rescan();
    await first;
    await _waitUntil(() => slow.isRunning, reason: 'the start to finish');
    // Long enough for a second start, had one been begun, to bind everything.
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(
      slowBound.where((int bound) => bound == slowPort),
      hasLength(1),
      reason: 'exactly one listener on the discovery port\n'
          '  logs=${slowLogs.join(' | ')}',
    );
  });

  // --- Being heard by a network that cannot hear an announce -----------------
  //
  // What these three cover is a one-way network: the peer is fine, it can reach
  // us, and it answers — but our multicast or broadcast has stopped arriving at
  // it, so every announce we send is invisible there. Waiting never repairs it
  // and pressing Rescan always does, because a refresh opens with a probe and a
  // **probe is answered by unicast**. That difference is the whole bug: the list
  // only filled when a human noticed it had not.

  test('the heartbeat asks as well as tells', () async {
    port = await _servicePort();
    final _Wire wire = await _Wire.bind(port);
    addTearDown(wire.close);

    service = DiscoveryService(
      discoveryPort: port,
      announceInterval: const Duration(milliseconds: 60),
      probeEveryRounds: 3,
      // Out of the way: this test is about the heartbeat, not the opening.
      startBurstRounds: 1,
    );
    service.updateSelf(_self);
    await service.start();
    addTearDown(service.dispose);

    await _waitUntil(
      () => wire.probes >= 3,
      reason: 'probes to keep going out on the heartbeat',
      diagnostics: () => '  wire=${wire.summary}',
    );
    expect(
      wire.announces,
      greaterThanOrEqualTo(3),
      reason: 'and the plain announces not to stop: a peer that *can* hear '
          'them still needs them, and they are how this device stays in that '
          'peer\'s list\n  wire=${wire.summary}',
    );
  });

  test('a device coming up introduces itself more than once', () async {
    port = await _servicePort();
    final _Wire wire = await _Wire.bind(port);
    addTearDown(wire.close);

    service = DiscoveryService(
      discoveryPort: port,
      // Long enough that nothing in this test can have come from the
      // heartbeat, so every extra packet is the burst's and nothing else's.
      announceInterval: const Duration(seconds: 30),
      startBurstRounds: 3,
      startBurstGap: const Duration(milliseconds: 50),
    );
    service.updateSelf(_self);
    await service.start();
    addTearDown(service.dispose);

    await _waitUntil(
      () => wire.probes >= 1,
      reason: 'the opening burst to start',
      diagnostics: () => '  wire=${wire.summary}',
    );
    // Fixed rather than polled, because elapsed time *is* what is being
    // measured here: a poll would stop at the first sighting and the span it
    // then computed would be zero by construction. The burst is three rounds
    // 50ms apart, so this is finished long before the wait is.
    await Future<void>.delayed(const Duration(milliseconds: 400));

    expect(
      wire.probeSpan,
      greaterThanOrEqualTo(const Duration(milliseconds: 80)),
      reason: 'the rounds of the opening burst to be spread over time, which '
          'is the whole point of them — three datagrams leaving in the same '
          'instant are three datagrams one Wi-Fi hiccup takes together, and '
          'that is the failure this burst was added to fix\n'
          '  wire=${wire.summary}  span=${wire.probeSpan.inMilliseconds}ms',
    );
    expect(
      wire.announces,
      greaterThanOrEqualTo(2),
      reason: 'and the rounds to introduce this device, not just to ask: a '
          'probe alone leaves the peer that hears it to reply, and there is '
          'no reason to make a working network do that work\n'
          '  wire=${wire.summary}',
    );
  });

  test('a stop during the opening burst ends it', () async {
    port = await _servicePort();
    final _Wire wire = await _Wire.bind(port);
    addTearDown(wire.close);

    service = DiscoveryService(
      discoveryPort: port,
      announceInterval: const Duration(seconds: 30),
      startBurstRounds: 8,
      startBurstGap: const Duration(milliseconds: 120),
    );
    service.updateSelf(_self);
    await service.start();
    addTearDown(service.dispose);

    await _waitUntil(
      () => wire.probes >= 2,
      reason: 'the burst to be under way',
      diagnostics: () => '  wire=${wire.summary}',
    );

    await service.stop();
    // Counted from the probes alone: the goodbye `stop` sends is a packet of
    // its own and would otherwise look like the burst carrying on.
    final int atStop = wire.probes;

    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(
      wire.probes,
      atStop,
      reason: 'a device that has said goodbye must not go on introducing '
          'itself — the bye would be followed by an announce, and every peer '
          'would take it for this device coming back\n  wire=${wire.summary}',
    );
    // What holds that line is `stop` closing the sockets, not the burst timer
    // being cancelled — measured, by deleting the guard that used to sit in the
    // burst and then the cancellation as well, and watching this still pass.
    // So this is a property test, not a test of either line: it fails if the
    // sockets ever outlive the goodbye, which is the refactor that would matter.
  });

  // --- The watchdog: repairing a network that has stopped delivering --------
  //
  // Every other repair in the service is triggered by something arriving — a
  // datagram, a lifecycle change, a finger on Rescan. These cover the failure
  // where nothing arrives, so nothing triggers, and the device list is left
  // showing peers it can no longer hear.

  test(
      'a list of peers that has all gone quiet is rebuilt without being '
      'asked', () async {
    await startService(silentPeerAfter: const Duration(milliseconds: 300));
    await peer.send(_announce(port: peer.port), port);
    await _waitUntil(() => service.table.length == 1, reason: 'the peer');

    final int before = listeners().length;
    await _waitUntil(
      () => listeners().length > before,
      reason: 'discovery to rebuild itself once every peer had gone quiet',
      diagnostics: () => '  logs=${logs.join(' | ')}',
    );
    expect(
      logs.any((String line) => line.contains('watchdog')),
      isTrue,
      reason: 'and to say so, because this is the one repair nobody asked for '
          'and there is otherwise no sign it happened\n  logs=${logs.join(' | ')}',
    );
  });

  test('no repair is made while any peer is still talking', () async {
    await startService(silentPeerAfter: const Duration(milliseconds: 300));
    final int before = listeners().length;

    // Several times the threshold, with an announce well inside it throughout.
    // One peer talking is proof the network is delivering, so the quiet peers
    // are the ones that really have gone and there is nothing here to repair.
    final DateTime until = DateTime.now().add(const Duration(seconds: 3));
    while (DateTime.now().isBefore(until)) {
      await peer.send(_announce(port: peer.port), port);
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }

    expect(
      listeners(),
      hasLength(before),
      reason: 'a rebuild here would close the listening socket every time a '
          'laptop was shut, and it would be closing it on a working network',
    );
  });

  test('one silence gets one repair, not one a second', () async {
    await startService(silentPeerAfter: const Duration(milliseconds: 200));
    await peer.send(_announce(port: peer.port), port);
    await _waitUntil(
      () => service.table.length == 1,
      reason: 'the peer',
      diagnostics: () => '  port=$port peerPort=${peer.port}\n'
          '  table=${service.table.length} running=${service.isRunning}\n'
          '  listeners=${listeners().length} answerers=${answerers().length}\n'
          '  logs=${logs.join(' | ')}\n'
          '  sends=${peer.sendLog.join(' ; ')}\n'
          '  peer received ${peer.received.length} datagrams',
    );

    final int before = listeners().length;
    await _waitUntil(
      () => listeners().length > before,
      reason: 'the first repair',
    );
    final int afterFirstRepair = listeners().length;

    // The peer is still listed and still silent — it has gone home, not broken
    // the network. Several watchdog ticks go by.
    await Future<void>.delayed(const Duration(seconds: 4));
    expect(
      listeners(),
      hasLength(afterFirstRepair),
      reason:
          'the repair to have been made once. Repeated every tick, it would '
          'rebuild discovery over and over on a network where nothing is wrong '
          'and the peer it waits for is simply gone',
    );
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

  test('rescan rebuilds the listening socket, not just the sending ones',
      () async {
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

  test('a stop that lands mid-rebind leaves no socket open behind it',
      () async {
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
