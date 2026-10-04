import 'dart:async';
import 'dart:io';

import '../constants.dart';
import '../discovery/network_interfaces.dart';
import '../protocol/payloads.dart';
import 'control_connection.dart';
import 'transport_tuning.dart';

/// The single TCP listener — design.md §4.4.
///
/// Binds one port and turns every accepted socket into a [ControlConnection].
/// That is deliberately all it does: it does not know which peers matter, which
/// of two connections to a peer should win, or how to reconnect. Those are
/// pool-level questions, and keeping them out of here means the listener can be
/// tested by connecting a plain socket to it.
///
/// The same port as discovery, which is a choice worth restating: an announce
/// already tells every peer our address, and carrying it on one port means one
/// firewall rule to allow rather than two.
class FeijianServer {
  FeijianServer({
    required this.selfHello,
    this.port = kDiscoveryPort,
    this.tuning = const TransportTuning(),
    this.onLog,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// Identity announced on every accepted connection.
  ///
  /// Its `role` is only a default — an inbound connection answers with whatever
  /// role the peer asked for, since one listener serves both (see
  /// `HelloPayload.withRole`).
  final HelloPayload selfHello;

  /// 0 asks the OS for any free port. Tests use that; the app uses the default.
  final int port;

  /// Handed to every connection this server accepts.
  final TransportTuning tuning;

  final void Function(String message)? onLog;

  final DateTime Function() _clock;

  final StreamController<ControlConnection> _incoming =
      StreamController<ControlConnection>.broadcast();

  ServerSocket? _server;
  bool _stopping = false;

  /// Handshaken connections, in arrival order. The handshake itself is not
  /// finished when a connection appears here — [ControlConnection.state] says
  /// when it is.
  Stream<ControlConnection> get incoming => _incoming.stream;

  /// The bound port, or null when not listening. Differs from [port] when 0 was
  /// requested.
  int? get boundPort => _server?.port;

  bool get isRunning => _server != null;

  /// Binds and starts accepting. Throws [SocketException] if the port is taken
  /// — which on Windows is a real possibility, since another copy of the app or
  /// anything else on 24250 will hold it exclusively.
  Future<void> start() async {
    if (_server != null) {
      return;
    }
    _stopping = false;
    final ServerSocket server = await ServerSocket.bind(
      InternetAddress.anyIPv4,
      port,
      // Not shared: two instances on one machine would each get some of the
      // incoming connections, and a half-delivered conversation is worse than
      // a clear "port in use" at startup.
      shared: false,
    );
    _server = server;
    _log('listening on ${server.address.address}:${server.port}');
    server.listen(
      _onSocket,
      onError: (Object error) {
        // The listening socket itself failed, which is not recoverable by
        // retrying the accept. Report and stop rather than spinning.
        _log('listener error: $error');
        unawaited(stop());
      },
      cancelOnError: false,
    );
  }

  /// Stops accepting and closes every connection handed out.
  ///
  /// The connections are tracked here as well as by the pool because a socket
  /// accepted microseconds before [stop] has not reached the pool yet, and
  /// dropping it on the floor would leave it open with nothing holding a
  /// reference to close it.
  ///
  /// Restartable: [incoming] stays live across a stop, so whoever is listening
  /// on it does not have to resubscribe when the network changes. Only
  /// [dispose] ends the stream.
  Future<void> stop() async {
    if (_stopping) {
      return;
    }
    _stopping = true;

    final ServerSocket? server = _server;
    _server = null;
    if (server != null) {
      try {
        await server.close();
      } on Object catch (error) {
        _log('error closing the listener: $error');
      }
    }

    final List<ControlConnection> open =
        List<ControlConnection>.of(_handedOut);
    _handedOut.clear();
    await Future.wait(open.map((ControlConnection c) => c.close()));
    _log('stopped');
  }

  /// Stops and ends [incoming]. The object is not reusable afterwards.
  Future<void> dispose() async {
    await stop();
    if (!_incoming.isClosed) {
      await _incoming.close();
    }
  }

  final Set<ControlConnection> _handedOut = <ControlConnection>{};

  void _onSocket(Socket socket) {
    if (_stopping) {
      socket.destroy();
      return;
    }

    // Refuse anything that did not come from the LAN. The listener is bound to
    // `anyIPv4`, so without this a port-forward would hand the whole internet a
    // socket into the app.
    if (!NetworkInterfaceHelper.isAcceptablePeerAddress(socket.remoteAddress)) {
      _log('refusing a connection from ${socket.remoteAddress.address}');
      socket.destroy();
      return;
    }

    // Chat frames are small and latency-visible; Nagle would sit on a message
    // for up to 40ms waiting for company. File chunks are large enough that the
    // coalescing it would do is worthless anyway.
    try {
      socket.setOption(SocketOption.tcpNoDelay, true);
    } on Object catch (error) {
      _log('could not set tcpNoDelay: $error');
    }

    final ControlConnection connection = ControlConnection.accept(
      socket,
      selfHello: selfHello,
      tuning: tuning,
      onLog: onLog,
      clock: _clock,
    );

    _handedOut.add(connection);
    connection.closed.listen((_) => _handedOut.remove(connection));

    if (_incoming.isClosed) {
      // stop() ran between the accept and here.
      unawaited(connection.close());
      return;
    }
    _incoming.add(connection);
  }

  void _log(String message) => onLog?.call('server: $message');
}
