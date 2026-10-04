import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../core/discovery/peer_source.dart';
import '../core/models/message.dart';
import '../core/models/peer.dart';
import '../core/protocol/payloads.dart';
import '../core/transport/connection_manager.dart';
import '../data/repository/chat_repository.dart';
import '../data/repository/peer_repository.dart';

/// Everything that joins the network to the database.
///
/// One object owns both halves of M2, because they are not separable in
/// practice: a message is stored *and* sent, an announce is recorded *and* acted
/// on by opening a connection, and an incoming message is written before it is
/// acknowledged. Splitting these into a "message" service and a "peer" service
/// would put the ordering rule that matters most — write, then ack — across two
/// objects.
///
/// Nothing above this class touches a socket or a row; nothing below it knows
/// the app exists.
class LanService {
  LanService({
    required this.manager,
    required this.discovery,
    required ChatRepository chat,
    required PeerRepository peers,
    DateTime Function()? clock,
    void Function(String message)? onLog,
  })  : _chat = chat,
        _peers = peers,
        _clock = clock ?? DateTime.now,
        _onLog = onLog;

  final ConnectionManager manager;

  /// Borrowed, not owned: the device list already owns discovery's lifecycle
  /// (see `discoveredPeersProvider`). Disposing it here would take the device
  /// list down with the chat, and it is only ever read.
  final PeerSource discovery;

  final ChatRepository _chat;
  final PeerRepository _peers;
  final DateTime Function() _clock;
  final void Function(String message)? _onLog;

  final StreamController<String> _messagesChanged =
      StreamController<String>.broadcast();

  /// Peers whose history changed — a message stored, or a status advanced.
  ///
  /// Broadcast and *not* replayed: a listener that missed an event reads the
  /// current state from the database anyway, so a fresh listener loses nothing.
  /// That is also why an event carries only the peer id and never a message:
  /// the database is the source of truth, and the event just says "look again".
  Stream<String> get messagesChanged => _messagesChanged.stream;

  // `late` so the `onListen` callback can reach back into `this` — a plain
  // field initializer runs before the object exists.
  late final StreamController<Set<String>> _onlinePeers =
      StreamController<Set<String>>.broadcast(
    onListen: () {
      // Emitting the current set on listen closes a real gap: the device list
      // subscribes after the first peers have already connected, and waiting for
      // the *next* connection would leave them shown as offline indefinitely.
      if (!_onlinePeers.isClosed) {
        _onlinePeers.add(_connected());
      }
    },
  );

  /// Peer ids with a usable control connection right now.
  Stream<Set<String>> get onlinePeers => _onlinePeers.stream;

  final List<StreamSubscription<Object?>> _subscriptions =
      <StreamSubscription<Object?>>[];

  bool _started = false;
  bool _disposed = false;

  /// Peers already written to the database, with the announce that was written.
  ///
  /// The `changes` stream only fires when the *displayed* list changes (a new
  /// peer, a rename, an offline transition), so a steady peer costs one write
  /// rather than one every five seconds. `last_seen` is therefore the time of
  /// the last visible change, which is also the honest answer for an offline
  /// peer: the moment we noticed it was gone.
  final Map<String, String> _recorded = <String, String>{};

  Set<String> _connected() => manager.connectedPeers;

  Future<void> start() async {
    if (_started || _disposed) {
      return;
    }
    _started = true;

    _subscriptions.addAll(<StreamSubscription<Object?>>[
      manager.incoming.listen((IncomingMessage m) => unawaited(_onIncoming(m))),
      manager.delivered.listen((MessageDelivered d) => unawaited(_onDelivered(d))),
      manager.deliveryFailed
          .listen((MessageDeliveryFailed f) => unawaited(_onFailed(f))),
      manager.peerConnected.listen((String peerId) {
        // §5.2: a control connection coming up is one of the two moments the
        // offline queue is flushed, the other being a fresh announce.
        unawaited(_flushPending(peerId));
        _emitOnline();
      }),
      manager.peerLost.listen((PeerConnectionLost lost) => _emitOnline()),
      discovery.changes.listen((void _) => unawaited(_absorbAnnounces())),
    ]);

    try {
      await manager.start();
    } on Object catch (error, stack) {
      // A port already in use must not take the app down: messaging stops
      // working, but the device list, settings and history all still do, and
      // the reason is logged rather than swallowed.
      _log('could not listen for connections: $error\n$stack');
    }

    await _absorbAnnounces();
  }

  /// Sends a text message, storing it first.
  ///
  /// The database write comes first and the send is best-effort, because §4.4.1
  /// measured a failed connect at about two seconds on Windows — a send path that
  /// waited on the network would freeze the chat page for that long every time a
  /// peer went away. Stored as `pending`, the message is durable, visible, and
  /// owed; [_flushPending] picks it up when the peer reappears, reusing the same
  /// `msgId` so the peer can dedupe it (§4.5).
  ///
  /// Returns null when there is nothing to send: whitespace is not a message,
  /// and storing it would leave a blank bubble in the conversation that no
  /// amount of retrying could fill. Surrounding whitespace is trimmed, the same
  /// way the composer's text is — a message that arrived with a trailing newline
  /// from a soft keyboard is not a different message.
  Future<Message?> sendText({
    required String peerId,
    required String text,
  }) async {
    final String body = text.trim();
    if (body.isEmpty) {
      return null;
    }
    final Message saved = await _chat.saveOutgoing(
      msgId: const Uuid().v4(),
      peerId: peerId,
      text: body,
      now: _clock(),
    );
    _markChanged(peerId);
    await _send(peerId, saved);
    return saved;
  }

  /// Asks for a failed message to be attempted again.
  ///
  /// Clears the retry count, so a message that already burned its automatic
  /// attempts still gets one.
  Future<void> retryMessage(String peerId, String msgId) async {
    await _chat.requeue(msgId);
    _markChanged(peerId);
    await _flushPending(peerId);
  }

  bool isConnected(String peerId) => manager.isConnected(peerId);

  /// Makes sure a connection to [peerId] is kept alive.
  ///
  /// Called when a conversation is opened: a device the user is looking at is a
  /// device worth being connected to, even if it has not announced recently.
  void ensureConnected(Peer peer) {
    final InternetAddress? address = _addressOf(peer);
    if (address == null) {
      return;
    }
    manager.requireConnection(peer.id, address: address, port: peer.lastPort);
  }

  /// Ends every subscription. The object is not reusable after.
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;

    // Started before the subscriptions are cancelled, not after: disposing the
    // manager is what cancels the reconnect and connect-timeout timers, and
    // awaiting a cancel first would leave them armed for however long that
    // takes — long enough for a test to tear the tree down and find a timer
    // still pending, and long enough for the app's own shutdown to outlive the
    // window where it stops caring.
    final Future<void> stopping = manager.dispose();
    for (final StreamSubscription<Object?> sub in _subscriptions) {
      await sub.cancel();
    }
    _subscriptions.clear();
    await stopping;

    await _messagesChanged.close();
    await _onlinePeers.close();
  }

  // --- Incoming -------------------------------------------------------------

  Future<void> _onIncoming(IncomingMessage incoming) async {
    final MessagePayload payload = incoming.payload;
    if (_disposed) {
      return;
    }

    bool isNew;
    try {
      isNew = await _chat.storeIncoming(
        msgId: payload.msgId,
        peerId: incoming.peerId,
        text: payload.text,
        now: _clock(),
      );
    } on Object catch (error, stack) {
      // Not acknowledged: the sender keeps retrying, which is the correct
      // outcome for a message we failed to store. Acking here would tell it the
      // message is safe when it is not.
      _log('could not store ${payload.msgId} from ${incoming.peerId}: $error\n$stack');
      return;
    }

    // A duplicate is acknowledged too. The peer is retrying precisely because it
    // never saw an ack, and staying quiet would leave it retrying until it gave
    // up on a message that arrived the first time.
    if (!manager.sendAck(incoming.peerId, payload.msgId)) {
      _log('no connection to ack ${payload.msgId} to ${incoming.peerId}');
    }
    if (isNew) {
      _markChanged(incoming.peerId);
    }
  }

  Future<void> _onDelivered(MessageDelivered delivered) async {
    final bool changed = await _chat.setStatus(
      delivered.msgId,
      MessageStatus.delivered,
      deliveredAt: _clock(),
    );
    if (changed) {
      _markChanged(delivered.peerId);
    }
  }

  Future<void> _onFailed(MessageDeliveryFailed failed) async {
    final bool changed = await _chat.setStatus(
      failed.msgId,
      MessageStatus.failed,
      retryCount: failed.attempts,
    );
    if (changed) {
      _markChanged(failed.peerId);
    }
  }

  // --- Outgoing -------------------------------------------------------------

  /// Sends everything still owed to [peerId], oldest first (§5.2).
  ///
  /// A send that fails leaves the row `pending`, so the next flush — the next
  /// announce, the next reconnect, or the user's retry — picks it up again
  /// rather than losing it.
  Future<void> _flushPending(String peerId) async {
    final List<Message> owed = await _chat.pendingFor(peerId);
    for (final Message message in owed) {
      if (!manager.isConnected(peerId)) {
        return;
      }
      await _send(peerId, message);
    }
  }

  Future<void> _send(String peerId, Message message) async {
    final bool sent = manager.sendMessage(
      peerId,
      MessagePayload(
        msgId: message.id,
        // The local clock, not the peer's (§4.5). For a queued message this is
        // when it was written rather than when it finally goes out. The
        // receiver does not sort by it — each device stamps an incoming message
        // with its own clock (§4.5: device clocks are not to be trusted) — so
        // this is carried for diagnosis and for a future "sent at" line, and
        // nothing downstream may start depending on it for ordering.
        ts: message.createdAt,
        text: message.text ?? '',
      ),
    );
    if (!sent) {
      // Still the queue's problem. No status change: the message has not left,
      // so calling it `sent` would put a tick on something the peer never saw.
      return;
    }
    if (await _chat.setStatus(message.id, MessageStatus.sent)) {
      _markChanged(peerId);
    }
  }

  // --- Discovery ------------------------------------------------------------

  /// Writes what peers announced about themselves and dials the ones that are up.
  Future<void> _absorbAnnounces() async {
    if (_disposed) {
      return;
    }
    for (final Peer peer in discovery.peers) {
      final String fingerprint = '${peer.name}|${peer.icon.wire}|'
          '${peer.deviceType.wire}|${peer.os}|${peer.lastIp}|${peer.isOnline}';
      if (_recorded[peer.id] != fingerprint) {
        _recorded[peer.id] = fingerprint;
        try {
          await _peers.recordAnnounce(peer, at: _clock());
        } on Object catch (error) {
          // A device that cannot be stored must not stop the others from being
          // connected to; drop it from the map so the next announce retries.
          _recorded.remove(peer.id);
          _log('could not record ${peer.id}: $error');
          continue;
        }
      }
      if (peer.isOnline) {
        ensureConnected(peer);
      }
    }
  }

  InternetAddress? _addressOf(Peer peer) {
    final String? ip = peer.lastIp;
    if (ip == null) {
      return null;
    }
    return InternetAddress.tryParse(ip);
  }

  void _emitOnline() {
    if (!_onlinePeers.isClosed) {
      _onlinePeers.add(_connected());
    }
  }

  void _markChanged(String peerId) {
    if (!_messagesChanged.isClosed) {
      _messagesChanged.add(peerId);
    }
  }

  void _log(String message) {
    _onLog?.call('lan: $message');
    debugPrint('[lan] $message');
  }
}
