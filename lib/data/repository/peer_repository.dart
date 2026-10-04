import 'package:feijian/data/dao/peer_dao.dart';
import 'package:feijian/data/database.dart';

import '../../core/models/peer.dart';

/// The stored device list — design.md §5.1 `peer` table.
///
/// Turns rows into [Peer] values so that nothing above this layer imports drift
/// or knows a column name. The mapping is not quite one-to-one, and the
/// difference is the interesting part: `isOnline` and `lastPort` are
/// **runtime-only**. A peer's port is where it is listening *right now*, so
/// [known] always reports `isOnline: false` and no port — the state layer
/// overlays liveness from discovery, and a stale port from a previous run must
/// never be dialled.
class PeerRepository {
  PeerRepository(AppDatabase db) : _peers = PeerDao(db);

  final PeerDao _peers;

  /// Every device this installation has ever seen, name-sorted.
  Future<List<Peer>> known() async {
    final List<PeerRow> rows = await _peers.all();
    return rows.map(_toPeer).toList();
  }

  Future<Peer?> byId(String id) async {
    final PeerRow? row = await _peers.byId(id);
    return row == null ? null : _toPeer(row);
  }

  /// Records what a peer announced about itself.
  ///
  /// [Peer.lastPort] is deliberately dropped: §5.1 does not persist it, since a
  /// peer that restarts on a different port would otherwise be dialled at the
  /// address it used last time.
  Future<void> recordAnnounce(Peer peer, {required DateTime at}) {
    return _peers.recordSeen(
      id: peer.id,
      name: peer.name,
      deviceType: peer.deviceType.wire,
      os: peer.os,
      icon: peer.icon.wire,
      lastIp: peer.lastIp,
      lastSeen: at.millisecondsSinceEpoch,
    );
  }

  Future<List<Peer>> trusted() async {
    final List<PeerRow> rows = await _peers.trusted();
    return rows.map(_toPeer).toList();
  }

  Future<void> setTrusted(String id, bool trusted) =>
      _peers.setTrusted(id, trusted);

  /// Renames a device locally.
  ///
  /// Not permanent: the next announce overwrites it with the name the device
  /// gives itself. That is intended — this renames *the row in this list*, and a
  /// device that renames itself is the better authority on its own name.
  Future<void> rename(String id, String name) => _peers.rename(id, name);

  /// Removes a device from the list, keeping its conversation and history.
  Future<int> forget(String id) => _peers.forget(id);

  Future<int> count() => _peers.count();
}

Peer _toPeer(PeerRow row) {
  return Peer(
    id: row.id,
    name: row.name,
    deviceType: DeviceType.fromWire(row.deviceType),
    // An icon the user picked is stored as one of the four known values, so an
    // unrecognised string means the row predates a change or was edited by
    // hand; falling back by device type is a better guess than a desktop icon
    // on a phone.
    icon: _iconOr(row.icon, DeviceType.fromWire(row.deviceType)),
    os: row.os,
    lastIp: row.lastIp,
    lastSeen: row.lastSeen == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(row.lastSeen!),
    isTrusted: row.isTrusted,
    // Runtime-only, and unknown from the database alone — see the class comment.
    isOnline: false,
  );
}

DeviceIcon _iconOr(String? stored, DeviceType type) {
  if (stored == null) {
    return DeviceIcon.defaultFor(type);
  }
  return DeviceIcon.values
      .where((DeviceIcon i) => i.wire == stored)
      .firstOrNull ??
      DeviceIcon.defaultFor(type);
}
