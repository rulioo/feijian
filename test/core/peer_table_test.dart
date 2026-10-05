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

/// A peer built the way Add-by-IP builds one: from a `hello`, with no
/// `lastSeen` — there is no announce to take one from, and inventing one would
/// put the entry back under the ageing rules that manual mode exists to escape.
Peer _manual({
  String id = 'manual-1',
  String name = 'Study-PC',
  String ip = '192.168.1.150',
  int port = 24250,
  bool online = false,
}) {
  return Peer(
    id: id,
    name: name,
    deviceType: DeviceType.windows,
    icon: DeviceIcon.desktop,
    lastIp: ip,
    lastPort: port,
    isOnline: online,
  );
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

  group('manual peers (Add by IP)', () {
    test('adds a peer that no announce will confirm', () {
      final PeerTable table = PeerTable();

      expect(table.addManual(_manual()), isTrue);
      expect(table['manual-1']!.name, 'Study-PC');
      expect(table['manual-1']!.lastIp, '192.168.1.150');
      expect(table.isManual('manual-1'), isTrue);
      expect(table.manualIds, <String>{'manual-1'});
      expect(table.length, 1);
    });

    test('reports no change when the same entry is added again', () {
      final PeerTable table = PeerTable();
      table.addManual(_manual());

      expect(table.addManual(_manual()), isFalse);
      expect(table.length, 1);
    });

    test('refuses this device\'s own id', () {
      final PeerTable table = PeerTable(selfId: 'manual-1');

      expect(table.addManual(_manual()), isFalse);
      expect(table.isEmpty, isTrue);
    });

    test('leaves a peer that announces for real alone', () {
      final PeerTable table = PeerTable();
      _touch(table, _announce(id: 'manual-1'));

      // A name and an icon off the network beat anything typed into a box, and
      // the device is reachable the ordinary way already — there is nothing for
      // manual mode to add, so the address is not even recorded.
      expect(table.addManual(_manual(name: 'Typed-In')), isFalse);
      expect(table['manual-1']!.name, 'Bob-PC');
      expect(table.isManual('manual-1'), isFalse);
    });

    test('survives the ageing that removes an announced peer', () {
      final PeerTable table = PeerTable();
      table.addManual(_manual(online: true));

      // The whole reason manual mode exists: behind AP isolation no announce
      // ever arrives, so there is no `lastSeen` to measure and the ordinary
      // rules would delete the user's entry a minute after they made it.
      final DateTime muchLater =
          _t0.add(kPeerRemoveAfter + const Duration(hours: 1));
      expect(table.applyTimeouts(muchLater), isFalse);
      expect(table.length, 1);
      expect(table['manual-1']!.isOnline, isTrue);
    });

    test('takes its online state from the connection, not from a clock', () {
      final PeerTable table = PeerTable();
      table.addManual(_manual());

      expect(table['manual-1']!.isOnline, isFalse, reason: 'as entered');
      expect(table.setOnline('manual-1', isOnline: true), isTrue);
      expect(table['manual-1']!.isOnline, isTrue);
      expect(table.setOnline('manual-1', isOnline: true), isFalse);
      expect(table.setOnline('manual-1', isOnline: false), isTrue);
      expect(table['manual-1']!.isOnline, isFalse);
    });

    test('setOnline is inert for an announced peer', () {
      final PeerTable table = PeerTable();
      _touch(table, _announce());

      // The network decides for those, and a second authority would flip the
      // entry back and forth every time an announce landed mid-reconnect.
      expect(table.setOnline('peer-1', isOnline: false), isFalse);
      expect(table['peer-1']!.isOnline, isTrue);
      expect(table.setOnline('nobody', isOnline: true), isFalse);
    });

    test('is not removed by a bye', () {
      final PeerTable table = PeerTable();
      table.addManual(_manual());

      // `bye` arrives over a control connection. A device reached by typing its
      // address is exactly the one whose connection drops while the device is
      // still wanted, so the goodbye must not take the entry with it.
      expect(table.remove('manual-1'), isFalse);
      expect(table.isManual('manual-1'), isTrue);
      expect(table.length, 1);
    });

    test('stops being manual once it announces', () {
      final PeerTable table = PeerTable();
      table.addManual(_manual());

      expect(
        _touch(table, _announce(id: 'manual-1', name: 'Study-PC')),
        isTrue,
        reason: 'the announce brings an address the entry did not have',
      );
      expect(table.isManual('manual-1'), isFalse);

      // And from here the ordinary rules apply again — the exit from manual
      // mode that needs no UI.
      table.applyTimeouts(_t0.add(kPeerRemoveAfter + const Duration(seconds: 1)));
      expect(table.isEmpty, isTrue);
    });

    test('forget removes a manual peer, and an announced one too', () {
      final PeerTable table = PeerTable();
      table.addManual(_manual(id: 'typed'));
      _touch(table, _announce(id: 'heard'));

      // The user-facing "Remove device" acts on either: the ageing rules will
      // not take a manual peer away, and a user who wants a device gone should
      // not have to wait out a minute of silence for an announced one.
      expect(table.forget('typed'), isTrue);
      expect(table.forget('heard'), isTrue);
      expect(table.forget('nobody'), isFalse);
      expect(table.isEmpty, isTrue);
      expect(table.manualIds, isEmpty);
    });

    test('manualIds is a snapshot, and cannot be used to mutate the table', () {
      final PeerTable table = PeerTable();
      table.addManual(_manual());
      final Set<String> ids = table.manualIds;

      // Unmodifiable rather than merely copied, so reaching for the obvious
      // thing — clearing it to un-manual everything — fails loudly instead of
      // quietly doing nothing to the table the caller was trying to change.
      expect(() => ids.clear(), throwsUnsupportedError);

      table.addManual(_manual(id: 'typed-2'));
      expect(ids, <String>{'manual-1'}, reason: 'a snapshot, not a live view');
      expect(table.manualIds, <String>{'manual-1', 'typed-2'});
    });

    test('clear drops the manual entries with the rest', () {
      final PeerTable table = PeerTable();
      table.addManual(_manual());
      table.clear();

      expect(table.isEmpty, isTrue);
      expect(table.manualIds, isEmpty);
      expect(table.applyTimeouts(_t0), isFalse);
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
