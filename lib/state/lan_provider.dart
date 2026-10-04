import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/constants.dart';
import '../core/discovery/peer_source.dart';
import '../core/models/peer.dart';
import '../core/protocol/payloads.dart';
import '../core/transport/connection_manager.dart';
import 'data_providers.dart';
import 'lan_service.dart';
import 'providers.dart';
import 'settings_provider.dart';

/// The bridge between discovery, the TCP listener and the database.
///
/// Asynchronous because everything it needs is: the device id comes from a file,
/// the listen port from the stored settings, and binding a socket can fail.
/// Consumers that only want to render something use
/// [onlinePeersProvider] instead of awaiting this.
final FutureProvider<LanService> lanServiceProvider = FutureProvider<LanService>(
  (Ref ref) async {
    // Depends on the identity *fields*, as a record — records compare by value,
    // so this rebuilds when a rename, an icon change or a new port actually
    // changes the hello, and not when the user toggles notifications or picks a
    // different auto-accept policy. Without the select, any settings change
    // would tear down the listener and drop every connection with it.
    ref.watch(
      selfDeviceProvider.select(
        (AsyncValue<Peer> self) => (
          self.valueOrNull?.id,
          self.valueOrNull?.name,
          self.valueOrNull?.deviceType,
          self.valueOrNull?.icon,
          self.valueOrNull?.os,
        ),
      ),
    );
    ref.watch(settingsProvider.select((AppSettings s) => s.listenPort));

    final Peer self = await ref.read(selfDeviceProvider.future);
    if (self.id.isEmpty) {
      throw StateError('this device has no id');
    }
    final AppSettings settings = ref.read(settingsProvider);
    // Borrowed from the device list, which owns its lifecycle.
    final PeerSource discovery = ref.watch(discoveryServiceProvider);

    final LanService service = LanService(
      manager: ConnectionManager(
        // The same port carries discovery (UDP) and control connections (TCP):
        // they are separate namespaces, and one number is one thing for a user
        // to remember and for a firewall rule to allow.
        port: settings.listenPort,
        selfHello: HelloPayload(
          role: ConnectionRole.control,
          deviceId: self.id,
          name: self.name,
          deviceType: self.deviceType,
          icon: self.icon,
          port: settings.listenPort,
          version: kProtocolVersion,
        ),
        onLog: (String message) => debugPrint('[conn] $message'),
      ),
      discovery: discovery,
      chat: ref.watch(chatRepositoryProvider),
      peers: ref.watch(peerRepositoryProvider),
      onLog: (String message) => debugPrint('[lan] $message'),
    );

    ref.onDispose(() => unawaited(service.dispose()));
    await service.start();
    return service;
  },
);

/// Peer ids with a usable control connection right now.
///
/// Empty while the service is still starting, which is also the honest answer:
/// nothing is connected yet.
final StreamProvider<Set<String>> onlinePeersProvider =
    StreamProvider<Set<String>>((Ref ref) {
      final LanService? service = ref.watch(lanServiceProvider).valueOrNull;
      if (service == null) {
        return const Stream<Set<String>>.empty();
      }
      return service.onlinePeers;
    });

/// Whether one peer is reachable right now.
///
/// Watches the set rather than asking the manager directly, so the widget
/// rebuilds when the connection comes or goes — a direct call would be read once
/// and never update.
final ProviderFamily<bool, String> peerOnlineProvider =
    Provider.family<bool, String>((Ref ref, String peerId) {
      final Set<String>? online = ref.watch(onlinePeersProvider).valueOrNull;
      return online?.contains(peerId) ?? false;
    });

/// Whether the message router is ready to send anything.
///
/// The offline banner on a conversation is the visible symptom, so the reason a
/// service failed to start is worth surfacing rather than logging alone.
final Provider<Object?> lanErrorProvider = Provider<Object?>((Ref ref) {
  return ref.watch(lanServiceProvider).error;
});
