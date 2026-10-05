import '../models/peer.dart';

/// The peers discovery currently knows about — design.md §4.1.
///
/// A seam rather than a convenience: everything above discovery needs the
/// *contents* of the peer table and the fact that they changed, and nothing
/// else. Depending on the whole `DiscoveryService` would drag in socket
/// ownership and a fixed UDP port, which is what makes the layer above it
/// impossible to exercise in a test that does not want to bind 24250.
abstract interface class PeerSource {
  /// Fires when the *displayed* list changes — a peer appearing, renaming
  /// itself, or going offline. Routine announces from an unchanged peer do not
  /// fire, so a steady network costs no work.
  Stream<void> get changes;

  /// The peers, ordered for display.
  List<Peer> get peers;

  /// Adds a peer the user entered by hand — the Add-by-IP escape hatch
  /// (design.md §4.1).
  ///
  /// The one write the layers above discovery need to make, and the reason this
  /// is a seam and not a read-only view. Everything else a peer is comes off the
  /// network; a typed address is the exception, and the ageing rules have to be
  /// told about it or they delete it within the minute — see `PeerTable`. The
  /// implementation emits [changes] when the displayed list changes.
  bool addManual(Peer peer);

  /// True when [id] was entered by hand and has not announced since.
  bool isManual(String id);

  /// Sets whether a manual peer is reachable, from the connection state.
  bool setOnline(String id, {required bool isOnline});

  /// Forgets a peer the user removed by hand. Manual peers are exempt from
  /// ageing, so this is the only thing that takes one off the list.
  bool forget(String id);
}
