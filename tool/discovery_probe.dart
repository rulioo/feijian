// Diagnostic harness for M1. Not part of the app; run it by hand:
//
//   dart run tool/discovery_probe.dart
//
// It answers the questions that cannot be answered from unit tests, because
// they depend on the machine's real adapters:
//
//   1. Which interfaces does the filter keep, and which does it drop?
//   2. Does a second peer implementation actually show up in the peer table
//      over multicast on a real NIC?
//   3. Is a peer's announce answered with a unicast reply?
//
// It deliberately does NOT prove cross-device discovery. That needs two
// machines on one Wi-Fi network, and no amount of same-host trickery
// substitutes: the second listener below shares this host's network stack,
// queues and routing table, which is exactly the part that real deployments
// get wrong.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:feijian/core/constants.dart';
import 'package:feijian/core/discovery/announce.dart';
import 'package:feijian/core/discovery/discovery_service.dart';
import 'package:feijian/core/discovery/network_interfaces.dart';
import 'package:feijian/core/models/peer.dart';

const Peer _self = Peer(
  id: 'probe-self',
  name: 'Probe-Self',
  deviceType: DeviceType.windows,
  icon: DeviceIcon.desktop,
  os: 'diagnostic',
  lastPort: kDiscoveryPort,
);

Future<void> main() async {
  stdout.writeln('--- interfaces ---');
  final Map<NetworkInterface, List<String>> kept =
      await NetworkInterfaceHelper.usableInterfaces();
  for (final MapEntry<NetworkInterface, List<String>> entry in kept.entries) {
    stdout.writeln('  keep ${entry.key.name}: ${entry.value.join(', ')}');
  }
  final List<NetworkInterface> all = await NetworkInterface.list(
    type: InternetAddressType.IPv4,
    includeLoopback: true,
  );
  // Compared by name, not by identity: NetworkInterface has no value equality,
  // so a second list() call returns objects that never match the first.
  final Set<String> keptNames =
      kept.keys.map((NetworkInterface ni) => ni.name).toSet();
  for (final NetworkInterface ni in all) {
    if (keptNames.contains(ni.name)) {
      continue;
    }
    stdout.writeln(
      '  drop ${ni.name}: '
      '${ni.addresses.map((InternetAddress a) => a.address).join(', ')}',
    );
  }
  stdout.writeln('  primary: ${await NetworkInterfaceHelper.primaryIpv4()}');

  stdout.writeln('\n--- service ---');
  final DiscoveryService service = DiscoveryService(
    onLog: (String message) => stdout.writeln('  log: $message'),
  );
  service.updateSelf(_self);
  service.changes.listen((_) {
    for (final Peer peer in service.table.peers) {
      stdout.writeln(
        '  peer: ${peer.name} @ ${peer.lastIp}:${peer.lastPort} '
        'online=${peer.isOnline}',
      );
    }
  });

  await service.start();
  stdout.writeln('  running: ${service.isRunning}');

  // --- Stand in for a second device ----------------------------------------
  // A raw socket that joins the same group on the real interface and speaks
  // the same protocol, with loopback left ON so this host can hear it. That
  // isolates the receive path: if this peer is not discovered, the fault is in
  // receiving, not in the absence of a neighbour.
  stdout.writeln('\n--- simulated peer ---');
  final RawDatagramSocket listener = await RawDatagramSocket.bind(
    InternetAddress.anyIPv4,
    kDiscoveryPort,
    reuseAddress: true,
  );
  listener.broadcastEnabled = true;
  listener.multicastLoopback = true;

  final NetworkInterface? nic =
      kept.keys.isEmpty ? null : kept.keys.first;
  if (nic != null) {
    try {
      listener.joinMulticast(InternetAddress(kMulticastGroup), nic);
      stdout.writeln('  joined $kMulticastGroup on ${nic.name}');
    } on SocketException catch (error) {
      stdout.writeln('  join failed: ${error.message}');
    }
  }

  final List<Datagram> heard = <Datagram>[];
  listener.listen((RawSocketEvent event) {
    if (event != RawSocketEvent.read) {
      return;
    }
    Datagram? datagram;
    while ((datagram = listener.receive()) != null) {
      heard.add(datagram!);
    }
  });

  final Uint8List fake = AnnouncePacket(
    type: AnnounceType.announce,
    id: 'probe-peer',
    ts: DateTime.now().toUtc(),
    name: 'Simulated-Peer',
    deviceType: DeviceType.android,
    icon: DeviceIcon.phone,
    os: 'diagnostic',
    port: kDiscoveryPort,
  ).encode();

  // Sent every second: the peer table greys a peer out after 15s, and this
  // also lets a lost datagram be retried rather than ending the probe.
  final Timer beat = Timer.periodic(const Duration(seconds: 1), (_) {
    listener.send(fake, InternetAddress(kMulticastGroup), kDiscoveryPort);
  });
  listener.send(fake, InternetAddress(kMulticastGroup), kDiscoveryPort);

  await Future<void>.delayed(const Duration(seconds: 6));
  beat.cancel();

  stdout.writeln('\n--- result ---');
  stdout.writeln('  discovered: ${service.table.length}');
  stdout.writeln('  datagrams this host received on the group: ${heard.length}');
  final int fromService = heard.where((Datagram d) {
    final AnnounceDecode decoded =
        AnnouncePacket.decode(d.data, now: DateTime.now().toUtc());
    return decoded.packet?.id == 'probe-self';
  }).length;
  // Which channel delivered these is not distinguished here, and on Windows
  // the broadcast half can reach a wildcard-bound local socket even though the
  // senders disable multicast loopback. Either way it is why the service filters
  // its own id out of the peer table rather than assuming it never sees it.
  stdout.writeln('  datagrams from the service seen locally: $fromService');

  await service.dispose();
  listener.close();
  exit(0);
}
