import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/debug_flags.dart';
import '../core/discovery/network_interfaces.dart';
import '../core/models/peer.dart';
import '../platform/download_path.dart';
import 'settings_provider.dart';

/// This device, as shown on the card at the top of the device list.
///
/// Resolves the LAN address by enumerating interfaces rather than asking the
/// OS for "the" address — see [NetworkInterfaceHelper] for why that matters.
///
/// TODO(M1): replace the placeholder `id` with the UUID persisted on first
/// launch. Every connection and dedupe decision keys off it, so it must be
/// stable across restarts.
final FutureProvider<Peer> selfDeviceProvider = FutureProvider<Peer>((
  Ref ref,
) async {
  final AppSettings settings = ref.watch(settingsProvider);
  final DeviceType type = DeviceType.current;
  final String? ip = await NetworkInterfaceHelper.primaryIpv4();

  return Peer(
    id: 'self',
    name: settings.displayName ?? _hostname(),
    deviceType: type,
    icon: settings.deviceIcon ?? DeviceIcon.defaultFor(type),
    os: _osLabel(),
    lastIp: ip,
    isOnline: true,
  );
});

/// Peers currently visible on the LAN.
///
/// TODO(M1): driven by [DiscoveryService] announce traffic. Until then this is
/// either empty or the review-only sample set, per [kShowSamplePeers].
final Provider<List<Peer>> peersProvider = Provider<List<Peer>>((Ref ref) {
  if (kShowSamplePeers) {
    return _samplePeers;
  }
  return const <Peer>[];
});

/// Count of reachable peers, for the list section header.
final Provider<int> onlinePeerCountProvider = Provider<int>((Ref ref) {
  return ref
      .watch(peersProvider)
      .where((Peer p) => p.isOnline)
      .length;
});

/// The conversation currently open. Null on a phone until a device is tapped,
/// and null on desktop until the user picks one from the left pane.
final StateProvider<Peer?> selectedPeerProvider = StateProvider<Peer?>(
  (Ref ref) => null,
);

/// Where received files are saved, resolved once per app run.
final FutureProvider<String> downloadPathProvider = FutureProvider<String>((
  Ref ref,
) {
  return DownloadPath.displayPath();
});

String _hostname() {
  try {
    return Platform.localHostname;
  } on Exception {
    // Throws on some sandboxed/hardened configurations.
    return 'My Device';
  }
}

/// "Windows 11 (build 26100), locale zh-CN" -> "Windows 11"
String _osLabel() {
  final String raw = Platform.operatingSystemVersion;
  final int cut = raw.indexOf(RegExp(r'[(,]'));
  if (cut > 0) {
    return raw.substring(0, cut).trim();
  }
  return raw;
}

/// Review-only placeholder data. **Deleted in M1** — see [kShowSamplePeers].
final List<Peer> _samplePeers = <Peer>[
  Peer(
    id: 'sample-1',
    name: 'Bob-PC',
    deviceType: DeviceType.windows,
    icon: DeviceIcon.desktop,
    os: 'Windows 11',
    lastIp: '192.168.1.101',
    lastSeen: DateTime.now(),
    isOnline: true,
  ),
  Peer(
    id: 'sample-2',
    name: 'Alice-Phone',
    deviceType: DeviceType.android,
    icon: DeviceIcon.phone,
    os: 'Android 14',
    lastIp: '192.168.1.105',
    lastSeen: DateTime.now(),
    isOnline: true,
  ),
  Peer(
    id: 'sample-3',
    name: 'Meeting-Room-PC',
    deviceType: DeviceType.windows,
    icon: DeviceIcon.desktop,
    os: 'Windows 10',
    lastIp: '192.168.1.110',
    lastSeen: DateTime.now().subtract(const Duration(minutes: 3)),
    isOnline: false,
  ),
];
