import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/discovery/discovery_service.dart';
import '../../core/models/peer.dart';
import '../../core/models/transfer.dart';
import '../../data/repository/settings_repository.dart';
import '../../l10n/app_localizations.dart';
import '../../platform/tray_controller.dart';
import '../../platform/tray_host.dart';
import '../../state/data_providers.dart';
import '../../state/lan_provider.dart';
import '../../state/lan_service.dart';
import '../../state/providers.dart';
import '../../state/settings_provider.dart';
import '../../state/transfer_provider.dart';
import '../../state/transfer_service.dart';

/// Connects the tray to the rest of the app — design.md §7.2.
///
/// Invisible, and wraps the whole shell for the same reason
/// `DiscoveryLifecycle` does: "close means hide" is a property of the process,
/// not of whichever page happens to be on top. It is also deliberately outside
/// the navigator, so that the window can be revealed *before* a dialog is raised
/// on it rather than after.
///
/// **It has to be mounted inside a `MaterialApp`** — in `MaterialApp.builder`,
/// which is outside the navigator and inside `Localizations`. `_labels` reads
/// `AppLocalizations.of(context)`, and `MaterialApp` is what puts a
/// `Localizations` in the tree; mounted one level further out, as the outermost
/// widget of the app, that lookup returns null and the `!` in the generated
/// `of` throws on the first frame — a crash at launch, and one no host-side
/// test would catch.
///
/// All the judgement lives in [TrayController]; this is the wiring, and it is
/// kept thin enough to be read as such.
class TrayLifecycle extends ConsumerStatefulWidget {
  const TrayLifecycle({required this.child, this.host, super.key});

  final Widget child;

  /// Injectable for tests. Null means the real Windows host, which reports
  /// itself unsupported off Windows and so does nothing there.
  final TrayHost? host;

  @override
  ConsumerState<TrayLifecycle> createState() => _TrayLifecycleState();
}

class _TrayLifecycleState extends ConsumerState<TrayLifecycle> {
  TrayController? _controller;

  /// Whether this platform has a tray at all, decided once and synchronously.
  ///
  /// Synchronously matters: [build] only subscribes to the providers it needs
  /// when there is something to tell, and `build` runs before the post-frame
  /// callback that starts the controller. Deciding it asynchronously would
  /// leave the first frame unsubscribed — and, since nothing would rebuild
  /// afterwards, leave it that way.
  late final TrayHost _host;
  late final bool _enabled;

  /// The offer subscription, so a rebuilt engine is noticed — the same reason
  /// `OfferListener` follows its service rather than reading it once.
  StreamSubscription<Transfer>? _offers;
  TransferService? _watchedOffers;

  /// One rebuild of the tray menu per burst of discovery traffic.
  Timer? _menuDebounce;
  List<Peer> _pendingPeers = const <Peer>[];

  @override
  void initState() {
    super.initState();
    _host = widget.host ?? const WindowsTrayHost();
    _enabled = _host.isSupported;
    // After the first frame, because the labels come from `AppLocalizations`,
    // which is not reachable from `initState`.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _enabled) {
        unawaited(_start());
      }
    });
  }

  @override
  void dispose() {
    _menuDebounce?.cancel();
    unawaited(_offers?.cancel());
    super.dispose();
  }

  Future<void> _start() async {
    final TrayController controller = TrayController(
      host: _host,
      settings: _RefTraySettings(ref),
      labels: _labels,
      shutdown: _shutdown,
      onPeerSelected: _selectPeer,
    );
    _controller = controller;

    await controller.start();
    if (!mounted) {
      return;
    }
    // The tray menu has to be right the first time it is opened, and
    // `ref.listen` below only fires on later changes.
    await controller.setPeers(_onlineEntries(ref.read(peersProvider)));
    _followOffers(ref.read(transferServiceProvider).valueOrNull);
  }

  /// Ends the session politely on the way out.
  ///
  /// Both calls are idempotent and overlap with the providers' own teardown —
  /// which, on this path, never runs: quitting ends the process from C++, so
  /// Dart gets no further turn and no `onDispose` callback fires. That is why
  /// the goodbye is sent here, explicitly, rather than left to the disposal
  /// that the framework would normally perform. Without it every peer waits out
  /// [kPeerRemoveAfter] — a full minute of showing this device as merely away —
  /// instead of learning from the `bye` that it has gone.
  ///
  /// Deliberately not disposing the transfer service: a quit abandons transfers
  /// in flight, and tearing the engine down is the slow half of that while
  /// closing the control connections — which `LanService.dispose` already does
  /// — is the half that matters to the peer.
  Future<void> _shutdown() async {
    final DiscoveryService discovery = ref.read(discoveryServiceProvider);
    final LanService? lan = ref.read(lanServiceProvider).valueOrNull;
    await Future.wait(<Future<void>>[
      if (lan != null) lan.dispose(),
      discovery.stop(),
    ]);
  }

  void _selectPeer(String peerId) {
    final Peer? peer = ref
        .read(peersProvider)
        .where((Peer p) => p.id == peerId)
        .firstOrNull;
    if (peer != null) {
      ref.read(selectedPeerProvider.notifier).state = peer;
    }
  }

  TrayLabels _labels() {
    final AppLocalizations l10n = AppLocalizations.of(context);
    return TrayLabels(
      menuOpen: l10n.trayMenuOpen,
      menuStatus: l10n.trayMenuStatus,
      menuQuit: l10n.trayMenuQuit,
      hintTitle: l10n.trayHintTitle,
      hintBody: l10n.trayHintBody,
      deviceCount: l10n.trayStatusOnline,
    );
  }

  static List<TrayPeerEntry> _onlineEntries(List<Peer> peers) => <TrayPeerEntry>[
    for (final Peer peer in peers.where((Peer p) => p.isOnline))
      TrayPeerEntry(id: peer.id, label: peer.name),
  ];

  /// Rebuilds the tray menu once the device list stops moving.
  ///
  /// Debounced because a peer arriving produces a burst of table changes, and
  /// because an announce every five seconds rewrites the list whether or not
  /// anything about it changed — a channel write per heartbeat for a menu
  /// nobody has open is pure noise. The native side keeps the last snapshot and
  /// rebuilds the menu from it at pop-up time, so the debounce delays a stale
  /// menu by a quarter of a second at most, and only while it is already open.
  void _scheduleMenu(List<Peer> peers) {
    _pendingPeers = peers;
    _menuDebounce?.cancel();
    _menuDebounce = Timer(const Duration(milliseconds: 250), () {
      unawaited(_controller?.setPeers(_onlineEntries(_pendingPeers)));
    });
  }

  /// Follows the transfer engine, resubscribing when it is replaced.
  void _followOffers(TransferService? service) {
    if (identical(service, _watchedOffers)) {
      return;
    }
    _watchedOffers = service;
    unawaited(_offers?.cancel());
    // The offer itself is not needed: what matters is that one arrived and is
    // waiting, not which one. `confirmBeforeReceiving` is read inside.
    _offers = service?.offers.listen((Transfer _) {
      unawaited(_revealFor());
    });
  }

  /// Brings the window back for an offer that needs an answer on screen.
  ///
  /// Only when `confirmBeforeReceiving` is on, because that is the only case
  /// where something is waiting on the user: with it off the offer is accepted
  /// the moment it arrives, and popping the window up over whatever they were
  /// doing would be more intrusive than the chime and the unread badge that
  /// already announce it.
  ///
  /// The setting is read when the offer arrives rather than watched, matching
  /// `OfferListener`: the switch governs the next offer, not one already here.
  Future<void> _revealFor() async {
    if (!mounted || !ref.read(settingsProvider).confirmBeforeReceiving) {
      return;
    }
    await _controller?.revealForAttention();
  }

  @override
  Widget build(BuildContext context) {
    if (_enabled) {
      ref.listen<List<Peer>>(peersProvider, (
        List<Peer>? _,
        List<Peer> next,
      ) {
        _scheduleMenu(next);
      });
      ref.listen<bool>(
        settingsProvider.select((AppSettings s) => s.minimizeToTray),
        (bool? previous, bool next) {
          unawaited(_controller?.syncVisibility());
        },
      );
      ref.listen<AsyncValue<TransferService>>(transferServiceProvider, (
        AsyncValue<TransferService>? _,
        AsyncValue<TransferService> next,
      ) {
        _followOffers(next.valueOrNull);
      });
    }
    return widget.child;
  }
}

/// [TraySettings] over the live providers.
class _RefTraySettings implements TraySettings {
  const _RefTraySettings(this._ref);

  final WidgetRef _ref;

  @override
  bool get minimizeToTray => _ref.read(settingsProvider).minimizeToTray;

  @override
  Future<bool> claimHint() async {
    final SettingsRepository store = _ref.read(settingsRepositoryProvider);
    // Absent means never shown, which is the same as the row reading `false` —
    // `getBool` returns null for a missing key and for anything it cannot parse,
    // and a value from a future build is not worth repeating the hint over.
    if (await store.getBool(SettingKeys.trayHintShown) ?? false) {
      return false;
    }
    await store.putBool(SettingKeys.trayHintShown, true);
    return true;
  }
}
