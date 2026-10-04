/// Not a test file — a shared harness. Named `*_harness.dart` so `flutter test`
/// does not try to run it as one.
///
/// Everything here runs over real loopback sockets rather than a fake. The
/// transport's bugs live in the places a fake would paper over: a frame split
/// across two TCP reads, a peer that stops answering, whether a `bye` actually
/// leaves the machine before the socket is destroyed. A mock would test the
/// mock.
library;

import 'dart:io';

import 'package:feijian/core/constants.dart';
import 'package:feijian/core/models/peer.dart';
import 'package:feijian/core/protocol/payloads.dart';
import 'package:feijian/core/transport/connection_state.dart';
import 'package:feijian/core/transport/control_connection.dart';
import 'package:feijian/core/transport/feijian_server.dart';
import 'package:feijian/core/transport/transport_tuning.dart';
import 'package:flutter_test/flutter_test.dart';

/// The real timings are tens of seconds; these are used instead so a handshake
/// timeout or an ack retry can be observed instead of waited out. The shape of
/// each value relative to the others is the same as production — notably the
/// heartbeat stays half the idle timeout, and retries stay well under the ack
/// window.
const TransportTuning testTuning = TransportTuning(
  handshakeTimeout: Duration(milliseconds: 400),
  idleTimeout: Duration(milliseconds: 900),
  connectTimeout: Duration(seconds: 5),
  closeFlushTimeout: Duration(milliseconds: 500),
  ackTimeout: Duration(milliseconds: 150),
  maxRetries: 3,
  backoff: <Duration>[
    Duration(milliseconds: 40),
    Duration(milliseconds: 40),
  ],
);

/// How long a test will wait for something that should happen promptly. Long
/// enough to survive a loaded CI machine, short enough that a real failure still
/// fails rather than hanging until the suite times out.
const Duration patience = Duration(seconds: 5);

HelloPayload helloFor(
  String deviceId, {
  String? name,
  ConnectionRole role = ConnectionRole.control,
  int port = kDiscoveryPort,
  int version = kProtocolVersion,
  DeviceType deviceType = DeviceType.windows,
  DeviceIcon icon = DeviceIcon.desktop,
}) {
  return HelloPayload(
    role: role,
    deviceId: deviceId,
    name: name ?? deviceId,
    deviceType: deviceType,
    icon: icon,
    port: port,
    version: version,
  );
}

/// Waits until [connection] finishes its handshake.
Future<void> waitForReady(
  ControlConnection connection, {
  Duration timeout = patience,
}) async {
  if (connection.isReady) {
    return;
  }
  await connection.stateChanges
      .firstWhere((ConnectionState s) => s == ConnectionState.ready)
      .timeout(timeout);
}

/// Waits until [connection] finishes, and reports why.
Future<ConnectionClosedReason> waitForClosed(
  ControlConnection connection, {
  Duration timeout = patience,
}) async {
  final ConnectionClosedReason? already = connection.closeReason;
  if (already != null) {
    return already;
  }
  return connection.closed.first.timeout(timeout);
}

/// A dialled connection and the connection it produced on the other side.
class ConnectionPair {
  ConnectionPair({
    required this.outbound,
    required this.inbound,
    required this.server,
  });

  /// The side that dialled.
  final ControlConnection outbound;

  /// The side the server accepted.
  final ControlConnection inbound;

  final FeijianServer server;

  Future<void> close() async {
    await outbound.close();
    await inbound.close();
    await server.dispose();
  }
}

/// Starts a server and dials it, returning both ends once the handshake is done.
Future<ConnectionPair> connectedPair({
  String outboundId = 'device-aaa',
  String inboundId = 'device-bbb',
  ConnectionRole role = ConnectionRole.control,
  TransportTuning tuning = testTuning,
  int serverPort = 0,
}) async {
  final FeijianServer server = FeijianServer(
    selfHello: helloFor(inboundId),
    port: serverPort,
    tuning: tuning,
  );
  await server.start();

  final Future<ControlConnection> accepted = server.incoming.first;
  final ControlConnection outbound = await ControlConnection.connect(
    address: InternetAddress.loopbackIPv4,
    port: server.boundPort!,
    selfHello: helloFor(outboundId, role: role),
    tuning: tuning,
  );
  final ControlConnection inbound = await accepted;

  await waitForReady(outbound);
  await waitForReady(inbound);

  return ConnectionPair(outbound: outbound, inbound: inbound, server: server);
}

/// Waits for [condition] to come true, polling.
///
/// Polling rather than awaiting a stream event on purpose: the manager's streams
/// are broadcast, so a test that subscribes after the thing it is waiting for
/// happened would hang forever instead of failing. Polling the observable state
/// has no such window.
Future<void> waitUntil(
  bool Function() condition, {
  required String describe,
  Duration timeout = patience,
}) async {
  final DateTime deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out after $timeout waiting for $describe');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// Waits until reading [read] produces a value satisfying [done].
///
/// For conditions that live in the database rather than in memory: there is no
/// stream to await, and the write happens on the far side of a socket, so the
/// only way to know is to keep asking. Polling rather than asserting once,
/// because "has the peer stored it yet" has no moment it can be awaited on.
Future<T> waitForValue<T>(
  Future<T> Function() read,
  bool Function(T value) done, {
  required String describe,
  Duration timeout = patience,
}) async {
  final DateTime deadline = DateTime.now().add(timeout);
  T value = await read();
  while (!done(value)) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out after $timeout waiting for $describe (last value: $value)');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
    value = await read();
  }
  return value;
}

/// A port that was free a moment ago.
///
/// Inherently racy — something else could take it between the close and the
/// bind — but the alternative is hard-coding a port and having the suite fail
/// whenever a real Feijian happens to be running on the machine.
Future<int> freePort() async {
  final ServerSocket probe = await ServerSocket.bind(
    InternetAddress.loopbackIPv4,
    0,
  );
  final int port = probe.port;
  await probe.close();
  return port;
}
