import 'dart:async';
import 'dart:io';

import 'package:feijian/core/discovery/discovery_service.dart';
import 'package:feijian/core/models/peer.dart';
import 'package:feijian/core/models/transfer.dart';
import 'package:feijian/core/protocol/payloads.dart';
import 'package:feijian/core/transport/connection_manager.dart';
import 'package:feijian/data/database.dart';
import 'package:feijian/data/repository/settings_repository.dart';
import 'package:feijian/data/repository/transfer_repository.dart';
import 'package:feijian/l10n/app_localizations.dart';
import 'package:feijian/state/data_providers.dart';
import 'package:feijian/state/lan_provider.dart';
import 'package:feijian/state/lan_service.dart';
import 'package:feijian/state/providers.dart';
import 'package:feijian/state/settings_provider.dart';
import 'package:feijian/state/transfer_provider.dart';
import 'package:feijian/state/transfer_service.dart';
import 'package:feijian/ui/widgets/tray_lifecycle.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

// The tray's wiring to the app — design.md §7.2.
//
// `tray_controller_test.dart` covers what the tray decides; this covers that the
// decisions are reached at all, over the real `com.feijian.lan/tray` channel and
// with the app's own providers behind them. `TrayLifecycle` is mounted through
// `MaterialApp.builder`, exactly as `lib/app.dart` mounts it — which is not
// incidental: its menu captions come from `AppLocalizations.of`, and one level
// further out, above the `MaterialApp` that provides `Localizations`, that
// lookup throws on the first frame. The first test below is what fails if
// anyone moves it back out.
//
// **What this cannot cover, and does not pretend to**: everything on the far
// side of the channel. `windows/runner/flutter_window.cpp` turns `WM_CLOSE` into
// the `closeRequested` these tests fabricate, `tray_window.cpp` owns the icon,
// the menu and the balloon, and neither has ever run under a test — a Win32
// shell is not something a widget test has. Those are verified by hand on a
// machine with a desktop session, and the same is true of whether Windows
// delivers the balloon at all. A green run here says the Dart half is wired
// correctly, not that the tray works.

/// The channel `WindowsTrayHost` talks on, at file scope so the harness below
/// can reach it.
const MethodChannel _channel = MethodChannel('com.feijian.lan/tray');
const StandardMethodCodec _codec = StandardMethodCodec();

void main() {
  const Peer bob = Peer(
    id: 'peer-bob',
    name: 'Bob-PC',
    deviceType: DeviceType.android,
    icon: DeviceIcon.phone,
    os: 'Android 14',
    lastIp: '127.0.0.1',
    isOnline: true,
  );

  testWidgets('the menu reaches the native side in the app\'s own words', (
    WidgetTester tester,
  ) async {
    final _Harness harness = await _Harness.pump(tester);

    // The captions are read from `AppLocalizations`, so their arriving intact
    // is the check that the widget is mounted where its localizations are —
    // see the file header.
    final Map<Object?, Object?> menu = harness.argumentsOf('setMenu');
    expect(menu['open'], 'Open');
    expect(menu['status'], 'Status');
    expect(menu['quit'], 'Quit');
    expect(menu['summary'], 'No devices online');

    // The icon's visibility follows the setting, and is pushed at startup —
    // there is no later event that would fix a tray icon missing at launch.
    expect(harness.argumentsOf('setTrayVisible')['visible'], isTrue);
  });

  testWidgets('a close from the window hides it and never ends the process', (
    WidgetTester tester,
  ) async {
    final _Harness harness = await _Harness.pump(tester);

    await harness.deliver('closeRequested');

    expect(harness.methods, contains('hide'));
    expect(harness.methods, isNot(contains('quit')),
        reason: 'close-to-tray is on, and this is the branch that must not be '
            'wrong: a close that quit would be the feature not working');
  });

  testWidgets('Open brings a hidden window back', (WidgetTester tester) async {
    final _Harness harness = await _Harness.pump(tester);
    await harness.deliver('closeRequested');
    final int afterHide = harness.outbound.length;

    await harness.deliver('open');

    expect(
      harness.methods.sublist(afterHide),
      <String>['show'],
      reason: 'nothing else belongs on a reveal',
    );
  });

  testWidgets('Quit ends the process, and says goodbye on the way out', (
    WidgetTester tester,
  ) async {
    final _Harness harness = await _Harness.pump(tester);

    await harness.deliver('quit');

    expect(harness.methods.last, 'quit');
    // The peers are told before the process stops getting turns: `PostQuitMessage`
    // ends the message loop from C++, and no Riverpod `onDispose` runs after it.
    expect(harness.discovery.stopped, isTrue);
  });

  testWidgets('a device picked from the tray menu opens that conversation', (
    WidgetTester tester,
  ) async {
    final _Harness harness = await _Harness.pump(tester, peers: const <Peer>[bob]);
    await harness.deliver('closeRequested');
    final int afterHide = harness.outbound.length;

    await harness.deliver('peerSelected', <String, Object?>{'peerId': bob.id});

    // The window first, so the conversation being opened can be seen on it.
    expect(harness.methods.sublist(afterHide), <String>['show']);
    expect(harness.container.read(selectedPeerProvider)?.id, bob.id);
  });

  testWidgets('the online devices are offered as menu rows', (
    WidgetTester tester,
  ) async {
    final _Harness harness = await _Harness.pump(tester, peers: const <Peer>[bob]);

    final List<Object?> peers =
        harness.argumentsOf('setMenu')['peers']! as List<Object?>;
    expect(peers, hasLength(1));
    expect((peers.single! as Map<Object?, Object?>)['label'], 'Bob-PC');
    expect(harness.argumentsOf('setMenu')['summary'], '1 device online');
  });

  testWidgets('where-the-window-went is explained once, not on every close', (
    WidgetTester tester,
  ) async {
    // The real `SettingsRepository` behind this one, so that the "already
    // shown" flag is the one the app would write rather than a fake's.
    final _Harness harness = await _Harness.pump(tester);

    await harness.deliver('closeRequested');
    await harness.deliver('open');
    await harness.deliver('closeRequested');

    expect(
      harness.methods.where((String m) => m == 'balloon'),
      hasLength(1),
      reason: 'a hint repeated on every close would be nagging',
    );
    expect(harness.methods.where((String m) => m == 'hide'), hasLength(2),
        reason: 'the window still hides every time');
  });

  testWidgets('an offer that needs an answer brings the window back', (
    WidgetTester tester,
  ) async {
    final _Harness harness = await _Harness.pump(tester, askBeforeReceiving: true);
    await harness.deliver('closeRequested');
    final int afterHide = harness.outbound.length;

    // Nothing about the offer matters but that one arrived: the window has to
    // be back *before* `OfferListener` raises a dialog on it, or the sender
    // waits out `kOfferTimeout` for an answer to a question never asked aloud.
    harness.transfers.push(await harness.offer());
    await tester.pump();

    expect(harness.methods.sublist(afterHide), contains('show'));
  });

  testWidgets('an offer that needs no answer leaves a hidden window alone', (
    WidgetTester tester,
  ) async {
    final _Harness harness = await _Harness.pump(tester, askBeforeReceiving: false);
    await harness.deliver('closeRequested');
    final int afterHide = harness.outbound.length;

    harness.transfers.push(await harness.offer());
    await tester.pump();

    expect(harness.methods.sublist(afterHide), isEmpty,
        reason: 'with the offer auto-accepted there is nothing to answer, and '
            'popping the window up over the user would be the chime\'s job');
  });
}

/// A widget tree with the real tray host at the app's own mount point.
class _Harness {
  _Harness._(this.tester, this.db, this.discovery);

  final WidgetTester tester;
  final AppDatabase db;
  final _StubDiscovery discovery;

  late ProviderContainer container;

  /// A service whose offer stream the test drives, standing in for the engine.
  late final _FakeOffers transfers;

  /// Every call the Dart side made on the channel, in order, decoded as the
  /// native side would receive it.
  final List<MethodCall> outbound = <MethodCall>[];

  List<String> get methods =>
      outbound.map((MethodCall call) => call.method).toList();

  /// The arguments of the *last* call to [method] — the state as it stands.
  ///
  /// Last rather than first because the menu is pushed twice on the way up: an
  /// empty one from `start`, then the real one once the online devices have been
  /// read. The first is not wrong, it is just the state before the app knew
  /// anything.
  Map<Object?, Object?> argumentsOf(String method) =>
      outbound.lastWhere((MethodCall call) => call.method == method).arguments
          ! as Map<Object?, Object?>;

  /// Mounts the tray the way `lib/app.dart` does.
  ///
  /// The overrides exist to keep this off the network: discovery is a service
  /// that never started, and the LAN and transfer services are futures that
  /// never resolve, so nothing binds a port. What is *not* overridden is
  /// `WindowsTrayHost` — the real one is used, on its real channel.
  static Future<_Harness> pump(
    WidgetTester tester, {
    List<Peer> peers = const <Peer>[],
    bool askBeforeReceiving = false,
  }) async {
    final AppDatabase db = AppDatabase.memory();
    addTearDown(db.close);

    final _StubDiscovery discovery = _StubDiscovery();
    final _Harness harness = _Harness._(tester, db, discovery);
    final ConnectionManager manager = ConnectionManager(
      port: 0,
      selfHello: const HelloPayload(
        role: ConnectionRole.control,
        deviceId: 'test-self',
        name: 'Test-Box',
        deviceType: DeviceType.windows,
        icon: DeviceIcon.desktop,
        port: 0,
        version: 1,
      ),
    );
    addTearDown(manager.dispose);
    harness.transfers = _FakeOffers(
      manager: manager,
      transfers: TransferRepository(db),
      downloadDirectory: () async => Directory.systemTemp,
    );
    addTearDown(harness.transfers.dispose);

    harness.container = ProviderContainer(
      overrides: <Override>[
        settingsRepositoryProvider.overrideWithValue(SettingsRepository(db)),
        peersProvider.overrideWithValue(peers),
        discoveryServiceProvider.overrideWithValue(discovery),
        transferServiceProvider.overrideWith(
          (Ref ref) => Future<TransferService>.value(harness.transfers),
        ),
        // Left unresolved on purpose: a real `LanService` binds a socket on
        // construction, and this test is not about the LAN. `_shutdown` reads it
        // through `valueOrNull`, which is null while it is loading, so the quit
        // path skips it — the same way it would if the LAN had failed to come up.
        lanServiceProvider.overrideWith(
          (Ref ref) => Completer<LanService>().future,
        ),
        // Same reason: the app would start this from settings on the first frame.
        databaseProvider.overrideWithValue(db),
      ],
    );
    addTearDown(harness.container.dispose);

    if (askBeforeReceiving) {
      harness.container
          .read(settingsProvider.notifier)
          .update(
            (AppSettings s) => s.copyWith(confirmBeforeReceiving: true),
          );
    }

    // Every call the Dart side makes, captured where the native side would
    // receive it.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (MethodCall call) async {
          harness.outbound.add(call);
          return null;
        });

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: harness.container,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          builder: (BuildContext context, Widget? child) =>
              TrayLifecycle(child: child ?? const SizedBox.shrink()),
          home: const Scaffold(body: SizedBox.shrink()),
        ),
      ),
    );
    await harness.settle();
    return harness;
  }

  /// One method call, as the native side would send it.
  Future<void> deliver(String method, [Object? arguments]) async {
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          _channel.name,
          _codec.encodeMethodCall(MethodCall(method, arguments)),
          (ByteData? _) {},
        );
    await settle();
  }

  /// A file offer, as the engine would have written it before announcing it.
  Future<Transfer> offer() => TransferRepository(db).beginIncoming(
    xferId: 'xfer-1',
    peerId: 'peer-bob',
    fileName: 'holiday.png',
    totalSize: 1024,
    now: DateTime(2026, 1, 1, 9),
  );

  /// Lets the post-frame start, the channel hops and the database reads finish,
  /// then advances past the settings store's own round trip.
  ///
  /// `pump` alone is not enough for the last of those: the hint flag is written
  /// to real SQLite, which completes on the event loop rather than on the frame
  /// clock.
  Future<void> settle() async {
    for (int i = 0; i < 3; i++) {
      await tester.pump();
    }
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    for (int i = 0; i < 3; i++) {
      await tester.pump();
    }
  }
}

/// Discovery, constructed but never started: no socket, no port, no announce
/// sweep — and a [stopped] flag the quit path can be checked against.
class _StubDiscovery extends DiscoveryService {
  bool stopped = false;

  @override
  Future<void> stop() async {
    stopped = true;
    return super.stop();
  }
}

/// The engine with its offer stream in the test's hands — the same seam
/// `offer_listener_test.dart` uses, for the same reason: an offer arrives from a
/// socket, and no socket completes in a widget test.
class _FakeOffers extends TransferService {
  _FakeOffers({
    required super.manager,
    required super.transfers,
    required super.downloadDirectory,
  });

  final StreamController<Transfer> _pushed =
      StreamController<Transfer>.broadcast();

  @override
  Stream<Transfer> get offers => _pushed.stream;

  void push(Transfer offer) => _pushed.add(offer);

  @override
  Future<void> dispose() async {
    await _pushed.close();
    return super.dispose();
  }
}
