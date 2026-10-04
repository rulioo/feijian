import 'package:drift/drift.dart';

import '../database.dart';

/// Reads and writes the `peer` table — design.md §5.1.
///
/// Every write here is triggered by something a peer said about itself, so the
/// interesting question is not "how do I store this" but "which columns are the
/// peer's to change". See [recordSeen].
class PeerDao {
  PeerDao(this._db);

  final AppDatabase _db;

  /// Records what a peer just told us about itself, creating the row if needed.
  ///
  /// Only the columns the peer owns are written. `is_trusted` is deliberately
  /// left out: it is the user's decision about that device, and an announce
  /// arrives every five seconds per peer — a blanket upsert would reset the
  /// trust the user granted a moment after granting it. The same reasoning
  /// protects `avatar`, which is uploaded deliberately rather than announced.
  ///
  /// [lastSeen] is the peer's own timestamp and is display-only (§4.5); callers
  /// that need to know whether a peer is *currently* reachable should use the
  /// in-memory online state, not this column.
  Future<void> recordSeen({
    required String id,
    required String name,
    required String deviceType,
    String? os,
    String? icon,
    String? lastIp,
    int? lastSeen,
  }) {
    return _db.into(_db.peers).insert(
          PeersCompanion(
            id: Value<String>(id),
            name: Value<String>(name),
            deviceType: Value<String>(deviceType),
            os: Value<String?>(os),
            icon: Value<String?>(icon),
            lastIp: Value<String?>(lastIp),
            lastSeen: Value<int?>(lastSeen),
          ),
          // The companion names exactly the peer-owned columns, so this update
          // touches those and nothing else. A value we did not gather this time
          // (an older announce with no `os`) does clear that column — which is
          // correct, since it means the peer no longer reports one.
          // The callback is handed the existing row so an update can refer to
          // it; nothing here needs that, since every value comes from the
          // announce being recorded.
          onConflict: DoUpdate(
            (_) => PeersCompanion(
              name: Value<String>(name),
              deviceType: Value<String>(deviceType),
              os: Value<String?>(os),
              icon: Value<String?>(icon),
              lastIp: Value<String?>(lastIp),
              lastSeen: Value<int?>(lastSeen),
            ),
            target: <Column<Object>>[_db.peers.id],
          ),
        );
  }

  Future<PeerRow?> byId(String id) {
    return (_db.select(_db.peers)..where((Peers t) => t.id.equals(id)))
        .getSingleOrNull();
  }

  Future<List<PeerRow>> all() {
    return (_db.select(_db.peers)
          ..orderBy(<OrderingTerm Function(Peers)>[
            (Peers t) => OrderingTerm.asc(t.name),
          ]))
        .get();
  }

  /// Peers the user has trusted to send files without asking (§6.4).
  Future<List<PeerRow>> trusted() {
    return (_db.select(_db.peers)
          ..where((Peers t) => t.isTrusted.equals(true)))
        .get();
  }

  Future<void> setTrusted(String id, bool trusted) {
    return (_db.update(_db.peers)..where((Peers t) => t.id.equals(id)))
        .write(PeersCompanion(isTrusted: Value<bool>(trusted)));
  }

  /// Applies a rename made on this device.
  ///
  /// Separate from [recordSeen] because the two disagree by design: a local
  /// rename wins until the peer announces a name of its own, at which point the
  /// peer's own choice is the truer one. [recordSeen] therefore does overwrite
  /// this — the user is renaming a device they are looking at, not claiming to
  /// know better than the device itself.
  Future<void> rename(String id, String name) {
    return (_db.update(_db.peers)..where((Peers t) => t.id.equals(id)))
        .write(PeersCompanion(name: Value<String>(name)));
  }

  /// Removes a peer from the device list.
  ///
  /// Returns the number of rows removed. Conversations and messages are left
  /// alone on purpose: losing a conversation because the user tidied their
  /// device list is not a trade anyone would accept, and there is no undo. The
  /// `conversation.peer_id` column is therefore not a foreign key — see the note
  /// on it in `database.dart`.
  Future<int> forget(String id) {
    return (_db.delete(_db.peers)..where((Peers t) => t.id.equals(id))).go();
  }

  Future<int> count() async {
    final Expression<int> tally = _db.peers.id.count();
    final TypedResult result =
        await (_db.selectOnly(_db.peers)..addColumns(<Expression<Object>>[tally]))
            .getSingle();
    return result.read(tally) ?? 0;
  }
}
