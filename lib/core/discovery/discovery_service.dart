import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../constants.dart';
import '../models/peer.dart';
import 'announce.dart';
import 'network_interfaces.dart';
import 'peer_table.dart';

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
class DiscoveryService {
  DiscoveryService({
    int discoveryPort = kDiscoveryPort,
    String multicastGroup = kMulticastGroup,
    this.onLog,
  }) : _discoveryPort = discoveryPort,
       _multicast = _parseOrFallback(multicastGroup, kMulticastGroup),
       _broadcast = InternetAddress(kBroadcastAddress);

  /// The peers currently known. Read it directly; listen to [changes] to know
  /// when it has moved on.
  final PeerTable table = PeerTable();

  /// Receives debug lines. Injected so `core/` stays free of Flutter's
  /// `debugPrint` — and so tests can assert on what was rejected.
  final void Function(String message)? onLog;

  /// Fires whenever [table] changed. Broadcast: the service never depends on
  /// anyone listening.
  Stream<void> get changes => _changes.stream;

  final int _discoveryPort;
  final InternetAddress _multicast;
  final InternetAddress _broadcast;

  final StreamController<void> _changes = StreamController<void>.broadcast();

  RawDatagramSocket? _receiver;
  StreamSubscription<RawSocketEvent>? _receiverSub;
  final List<RawDatagramSocket> _senders = <RawDatagramSocket>[];
  Timer? _announceTimer;
  Timer? _timeoutTimer;

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
    final RawDatagramSocket receiver = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      _discoveryPort,
      reuseAddress: true,
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

    for (final MapEntry<NetworkInterface, List<String>> entry
        in interfaces.entries) {
      for (final String address in entry.value) {
        try {
          final RawDatagramSocket sender = await RawDatagramSocket.bind(
            InternetAddress(address),
            0, // ephemeral: nobody replies to this socket, see _reply
          );
          sender.broadcastEnabled = true;
          sender.multicastHops = 1; // never leave the local segment
          sender.multicastLoopback = false; // our own multicast is not news
          sender.readEventsEnabled = false; // send-only
          _senders.add(sender);
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

  /// Announces immediately, without waiting for the next scheduled round.
  ///
  /// Backs the Rescan button. On a network where the first announce was lost,
  /// this is the difference between "wait five seconds" and "nothing happens".
  void rescan() {
    if (!_started) {
      return;
    }
    _send(AnnounceType.probe);
    _send(AnnounceType.announce);
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
    _failingSenders.clear();
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
      // silent, which would look identical to a firewall block.
      final RawDatagramSocket? receiver = _receiver;
      if (receiver != null) {
        _sendTo(receiver, bytes, _multicast);
        _sendTo(receiver, bytes, _broadcast);
      }
      return;
    }

    for (final RawDatagramSocket sender in _senders) {
      _sendTo(sender, bytes, _multicast);
      _sendTo(sender, bytes, _broadcast);
    }
  }

  /// Unicast announce back to one peer.
  void _reply(AnnouncePacket packet, InternetAddress to) {
    final Peer? self = _self;
    final RawDatagramSocket? receiver = _receiver;
    if (self == null || receiver == null) {
      return;
    }

    final Uint8List bytes;
    try {
      bytes = _build(AnnounceType.announce, self);
    } on AnnounceTooLargeException catch (error) {
      _log('not replying: $error');
      return;
    }

    // Sent from the receiving socket, not from a per-interface sender: for a
    // *specific* destination the routing table picks the correct interface by
    // construction, and the per-interface senders exist precisely because that
    // is not true of broadcast and multicast.
    //
    // Addressed to the peer's own port from its packet, never to
    // `datagram.port` — that source port belongs to the peer's ephemeral
    // send-only socket, which is not reading.
    _sendTo(receiver, bytes, to, port: packet.port ?? _discoveryPort);
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

  /// Senders that have started failing, so the failure is reported once when it
  /// begins rather than every announce interval forever.
  final Set<String> _failingSenders = <String>{};

  void _sendTo(
    RawDatagramSocket socket,
    Uint8List bytes,
    InternetAddress target, {
    int? port,
  }) {
    final String where = socket.address.address;
    int written;
    try {
      written = socket.send(bytes, target, port ?? _discoveryPort);
    } on SocketException {
      // Swallowed deliberately: a single unusable interface must not stop the
      // others from being tried, and the interface was already validated at
      // bind time.
      _noteSendFailure(where, 'threw');
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
      _noteSendFailure(where, 'wrote $written of ${bytes.length} bytes');
      return;
    }
    if (_failingSenders.remove(where)) {
      _log('sending via $where recovered');
    }
  }

  /// Logs the first failure for [where] and stays quiet until it recovers.
  ///
  /// A dead adapter is a normal, self-correcting condition — a laptop lid
  /// closing, a VPN dropping — so a line per announce would bury everything
  /// else. Logging the *transition* keeps the one fact that matters and costs
  /// nothing while it persists.
  void _noteSendFailure(String where, String detail) {
    if (_failingSenders.add(where)) {
      _log('cannot send via $where: $detail');
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
