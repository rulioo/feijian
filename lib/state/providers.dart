import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/discovery/discovery_service.dart';
import '../core/discovery/network_interfaces.dart';
import '../core/models/peer.dart';
import '../platform/device_identity.dart';
import '../platform/download_path.dart';
import 'settings_provider.dart';

/// This device, as shown on the card at the top of the device list.
///
/// Resolves the LAN address by enumerating interfaces rather than asking the
/// OS for "the" address — see [NetworkInterfaceHelper] for why that matters.
final FutureProvider<Peer> selfDeviceProvider = FutureProvider<Peer>((
  Ref ref,
) async {
  final AppSettings settings = ref.watch(settingsProvider);
  final DeviceType type = DeviceType.current;

  // Both are IO, and both are independent of each other.
  final (String? ip, String id) = await (
    NetworkInterfaceHelper.primaryIpv4(),
    DeviceIdentity.load(),
  ).wait;

  return Peer(
    id: id,
    name: settings.displayName ?? _hostname(),
    deviceType: type,
    icon: settings.deviceIcon ?? DeviceIcon.defaultFor(type),
    os: _osLabel(),
    lastIp: ip,
    // Announced to peers so they know where to open the control connection.
    // The TCP listener binds this same number (design.md §4.2): UDP discovery
    // and TCP control are separate namespaces, so one port is one thing for a
    // user to remember and one rule for a firewall.
    lastPort: settings.listenPort,
    isOnline: true,
  );
});

/// The LAN discovery service.
///
/// Constructed here; started by [discoveredPeersProvider] once this device's
/// identity resolves. Widget tests override this with a service that is never
/// started, so the UI can be exercised without binding real UDP sockets.
///
/// Only the endpoint is watched, via `select`: every other setting (the display
/// name above all) must not tear down and rebind the sockets while the user is
/// typing.
final Provider<DiscoveryService> discoveryServiceProvider =
    Provider<DiscoveryService>((Ref ref) {
      final (int, String) endpoint = ref.watch(
        settingsProvider.select(
          (AppSettings s) => (s.listenPort, s.multicastAddress),
        ),
      );
      return DiscoveryService(
        discoveryPort: endpoint.$1,
        multicastGroup: endpoint.$2,
        onLog: (String message) => debugPrint('[discovery] $message'),
      );
    });

/// Peers currently visible on the LAN, pushed as discovery learns about them.
///
/// A stream rather than a watch on the service's table, so that a peer going
/// offline on its own schedule updates the list without the UI polling.
final StreamProvider<List<Peer>> discoveredPeersProvider =
    StreamProvider<List<Peer>>((Ref ref) {
      final DiscoveryService service = ref.watch(discoveryServiceProvider);
      final StreamController<List<Peer>> out = StreamController<List<Peer>>();

      final StreamSubscription<void> changes = service.changes.listen((_) {
        if (!out.isClosed) {
          out.add(service.table.peers);
        }
      });

      // Renames and icon changes reach peers as soon as the user makes them.
      ref.listen<AsyncValue<Peer>>(selfDeviceProvider, (
        AsyncValue<Peer>? _,
        AsyncValue<Peer> next,
      ) {
        final Peer? self = next.valueOrNull;
        if (self != null) {
          service.updateSelf(self);
        }
      });

      unawaited(() async {
        try {
          service.updateSelf(await ref.read(selfDeviceProvider.future));
          await service.start();
          if (!out.isClosed) {
            out.add(service.table.peers);
          }
        } on Object catch (error, stack) {
          // Losing the discovery port (already in use, no permission, blocked
          // by policy) must not take the device list down with it. The empty
          // state that follows is already the right thing to show, and it
          // names the firewall as a cause.
          debugPrint('[discovery] start failed: $error\n$stack');
          if (!out.isClosed) {
            out.addError(error, stack);
          }
        }
      }());

      ref.onDispose(() {
        unawaited(changes.cancel());
        unawaited(service.dispose());
        unawaited(out.close());
      });

      return out.stream;
    });

/// The discovered peers, or an empty list while discovery is still starting.
final Provider<List<Peer>> peersProvider = Provider<List<Peer>>((Ref ref) {
  return ref.watch(discoveredPeersProvider).valueOrNull ?? const <Peer>[];
});

/// Count of reachable peers, for the list section header.
final Provider<int> onlinePeerCountProvider = Provider<int>((Ref ref) {
  return ref.watch(peersProvider).where((Peer p) => p.isOnline).length;
});

/// Peer ids the user entered by hand, and which no announce has confirmed since.
///
/// These are the ones the ageing rules cannot remove, so they are also the ones
/// that need a "Remove device" action — without it there would be no way to get
/// rid of a mistyped address except restarting the app.
///
/// The peer list is watched first so this recomputes when one is added or
/// forgotten. Reading the table alone would never trigger a rebuild: the table
/// is mutable state behind a getter, not a value the provider can compare.
final Provider<Set<String>> manualPeerIdsProvider = Provider<Set<String>>((
  Ref ref,
) {
  ref.watch(discoveredPeersProvider);
  return ref.watch(discoveryServiceProvider).table.manualIds;
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
