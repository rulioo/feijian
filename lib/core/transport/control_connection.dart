import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../constants.dart';
import '../protocol/frame_codec.dart';
import '../protocol/payloads.dart';
import 'connection_state.dart';
import 'transport_tuning.dart';

/// One TCP connection to one peer — design.md §4.4.
///
/// Owns the socket, the `hello` handshake, framing, the heartbeat and the idle
/// detector. It deliberately does *not* know about reconnecting or about which
/// of two simultaneous connections to a peer should survive; that is
/// `ConnectionManager`'s job, because it has to outlive any single socket.
///
/// The handshake lives here rather than in the server because the peer's device
/// id — the identity everything else is keyed on — only exists once its `hello`
/// has been read, and splitting that read from the rest of the framing would
/// mean two decoders and an awkward handover of buffered bytes.
///
/// Pure Dart. Tests drive it over a real loopback socket rather than a fake,
/// because the parts most likely to be wrong — a frame split across reads, a
/// peer that goes silent, a `bye` that must actually leave the machine — exist
/// only in the real socket.
class ControlConnection {
  ControlConnection._({
    required Socket socket,
    required this.selfHello,
    required this.isOutbound,
    this.tuning = const TransportTuning(),
    this.onLog,
    DateTime Function()? clock,
  }) : _socket = socket,
       _clock = clock ?? DateTime.now;

  /// Opens an outbound connection and sends our `hello` on it.
  ///
  /// Throws [SocketException] if the peer is not listening, and [TimeoutException]
  /// if the SYN goes nowhere — without the timeout a filtered port hangs for the
  /// OS default, which on Windows is over twenty seconds.
  static Future<ControlConnection> connect({
    required InternetAddress address,
    required int port,
    required HelloPayload selfHello,
    TransportTuning tuning = const TransportTuning(),
    void Function(String message)? onLog,
    DateTime Function()? clock,
  }) async {
    final Socket socket = await Socket.connect(
      address,
      port,
      timeout: tuning.connectTimeout,
    );
    final ControlConnection connection = ControlConnection._(
      socket: socket,
      selfHello: selfHello,
      isOutbound: true,
      tuning: tuning,
      onLog: onLog,
      clock: clock,
    );
    connection._listen();
    // First frame on the connection, before anything else (design.md §4.3).
    connection._sendHello();
    return connection;
  }

  /// Wraps a socket accepted by the server. Our `hello` waits for the peer's.
  static ControlConnection accept(
    Socket socket, {
    required HelloPayload selfHello,
    TransportTuning tuning = const TransportTuning(),
    void Function(String message)? onLog,
    DateTime Function()? clock,
  }) {
    final ControlConnection connection = ControlConnection._(
      socket: socket,
      selfHello: selfHello,
      isOutbound: false,
      tuning: tuning,
      onLog: onLog,
      clock: clock,
    );
    connection._listen();
    return connection;
  }

  final Socket _socket;
  final DateTime Function() _clock;

  /// What we announce on this connection.
  final HelloPayload selfHello;

  /// True when this side opened the socket. Which side did decides which of two
  /// simultaneous connections is kept (design.md §4.4).
  final bool isOutbound;

  /// The timeouts this connection runs on.
  final TransportTuning tuning;

  final void Function(String message)? onLog;

  /// Single-subscription, unlike the two below: a connection has exactly one
  /// owner, and if that owner subscribes a turn late the frames wait for it
  /// instead of being dropped. A broadcast controller discards events with no
  /// listener, which for this stream would mean silently losing a message.
  final StreamController<Frame> _frames = StreamController<Frame>();

  final StreamController<ConnectionState> _states =
      StreamController<ConnectionState>.broadcast();

  /// Broadcast because two parties legitimately care: the pool, and the server
  /// tracking which of its accepted sockets are still open.
  final StreamController<ConnectionClosedReason> _closed =
      StreamController<ConnectionClosedReason>.broadcast();

  final FrameDecoder _decoder = FrameDecoder();

  ConnectionState _state = ConnectionState.handshaking;
  ConnectionClosedReason? _reason;
  HelloPayload? _peerHello;
  bool _closing = false;

  StreamSubscription<Uint8List>? _sub;
  Timer? _heartbeat;
  Timer? _idleTimer;
  Timer? _handshakeTimer;

  /// Frames from the peer, after the handshake. Never yields `hello`, `ping`,
  /// `pong` or `bye`: those are this class's business.
  Stream<Frame> get frames => _frames.stream;

  Stream<ConnectionState> get stateChanges => _states.stream;

  /// Fires exactly once, carrying why the connection ended.
  Stream<ConnectionClosedReason> get closed => _closed.stream;

  ConnectionState get state => _state;

  ConnectionClosedReason? get closeReason => _reason;

  HelloPayload? get peerHello => _peerHello;

  /// The peer's device id, or null before its `hello` has been accepted.
  String? get remoteId => _peerHello?.deviceId;

  /// True once the handshake finished. Equivalent to [state] being ready.
  bool get isReady => _state == ConnectionState.ready;

  String get remoteAddress => _socket.remoteAddress.address;

  bool get isHandshakePending => _state == ConnectionState.handshaking;

  /// Writes [frame], reporting whether it went out.
  ///
  /// False means the connection is not writable; the caller must treat the
  /// message as unsent rather than assuming it is on its way.
  bool send(Frame frame) {
    if (_state == ConnectionState.closed) {
      return false;
    }
    try {
      _socket.add(FrameCodec.encode(frame));
      return true;
    } on Object catch (error) {
      // A write to a socket the OS has already torn down throws here rather
      // than surfacing on the read side.
      _log('write failed: $error');
      unawaited(close(ConnectionClosedReason.socketError));
      return false;
    }
  }

  /// Waits for everything written so far to reach the OS.
  Future<void> flush() async {
    if (_state == ConnectionState.closed) {
      return;
    }
    try {
      await _socket.flush();
    } on Object catch (error) {
      _log('flush failed: $error');
      await close(ConnectionClosedReason.socketError);
    }
  }

  /// Sends `bye` and closes. Idempotent, and safe to call from anywhere.
  ///
  /// The flush before the teardown is load-bearing, not tidiness: `destroy()`
  /// discards whatever is still buffered, so without it the `bye` is written to
  /// the buffer and then thrown away, and the peer never learns we left. It is
  /// best effort all the same — a connection is often closed precisely because
  /// the peer stopped responding — hence the cap on how long we will wait.
  Future<void> close([
    ConnectionClosedReason reason = ConnectionClosedReason.localBye,
  ]) async {
    if (_state == ConnectionState.closed || _closing) {
      return;
    }
    _closing = true;

    if (reason == ConnectionClosedReason.localBye) {
      _send(Frame.of(FrameType.bye));
      try {
        await _socket.flush().timeout(tuning.closeFlushTimeout);
      } on Object {
        // Already broken, or too slow to be worth waiting for. Either way the
        // peer reaches the same conclusion from the closing socket.
      }
    }

    _finish(reason);
  }

  // --- Handshake ------------------------------------------------------------

  void _sendHello({ConnectionRole? role}) {
    if (!_send(selfHello.withRole(role ?? selfHello.role).toFrame())) {
      _log('could not send hello');
    }
  }

  void _onHello(HelloPayload hello) {
    _peerHello = hello;

    if (hello.version != kProtocolVersion) {
      // Not fatal: §4.3 requires unknown frames and fields to be tolerated so
      // versions can interoperate. The framing itself is stable, so the useful
      // move is to carry on and say so, not to refuse the peer.
      _log(
        'peer speaks protocol v${hello.version}, this build speaks v$kProtocolVersion',
      );
    }

    // An inbound peer's hello is answered with ours, which is what completes
    // the handshake in both directions. The role is taken from the peer's
    // request, not from our own configuration: one listening socket serves both
    // control and data connections, and only this frame says which it is.
    if (!isOutbound) {
      _sendHello(role: hello.role);
    }

    _handshakeTimer?.cancel();
    _handshakeTimer = null;
    _setState(ConnectionState.ready);
    // Half the idle timeout: two missed heartbeats are survivable, three are
    // the limit, and beating at half the deadline means the peer's timer is
    // re-armed before it can expire.
    _heartbeat = Timer.periodic(tuning.idleTimeout ~/ 2, (_) => _beat());
    _armIdleTimer();
    _log('handshake complete with ${hello.name} (${hello.deviceId})');
  }

  void _listen() {
    _handshakeTimer = Timer(tuning.handshakeTimeout, () {
      if (_state == ConnectionState.handshaking) {
        _log('no hello within ${tuning.handshakeTimeout}');
        unawaited(close(ConnectionClosedReason.handshakeTimeout));
      }
    });

    _sub = _socket.listen(
      _onData,
      onError: (Object error) {
        // A reset by the peer is routine — it is how a vanished device looks.
        _log('socket error: $error');
        unawaited(close(ConnectionClosedReason.socketError));
      },
      onDone: () {
        // The peer closed. If a reason is already recorded this is the tail of
        // an orderly shutdown, and must not be overwritten with a vaguer one.
        unawaited(close(_reason ?? ConnectionClosedReason.remoteBye));
      },
      cancelOnError: false,
    );
  }

  // --- Receiving ------------------------------------------------------------

  void _onData(Uint8List chunk) {
    if (_state == ConnectionState.closed) {
      return;
    }
    // Any byte proves the peer is alive, including one mid-frame: the idle
    // detector is about silence, not about complete messages.
    _armIdleTimer();

    final List<Frame> frames;
    try {
      frames = _decoder.add(chunk);
    } on FrameException catch (error) {
      // The bytes after a framing error are not known to be frame boundaries,
      // so there is nothing to resynchronise to. Dropping the connection is the
      // only safe response (design.md §4.2).
      _log('unusable frame stream: ${error.reason}');
      unawaited(close(ConnectionClosedReason.protocolError));
      return;
    }

    for (final Frame frame in frames) {
      if (_state == ConnectionState.closed) {
        return;
      }
      if (!_handleControlFrame(frame) && _state != ConnectionState.closed) {
        if (!_frames.isClosed) {
          _frames.add(frame);
        }
      }
    }
  }

  /// Consumes the frames that belong to the connection itself.
  ///
  /// Returns true when the frame was one of ours and must not be forwarded.
  bool _handleControlFrame(Frame frame) {
    switch (frame.type) {
      case FrameType.bye:
        unawaited(close(ConnectionClosedReason.remoteBye));
        return true;

      case FrameType.hello:
        if (_state != ConnectionState.handshaking) {
          // A second hello would let a peer rewrite the identity this
          // connection is filed under, mid-conversation.
          _log('ignoring a hello sent after the handshake');
          return true;
        }
        final PayloadDecode<HelloPayload> decoded = HelloPayload.from(frame);
        if (!decoded.isSuccess) {
          _log('bad hello: ${decoded.reason}');
          unawaited(close(ConnectionClosedReason.protocolError));
          return true;
        }
        _onHello(decoded.value!);
        return true;

      case FrameType.ping:
        // Answered here rather than by the manager: a heartbeat is about this
        // socket, and routing it upward would let a busy layer starve it.
        _send(HeartbeatPayload(ts: _clock()).toFrame(FrameType.pong));
        return true;

      case FrameType.pong:
        return true; // liveness is already recorded by arming the idle timer

      default:
        if (!frame.isKnownType) {
          // §4.3: a newer peer may use frames this build has never heard of.
          // Ignoring them is what lets the two interoperate.
          _log('ignoring unknown frame type "${frame.type}"');
          return true;
        }
        if (_state != ConnectionState.ready) {
          // A real frame before the handshake means the peer is not following
          // the protocol; there is no conversation to attach it to yet.
          _log('ignoring "${frame.type}" before the handshake finished');
          return true;
        }
        return false;
    }
  }

  // --- Heartbeat and teardown ----------------------------------------------

  void _beat() {
    if (_state != ConnectionState.ready) {
      return;
    }
    _send(HeartbeatPayload(ts: _clock()).toFrame(FrameType.ping));
  }

  void _armIdleTimer() {
    _idleTimer?.cancel();
    _idleTimer = Timer(tuning.idleTimeout, () {
      _log('nothing received for ${tuning.idleTimeout}');
      unawaited(close(ConnectionClosedReason.idleTimeout));
    });
  }

  /// Writes without the closed-check-and-logging of [send], for internal use
  /// where a failure is already being handled.
  bool _send(Frame frame) {
    try {
      _socket.add(FrameCodec.encode(frame));
      return true;
    } on Object catch (error) {
      _log('write failed: $error');
      unawaited(close(ConnectionClosedReason.socketError));
      return false;
    }
  }

  void _setState(ConnectionState next) {
    if (_state == next) {
      return;
    }
    _state = next;
    if (!_states.isClosed) {
      _states.add(next);
    }
  }

  void _finish(ConnectionClosedReason reason) {
    _reason = reason;
    _heartbeat?.cancel();
    _heartbeat = null;
    _idleTimer?.cancel();
    _idleTimer = null;
    _handshakeTimer?.cancel();
    _handshakeTimer = null;

    _setState(ConnectionState.closed);

    unawaited(_sub?.cancel());
    _sub = null;
    try {
      _socket.destroy();
    } on Object {
      // Already gone; destroying twice is not an error worth reporting.
    }

    if (!_frames.isClosed) {
      unawaited(_frames.close());
    }
    if (!_states.isClosed) {
      unawaited(_states.close());
    }
    // Added before closing — a controller refuses adds once closed. Listeners
    // that need the reason synchronously can also read [closeReason], which is
    // set before any of this.
    if (!_closed.isClosed) {
      _closed.add(reason);
      unawaited(_closed.close());
    }
  }

  void _log(String message) =>
      onLog?.call('conn[${remoteId ?? '?'} ${isOutbound ? 'out' : 'in'}]: $message');
}
