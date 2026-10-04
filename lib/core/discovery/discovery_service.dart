import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../constants.dart';
import '../models/peer.dart';
import 'announce.dart';
import 'network_interfaces.dart';
import 'peer_source.dart';
import 'peer_table.dart';

/// Binds one datagram socket.
///
/// A seam, and the only one in this class: [DiscoveryService] throws away a
/// socket that has stopped writing and binds another, and no test can make a
/// real socket latch the way the OS makes one latch.
typedef DatagramBinder = Future<RawDatagramSocket> Function(
  InternetAddress address,
  int port,
);

/// UDP device discovery — multicast plus broadcast, design.md §4.1.
///
/// Pure Dart, no Flutter import, so it runs under `flutter test` on the VM and
/// the whole receive path can be exercised by posting real datagrams at it.
///
/// ## Why one socket per interface
///
/// Both channels are sent from *every* usable interface rather than from a
/// single wildcard socket. Dart offers no way to choose the egress interface
/// for a datagram: `RawDatagramSocket.multicastInterface` is deprecated and
/// unimplemented, and there is no `setMulticastInterface`. Binding one
/// send-only socket per interface address is the only portable equivalent, and
/// it is load-bearing rather than a nicety — a single wildcard socket sends
/// everything out the interface the routing table prefers, which on a Windows
/// machine with Hyper-V installed is very often the virtual adapter. The
/// failure mode is the worst kind: no error, no log, and no peer ever found.
class DiscoveryService implements PeerSource {
  DiscoveryService({
    int discoveryPort = kDiscoveryPort,
    String multicastGroup = kMulticastGroup,
    this.onLog,
    DatagramBinder? bind,
  }) : _discoveryPort = discoveryPort,
       _bind = bind ?? _bindSocket,
       _multicast = _parseOrFallback(multicastGroup, kMulticastGroup),
       _broadcast = InternetAddress(kBroadcastAddress);

  static Future<RawDatagramSocket> _bindSocket(
    InternetAddress address,
    int port,
  ) => RawDatagramSocket.bind(address, port, reuseAddress: true);

  /// The peers currently known. Read it directly; listen to [changes] to know
  /// when it has moved on.
  final PeerTable table = PeerTable();

  /// Receives debug lines. Injected so `core/` stays free of Flutter's
  /// `debugPrint` — and so tests can assert on what was rejected.
  final void Function(String message)? onLog;

  /// Fires whenever [table] changed. Broadcast: the service never depends on
  /// anyone listening.
  @override
  Stream<void> get changes => _changes.stream;

  /// The peer list as [PeerSource] sees it — same thing as `table.peers`.
  @override
  List<Peer> get peers => table.peers;

  final int _discoveryPort;
  final DatagramBinder _bind;
  final InternetAddress _multicast;
  final InternetAddress _broadcast;

  final StreamController<void> _changes = StreamController<void>.broadcast();

  RawDatagramSocket? _receiver;
  StreamSubscription<RawSocketEvent>? _receiverSub;

  /// Sends the unicast answers to probes and announces.
  ///
  /// Its own socket, not the listener's. A reply goes to one address, and if
  /// nothing is listening there any more the ICMP port-unreachable it draws
  /// latches the socket it was sent from — see [_noteSendFailure]. Sharing one
  /// socket between answering and listening would let a single stale peer stop
  /// the app answering probes for good, and a probe answer is the only thing a
  /// device that cannot hear multicast has to go on.
  ///
  /// Bound to the wildcard address rather than to one interface, because for a
  /// *specific* destination the routing table picks the right interface by
  /// construction — which is the same reason the per-interface senders below
  /// exist, for the case where it does not.
  RawDatagramSocket? _replySocket;

  final List<RawDatagramSocket> _senders = <RawDatagramSocket>[];
  Timer? _announceTimer;
  Timer? _timeoutTimer;

  /// Consecutive refused writes per socket, and the sockets the first refusal
  /// has already been reported for.
  final Map<RawDatagramSocket, int> _writeFailures =
      <RawDatagramSocket, int>{};
  final Set<RawDatagramSocket> _reportedFailure = <RawDatagramSocket>{};

  /// True while a manual refresh is in flight, so a second press does not bind
  /// a third set of sockets over the top of the first.
  bool _refreshing = false;

  /// Refused writes on one socket before it is discarded and bound again.
  ///
  /// A round writes each datagram twice per sender (multicast and broadcast),
  /// so a socket that is genuinely dead reaches this in two rounds — about
  /// [kAnnounceInterval] x2. A healthy socket that loses one datagram of a
  /// burst reaches one and is reset by the next successful write.
  static const int _failureLimit = 3;

  /// Rounds of probe-and-announce a manual refresh sends, and the gap between
  /// them. One UDP datagram on Wi-Fi is a coin flip; this is the one place
  /// where a user is waiting on the result.
  static const int _refreshRounds = 3;
  static const Duration _refreshGap = Duration(milliseconds: 400);

  Peer? _self;
  bool _started = false;

  bool get isRunning => _started;

  /// Addresses we are currently sending from — for the About/diagnostics view,
  /// where "which interface is this thing actually using" is the first
  /// question worth answering.
  List<String> get senderAddresses => _senders
      .map((RawDatagramSocket socket) => socket.address.address)
      .toList(growable: false);

  /// Sets or replaces this device's identity and announces a change at once.
  ///
  /// Called before [start] to supply the identity, and afterwards whenever the
  /// user renames the device or changes its icon — a rename that waited up to
  /// [kAnnounceInterval] to propagate would look like a bug.
  void updateSelf(Peer self) {
    final Peer? previous = _self;
    final bool identityChanged =
        previous != null &&
        (previous.name != self.name ||
            previous.icon != self.icon ||
            previous.deviceType != self.deviceType);

    _self = self;
    table.selfId = self.id;

    if (identityChanged && _started) {
      _send(AnnounceType.announce);
    }
  }

  /// Binds the sockets and starts announcing.
  ///
  /// Throws [StateError] if called before [updateSelf], and [SocketException]
  /// if the discovery port cannot be bound — the caller decides whether that is
  /// fatal, because it usually is not: another copy of the app already running
  /// is the common cause.
  Future<void> start() async {
    if (_started) {
      return;
    }
    final Peer? self = _self;
    if (self == null) {
      throw StateError('updateSelf() must be called before start()');
    }
    table.selfId = self.id;

    // Bound to the wildcard address so multicast and broadcast arriving on any
    // interface reach this one socket.
    final RawDatagramSocket receiver = await _bind(
      InternetAddress.anyIPv4,
      _discoveryPort,
    );
    receiver.broadcastEnabled = true;
    _receiver = receiver;
    _receiverSub = receiver.listen(
      _onSocketEvent,
      onError: (Object error) => _log('receive error: $error'),
      cancelOnError: false,
    );

    final Map<NetworkInterface, List<String>> interfaces =
        await NetworkInterfaceHelper.usableInterfaces();

    // Joining per interface rather than once implicitly: an implicit join
    // follows the default route, which is what pulls multicast in from a
    // virtual adapter we deliberately excluded.
    for (final NetworkInterface ni in interfaces.keys) {
      try {
        receiver.joinMulticast(_multicast, ni);
      } on SocketException catch (error) {
        _log('multicast join failed on ${ni.name}: ${error.message}');
      }
    }

    _replySocket = await _bindReplySocket();

    for (final MapEntry<NetworkInterface, List<String>> entry
        in interfaces.entries) {
      for (final String address in entry.value) {
        try {
          _senders.add(await _bindSender(InternetAddress(address)));
        } on SocketException catch (error) {
          _log('cannot send via $address: ${error.message}');
        }
      }
    }

    _started = true;

    // One line, once. When a user reports "it finds nothing", the first
    // question is which interfaces discovery actually picked — and the failure
    // mode this whole class exists to avoid is the silent one, so the answer
    // must not require a debugger.
    _log(
      'listening on $_discoveryPort for group ${_multicast.address}; '
      'sending via ${_senders.isEmpty ? 'the default route (no usable interface)' : senderAddresses.join(', ')}',
    );

    // A probe pulls answers from devices that are already up; the announce
    // introduces us to devices that start later.
    _send(AnnounceType.probe);
    _send(AnnounceType.announce);

    _announceTimer = Timer.periodic(
      kAnnounceInterval,
      (_) => _send(AnnounceType.announce),
    );
    // 1s granularity: fine enough that the 15s/60s thresholds land where the
    // design says they do, cheap enough not to think about.
    _timeoutTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _applyTimeouts(),
    );
  }

  /// Discovers again, now — the Rescan button and the refresh action of §6.2.
  ///
  /// Rebuilt sockets, not just another announce. The reason a user presses this
  /// is that the list stopped changing, and the usual cause is a socket that has
  /// latched ([_noteSendFailure]) — which is also why restarting the app
  /// discovers everything at once, since that is the same repair done by hand.
  /// Re-announcing on a socket that writes zero bytes is a no-op, and a refresh
  /// button that does nothing is indistinguishable from a broken one.
  ///
  /// The rounds are spaced because a user waiting on a result deserves better
  /// than one datagram's odds. Safe to call before [start] and after [stop],
  /// where it does nothing.
  void rescan() {
    if (!_started || _refreshing) {
      return;
    }
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    _refreshing = true;
    try {
      await _rebindAll();
      for (int round = 0; round < _refreshRounds; round++) {
        if (!_started) {
          return;
        }
        _send(AnnounceType.probe);
        _send(AnnounceType.announce);
        if (round < _refreshRounds - 1) {
          await Future<void>.delayed(_refreshGap);
        }
      }
    } finally {
      _refreshing = false;
    }
  }

  /// Closes every sending socket and binds replacements.
  ///
  /// The listener is deliberately left alone: it never sends, so it cannot
  /// latch, and rebinding it would mean rejoining the multicast group on every
  /// interface for no gain.
  Future<void> _rebindAll() async {
    final List<RawDatagramSocket> stale = List<RawDatagramSocket>.of(_senders);
    _senders.clear();
    _writeFailures.clear();
    _reportedFailure.clear();
    for (final RawDatagramSocket socket in stale) {
      socket.close();
    }
    _replySocket?.close();
    _replySocket = await _bindReplySocket();

    final Map<NetworkInterface, List<String>> interfaces =
        await NetworkInterfaceHelper.usableInterfaces();
    for (final MapEntry<NetworkInterface, List<String>> entry
        in interfaces.entries) {
      for (final String address in entry.value) {
        try {
          _senders.add(await _bindSender(InternetAddress(address)));
        } on SocketException catch (error) {
          _log('cannot send via $address: ${error.message}');
        }
      }
    }

    if (!_started) {
      // stop() ran while the sockets were being bound. Close what was just
      // made rather than leaving live sockets behind a stopped service.
      for (final RawDatagramSocket socket in _senders) {
        socket.close();
      }
      _senders.clear();
      _replySocket?.close();
      _replySocket = null;
    }
  }

  Future<RawDatagramSocket> _bindSender(InternetAddress address) async {
    // Ephemeral port: nobody answers a sender. Replies go out [_replySocket].
    final RawDatagramSocket sender = await _bind(address, 0);
    sender.broadcastEnabled = true;
    sender.multicastHops = 1; // never leave the local segment
    sender.multicastLoopback = false; // our own multicast is not news
    sender.readEventsEnabled = false; // send-only
    return sender;
  }

  Future<RawDatagramSocket?> _bindReplySocket() async {
    try {
      final RawDatagramSocket socket = await _bind(InternetAddress.anyIPv4, 0);
      socket.broadcastEnabled = true;
      socket.readEventsEnabled = false; // send-only
      return socket;
    } on SocketException catch (error) {
      // Answers then fall back to the listener, which works but re-couples the
      // two — loud on purpose, because that is a worse state to be in.
      _log('cannot bind a socket to answer from, falling back to the '
          'listener: ${error.message}');
      return null;
    }
  }

  /// Says goodbye and releases every socket. Idempotent.
  ///
  /// The `bye` is what lets peers drop this device at once; without it they
  /// keep showing it as offline for [kPeerRemoveAfter] after a clean exit.
  Future<void> stop() async {
    if (!_started) {
      return;
    }
    _started = false;

    _announceTimer?.cancel();
    _announceTimer = null;
    _timeoutTimer?.cancel();
    _timeoutTimer = null;

    // Must precede the closes, and is best effort — on a machine that is
    // shutting down there may be no network left to send it on.
    _send(AnnounceType.bye);

    await _receiverSub?.cancel();
    _receiverSub = null;

    for (final RawDatagramSocket sender in _senders) {
      sender.close();
    }
    _senders.clear();
    _writeFailures.clear();
    _reportedFailure.clear();
    _replySocket?.close();
    _replySocket = null;
    _receiver?.close();
    _receiver = null;

    table.clear();
  }

  /// Stops and closes [changes]. The service cannot be restarted afterwards.
  Future<void> dispose() async {
    await stop();
    await _changes.close();
  }

  // --- Sending --------------------------------------------------------------

  /// Puts one announce on the wire via every usable interface, on both
  /// channels.
  ///
  /// Deliberately synchronous, and deliberately duplicated. Both properties are
  /// load-bearing:
  ///
  /// * Synchronous, because [stop] sends the goodbye and then closes the
  ///   sockets in the same turn. An announce that resolved on a later turn
  ///   would be written to a closed socket, and peers would keep showing this
  ///   device as offline for [kPeerRemoveAfter] after a clean exit.
  /// * Duplicated, because Windows drops UDP datagrams sent back to back and
  ///   reports it only as a 0-byte write. Measured on a real NIC with four
  ///   sends in a burst, about 4% never left the machine; a 1ms gap between
  ///   them removed the loss. Spacing the sends out is not an option here for
  ///   the reason above, so the multicast and broadcast copies of each packet
  ///   are what cover a dropped one, and the next round is 5s behind them.
  ///   Removing either channel to "simplify" would turn a rare dropped datagram
  ///   into a rare missed discovery.
  ///
  /// [sendTo] still checks the write, so a datagram that is lost is logged
  /// rather than passing unnoticed.
  void _send(AnnounceType type) {
    final Peer? self = _self;
    if (self == null) {
      return;
    }

    final Uint8List bytes;
    try {
      bytes = _build(type, self);
    } on AnnounceTooLargeException catch (error) {
      // The name is the only field a user can grow, and it is capped at
      // kMaxDeviceNameLength, so this means a bug rather than user input.
      _log('not sending $type: $error');
      return;
    }

    if (_senders.isEmpty) {
      // No usable interface was found — enumeration failed, or every adapter is
      // filtered as virtual. Fall back to the routing table rather than going
      // silent, which would look identical to a firewall block. [_replySocket]
      // is the routing-table socket; the listener is the last resort, because
      // it is the one socket that has to keep listening.
      final RawDatagramSocket? fallback = _replySocket ?? _receiver;
      if (fallback != null) {
        _sendTo(fallback, bytes, _multicast);
        _sendTo(fallback, bytes, _broadcast);
      }
      return;
    }

    // A copy, because _sendTo is allowed to retire a socket underneath this
    // loop: a write refused _failureLimit times calls _replace, whose body runs
    // up to its first `await` synchronously and takes the dead socket out of
    // _senders — while this loop is walking it. Walking the live list throws
    // `ConcurrentModificationError` instead, which surfaces as an unhandled
    // async error rather than a failed write, and the announce that would have
    // gone out on the *other* interfaces never leaves.
    for (final RawDatagramSocket sender
        in List<RawDatagramSocket>.of(_senders)) {
      _sendTo(sender, bytes, _multicast);
      _sendTo(sender, bytes, _broadcast);
    }
  }

  /// Unicast announce back to one peer.
  void _reply(AnnouncePacket packet, InternetAddress to) {
    final Peer? self = _self;
    final RawDatagramSocket? socket = _replySocket ?? _receiver;
    if (self == null || socket == null) {
      return;
    }

    final Uint8List bytes;
    try {
      bytes = _build(AnnounceType.announce, self);
    } on AnnounceTooLargeException catch (error) {
      _log('not replying: $error');
      return;
    }

    // Sent from [_replySocket] — a routing-table socket, and a different one
    // from the listener, for the two reasons given where it is declared. Not
    // from a per-interface sender, which is the one case where the routing
    // table is wrong: that is true of broadcast and multicast, not of a
    // destination we have an address for.
    //
    // Addressed to the peer's own port from its packet, never to
    // `datagram.port` — that source port belongs to the peer's ephemeral
    // send-only socket, which is not reading.
    _sendTo(socket, bytes, to, port: packet.port ?? _discoveryPort);
  }

  Uint8List _build(AnnounceType type, Peer self) {
    final bool full = type == AnnounceType.announce;
    return AnnouncePacket(
      type: type,
      id: self.id,
      ts: DateTime.now().toUtc(),
      name: full ? self.name : null,
      deviceType: full ? self.deviceType : null,
      icon: full ? self.icon : null,
      os: full ? self.os : null,
      // On every type, so a reply to a probe reaches a peer that moved off the
      // default port.
      port: self.lastPort,
    ).encode();
  }

  void _sendTo(
    RawDatagramSocket socket,
    Uint8List bytes,
    InternetAddress target, {
    int? port,
  }) {
    int written;
    try {
      written = socket.send(bytes, target, port ?? _discoveryPort);
    } on Object catch (error) {
      // Swallowed deliberately: a single unusable interface must not stop the
      // others from being tried, and the interface was already validated at
      // bind time. Caught as `Object` and not `SocketException` because
      // [_replace] closes sockets underneath this loop, and a write to a closed
      // socket is not required to be a `SocketException`.
      _noteSendFailure(socket, 'threw $error');
      return;
    }

    // A failed send is *reported by return value*, not by throwing. On Windows
    // a UDP socket that has received an ICMP port-unreachable latches the error
    // and every later send quietly returns 0 — measured on a development
    // machine, where the second and third datagrams of a burst went nowhere
    // while the first was delivered. Nothing else in the pipeline can see that,
    // so without this check the app would stop announcing entirely and the only
    // symptom would be a peer list that never fills in. That is precisely the
    // silent failure this class is written to avoid.
    if (written < bytes.length) {
      _noteSendFailure(socket, 'wrote $written of ${bytes.length} bytes');
      return;
    }

    _writeFailures.remove(socket);
    if (_reportedFailure.remove(socket)) {
      _log('sending via ${socket.address.address} recovered');
    }
  }

  /// Counts a refused write, reports the first, and replaces the socket once it
  /// has clearly stopped working.
  ///
  /// A dead adapter is a normal, self-correcting condition — a laptop lid
  /// closing, a VPN dropping — so a line per announce would bury everything
  /// else, and only the *transition* is logged. An ICMP latch is the other
  /// case, and it does not self-correct: the socket keeps returning 0 for the
  /// rest of the process's life, which is why counting it matters and logging
  /// it was not enough.
  void _noteSendFailure(RawDatagramSocket socket, String detail) {
    // A socket this service has already retired — reachable because [_send]
    // works from a copy of [_senders], so its loop can still write to a socket
    // that [_replace] closed a moment ago. Counting those writes would build a
    // failure record for something nothing will ever use again.
    final bool isReplySocket = identical(socket, _replySocket);
    final bool isListener = identical(socket, _receiver);
    if (!isReplySocket && !isListener && !_senders.contains(socket)) {
      return;
    }

    final int failures = (_writeFailures[socket] ?? 0) + 1;
    _writeFailures[socket] = failures;

    if (_reportedFailure.add(socket)) {
      _log('cannot send via ${socket.address.address}: $detail');
    }
    // The listener is counted and reported but never replaced: it is the one
    // socket that must keep receiving, and it only ever sends in the degraded
    // case where no reply socket could be bound at all (see [_reply]). Closing
    // it to cure a refused write would trade a lost answer for a lost device.
    if (failures >= _failureLimit &&
        !isListener &&
        (isReplySocket || _senders.contains(socket))) {
      unawaited(_replace(socket));
    }
  }

  /// Throws away a socket that has stopped writing and binds a replacement.
  ///
  /// The only cure for the latch [_noteSendFailure] describes, short of
  /// restarting the process — which is what a user works out to do instead, and
  /// what [rescan] does on demand.
  Future<void> _replace(RawDatagramSocket dead) async {
    if (!_started) {
      return;
    }
    _writeFailures.remove(dead);
    _reportedFailure.remove(dead);
    final String where = dead.address.address;

    if (identical(dead, _replySocket)) {
      _replySocket = null;
      dead.close();
      _replySocket = await _bindReplySocket();
      if (_replySocket != null) {
        _log('replaced the socket answering probes on $where');
      }
      return;
    }

    if (!_senders.remove(dead)) {
      // Not a socket this service owns — a stale callback after a rebind.
      return;
    }
    dead.close();

    try {
      final RawDatagramSocket fresh = await _bindSender(InternetAddress(where));
      if (!_started) {
        fresh.close();
        return;
      }
      _senders.add(fresh);
      _log('replaced the sender on $where after $_failureLimit refused sends');
    } on SocketException catch (error) {
      _log('could not replace the sender on $where: ${error.message}');
    }
  }

  // --- Receiving ------------------------------------------------------------

  void _onSocketEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) {
      return;
    }
    final RawDatagramSocket? receiver = _receiver;
    if (receiver == null) {
      return;
    }
    // Drain everything queued, not just one datagram: the stream reports
    // readiness, it does not deliver packets one event each.
    Datagram? datagram;
    while ((datagram = receiver.receive()) != null) {
      try {
        _handleDatagram(datagram!);
      } on Object catch (error, stack) {
        // Anything on the LAN can send to this port (design.md §9), so a
        // datagram that makes the handler throw must not abort the drain loop
        // and silently discard every packet queued behind it.
        _log('failed to handle datagram from ${datagram!.address.address}: '
            '$error\n$stack');
      }
    }
  }

  void _handleDatagram(Datagram datagram) {
    final DateTime now = DateTime.now();
    final AnnounceDecode decoded = AnnouncePacket.decode(datagram.data, now: now);
    if (!decoded.isSuccess) {
      _log('ignored ${datagram.address.address}: ${decoded.reason}');
      return;
    }

    final AnnouncePacket packet = decoded.packet!;
    if (packet.id == _self?.id) {
      // Our own broadcast arriving back off the network. Multicast loopback is
      // off, so this is the broadcast half.
      return;
    }

    switch (packet.type) {
      case AnnounceType.bye:
        if (table.remove(packet.id)) {
          _notify();
        }

      case AnnounceType.probe:
        // Identity only — there is nothing to display and nothing to record,
        // so the answer is the whole response.
        _reply(packet, datagram.address);

      case AnnounceType.announce:
        final DateTime? previous = table.lastSeenOf(packet.id);
        if (table.touch(packet: packet, fromIp: datagram.address.address, now: now)) {
          _notify();
        }

        // Answer a *fresh* contact with a unicast announce so both sides
        // converge without waiting for the next scheduled round.
        //
        // The freshness test is what stops the two sides from answering each
        // other forever: once a peer has been heard from within one announce
        // interval, its announces need no answer, because the next scheduled
        // round arrives before the peer could age out.
        final bool firstContact =
            previous == null || now.difference(previous) > kAnnounceInterval;
        if (firstContact) {
          _reply(packet, datagram.address);
        }
    }
  }

  void _applyTimeouts() {
    if (table.applyTimeouts(DateTime.now())) {
      _notify();
    }
  }

  void _notify() {
    if (!_changes.isClosed) {
      _changes.add(null);
    }
  }

  void _log(String message) => onLog?.call(message);

  static InternetAddress _parseOrFallback(String value, String fallback) {
    try {
      return InternetAddress(value);
    } on ArgumentError {
      // A hand-edited settings file must not stop the app from starting.
      return InternetAddress(fallback);
    }
  }
}
