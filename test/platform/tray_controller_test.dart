import 'dart:async';

import 'package:feijian/platform/tray_controller.dart';
import 'package:feijian/platform/tray_host.dart';
import 'package:flutter_test/flutter_test.dart';

/// Close-to-tray, as a set of decisions — design.md §7.2.
///
/// Every judgement this feature makes is in [TrayController], which is the
/// point of it existing separately from the platform: these tests drive the
/// controller with a recorder where the Windows API would be and assert on what
/// it decided. Whether clicking X leaves the app running or ends it is the one
/// branch that must not be wrong, and it is the first two below.
///
/// What this does not cover, and cannot: the C++ that delivers
/// `closeRequested`, the shell's balloon, `TaskbarCreated`, and the shutdown
/// messages. Those live in `windows/runner/` and are verified by hand on a
/// machine with a desktop session. A green run here says the decisions are
/// right, not that the tray works.
void main() {
  late _FakeTrayHost host;
  late _FakeTraySettings settings;
  late _Harness harness;

  setUp(() {
    host = _FakeTrayHost();
    settings = _FakeTraySettings();
    harness = _Harness(host: host, settings: settings);
  });

  test('a close hides when close-to-tray is on, and never quits', () async {
    await harness.start();
    host.emit(const TrayCloseRequested());
    await harness.settle();

    expect(harness.log, <String>['hide']);
    expect(harness.controller.isHidden, isTrue);
  });

  test('a close quits when close-to-tray is off, and never hides', () async {
    settings.minimizeToTray = false;
    await harness.start();
    host.emit(const TrayCloseRequested());
    await harness.settle();

    // The goodbye goes first: the process is about to stop giving Dart turns,
    // so a `bye` sent after this point is a `bye` that never leaves the machine.
    expect(harness.log, <String>['shutdown', 'quit']);
    expect(harness.controller.isHidden, isFalse);
  });

  test('a second close follows the switch that is set at that moment', () async {
    await harness.start();
    host.emit(const TrayCloseRequested());
    await harness.settle();
    expect(harness.log, <String>['hide']);

    // The setting is read per close, not cached at construction: a user who
    // turns close-to-tray off and then clicks X means it.
    settings.minimizeToTray = false;
    host.emit(const TrayCloseRequested());
    await harness.settle();

    expect(harness.log, <String>['hide', 'shutdown', 'quit']);
  });

  test('Open from the menu reveals the window and does nothing else', () async {
    await harness.start();
    host.emit(const TrayCloseRequested());
    await harness.settle();
    harness.log.clear();

    host.emit(const TrayOpenRequested());
    await harness.settle();

    expect(harness.log, <String>['show']);
    expect(harness.controller.isHidden, isFalse);
  });

  test('Quit from the menu takes the same path as closing with the switch off',
      () async {
    await harness.start();
    host.emit(const TrayQuitRequested());
    await harness.settle();

    // Pinned against the close path on purpose: the tray's Quit and the
    // window's X with the switch off are the same act, and two paths that
    // drifted apart would be two different shutdown behaviours to debug.
    expect(harness.log, <String>['shutdown', 'quit']);
  });

  test('choosing a device reveals the window, then opens that device',
      () async {
    await harness.start();
    host.emit(const TrayCloseRequested());
    await harness.settle();
    harness.log.clear();

    host.emit(const TrayPeerSelected('peer-bob'));
    await harness.settle();

    // The window has to be back before the conversation it opens can be seen.
    expect(harness.log, <String>['show']);
    expect(harness.selected, <String>['peer-bob']);
  });

  test('the goodbye is abandoned, not waited on, and quit still happens',
      () async {
    settings.minimizeToTray = false;
    harness.shutdown = () => Completer<void>().future;  // never completes
    await harness.start();

    host.emit(const TrayCloseRequested());
    await harness.settle();

    // The one thing the shutdown path must never do is refuse to finish.
    expect(harness.log, <String>['shutdown', 'quit']);
  });

  test('a goodbye that throws does not stop the quit', () async {
    settings.minimizeToTray = false;
    harness.shutdown = () => Future<void>.error(StateError('socket is gone'));
    await harness.start();

    host.emit(const TrayCloseRequested());
    await harness.settle();

    expect(harness.log, <String>['shutdown', 'quit']);
  });

  test('the goodbye runs once no matter how often quit is asked for',
      () async {
    settings.minimizeToTray = false;
    await harness.start();

    host.emit(const TrayQuitRequested());
    await harness.settle();
    host.emit(const TrayQuitRequested());
    await harness.settle();

    expect(harness.log.where((String c) => c == 'shutdown'), hasLength(1));
    expect(harness.log.where((String c) => c == 'quit'), hasLength(2));
  });

  test('the where-did-it-go hint is shown once, across many closes', () async {
    settings.hintsRemaining = 1;  // a fresh install, with the row unset
    await harness.start();

    for (int i = 0; i < 3; i++) {
      host.emit(const TrayCloseRequested());
      await harness.settle();
    }

    expect(host.balloons, hasLength(1));
    expect(harness.log.where((String c) => c == 'hide'), hasLength(3),
        reason: 'the window still hides every time');
  });

  test('the menu snapshot is what the controller says it is', () async {
    await harness.start();
    await harness.controller.setPeers(<TrayPeerEntry>[
      const TrayPeerEntry(id: 'peer-bob', label: 'Bob-PC'),
      const TrayPeerEntry(id: 'peer-eve', label: 'Eve-Laptop'),
    ]);

    expect(host.menus.last, harness.controller.menuState);
    expect(host.menus.last.statusSummary, '2 devices online');
    expect(host.menus.last.openCaption, 'Open');
    expect(host.menus.last.peers, hasLength(2));
  });

  test('an unchanged device list is not pushed again', () async {
    await harness.start();
    final int afterStart = host.menus.length;
    const List<TrayPeerEntry> peers = <TrayPeerEntry>[
      TrayPeerEntry(id: 'peer-bob', label: 'Bob-PC'),
    ];

    await harness.controller.setPeers(peers);
    await harness.controller.setPeers(peers);

    expect(host.menus.length, afterStart + 1,
        reason: 'peer heartbeats rewrite the list every few seconds');
  });

  test('the empty list reaches the menu before any device is known',
      () async {
    await harness.start();

    // The tray must not read "0 devices" before it has been told the count; it
    // is what the user sees if they open the menu cold.
    expect(host.menus.first.statusSummary, 'No devices online');
    expect(host.menus.first.peers, isEmpty);
  });

  test('a hidden window is brought back for an offer that needs an answer',
      () async {
    await harness.start();
    host.emit(const TrayCloseRequested());
    await harness.settle();
    harness.log.clear();

    await harness.controller.revealForAttention();

    expect(harness.log, <String>['show']);
    expect(harness.controller.isHidden, isFalse);
  });

  test('a visible window is left alone when an offer arrives', () async {
    await harness.start();

    await harness.controller.revealForAttention();

    expect(harness.log, isEmpty);
  });

  test('the tray icon follows the switch, at start and afterwards', () async {
    // Not `harness.start()`, which forgets what starting did — the initial push
    // is half of what this test is about.
    await harness.controller.start();
    expect(harness.log, <String>['visible:true']);

    settings.minimizeToTray = false;
    await harness.controller.syncVisibility();
    expect(harness.log, <String>['visible:true', 'visible:false']);
  });

  test('on a platform with no tray, starting does nothing at all', () async {
    host = _FakeTrayHost(isSupported: false);
    harness = _Harness(host: host, settings: settings);

    await harness.controller.start();
    await harness.settle();

    expect(host.started, isFalse);
    expect(harness.log, isEmpty);
    expect(host.menus, isEmpty);

    // Not covered here, and not coverable through [TrayHost]: `_close` also
    // refuses to hide when `isSupported` is false, so that a close cannot
    // become a lockout. With no handler registered there is no way to deliver a
    // close to that branch from a test, and none from the platform either --
    // it is unreachable by construction and kept as a safety net.
  });
}

/// Wires a controller to the fakes and gives the tests one ordered log.
///
/// A single log rather than one per side: "the goodbye is sent before the
/// process ends" is an ordering claim, and an ordering claim cannot be checked
/// across two lists.
class _Harness {
  _Harness({required this.host, required this.settings}) {
    host.log = log;
    controller = TrayController(
      host: host,
      settings: settings,
      labels: () => _labels,
      shutdown: _shutdown,
      onPeerSelected: selected.add,
      // Shorter than a real quit's, so the tests that have to wait one out stay
      // quick. The value is not what is being tested; that there is a bound at
      // all is.
      gracePeriod: const Duration(milliseconds: 10),
    );
  }

  final _FakeTrayHost host;
  final _FakeTraySettings settings;

  /// Every side effect the controller caused, in the order it caused them.
  final List<String> log = <String>[];

  late final TrayController controller;

  /// Peer ids the controller asked to open.
  final List<String> selected = <String>[];

  /// Replaced by a test that wants a goodbye which hangs or throws.
  Future<void> Function() shutdown = () async {};

  Future<void> _shutdown() async {
    log.add('shutdown');
    await shutdown();
  }

  /// Starts the controller and forgets what starting it did, so that each test
  /// asserts only on the behaviour it is about.
  Future<void> start() async {
    await controller.start();
    log.clear();
  }

  /// Waits out a quit path. Longer than the injected grace period, because a
  /// quit always runs through that timer even when the goodbye resolves at once.
  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 30));
}

const TrayLabels _labels = TrayLabels(
  menuOpen: 'Open',
  menuStatus: 'Status',
  menuQuit: 'Quit',
  hintTitle: 'Feijian',
  hintBody: 'Still running.',
  deviceCount: _deviceCount,
);

/// Mirrors the `trayStatusOnline` plural in `app_en.arb`, including its zero
/// case — which is the one that matters, and the reason there is no separate
/// "no devices" string to get out of step with.
String _deviceCount(int count) => switch (count) {
  0 => 'No devices online',
  1 => '1 device online',
  _ => '$count devices online',
};

class _FakeTrayHost implements TrayHost {
  _FakeTrayHost({this.isSupported = true});

  @override
  final bool isSupported;

  bool started = false;
  final List<TrayMenuState> menus = <TrayMenuState>[];
  final List<String> balloons = <String>[];

  /// Set by the harness, so that host calls and the goodbye land in one list.
  late List<String> log;

  void Function(TrayEvent event)? _onEvent;

  @override
  Future<void> start({required void Function(TrayEvent event) onEvent}) async {
    started = true;
    _onEvent = onEvent;
  }

  /// Delivers an event the way the native side would. Synchronous, like the
  /// channel callback: the controller is responsible for not blocking on it.
  void emit(TrayEvent event) {
    final void Function(TrayEvent)? deliver = _onEvent;
    if (deliver == null) {
      fail('the controller never registered for events');
    }
    deliver(event);
  }

  @override
  Future<void> hide() async => log.add('hide');

  @override
  Future<void> show() async => log.add('show');

  @override
  Future<void> quit() async => log.add('quit');

  @override
  Future<void> setTrayVisible(bool visible) async =>
      log.add('visible:$visible');

  // Not logged: the menu is asserted on through [menus], where the whole
  // snapshot is available and the "was it even a change" question can be asked.
  @override
  Future<void> updateMenu(TrayMenuState state) async => menus.add(state);

  @override
  Future<void> balloon({required String title, required String body}) async {
    log.add('balloon');
    balloons.add(body);
  }
}

/// Settable fields rather than constructor arguments: every test that cares
/// changes one of them *after* the harness is built — which is the point, since
/// both are read at the moment they are needed rather than captured.
class _FakeTraySettings implements TraySettings {
  @override
  bool minimizeToTray = true;

  /// How many more times [claimHint] may say yes. Zero here — the hint already
  /// shown — because that is the steady state for anyone who has used the app
  /// once, and it keeps the balloon out of assertions that are about the
  /// hide-or-quit decision. The one test about the hint raises it to one, which
  /// is what a fresh install has.
  int hintsRemaining = 0;

  @override
  Future<bool> claimHint() async {
    if (hintsRemaining <= 0) {
      return false;
    }
    hintsRemaining--;
    return true;
  }
}
