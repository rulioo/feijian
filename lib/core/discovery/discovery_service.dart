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
/// The only *socket* seam in this class: [DiscoveryService] throws away a
/// socket that has stopped writing and binds another, and no test can make a
/// real socket latch the way the OS makes one latch. (The timing fields on the
/// constructor are seams of the other kind — they exist so a test can watch the
/// heartbeat without waiting out a real five-second interval.)
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
    this.announceInterval = kAnnounceInterval,
    this.probeEveryRounds = kProbeEveryRounds,
    this.startBurstRounds = kStartBurstRounds,
    this.startBurstGap = kStartBurstGap,
    this.silentPeerAfter = kSilentPeerRebindAfter,
  })  : _discoveryPort = discoveryPort,
        _bind = bind ?? _bindSocket,
        _multicast = _parseOrFallback(multicastGroup, kMulticastGroup),
        _broadcast = InternetAddress(kBroadcastAddress);

  /// How often the heartbeat tells the network this device is here.
  ///
  /// Injectable only so tests do not have to wait out the real interval; the
  /// cadence itself is [kAnnounceInterval]'s.
  final Duration announceInterval;

  /// Heartbeat rounds between the probes — see [_onAnnounceTick].
  final int probeEveryRounds;

  /// Rounds of probe-and-announce sent when discovery first comes up, and the
  /// gap between them — see [_sendStartBurst]. The same shape as the rounds a
  /// manual refresh sends, for the same reason.
  final int startBurstRounds;
  final Duration startBurstGap;

  /// How long every peer may stay silent before discovery rebuilds itself —
  /// see [_repairIfEveryPeerHasGoneQuiet].
  final Duration silentPeerAfter;

  static Future<RawDatagramSocket> _bindSocket(
    InternetAddress address,
    int port,
  ) =>
      RawDatagramSocket.bind(address, port, reuseAddress: true);

  /// The peers currently known. Read it directly; listen to [changes] to know
  /// when it has moved on.
  final PeerTable table = PeerTable();

  /// Receives debug lines. Injected so `core/` stays free of Flutter's
  /// `debugPrint` — and so tests can assert on what was rejected.
  final void Function(String message)? onLog;

  /// Fires whenever something a listener can see has changed — the peer table,
  /// or whether discovery is running at all. Broadcast: the service never
  /// depends on anyone listening.
  ///
  /// Lifecycle counts, not just the table. A listener that only hears about peer
  /// changes cannot tell "discovery never started" from "nobody is out there",
  /// and the difference between those two is the whole of this class's reported
  /// history — so a start that succeeds with no peers on the network still has
  /// to say so.
  @override
  Stream<void> get changes => _changes.stream;

  /// The peer list as [PeerSource] sees it — same thing as `table.peers`.
  @override
  List<Peer> get peers => table.peers;

  @override
  bool addManual(Peer peer) {
    if (!table.addManual(peer)) {
      return false;
    }
    _notify();
    return true;
  }

  @override
  bool isManual(String id) => table.isManual(id);

  @override
  bool setOnline(String id, {required bool isOnline}) {
    if (!table.setOnline(id, isOnline: isOnline)) {
      return false;
    }
    _notify();
    return true;
  }

  @override
  bool forget(String id) {
    if (!table.forget(id)) {
      return false;
    }
    _notify();
    return true;
  }

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

  /// The pending round of the opening burst, if one is still to come.
  Timer? _startBurstTimer;

  /// Heartbeat rounds since the last start, for [_onAnnounceTick].
  int _announceRound = 0;

  /// True once the watchdog has rebuilt discovery for the silence currently in
  /// progress. Cleared the moment anything is heard again, so the next silence
  /// is repairable too — but a silence that outlasts the repair does not turn
  /// into a rebuild every second. See [_repairIfEveryPeerHasGoneQuiet].
  bool _silenceRepaired = false;

  /// Consecutive refused writes per socket, and the sockets the first refusal
  /// has already been reported for.
  final Map<RawDatagramSocket, int> _writeFailures = <RawDatagramSocket, int>{};
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

  /// True between an explicit [stop] and the next [start].
  ///
  /// This is the flag that tells the two ways of not being started apart, and
  /// [rescan] has to: a service that never got going is exactly what a second
  /// press of the button is for, while a service that was stopped on purpose is
  /// not one a refresh button has any business bringing back. [dispose] reaches
  /// this through [stop], so a disposed service is covered by the same flag —
  /// and *must* be, because starting one would bind real sockets behind the
  /// `changes` stream `dispose` has already closed: a service that receives,
  /// announces, and reports none of it.
  bool _stopped = false;

  /// True while [_startBody] is in flight — see [start], which is the only
  /// thing that sets it.
  bool _starting = false;

  bool get isRunning => _started;

  /// Whether anything is being received right now.
  ///
  /// Deliberately separate from [isRunning], because the two come apart in the
  /// state that matters most: a service whose listener could not be bound is
  /// still *running* — its timers fire, its senders announce, and every peer it
  /// talks to sees it normally — while hearing nothing at all. From the outside
  /// that is indistinguishable from an empty network, and telling the two apart
  /// is the difference between "nobody is there" and "I have gone deaf".
  bool get isListening => _receiver != null;

  /// Both halves working: sending and receiving. What the device list needs to
  /// be telling the truth when it says it found nothing.
  bool get isHealthy => _started && _receiver != null;

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
    final bool identityChanged = previous != null &&
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
  Future<void> start() {
    if (_started || _starting) {
      // Idempotent, and idempotent *including a start still in flight*.
      // `_started` only turns true at the very end of one, so a second caller
      // arriving during launch — a rescan from the refresh button, or from the
      // app coming back to the foreground — would otherwise read "not started"
      // and begin another. Both binds pass `reuseAddress`, so the second would
      // succeed rather than fail: two listeners on the discovery port, one of
      // them leaked, and the next launch finding its own port taken.
      return Future<void>.value();
    }
    _starting = true;
    return _startBody().whenComplete(() => _starting = false);
  }

  Future<void> _startBody() async {
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

    _joinGroup(receiver, interfaces);

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
    _stopped = false;
    // Before the first announce, and deliberately: a consumer that was showing
    // "discovery is not running" has to stop showing it the moment that is
    // false, even if the network turns out to be empty.
    _notify();

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

    // Then the same round again a couple of times, because a device that has
    // just joined the network gets exactly one moment to introduce itself and
    // it is the moment its owner is watching. The first round above stays
    // synchronous, so "it is on the wire before start() returns" still holds.
    _sendStartBurst();

    _announceRound = 0;
    _silenceRepaired = false;
    _announceTimer = Timer.periodic(announceInterval, (_) => _onAnnounceTick());
    // 1s granularity: fine enough that the 15s/60s thresholds land where the
    // design says they do, cheap enough not to think about. The watchdog shares
    // it — see [_repairIfEveryPeerHasGoneQuiet].
    _timeoutTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _applyTimeouts(),
    );
  }

  /// What the heartbeat does once every [announceInterval].
  ///
  /// Mostly it announces. Every [probeEveryRounds] it also asks.
  ///
  /// The asking is the part that matters on a broken network. An announce goes
  /// out over multicast and broadcast, and if either of those has stopped
  /// arriving at a peer — a multicast membership the kernel dropped when an
  /// interface bounced, a broadcast the access point will not forward — this
  /// device is invisible to that peer no matter how often it announces. The
  /// peer *can* still reach us by unicast, which is exactly what happens when
  /// someone presses Rescan: the refresh sends a probe, and every peer that
  /// hears it answers by unicast. Sending one on the heartbeat means the list
  /// repairs itself instead of waiting for a human to notice.
  void _onAnnounceTick() {
    _announceRound++;
    if (_announceRound % probeEveryRounds == 0) {
      _send(AnnounceType.probe);
    }
    _send(AnnounceType.announce);
  }

  /// Repeats the opening probe-and-announce [startBurstRounds] times in total,
  /// [startBurstGap] apart. Round one has already been sent by the caller.
  ///
  /// A [stop] that lands mid-burst ends it, because [stop] cancels the pending
  /// timer below. There was also an `if (!_started) return` here, guarding
  /// against a round going out from a service that had already said goodbye;
  /// it was removed as unreachable and unobservable. Unreachable because [stop]
  /// cancels this timer synchronously, before its first `await`, and a cancelled
  /// Dart timer never runs — and unobservable even with both removed, because
  /// [stop] also closes every socket, so a late round has nothing to write on.
  /// The test that covers stopping mid-burst therefore passes for either
  /// reason; keeping a guard that no test can fail is what it looks like to
  /// have a guard that does nothing.
  void _sendStartBurst() {
    if (startBurstRounds <= 1) {
      return;
    }
    int sent = 1;
    void schedule() {
      _startBurstTimer = Timer(startBurstGap, () {
        _send(AnnounceType.probe);
        _send(AnnounceType.announce);
        sent++;
        if (sent < startBurstRounds) {
          schedule();
        }
      });
    }

    schedule();
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
  /// than one datagram's odds.
  ///
  /// Safe to call before [start] and while a refresh is already in flight. It
  /// is *not* a no-op in the first case — see [_firstStart] for why that guard
  /// was removed.
  void rescan() {
    if (_refreshing || _stopped) {
      return;
    }
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    _refreshing = true;
    try {
      if (_started) {
        await _rebindAll();
      } else if (!await _firstStart()) {
        return;
      }
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

  /// Starts a service that never got going — the way back from a start that
  /// failed.
  ///
  /// This used to be the one case [rescan] refused to handle, and the guard
  /// (`if (!_started) return`) came from reading "not started" as "the user has
  /// not asked for this yet". It is not: [start] reports a port it cannot bind by
  /// throwing, the provider that performs it at launch time logs the failure and
  /// gives up, and nothing else ever tries again. So a device whose discovery
  /// port was momentarily taken — or blocked at that instant, which is what a
  /// VPN or a captive portal coming up during launch looks like — spent the rest
  /// of the process's life with an empty device list and two buttons that could
  /// not help, because **both of them returned early on the same flag**. Only
  /// restarting the app could cure it.
  ///
  /// That is the whole symptom this class keeps being reported for, arriving
  /// through a different door each time: the repair exists on the start path and
  /// the refresh path does not reach it. The button whose only job is "try
  /// again" must be able to try again.
  Future<bool> _firstStart() async {
    if (_self == null) {
      // No identity yet. [start] would throw a StateError, and a button press is
      // not the place to find that out — `updateSelf` is called before `start`
      // by the provider, so this is a race with launch, not a user error.
      _log('rescan: no identity yet, so discovery cannot start');
      return false;
    }
    try {
      await start();
      // [start] returns at once when one is already in flight, so reaching here
      // is not the same as being up. Reporting "started it" off a call that did
      // nothing is the kind of line that sends the next investigation down the
      // wrong path — and a start that is already running does everything this
      // refresh was going to do anyway, so there is nothing left to skip.
      if (!_started) {
        _log('rescan: a start was already in flight');
        return false;
      }
      _log('rescan: discovery was not running; started it');
      return true;
    } on Object catch (error) {
      _log('rescan: could not start discovery: $error');
      return false;
    }
  }

  /// Closes every socket and binds replacements — in both directions.
  ///
  /// The listener used to be left alone here, on the reasoning that it never
  /// sends and so cannot latch, and that rebuilding it would cost a multicast
  /// rejoin for no gain. **Both halves of that were wrong**, and the cost was a
  /// Refresh and a Rescan that could not recover from the one failure users
  /// actually hit.
  ///
  /// A multicast membership belongs to the interface it was made on, and the
  /// kernel drops it when that interface goes down — Wi-Fi sleeping through a
  /// long idle stretch, the phone roaming, the adapter resetting. Nothing
  /// reports it: the socket stays open, the join succeeded when it was made,
  /// and the only symptom is that announcements stop arriving. The senders are
  /// not what broke, so repairing them changes nothing, and re-announcing is
  /// likewise a no-op — the group we are sending to is not the group we are
  /// listening on. Restarting the process worked because [start] rejoins;
  /// nothing else did, because nothing else ever joined twice.
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

    // Enumerated once and used for both halves: the interfaces worth sending
    // on are exactly the ones worth listening on, and a second enumeration
    // could disagree with this one if the network moved in between.
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

    await _rebindListener(interfaces);

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

  /// Replaces the listening socket and rejoins the group on every interface.
  ///
  /// The old socket is closed *before* the replacement is bound, not after.
  /// Both binds pass `reuseAddress`, so a second socket on the same port would
  /// not fail — it would silently take half the traffic, and which half is the
  /// kernel's business. A listener that is absent for the few milliseconds the
  /// rebind takes is the cheaper mistake by a wide margin: announces repeat
  /// every [kAnnounceInterval], the refresh sends [_refreshRounds] rounds, and
  /// the senders are already rebound and working throughout.
  Future<void> _rebindListener(
    Map<NetworkInterface, List<String>> interfaces,
  ) async {
    if (!_started) {
      return;
    }
    final RawDatagramSocket? previous = _receiver;
    final StreamSubscription<RawSocketEvent>? previousSub = _receiverSub;
    _receiver = null;
    _receiverSub = null;

    await previousSub?.cancel();
    previous?.close();

    final RawDatagramSocket receiver;
    try {
      receiver = await _bind(InternetAddress.anyIPv4, _discoveryPort);
    } on SocketException catch (error) {
      // Degraded rather than repaired: nothing is listening any more. Loud,
      // because the way out is for the user to press Rescan again and there is
      // no other sign that anything went wrong.
      _log(
          'could not rebind the listener on $_discoveryPort: ${error.message}');
      return;
    }

    if (!_started) {
      // stop() ran during the bind. Same rule as everywhere else: a socket
      // created after the service stopped must not be left open.
      receiver.close();
      return;
    }

    receiver.broadcastEnabled = true;
    _receiver = receiver;
    _receiverSub = receiver.listen(
      _onSocketEvent,
      onError: (Object error) => _log('receive error: $error'),
      cancelOnError: false,
    );
    _joinGroup(receiver, interfaces);
    // The one line that says the receive path was repaired rather than assumed.
    // Without it, a refresh that fixed nothing looks identical in the log to
    // one that fixed everything.
    _log('rebuilt the listener on $_discoveryPort and rejoined the group on '
        '${interfaces.length} interface(s)');
  }

  /// Joins the group on every usable interface.
  ///
  /// Per interface rather than once implicitly: an implicit join follows the
  /// default route, which is what pulls multicast in from a virtual adapter we
  /// deliberately excluded.
  ///
  /// Called from [start] and again from every refresh, because a membership is
  /// not a property of the socket — see [_rebindAll] for what drops it.
  void _joinGroup(
    RawDatagramSocket receiver,
    Map<NetworkInterface, List<String>> interfaces,
  ) {
    // The receiver must still be the one this service listens on. Both callers
    // cross an `await` between binding and joining (enumerating the interfaces,
    // or cancelling the old subscription), and `stop()` can run in that window
    // and close the socket. Joining a closed socket does not throw and does not
    // return — it walks into `_NativeSocket.nativeJoinMulticast` and takes the
    // whole VM down with a segfault, verified on Dart 3.6.2 / Windows x64. A
    // guard here is the difference between a missed join and a crash on the way
    // out of the app.
    if (!identical(receiver, _receiver)) {
      return;
    }
    for (final NetworkInterface ni in interfaces.keys) {
      try {
        receiver.joinMulticast(_multicast, ni);
      } on SocketException catch (error) {
        _log('multicast join failed on ${ni.name}: ${error.message}');
      }
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
    // Set before the early return, not after it. A service whose start failed
    // was never running, so `_started` is already false and there is nothing
    // here to close — but it is still being told to end, and a later [rescan]
    // must not read "not started" as "never tried" and bind sockets behind a
    // `changes` stream that `dispose` is about to close.
    _stopped = true;
    if (!_started) {
      return;
    }
    _started = false;

    _announceTimer?.cancel();
    _announceTimer = null;
    _timeoutTimer?.cancel();
    _timeoutTimer = null;
    // Ends an opening burst that is still in flight. Correct ownership rather
    // than a load-bearing guard — see [_sendStartBurst] for why it is not, and
    // cannot be, the thing that keeps a stopped service off the network.
    _startBurstTimer?.cancel();
    _startBurstTimer = null;

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
    // `table.clear()` is a table operation, not a lifecycled one, so it does not
    // notify on its own — without this a deliberate stop would leave every
    // listener's last-known list on screen.
    _notify();
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
    final AnnounceDecode decoded =
        AnnouncePacket.decode(datagram.data, now: now);
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

    // Someone else's packet arrived, so whatever silence was in progress is
    // over and a later one deserves its own repair. Deliberately here rather
    // than where the table is touched: a probe is proof the path works even
    // though it records nothing, and what the watchdog needs to know is whether
    // anything is arriving at all.
    //
    // Past the self-check above, and that ordering is load-bearing: our own
    // broadcast comes back to our own listener, and if it counted as company
    // then the watchdog's own probes would clear the flag that stops it running
    // again, and discovery would rebuild itself once a second forever.
    _silenceRepaired = false;

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
        if (table.touch(
            packet: packet, fromIp: datagram.address.address, now: now)) {
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
    _repairIfEveryPeerHasGoneQuiet();
  }

  /// Rebuilds discovery when every peer this device has ever heard from has
  /// gone quiet at once — the watchdog, and the only repair here that nobody had
  /// to ask for.
  ///
  /// Every other way back from a broken network in this class is triggered by
  /// something: a datagram arriving, a lifecycle change, a finger on Rescan. The
  /// failure this covers is the one where nothing arrives, so nothing triggers.
  /// The device sits there with a list of peers it can no longer hear and, since
  /// the broken direction is the one pointing at it, no amount of announcing
  /// fixes it — the peers are not the ones who cannot hear.
  ///
  /// "Everyone silent" rather than "one peer silent" is the whole test. Some
  /// peers being quiet while one is talking means the network is delivering
  /// perfectly well and the quiet ones really have gone — rebuilding for that
  /// would close the listening socket every time a laptop was shut.
  ///
  /// Hand-added peers do not count, in either direction. They are dialled over
  /// TCP when the user opens them and are never expected to announce, so their
  /// silence says nothing about whether the network works.
  ///
  /// Runs on the existing one-second tick rather than a timer of its own: the
  /// threshold is tens of seconds, so a second of jitter costs nothing, and one
  /// less timer is one less thing to cancel in [stop].
  void _repairIfEveryPeerHasGoneQuiet() {
    if (_refreshing || _stopped || !_started || _silenceRepaired) {
      return;
    }

    final DateTime now = DateTime.now();
    bool heardFromAnyone = false;
    for (final Peer peer in table.peers) {
      final DateTime? lastSeen = peer.lastSeen;
      if (lastSeen == null) {
        continue;
      }
      heardFromAnyone = true;
      if (now.difference(lastSeen) < silentPeerAfter) {
        return;
      }
    }
    if (!heardFromAnyone) {
      return;
    }

    _silenceRepaired = true;
    _log(
      'watchdog: nothing heard from any peer for '
      '${silentPeerAfter.inSeconds}s, rebuilding discovery',
    );
    // The same rebuild a manual refresh performs, which is the point: the
    // button the user was pressing to fix this is now pressed for them.
    unawaited(_refresh());
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
