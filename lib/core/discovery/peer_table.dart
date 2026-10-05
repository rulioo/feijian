import '../constants.dart';
import '../models/peer.dart';
import 'announce.dart';

/// The set of peers currently known to discovery, with the online → offline →
/// removed ageing rules from design.md §4.1.
///
/// Pure Dart and free of sockets, so the whole state machine is testable by
/// calling [touch] and [applyTimeouts] with explicit timestamps.
///
/// Time is always passed in rather than read from [DateTime.now] for that
/// reason: the 15s and 60s thresholds are the substance of this class, and they
/// cannot be tested by a method that consults the clock itself.
class PeerTable {
  PeerTable({this.selfId});

  /// This device's own id. Announcements carrying it are ignored — they are our
  /// own datagrams looping back off the network.
  String? selfId;

  final Map<String, Peer> _byId = <String, Peer>{};

  /// Peers the user entered by hand rather than heard on the network.
  ///
  /// This exists because the ageing rules have nothing to work from on a peer
  /// that never announces. AP isolation — the very situation manual entry is
  /// for (design.md §4.1) — drops multicast entirely, so no announce ever
  /// arrives, `lastSeen` never advances, and [applyTimeouts] would delete the
  /// entry a minute after the user typed it in. Membership here exempts a peer
  /// from ageing until the user removes it or it starts announcing for real, at
  /// which point [touch] drops it from this set and the ordinary rules resume.
  final Set<String> _manual = <String>{};

  /// Peers, ordered for display: online first, then by name.
  ///
  /// The ordering is part of the contract, not an implementation detail — an
  /// unordered map iteration would make the list reshuffle on every announce.
  List<Peer> get peers {
    final List<Peer> list = _byId.values.toList();
    list.sort((Peer a, Peer b) {
      if (a.isOnline != b.isOnline) {
        return a.isOnline ? -1 : 1;
      }
      final int byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      // Names are user-editable and may collide; the id keeps the order stable.
      return byName != 0 ? byName : a.id.compareTo(b.id);
    });
    return list;
  }

  int get length => _byId.length;

  bool get isEmpty => _byId.isEmpty;

  int get onlineCount =>
      _byId.values.where((Peer peer) => peer.isOnline).length;

  Peer? operator [](String id) => _byId[id];

  /// When this peer was last heard from, for the announce-frequency check that
  /// decides whether a unicast reply is warranted.
  DateTime? lastSeenOf(String id) => _byId[id]?.lastSeen;

  /// Records an announce. Returns true when the *displayed* list changed.
  ///
  /// A routine announce from an unchanged peer returns false even though
  /// `lastSeen` advanced, so the UI does not rebuild every five seconds per
  /// peer for no visible reason.
  bool touch({
    required AnnouncePacket packet,
    required String fromIp,
    required DateTime now,
  }) {
    if (packet.id == selfId) {
      return false;
    }

    final Peer fresh = packet.toPeer(fromIp: fromIp, seenAt: now);
    final Peer? existing = _byId[packet.id];
    // A peer's name and icon are user-editable on their side and its address
    // may have changed, so the fresh announce always wins; only the locally
    // owned trust flag is carried across.
    final Peer merged = existing == null
        ? fresh
        : fresh.copyWith(isTrusted: existing.isTrusted);

    _byId[packet.id] = merged;

    // A real announce supersedes a hand-typed entry: the device is reachable the
    // ordinary way after all, so it stops being the user's problem to remove and
    // starts being aged like every other peer. This is the exit from manual
    // mode that needs no UI, and it is why a manual peer costs nothing once the
    // network starts behaving.
    _manual.remove(packet.id);

    return existing == null || !_sameVisibleState(existing, merged);
  }

  /// Ages peers out. Returns true when the displayed list changed.
  ///
  /// Two stages, per design.md §4.1: greying out at [kPeerOfflineAfter] keeps
  /// the conversation history reachable on a device that briefly dropped off,
  /// while removal at [kPeerRemoveAfter] keeps the list from filling with
  /// devices that left the network long ago.
  bool applyTimeouts(DateTime now) {
    bool changed = false;
    final List<String> expired = <String>[];
    // Peer is immutable, so the offline transition is a replacement rather than
    // an assignment — and it is deferred along with the removals, because
    // mutating the map while iterating it throws.
    final Map<String, Peer> wentOffline = <String, Peer>{};

    for (final MapEntry<String, Peer> entry in _byId.entries) {
      if (_manual.contains(entry.key)) {
        // Not aged: a hand-entered peer has no announces to be measured
        // against, and "we have heard nothing from it" is the normal state of a
        // device behind AP isolation rather than a reason to drop it.
        continue;
      }
      final DateTime? seen = entry.value.lastSeen;
      if (seen == null) {
        continue;
      }
      final Duration age = now.difference(seen);
      if (age > kPeerRemoveAfter) {
        expired.add(entry.key);
        changed = true;
      } else if (age > kPeerOfflineAfter && entry.value.isOnline) {
        wentOffline[entry.key] = entry.value.copyWith(isOnline: false);
        changed = true;
      }
    }

    for (final String id in expired) {
      _byId.remove(id);
    }
    _byId.addAll(wentOffline);
    return changed;
  }

  /// Marks a peer trusted, or clears it. Returns true when it changed.
  ///
  /// Trust is decided on this device and is never taken from the network, so
  /// [touch] carries the stored value across every announce.
  bool setTrusted(String id, bool trusted) {
    final Peer? peer = _byId[id];
    if (peer == null || peer.isTrusted == trusted) {
      return false;
    }
    _byId[id] = peer.copyWith(isTrusted: trusted);
    return true;
  }

  /// Drops a peer immediately, for an explicit `bye`.
  ///
  /// A manual peer is exempt. `bye` arrives over a control connection, and a
  /// device we reached by typing its address is exactly the one whose `bye` we
  /// may receive while still wanting it listed — the connection dropped, not the
  /// device. Only the user removes a manual entry; see [forget].
  bool remove(String id) {
    if (_manual.contains(id)) {
      return false;
    }
    return _byId.remove(id) != null;
  }

  /// True when [id] was entered by hand and has not announced since.
  bool isManual(String id) => _manual.contains(id);

  /// The manual peer ids, as a copy — the caller must not be able to mutate the
  /// table's own set.
  Set<String> get manualIds => Set<String>.unmodifiable(_manual);

  /// Records a peer the user entered by hand. Returns true when the displayed
  /// list changed.
  ///
  /// A peer that is already known from an announce is left alone: the announce
  /// carries a name, an icon and an OS string that a typed address does not, and
  /// the device is reachable the ordinary way already, so there is nothing for
  /// manual mode to add.
  ///
  /// The entry starts offline in the caller's hands — [setOnline] is what the
  /// connection state moves — but the caller decides, because it is the one that
  /// knows whether the address answered before it got here.
  bool addManual(Peer peer) {
    if (peer.id == selfId) {
      return false;
    }
    final Peer? existing = _byId[peer.id];
    if (existing != null && !_manual.contains(peer.id)) {
      return false;
    }
    _manual.add(peer.id);
    // Trust is decided locally and survives every other kind of update, so it
    // survives this one too.
    final Peer merged =
        existing == null ? peer : peer.copyWith(isTrusted: existing.isTrusted);
    _byId[peer.id] = merged;
    return existing == null || !_sameVisibleState(existing, merged);
  }

  /// Sets whether a manual peer is reachable. Returns true when the displayed
  /// list changed.
  ///
  /// Only manual peers: for an announced one the network is a better authority
  /// on whether a device is up, and the two would fight — an announce arriving
  /// mid-reconnect would flip the entry back and forth.
  bool setOnline(String id, {required bool isOnline}) {
    if (!_manual.contains(id)) {
      return false;
    }
    final Peer? peer = _byId[id];
    if (peer == null || peer.isOnline == isOnline) {
      return false;
    }
    _byId[id] = peer.copyWith(isOnline: isOnline);
    return true;
  }

  /// Drops a peer the user removed by hand — manual or not. Returns true when
  /// the displayed list changed.
  ///
  /// This is the only way out of manual mode that the user controls, and the
  /// counterpart to [remove]'s exemption: the ageing rules cannot take a manual
  /// peer away, so something has to.
  bool forget(String id) {
    _manual.remove(id);
    return _byId.remove(id) != null;
  }

  void clear() {
    _byId.clear();
    _manual.clear();
  }

  /// Compares only the fields the device list renders.
  ///
  /// `lastSeen` is excluded on purpose: it advances on every announce, so
  /// including it would report a change every [kAnnounceInterval] forever.
  static bool _sameVisibleState(Peer a, Peer b) {
    return a.name == b.name &&
        a.deviceType == b.deviceType &&
        a.icon == b.icon &&
        a.os == b.os &&
        a.isOnline == b.isOnline &&
        a.lastIp == b.lastIp &&
        a.lastPort == b.lastPort;
  }
}
