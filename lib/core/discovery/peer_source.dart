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
}
