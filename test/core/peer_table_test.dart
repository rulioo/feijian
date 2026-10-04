import 'package:feijian/core/constants.dart';
import 'package:feijian/core/discovery/announce.dart';
import 'package:feijian/core/discovery/peer_table.dart';
import 'package:feijian/core/models/peer.dart';
import 'package:flutter_test/flutter_test.dart';

final DateTime _t0 = DateTime.utc(2026, 10, 4, 12);

AnnouncePacket _announce({
  String id = 'peer-1',
  String name = 'Bob-PC',
  DeviceType deviceType = DeviceType.windows,
  DeviceIcon icon = DeviceIcon.desktop,
  String? os = 'Windows 11',
  int port = 24250,
  DateTime? ts,
}) {
  return AnnouncePacket(
    type: AnnounceType.announce,
    id: id,
    ts: ts ?? _t0,
    name: name,
    deviceType: deviceType,
    icon: icon,
    os: os,
    port: port,
  );
}

/// Records an announce arriving from [ip] at [now].
bool _touch(PeerTable table, AnnouncePacket packet, {String ip = '192.168.1.101', DateTime? now}) {
  return table.touch(packet: packet, fromIp: ip, now: now ?? _t0);
}

void main() {
  group('touch', () {
    test('adds a new peer as online', () {
      final PeerTable table = PeerTable();

      expect(_touch(table, _announce()), isTrue);
      expect(table.length, 1);

      final Peer peer = table['peer-1']!;
      expect(peer.name, 'Bob-PC');
      expect(peer.lastIp, '192.168.1.101');
      expect(peer.lastPort, 24250);
      expect(peer.isOnline, isTrue);
      expect(peer.lastSeen, _t0);
    });

    test('reports no change for a repeat announce but still ages the clock', () {
      final PeerTable table = PeerTable();
      _touch(table, _announce());

      final DateTime later = _t0.add(kAnnounceInterval);
      expect(_touch(table, _announce(), now: later), isFalse);
      // The clock must advance regardless, or the peer would be declared
      // offline while it is announcing perfectly well.
      expect(table['peer-1']!.lastSeen, later);
    });

    test('reports a change when the peer renames itself', () {
      final PeerTable table = PeerTable();
      _touch(table, _announce());

      expect(
        _touch(table, _announce(name: 'Bob-Desktop'), now: _t0.add(const Duration(seconds: 5))),
        isTrue,
      );
      expect(table['peer-1']!.name, 'Bob-Desktop');
    });

    test('reports a change when the peer moves to a new address', () {
      final PeerTable table = PeerTable();
      _touch(table, _announce());

      expect(
        _touch(table, _announce(), ip: '192.168.1.120', now: _t0.add(const Duration(seconds: 5))),
        isTrue,
      );
      expect(table['peer-1']!.lastIp, '192.168.1.120');
    });

    test('preserves a locally granted trust flag across announces', () {
      final PeerTable table = PeerTable();
      _touch(table, _announce());
      expect(table.setTrusted('peer-1', true), isTrue);

      // Trust is granted on this device, so every later announce must carry it
      // across. Losing it here would silently switch auto-accept back off.
      _touch(table, _announce(name: 'Bob-Desktop'), now: _t0.add(kAnnounceInterval));
      expect(table['peer-1']!.isTrusted, isTrue);

      // A peer going offline and returning keeps it too. It was last heard
      // from one interval ago, so age it from there.
      final DateTime offline = _t0.add(
        kAnnounceInterval + kPeerOfflineAfter + const Duration(seconds: 2),
      );
      table.applyTimeouts(offline);
      expect(table['peer-1']!.isOnline, isFalse);

      _touch(table, _announce(), now: _t0.add(const Duration(minutes: 1)));
      expect(table['peer-1']!.isOnline, isTrue);
      expect(table['peer-1']!.isTrusted, isTrue);
    });

    test('setTrusted reports no change when nothing moves', () {
      final PeerTable table = PeerTable();
      _touch(table, _announce());

      expect(table.setTrusted('peer-1', false), isFalse, reason: 'already false');
      expect(table.setTrusted('nobody', true), isFalse, reason: 'unknown peer');

      table.setTrusted('peer-1', true);
      expect(table.setTrusted('peer-1', true), isFalse, reason: 'already true');
    });

    test('ignores this device announcing itself back', () {
      final PeerTable table = PeerTable(selfId: 'self-id');

      expect(_touch(table, _announce(id: 'self-id')), isFalse);
      expect(table.isEmpty, isTrue);
    });
  });

  group('applyTimeouts', () {
    test('keeps a peer online inside the offline window', () {
      final PeerTable table = PeerTable();
      _touch(table, _announce());

      expect(
        table.applyTimeouts(_t0.add(kPeerOfflineAfter)),
        isFalse,
        reason: 'the threshold is exclusive',
      );
      expect(table['peer-1']!.isOnline, isTrue);
    });

    test('greys a peer out past the offline window, keeping it listed', () {
      final PeerTable table = PeerTable();
      _touch(table, _announce());

      expect(
        table.applyTimeouts(_t0.add(kPeerOfflineAfter + const Duration(seconds: 1))),
        isTrue,
      );
      expect(table['peer-1']!.isOnline, isFalse);
      expect(table.length, 1);
    });

    test('removes a peer past the removal window', () {
      final PeerTable table = PeerTable();
      _touch(table, _announce());

      expect(
        table.applyTimeouts(_t0.add(kPeerRemoveAfter + const Duration(seconds: 1))),
        isTrue,
      );
      expect(table.isEmpty, isTrue);
    });

    test('is quiet once nothing is left to age', () {
      final PeerTable table = PeerTable();
      _touch(table, _announce());
      final DateTime late = _t0.add(kPeerRemoveAfter + const Duration(seconds: 1));
      table.applyTimeouts(late);

      expect(table.applyTimeouts(late.add(const Duration(seconds: 1))), isFalse);
    });

    test('brings a greyed-out peer back when it announces again', () {
      final PeerTable table = PeerTable();
      _touch(table, _announce());
      table.applyTimeouts(_t0.add(kPeerOfflineAfter + const Duration(seconds: 1)));
      expect(table['peer-1']!.isOnline, isFalse);

      final DateTime later = _t0.add(kPeerOfflineAfter + const Duration(seconds: 6));
      expect(_touch(table, _announce(), now: later), isTrue);
      expect(table['peer-1']!.isOnline, isTrue);
    });
  });

  group('peers', () {
    test('orders by name', () {
      final PeerTable table = PeerTable();
      _touch(table, _announce(id: 'c', name: 'carol'));
      _touch(table, _announce(id: 'a', name: 'alice'));
      _touch(table, _announce(id: 'b', name: 'bob'));

      expect(
        table.peers.map((Peer p) => p.name),
        <String>['alice', 'bob', 'carol'],
      );
    });

    test('sorts an offline peer below every online one, name notwithstanding',
        () {
      final PeerTable table = PeerTable();
      // aaron is heard once and then goes quiet; zoe keeps announcing.
      _touch(table, _announce(id: 'a', name: 'aaron'));
      _touch(
        table,
        _announce(id: 'z', name: 'zoe'),
        now: _t0.add(kPeerOfflineAfter + const Duration(seconds: 1)),
      );
      table.applyTimeouts(_t0.add(kPeerOfflineAfter + const Duration(seconds: 1)));

      expect(table['a']!.isOnline, isFalse);
      expect(table['z']!.isOnline, isTrue);
      // Alphabetically aaron wins; the online-first rule must override that.
      expect(table.peers.map((Peer p) => p.name), <String>['zoe', 'aaron']);
    });

    test('orders equal names by id, so the list never reshuffles', () {
      final PeerTable table = PeerTable();
      _touch(table, _announce(id: 'bbb', name: 'same'));
      _touch(table, _announce(id: 'aaa', name: 'same'));

      expect(table.peers.map((Peer p) => p.id), <String>['aaa', 'bbb']);
    });

    test('counts only peers that are online', () {
      final PeerTable table = PeerTable();
      _touch(table, _announce(id: 'a', name: 'alice'));
      _touch(table, _announce(id: 'b', name: 'bob'));

      expect(table.onlineCount, 2);

      table.applyTimeouts(_t0.add(kPeerOfflineAfter + const Duration(seconds: 1)));
      expect(table.onlineCount, 0);
      expect(table.length, 2);
    });
  });

  group('remove', () {
    test('drops a known peer and reports it', () {
      final PeerTable table = PeerTable();
      _touch(table, _announce());

      expect(table.remove('peer-1'), isTrue);
      expect(table.isEmpty, isTrue);
    });

    test('reports nothing for an unknown peer', () {
      expect(PeerTable().remove('nobody'), isFalse);
    });
  });

  test('lastSeenOf mirrors the stored record', () {
    final PeerTable table = PeerTable();
    expect(table.lastSeenOf('peer-1'), isNull);

    _touch(table, _announce());
    expect(table.lastSeenOf('peer-1'), _t0);
  });
}
