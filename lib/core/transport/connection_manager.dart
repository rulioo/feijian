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

/// A file-transfer frame from a peer — design.md §4.3.
///
/// Handed up as the raw [Frame] rather than a parsed payload, because which
/// payload a frame is depends on its type and the transfer it belongs to is
/// keyed on its `xferId` — both of which the session layer knows and this one
/// does not. The alternative, parsing here, would put the offer/accept/reject
/// state machine's vocabulary into the connection pool.
class IncomingTransferFrame {
  const IncomingTransferFrame({required this.peerId, required this.frame});

  final String peerId;
  final Frame frame;

  @override
  String toString() => 'IncomingTransferFrame($peerId, ${frame.type})';
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

/// Why a dialled connection produced no peer — see
/// [ConnectionManager.connectToAddress].
///
/// Two outcomes rather than one because they call for two different next moves.
/// "Could not connect" would send a user who mistyped their own address out
/// looking for a device that is sitting in front of them.
enum DialProblem {
  /// No usable control connection came out of that address: nothing was
  /// listening, something accepted but never spoke the protocol, or it hung up
  /// before the handshake finished. All three look the same from here and are
  /// fixed the same way — check that the other device has the app running and
  /// that the address is still right.
  unreachable,

  /// The address answered as this device.
  thisDevice,
}

/// The outcome of [ConnectionManager.connectToAddress].
class DialResult {
  const DialResult._(this.hello, this.problem);

  const DialResult.connected(HelloPayload hello) : this._(hello, null);

  const DialResult.failed(DialProblem problem) : this._(null, problem);

  /// What the peer said about itself, when the dial produced a live connection.
  final HelloPayload? hello;

  /// Why it did not, when it did not.
  final DialProblem? problem;

  bool get isConnected => hello != null;
}

/// A `role: data` connection a peer opened for one of its transfers —
/// design.md §4.4.
///
/// Handed over rather than kept, because a data connection is not the pool's
/// kind of object: it belongs to one transfer for the length of that transfer,
/// it says nothing about whether the peer is reachable, and it must never
/// trigger a reconnect. What the pool does keep is the [xferId] the peer named
/// in its `hello`, which is what lets the transfer layer claim it before
/// reading a byte.
class DataConnection {
  const DataConnection({
    required this.peerId,
    required this.xferId,
    required this.connection,
  });

  /// Who opened it.
  final String peerId;

  /// The transfer it is for, as the peer named it in its `hello`.
  ///
  /// Never null here: a data connection that names no transfer is closed before
  /// it reaches this class, because there is nothing that could ever claim it.
  final String xferId;

  /// The socket. Its `frames` are unread — the receiver subscribes, and whoever
  /// subscribes owns every frame on it.
  final ControlConnection connection;

  @override
  String toString() => 'DataConnection($peerId, $xferId)';
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
  final StreamController<DataConnection> _dataConnections =
      StreamController<DataConnection>.broadcast();
  final StreamController<IncomingTransferFrame> _transferFrames =
      StreamController<IncomingTransferFrame>.broadcast();

  /// Every live `role: data` socket, whichever side opened it.
  ///
  /// Tracked for exactly one reason: [stop] has to close them. They are
  /// deliberately not in `_peers` — a data connection is a transfer's, not a
  /// peer's, and putting it there would have the pool's dedupe, retry and
  /// lost-peer logic act on a socket none of that applies to.
  final Set<ControlConnection> _dataSockets = <ControlConnection>{};

  /// Connections whose role has already been decided.
  ///
  /// `_onReady` runs from both a `stateChanges` event and a readiness check, and
  /// routing a socket twice would try to listen to its single-subscription frame
  /// stream a second time.
  final Set<ControlConnection> _routed = <ControlConnection>{};

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

  /// Accepted `role: data` connections, for whoever runs file transfers.
  ///
  /// Broadcast, and closing an unclaimed data connection is deliberate: it
  /// arrives without anyone asking for it, so a socket nobody is listening for
  /// is a socket nobody will ever close. The transfer layer subscribes when it
  /// is constructed rather than when the user first opens a conversation, or
  /// every transfer offered before then would be refused.
  Stream<DataConnection> get dataConnections => _dataConnections.stream;

  /// `file_offer`, `file_accept`, `file_reject`, `file_done`, `file_cancel` and
  /// `xfer_done` — everything a transfer says on the control connection.
  ///
  /// The handshake itself travels here rather than on the data connection,
  /// because the data connection does not exist until `file_accept` has been
  /// answered (design.md §4.6). Like [dataConnections] this is broadcast and
  /// unclaimed frames are dropped rather than buffered: a transfer frame is
  /// about a transfer, and a pool that held them for a session layer which
  /// never arrived would grow without bound.
  Stream<IncomingTransferFrame> get transferFrames => _transferFrames.stream;

  /// The bound listen port, or null when stopped.
  int? get boundPort => _server?.boundPort;

  Set<String> get connectedPeers => <String>{
        for (final MapEntry<String, _Peer> e in _peers.entries)
          if (e.value.connection?.isReady ?? false) e.key,
      };

  bool isConnected(String peerId) =>
      _peers[peerId]?.connection?.isReady ?? false;

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

    // Data connections are reached separately because they have no `_Peer` to
    // be found through. They stop with everything else: a transfer in flight
    // when the user quits is over either way, and leaving its socket open would
    // keep the app alive on Android.
    final List<ControlConnection> data =
        List<ControlConnection>.of(_dataSockets);
    _dataSockets.clear();

    // The server closes anything it accepted but has not handed over yet; these
    // are the ones it already handed over.
    await Future.wait(<Future<void>>[
      for (final ControlConnection c in live) c.close(),
      for (final ControlConnection c in data) c.close(),
    ]);

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
      _dataConnections.close(),
      _transferFrames.close(),
    ]);
    _routed.clear();
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

  /// Dials [address] directly and reports what answered.
  ///
  /// The Add-by-IP path (design.md §4.1). It is separate from
  /// [requireConnection] because the caller has no device id to key the request
  /// on — the id is the *result* of this call, not its input. A router with AP
  /// isolation drops multicast, so discovery never sees the device and there is
  /// nothing to key on until a connection has been made; this is the only way in.
  ///
  /// On success the peer is registered exactly as an announce-driven one would
  /// be, so announces, retries after a drop and message sends all work
  /// unchanged. The caller is expected to put the returned hello into the device
  /// list — this does not, because the transport has no device list.
  Future<DialResult> connectToAddress(
    InternetAddress address, {
    int? port,
    Duration? timeout,
  }) async {
    if (_stopping) {
      return const DialResult.failed(DialProblem.unreachable);
    }
    final int targetPort = port ?? kDiscoveryPort;

    final ControlConnection connection;
    try {
      connection = await ControlConnection.connect(
        address: address,
        port: targetPort,
        selfHello: selfHello,
        tuning: tuning,
        onLog: onLog,
        clock: _clock,
      );
    } on Object catch (error) {
      // The ordinary case, and not worth a stack trace: nothing is listening on
      // that address, or the router dropped it. Unlike an announce-driven dial
      // there is no retry to fall back on — the user typed the address, so the
      // user is the one who hears about it.
      _log('could not reach $address:$targetPort: $error');
      return const DialResult.failed(DialProblem.unreachable);
    }

    // Adopted before the handshake completes, not after. A peer that greets us
    // with its `hello` and a message in the same read would otherwise have the
    // message arrive with nobody reading the frames, and `_frames` is
    // single-subscription — a frame with no listener is dropped, not buffered.
    _adopt(connection);

    final HelloPayload? hello =
        await _helloWithin(connection, timeout ?? tuning.handshakeTimeout);
    if (hello == null) {
      await connection.close();
      return const DialResult.failed(DialProblem.unreachable);
    }

    // Named for the user rather than re-decided: `_onReady` already closed the
    // socket over this, one microtask ago.
    if (hello.deviceId == selfHello.deviceId) {
      await connection.close();
      return const DialResult.failed(DialProblem.thisDevice);
    }

    // One check covers the rest. `_adopt` subscribed before `_helloWithin` did,
    // so `_onReady` has already run by now — it registers the peer for every
    // connection that survives, and applies §4.4's tie-break against one that
    // already exists. So "the manager's connection for this id is this
    // connection" asks exactly "did this dial produce the peer's live socket".
    //
    // A role other than `control` needs no case of its own: `_onReady` closes
    // such a connection, so it lands in the failure below with the same advice,
    // which is the same advice either way.
    final _Peer? peer = _peers[hello.deviceId];
    if (identical(peer?.connection, connection)) {
      return DialResult.connected(hello);
    }

    // Losing the tie-break is not a failure to report. The user asked to reach a
    // device, and the device is reached — over the other socket, which is the one
    // §4.4 says both ends should keep. Only an unreachable peer is a failure.
    if (peer?.connection?.isReady ?? false) {
      // No close here: the tie-break in `_onReady` is what discarded this socket,
      // and it has already done so.
      _log('$address:$targetPort answered; keeping the connection already up');
      return DialResult.connected(hello);
    }

    // It greeted us and then went away, or the manager was stopped mid-dial.
    _log('$address:$targetPort answered but the connection is not usable');
    await connection.close();
    return const DialResult.failed(DialProblem.unreachable);
  }

  /// Waits for [connection] to finish its handshake, or gives up and returns
  /// null.
  ///
  /// `stateChanges` is broadcast, so a `ready` that already happened would never
  /// be seen — and that is the common case here, since a peer on the same LAN
  /// usually answers before this runs. The [ControlConnection.isReady] check
  /// closes that window, and is safe without a subscription because nothing can
  /// run between the check and the `listen`: there is no `await` in between.
  Future<HelloPayload?> _helloWithin(
    ControlConnection connection,
    Duration timeout,
  ) {
    if (connection.isReady) {
      return Future<HelloPayload?>.value(connection.peerHello);
    }

    final Completer<HelloPayload?> done = Completer<HelloPayload?>();
    late final StreamSubscription<ConnectionState> states;
    late final StreamSubscription<ConnectionClosedReason> closed;
    Timer? timer;

    void finish(HelloPayload? hello) {
      if (done.isCompleted) {
        return;
      }
      timer?.cancel();
      unawaited(states.cancel());
      unawaited(closed.cancel());
      done.complete(hello);
    }

    states = connection.stateChanges.listen((ConnectionState state) {
      if (state == ConnectionState.ready) {
        finish(connection.peerHello);
      }
    });
    // A connection that ends without ever becoming ready has to finish this too,
    // or a refusal would sit here for the whole timeout on a socket already gone.
    closed =
        connection.closed.listen((ConnectionClosedReason _) => finish(null));
    timer = Timer(timeout, () => finish(null));

    return done.future;
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

  /// Writes a file-transfer [frame] on the control connection to [peerId].
  ///
  /// Deliberately has no delivery tracking, unlike [sendMessage]. A `msg` is
  /// owed to the peer until it is acked; a `file_offer` is not — it is the first
  /// step of a handshake whose next step has a deadline, and re-sending an offer
  /// the peer already accepted would be a second transfer of the same file. The
  /// sender waits for an answer and gives up, which is what the transfer layer
  /// is for.
  bool sendTransfer(String peerId, Frame frame) {
    final ControlConnection? connection = _peers[peerId]?.connection;
    if (connection == null || !connection.isReady) {
      return false;
    }
    return connection.send(frame);
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

  /// Starts tracking a connection's lifecycle.
  ///
  /// Deliberately does *not* start reading its frames. What a connection is for
  /// is only known once its `hello` has arrived, and `ControlConnection.frames`
  /// is single-subscription: whichever layer attaches first owns every frame on
  /// the socket. A control connection's frames belong here and a data
  /// connection's belong to the transfer that asked for it, so the subscription
  /// waits for the role — see [_onReady]. Nothing is lost by waiting, since the
  /// controller buffers until a listener arrives.
  void _adopt(ControlConnection connection) {
    if (_stopping) {
      unawaited(connection.close());
      return;
    }
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
    if (!_routed.add(connection)) {
      // Already handled — the readiness check in `_adopt` can race the stream
      // event, and a second pass would try to listen to the frame stream twice.
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
      _routeData(connection, peerId, hello);
      return;
    }

    connection.frames.listen((Frame frame) => _onFrame(connection, frame));

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

  /// Hands an accepted `role: data` connection to the transfer that asked for
  /// it — design.md §4.4.
  ///
  /// The pool's involvement ends here. It does not read the socket and does not
  /// file the peer anywhere: a data connection is one transfer's property for
  /// the length of that transfer, and it is not evidence that the peer is
  /// reachable or unreachable.
  void _routeData(
    ControlConnection connection,
    String peerId,
    HelloPayload hello,
  ) {
    if (connection.isOutbound) {
      // Unreachable today: `_adopt` is only given sockets the server accepted
      // and the control dial. Guarded anyway, because an outbound data
      // connection already has an owner — the caller of [connectData] is
      // holding it — and routing it here would hand one socket to two readers.
      _log('ignoring a self-opened data connection to $peerId');
      return;
    }

    final String? xferId = hello.xferId;
    if (xferId == null) {
      // No transfer can ever claim this socket: the peer opened it without
      // saying which one it belongs to, and with up to [kMaxConcurrentXfers]
      // running there is nothing to infer it from. Closing beats holding a
      // socket and a heartbeat open on behalf of a transfer that is not ours.
      _log('closing an unattributed data connection from $peerId');
      unawaited(connection.close());
      return;
    }

    if (!_dataConnections.hasListener) {
      // What the pool did before transfers existed, now with the right reason
      // in the log: a data connection arrives without anyone asking for it, so
      // an unclaimed one is a socket nobody would ever close.
      _log('no transfer layer is listening; refusing data from $peerId');
      unawaited(connection.close());
      return;
    }

    _trackData(connection);
    _dataConnections.add(
      DataConnection(peerId: peerId, xferId: xferId, connection: connection),
    );
  }

  /// Opens a `role: data` connection to [peerId] for one transfer.
  ///
  /// Separate from the control connection on purpose (design.md §4.6): file
  /// bytes on the control socket would block the heartbeats and chat messages
  /// queued behind a multi-gigabyte file, and cancelling a transfer would mean
  /// tearing down the conversation with it.
  ///
  /// Returns null when the peer cannot be reached, never answers, or answers
  /// with the wrong role. All three mean the same thing to the caller — this
  /// transfer cannot proceed — and [FileSendException]/[FileReceiveException]
  /// already carry the outcome to the user, so no distinction is drawn here.
  Future<ControlConnection?> connectData(
    String peerId, {
    required String xferId,
    Duration? timeout,
  }) async {
    if (_stopping) {
      return null;
    }
    final _Peer? peer = _peers[peerId];
    final InternetAddress? address = peer?.address;
    if (peer == null || address == null) {
      // We have never been told where this peer lives. Reachable only if the
      // peer was released between accepting an offer and getting here.
      _log('no address for $peerId; cannot open a data connection');
      return null;
    }

    final ControlConnection connection;
    try {
      connection = await ControlConnection.connect(
        address: address,
        port: peer.port,
        selfHello: selfHello.forTransfer(xferId),
        tuning: tuning,
        onLog: onLog,
        clock: _clock,
      );
    } on Object catch (error) {
      _log('data connection to $peerId failed: $error');
      return null;
    }

    final HelloPayload? hello =
        await _helloWithin(connection, timeout ?? tuning.connectTimeout);
    if (hello == null) {
      _log('no hello on the data connection to $peerId');
      await connection.close();
      return null;
    }
    if (hello.role != ConnectionRole.data) {
      // It answered our `data` hello with a control one. Carrying on would have
      // it read file bytes as chat frames, so there is nothing to salvage.
      _log('$peerId answered a data hello with a "${hello.role.wire}" one');
      await connection.close();
      return null;
    }

    if (_stopping) {
      // The pool stopped while the handshake was in flight. Closing here rather
      // than returning it keeps `stop()`'s promise that nothing is left open.
      await connection.close();
      return null;
    }

    _trackData(connection);
    _log('data connection to $peerId open for $xferId');
    return connection;
  }

  /// Starts closing [connection] when the pool stops, and forgets it when it
  /// ends on its own.
  void _trackData(ControlConnection connection) {
    _dataSockets.add(connection);
    connection.closed.listen((ConnectionClosedReason _) {
      _dataSockets.remove(connection);
    });
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
    _routed.remove(connection);
    final String? peerId = connection.remoteId;

    // A connection that was already replaced finishes here after the newcomer
    // took its place. Nothing to do: the peer is still connected, and clearing
    // the slot now would orphan the live connection.
    if (peerId == null) {
      return;
    }

    // A data connection is one transfer's socket (design.md §4.4). Its death
    // says nothing about whether the peer is reachable, so it must not be
    // reported as a lost peer and must not start a reconnect — the transfer
    // that owns it is listening to the same socket and decides what happens
    // next. Without this the ordinary end of a finished transfer would look
    // like the peer going offline and would drain the offline queue at it.
    if (connection.peerHello?.role != ConnectionRole.control) {
      _log('$peerId: data connection closed (${reason.name})');
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
        final PayloadDecode<MessagePayload> decoded =
            MessagePayload.from(frame);
        if (!decoded.isSuccess) {
          // One unreadable message is not a reason to drop a working
          // connection (§4.3 drops the connection for framing errors only).
          _log('bad msg from $peerId: ${decoded.reason}');
          return;
        }
        if (!_incoming.isClosed) {
          _incoming
              .add(IncomingMessage(peerId: peerId, payload: decoded.value!));
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

      case FrameType.fileOffer:
      case FrameType.fileAccept:
      case FrameType.fileReject:
      case FrameType.fileDone:
      case FrameType.fileCancel:
      case FrameType.xferDone:
        // The transfer conversation (design.md §4.6). Passed up unparsed — see
        // [IncomingTransferFrame] — and dropped when nothing is listening, which
        // is what a build without file transfer is.
        if (!_transferFrames.isClosed) {
          _transferFrames.add(
            IncomingTransferFrame(peerId: peerId, frame: frame),
          );
        }
        return;

      case FrameType.fileData:
        // File bytes belong on a data connection (design.md §4.4). One arriving
        // here means the peer lost track of which socket it was writing to, and
        // the chunk has nowhere to go: this connection has no transfer attached
        // to it and nothing to write the bytes into.
        _log('file_data on the control connection from $peerId');
        return;

      default:
        // Anything a newer build invents. Ignored on purpose so versions
        // interoperate (§4.3) — logged once per frame here rather than at the
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
    final _PendingMessage pending =
        _PendingMessage(peerId: peerId, payload: payload);
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
