import 'dart:async';
import 'dart:collection';
import 'dart:io';

import '../constants.dart';
import '../protocol/frame_codec.dart';
import '../protocol/payloads.dart';
import 'connection_state.dart';
import 'control_connection.dart';
import 'feijian_server.dart';
import 'transport_tuning.dart';

/// A message that arrived from a peer.
///
/// The payload is handed over untouched: acknowledging it is a decision for the
/// layer that can persist it, not for the transport (see [ConnectionManager.sendAck]).
class IncomingMessage {
  const IncomingMessage({required this.peerId, required this.payload});

  final String peerId;
  final MessagePayload payload;

  @override
  String toString() => 'IncomingMessage($peerId, ${payload.msgId})';
}

/// A message we sent that the peer has confirmed receiving.
class MessageDelivered {
  const MessageDelivered({required this.peerId, required this.msgId});

  final String peerId;
  final String msgId;
}

/// A message we gave up on after [kMsgMaxRetries] retries.
class MessageDeliveryFailed {
  const MessageDeliveryFailed({
    required this.peerId,
    required this.msgId,
    required this.attempts,
  });

  final String peerId;
  final String msgId;
  final int attempts;
}

/// A peer's connection went away.
///
/// Worth surfacing because the queue behaves differently depending on why: a
/// `socketError` means the peer is gone and queued messages should wait, while
/// `protocolError` means something is wrong that waiting will not fix.
class PeerConnectionLost {
  const PeerConnectionLost({required this.peerId, required this.reason});

  final String peerId;
  final ConnectionClosedReason reason;
}

/// The connection pool — design.md §4.4 and §4.5.
///
/// Owns one [ControlConnection] per peer, decides which of two simultaneous
/// connections to a peer survives, reconnects with backoff, and tracks the
/// delivery of every message it sends. It knows nothing about the database or
/// the UI: it reports what happened on the wire and lets a higher layer decide
/// what to store and show.
///
/// Connections are opened on demand rather than to every discovered peer.
/// Eagerly connecting to all of them would be N² sockets on a large network,
/// and a peer nobody has clicked on has nothing to say.
class ConnectionManager {
  ConnectionManager({
    required this.selfHello,
    this.port = kDiscoveryPort,
    this.tuning = const TransportTuning(),
    this.onLog,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// Our identity, as sent in every `hello`.
  final HelloPayload selfHello;

  /// TCP port to listen on. 0 asks the OS for a free one (tests).
  final int port;

  /// The timeouts and retry limits in force.
  final TransportTuning tuning;

  final void Function(String message)? onLog;

  final DateTime Function() _clock;

  final Map<String, _Peer> _peers = <String, _Peer>{};

  /// Outbound messages awaiting an `msg_ack`, by `msgId`.
  final Map<String, _PendingMessage> _pending = <String, _PendingMessage>{};

  /// Ids we gave up on, oldest first, so a late ack still reports the truth.
  ///
  /// Bounded, because an unbounded set here is a leak on a long-lived session.
  /// It only has to outlast the retry window plus one round trip, which is
  /// seconds — not the whole session.
  final LinkedHashSet<String> _abandoned = LinkedHashSet<String>();

  final StreamController<String> _peerConnected =
      StreamController<String>.broadcast();
  final StreamController<PeerConnectionLost> _peerLost =
      StreamController<PeerConnectionLost>.broadcast();
  final StreamController<IncomingMessage> _incoming =
      StreamController<IncomingMessage>.broadcast();
  final StreamController<MessageDelivered> _delivered =
      StreamController<MessageDelivered>.broadcast();
  final StreamController<MessageDeliveryFailed> _failed =
      StreamController<MessageDeliveryFailed>.broadcast();

  FeijianServer? _server;
  StreamSubscription<ControlConnection>? _acceptSub;
  bool _stopping = false;

  /// Fires when a peer becomes writable — including a peer that connected to
  /// us, which is how queued messages find their way out without waiting for
  /// the next announce.
  Stream<String> get peerConnected => _peerConnected.stream;

  Stream<PeerConnectionLost> get peerLost => _peerLost.stream;

  Stream<IncomingMessage> get incoming => _incoming.stream;

  Stream<MessageDelivered> get delivered => _delivered.stream;

  Stream<MessageDeliveryFailed> get deliveryFailed => _failed.stream;

  /// The bound listen port, or null when stopped.
  int? get boundPort => _server?.boundPort;

  Set<String> get connectedPeers => <String>{
        for (final MapEntry<String, _Peer> e in _peers.entries)
          if (e.value.connection?.isReady ?? false) e.key,
      };

  bool isConnected(String peerId) => _peers[peerId]?.connection?.isReady ?? false;

  /// True once we have decided this peer is worth keeping a connection to.
  bool isWanted(String peerId) => _peers[peerId]?.wanted ?? false;

  /// How many messages are currently waiting to be acknowledged. Exposed for the
  /// diagnostics screen; a number that keeps climbing means acks are not coming.
  int get pendingAckCount => _pending.length;

  Future<void> start() async {
    if (_server != null) {
      return;
    }
    _stopping = false;
    final FeijianServer server = FeijianServer(
      selfHello: selfHello,
      port: port,
      tuning: tuning,
      onLog: onLog,
      clock: _clock,
    );
    await server.start();
    _server = server;
    _acceptSub = server.incoming.listen(_adopt);
    _log('started on port ${server.boundPort}');
  }

  /// Closes every connection and stops listening. Restartable.
  Future<void> stop() async {
    if (_stopping) {
      return;
    }
    _stopping = true;

    for (final _Peer peer in _peers.values) {
      peer.retryTimer?.cancel();
      peer.retryTimer = null;
      peer.connecting = false;
      peer.wanted = false;
    }
    for (final _PendingMessage pending in _pending.values) {
      pending.timer?.cancel();
    }
    _pending.clear();
    _abandoned.clear();

    await _acceptSub?.cancel();
    _acceptSub = null;

    final List<ControlConnection> live = <ControlConnection>[
      for (final _Peer peer in _peers.values)
        if (peer.connection != null) peer.connection!,
    ];
    for (final _Peer peer in _peers.values) {
      peer.connection = null;
    }

    // The server closes anything it accepted but has not handed over yet; these
    // are the ones it already handed over.
    await Future.wait(live.map((ControlConnection c) => c.close()));

    final FeijianServer? server = _server;
    _server = null;
    if (server != null) {
      await server.stop();
    }
    _log('stopped');
  }

  /// Ends [incoming] and the other streams. The object is not reusable after.
  Future<void> dispose() async {
    await stop();
    await Future.wait(<Future<void>>[
      _peerConnected.close(),
      _peerLost.close(),
      _incoming.close(),
      _delivered.close(),
      _failed.close(),
    ]);
  }

  // --- Public API -----------------------------------------------------------

  /// Makes sure a connection to [peerId] exists, dialling [address] if not.
  ///
  /// Safe to call repeatedly — the state layer calls it whenever an announce
  /// refreshes a peer's address, which is also how a peer that moved off the
  /// default port is picked up.
  void requireConnection(
    String peerId, {
    required InternetAddress address,
    int? port,
    bool wanted = true,
  }) {
    if (_stopping || peerId == selfHello.deviceId) {
      return;
    }
    final _Peer peer = _peerFor(peerId);
    peer.address = address;
    if (port != null && port >= 1 && port <= 65535) {
      peer.port = port;
    }
    if (wanted) {
      peer.wanted = true;
    }
    if (peer.connection != null || peer.connecting) {
      return;
    }
    unawaited(_connect(peer));
  }

  /// Stops keeping a connection to [peerId] alive and closes the current one.
  ///
  /// Called when a peer is removed from the device list, so a device that has
  /// left the network is not dialled every thirty seconds forever.
  Future<void> release(String peerId) async {
    final _Peer? peer = _peers.remove(peerId);
    if (peer == null) {
      return;
    }
    peer.wanted = false;
    peer.retryTimer?.cancel();
    peer.retryTimer = null;
    _cancelPendingFor(peerId);
    final ControlConnection? connection = peer.connection;
    peer.connection = null;
    if (connection != null) {
      _notifyLost(peerId, ConnectionClosedReason.localBye);
      await connection.close();
    }
  }

  /// Sends [payload] to [peerId], reporting whether it went out.
  ///
  /// False means there is no usable connection right now and the caller still
  /// owns the message — it is not queued here. Delivery tracking only starts
  /// once the frame is actually written, so a message that never left is never
  /// reported as sent.
  bool sendMessage(String peerId, MessagePayload payload) {
    final _Peer? peer = _peers[peerId];
    final ControlConnection? connection = peer?.connection;
    if (connection == null || !connection.isReady) {
      return false;
    }
    if (!connection.send(payload.toFrame())) {
      return false;
    }
    peer!.wanted = true;
    _trackPending(peerId, payload);
    return true;
  }

  /// Confirms receipt of [msgId] to [peerId].
  ///
  /// Deliberately not automatic. An ack means "I have this and it will survive
  /// a crash", so it must follow the database write, not the socket read. An
  /// auto-ack would make the sender's tick truthful about the network and a lie
  /// about the message.
  ///
  /// Duplicates must be acked too: the sender is retrying precisely because it
  /// never saw an ack, and going quiet would leave it retrying until it gave up
  /// on a message that arrived the first time.
  bool sendAck(String peerId, String msgId) {
    final ControlConnection? connection = _peers[peerId]?.connection;
    if (connection == null || !connection.isReady) {
      return false;
    }
    return connection.send(MsgAckPayload(msgId: msgId, ts: _clock()).toFrame());
  }

  /// Closes the connection to [peerId] without forgetting the peer.
  ///
  /// Idempotent, and does not schedule a retry: this is a deliberate close.
  Future<void> disconnect(String peerId) async {
    final _Peer? peer = _peers[peerId];
    if (peer == null) {
      return;
    }
    peer.wanted = false;
    peer.retryTimer?.cancel();
    peer.retryTimer = null;
    _cancelPendingFor(peerId);
    final ControlConnection? connection = peer.connection;
    peer.connection = null;
    if (connection != null) {
      // Reported even though we are the ones closing it: `peerLost` means "this
      // peer stopped being reachable", and a layer that flushes its queue on
      // connect has to hear about the other direction too.
      _notifyLost(peerId, ConnectionClosedReason.localBye);
      await connection.close();
    }
  }

  void _notifyLost(String peerId, ConnectionClosedReason reason) {
    if (!_peerLost.isClosed) {
      _peerLost.add(PeerConnectionLost(peerId: peerId, reason: reason));
    }
  }

  // --- Connections ----------------------------------------------------------

  _Peer _peerFor(String peerId) =>
      _peers.putIfAbsent(peerId, () => _Peer(peerId));

  Future<void> _connect(_Peer peer) async {
    final InternetAddress? address = peer.address;
    if (_stopping || peer.connecting || peer.connection != null) {
      return;
    }
    if (address == null) {
      // Nothing to dial: we have never been told where this peer lives.
      return;
    }
    peer.connecting = true;
    try {
      final ControlConnection connection = await ControlConnection.connect(
        address: address,
        port: peer.port,
        selfHello: selfHello,
        tuning: tuning,
        onLog: onLog,
        clock: _clock,
      );
      _adopt(connection);
    } on Object catch (error) {
      // A refused connection is the ordinary case — the peer is not listening,
      // which is what an app that is closed looks like. It is not an error
      // worth a stack trace, only a retry.
      peer.connecting = false;
      _log('could not reach ${peer.peerId} at $address: $error');
      if (peer.wanted && !_stopping) {
        _scheduleRetry(peer);
      }
    }
  }

  /// Starts tracking a connection. Reads its frames from here on.
  void _adopt(ControlConnection connection) {
    if (_stopping) {
      unawaited(connection.close());
      return;
    }
    connection.frames.listen((Frame frame) => _onFrame(connection, frame));
    connection.stateChanges.listen((ConnectionState state) {
      if (state == ConnectionState.ready) {
        _onReady(connection);
      }
    });
    connection.closed.listen((ConnectionClosedReason reason) {
      _onClosed(connection, reason);
    });

    // `stateChanges` is broadcast, so a `ready` that happened before this
    // subscription would be lost and the peer would never be recorded. Checking
    // the current state closes that window; `_onReady` is idempotent.
    if (connection.isReady) {
      _onReady(connection);
    }
  }

  void _onReady(ControlConnection connection) {
    final HelloPayload? hello = connection.peerHello;
    final String? peerId = connection.remoteId;
    if (hello == null || peerId == null) {
      return;
    }

    if (peerId == selfHello.deviceId) {
      // We found ourselves — our own announce came back off the network and we
      // dialled our own port. Harmless, but it is not a peer and must never be
      // shown as one.
      _log('closing a connection to ourselves');
      unawaited(connection.close());
      return;
    }

    if (hello.role != ConnectionRole.control) {
      // A data connection is one file transfer's socket (design.md §4.4), and
      // nothing in this build speaks it. Closing is the honest answer; M3 will
      // route it instead.
      _log('refusing a "${hello.role.wire}" connection from $peerId');
      unawaited(connection.close());
      return;
    }

    final _Peer peer = _peerFor(peerId);
    if (identical(peer.connection, connection)) {
      // Already handled — the ready check in `_adopt` can race the stream event.
      return;
    }
    peer.address ??= InternetAddress(connection.remoteAddress);
    peer.port = hello.port;
    peer.wanted = true;

    final ControlConnection? current = peer.connection;
    if (current != null && current.isReady) {
      if (!_candidateWins(connection, current, peerId)) {
        _log('duplicate connection to $peerId; keeping the existing one');
        unawaited(connection.close());
        return;
      }
      _log('duplicate connection to $peerId; keeping the new one');
      peer.connection = connection;
      peer.retryTimer?.cancel();
      peer.retryTimer = null;
      peer.connecting = false;
      // Anything written on the outgoing socket and never acked goes out again
      // on this one — see [_resendUnacked].
      _resendUnacked(peerId, connection);
      // No `peerConnected`: the peer never stopped being reachable, and a
      // spurious event would flush the offline queue a second time.
      unawaited(current.close(ConnectionClosedReason.localBye));
      return;
    }

    peer.connection = connection;
    peer.attempt = 0;
    peer.connecting = false;
    peer.retryTimer?.cancel();
    peer.retryTimer = null;
    _log('ready: ${hello.name} ($peerId)');
    if (!_peerConnected.isClosed) {
      _peerConnected.add(peerId);
    }
  }

  /// Which of two live connections to a peer to keep — design.md §4.4.
  ///
  /// Both ends must reach the same answer without negotiating, so the rule is
  /// stated in terms both can compute: the connection *opened by the device
  /// with the smaller id* wins. Each side sees one inbound and one outbound, so
  /// each keeps a different one of the two sockets and both survive.
  ///
  /// Preferring "mine" or "the newest" instead would make both ends keep the
  /// same socket and discard the other, and the discarded pair includes the one
  /// the winner is built on — so a simultaneous connect would leave the peers
  /// disconnected rather than connected.
  bool _candidateWins(
    ControlConnection candidate,
    ControlConnection current,
    String peerId,
  ) {
    final bool weAreSmaller = selfHello.deviceId.compareTo(peerId) < 0;
    final bool candidateIsOurs = candidate.isOutbound;
    final bool currentIsOurs = current.isOutbound;

    if (candidateIsOurs != currentIsOurs) {
      // The normal case: one each way, and the rule decides cleanly.
      return candidateIsOurs == weAreSmaller;
    }

    // Two connections the same way round. `requireConnection` never opens a
    // second outbound while one is tracked, so this needs a peer that dialled
    // us twice, or a bug. Keep the incumbent: that at least does not churn a
    // working connection, and the case is rare enough to be worth logging
    // rather than engineering for.
    _log(
      'two ${candidateIsOurs ? 'outbound' : 'inbound'} connections to $peerId; '
      'keeping the incumbent',
    );
    return false;
  }

  void _onClosed(ControlConnection connection, ConnectionClosedReason reason) {
    final String? peerId = connection.remoteId;

    // A connection that was already replaced finishes here after the newcomer
    // took its place. Nothing to do: the peer is still connected, and clearing
    // the slot now would orphan the live connection.
    if (peerId == null) {
      return;
    }
    final _Peer? peer = _peers[peerId];
    if (peer == null || !identical(peer.connection, connection)) {
      _log('$peerId: superseded connection closed (${reason.name})');
      return;
    }

    peer.connection = null;
    peer.connecting = false;
    _cancelPendingFor(peerId);
    _log('$peerId: disconnected (${reason.name})');

    _notifyLost(peerId, reason);

    if (peer.wanted && !_stopping) {
      _scheduleRetry(peer);
    }
  }

  void _scheduleRetry(_Peer peer) {
    if (peer.retryTimer != null || _stopping) {
      return;
    }
    final Duration wait = tuning.backoffFor(peer.attempt);
    peer.attempt++;
    _log('retrying ${peer.peerId} in $wait (attempt ${peer.attempt})');
    peer.retryTimer = Timer(wait, () {
      peer.retryTimer = null;
      unawaited(_connect(peer));
    });
  }

  // --- Frames ---------------------------------------------------------------

  void _onFrame(ControlConnection connection, Frame frame) {
    final String? peerId = connection.remoteId;
    if (peerId == null) {
      return;
    }
    switch (frame.type) {
      case FrameType.msg:
        final PayloadDecode<MessagePayload> decoded = MessagePayload.from(frame);
        if (!decoded.isSuccess) {
          // One unreadable message is not a reason to drop a working
          // connection (§4.3 drops the connection for framing errors only).
          _log('bad msg from $peerId: ${decoded.reason}');
          return;
        }
        if (!_incoming.isClosed) {
          _incoming.add(IncomingMessage(peerId: peerId, payload: decoded.value!));
        }
        return;

      case FrameType.msgAck:
        final PayloadDecode<MsgAckPayload> decoded = MsgAckPayload.from(frame);
        if (!decoded.isSuccess) {
          _log('bad msg_ack from $peerId: ${decoded.reason}');
          return;
        }
        _onAck(peerId, decoded.value!.msgId);
        return;

      default:
        // File transfer and anything a newer build invents. `file_*` belongs to
        // M3; unknown types are ignored on purpose so versions interoperate
        // (§4.3). Both are logged once per frame here rather than at the
        // connection, because this is the layer that knows it is unimplemented
        // rather than unrecognised.
        _log('unhandled "${frame.type}" from $peerId');
        return;
    }
  }

  // --- Delivery tracking ----------------------------------------------------

  void _trackPending(String peerId, MessagePayload payload) {
    // A resend of the same `msgId` — the offline queue reusing its id after a
    // reconnect — replaces the old entry rather than doubling the timers.
    _pending.remove(payload.msgId)?.timer?.cancel();
    _abandoned.remove(payload.msgId);
    final _PendingMessage pending = _PendingMessage(peerId: peerId, payload: payload);
    _pending[payload.msgId] = pending;
    _armAckTimer(pending);
  }

  /// Sends everything unacknowledged for [peerId] again over [connection].
  ///
  /// The moment this exists for: two devices that announce at each other dial
  /// each other, so for a short while both sockets are up and §4.4's tie-break
  /// has not been applied yet. The flush that the first `peerConnected` starts
  /// can write into whichever socket is current at that instant — including the
  /// one about to be discarded. When that happens the receiver may never see the
  /// frame, and nothing else would notice: the message is `sent` as far as the
  /// queue is concerned, so only the ack timer recovers it, ten seconds later.
  ///
  /// Re-sending costs one duplicate frame on the new socket. The receiver
  /// dedupes it by `msgId` and acks again (§4.5), so the message ends up exactly
  /// where it should be, without the stall.
  void _resendUnacked(String peerId, ControlConnection connection) {
    for (final _PendingMessage pending
        in _pending.values.toList(growable: false)) {
      if (pending.peerId != peerId) {
        continue;
      }
      // Not counted as a retry: the peer is not failing to answer, we changed
      // the socket underneath it. A write that fails here needs no handling
      // either — the ack timer is still armed and covers it.
      if (connection.send(pending.payload.toFrame())) {
        _armAckTimer(pending);
      }
    }
  }

  void _armAckTimer(_PendingMessage pending) {
    pending.timer?.cancel();
    pending.timer = Timer(tuning.ackTimeout, () {
      if (_stopping) {
        return;
      }
      final ControlConnection? connection = _peers[pending.peerId]?.connection;
      if (connection == null || !connection.isReady) {
        // The connection died while we were waiting, so there is nobody left to
        // ack. Drop the tracking without calling it failed: the message may
        // well be delivered by the offline queue's resend after a reconnect,
        // and a ⚠ that turns back into ✓✓ is worse than no warning.
        _pending.remove(pending.payload.msgId);
        return;
      }
      if (pending.attempts >= tuning.maxRetries) {
        _pending.remove(pending.payload.msgId);
        _rememberAbandoned(pending.payload.msgId);
        _log(
          'giving up on ${pending.payload.msgId} to ${pending.peerId} '
          'after ${tuning.maxRetries} retries',
        );
        if (!_failed.isClosed) {
          _failed.add(MessageDeliveryFailed(
            peerId: pending.peerId,
            msgId: pending.payload.msgId,
            attempts: pending.attempts,
          ));
        }
        return;
      }
      pending.attempts++;
      if (!connection.send(pending.payload.toFrame())) {
        _pending.remove(pending.payload.msgId);
        return;
      }
      _armAckTimer(pending);
    });
  }

  void _onAck(String peerId, String msgId) {
    final _PendingMessage? pending = _pending.remove(msgId);
    pending?.timer?.cancel();

    if (pending == null && !_abandoned.remove(msgId)) {
      // An ack for something we never sent, or sent so long ago we have
      // forgotten it. Reporting it would invent a message in the UI.
      _log('ack from $peerId for unknown msgId $msgId');
      return;
    }
    if (!_delivered.isClosed) {
      _delivered.add(MessageDelivered(peerId: peerId, msgId: msgId));
    }
  }

  void _rememberAbandoned(String msgId) {
    _abandoned.add(msgId);
    while (_abandoned.length > _abandonedWindow) {
      _abandoned.remove(_abandoned.first);
    }
  }

  void _cancelPendingFor(String peerId) {
    final List<String> mine = <String>[
      for (final MapEntry<String, _PendingMessage> e in _pending.entries)
        if (e.value.peerId == peerId) e.key,
    ];
    for (final String msgId in mine) {
      _pending.remove(msgId)?.timer?.cancel();
    }
  }

  void _log(String message) => onLog?.call('conn-mgr: $message');

  /// How many given-up ids stay remembered to recognise a very late ack.
  /// Small: it only has to outlast the retry window plus one round trip.
  static const int _abandonedWindow = 256;
}

class _Peer {
  _Peer(this.peerId);

  final String peerId;
  ControlConnection? connection;
  InternetAddress? address;
  int port = kDiscoveryPort;

  /// True once something asked for this peer to be reachable. A peer we have
  /// never been asked about is never dialled, and one we only met because it
  /// dialled us stops being retried once it is released.
  bool wanted = false;

  /// A connect attempt is in flight. Without this, `requireConnection` called
  /// on every announce would open a socket per announce while the first was
  /// still connecting.
  bool connecting = false;

  int attempt = 0;
  Timer? retryTimer;
}

class _PendingMessage {
  _PendingMessage({required this.peerId, required this.payload});

  final String peerId;
  final MessagePayload payload;

  /// Retries already spent. The first send is not a retry, so a fresh message
  /// starts at zero and gets [kMsgMaxRetries] more attempts.
  int attempts = 0;

  Timer? timer;
}
