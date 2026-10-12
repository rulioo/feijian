import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/constants.dart';
import 'tray_host.dart';

/// What the tray menu says, in the user's language.
///
/// Passed in rather than looked up here: this file is in `platform/`, which has
/// no business knowing about the widget tree, and a controller whose menu can be
/// asserted against literal English is a controller that can be tested without
/// standing up a localisation delegate.
class TrayLabels {
  const TrayLabels({
    required this.menuOpen,
    required this.menuStatus,
    required this.menuQuit,
    required this.hintTitle,
    required this.hintBody,
    required this.deviceCount,
  });

  final String menuOpen;
  final String menuStatus;
  final String menuQuit;
  final String hintTitle;
  final String hintBody;

  /// The disabled first line of the Status submenu. Takes the online count and
  /// is expected to handle zero itself, which is why there is no separate
  /// "no devices" string.
  final String Function(int count) deviceCount;
}

/// The two settings the tray consults.
///
/// A port, not `SettingsNotifier` directly, because the controller has to be
/// runnable somewhere with no `ProviderContainer` — and because [claimHint]
/// needs a test to be able to say "this is the second close" without writing to
/// the real settings store.
abstract interface class TraySettings {
  /// Read fresh on every close, never cached: the user can flip the switch and
  /// then click X, and that click has to obey the switch they just flipped.
  bool get minimizeToTray;

  /// True exactly once per install, and records the fact before returning.
  ///
  /// Read-and-write as one call so the two can never drift: writing after the
  /// balloon would repeat the hint if the balloon call threw, and there is no
  /// useful state in which the hint is "about to have been shown".
  Future<bool> claimHint();
}

/// Decides what the tray and the close button mean — design.md §7.2.
///
/// Everything this feature judges lives here and nothing else does: whether a
/// close hides or quits, what the menu snapshot says, and whether the
/// where-did-it-go hint has been earned. [TrayHost] is the wire, `TrayLifecycle`
/// is the wiring, and this is the part worth a test.
class TrayController {
  TrayController({
    required this.host,
    required this.settings,
    required this.labels,
    required this.shutdown,
    required this.onPeerSelected,
    this.gracePeriod = kShutdownGracePeriod,
  });

  /// How long [shutdown] gets before [quit] stops waiting for it.
  ///
  /// Injectable so a test can prove the bound without waiting it out, the same
  /// way `DiscoveryLifecycle.minimumAway` is.
  final Duration gracePeriod;

  final TrayHost host;
  final TraySettings settings;

  /// Read at the moment a string is needed, never captured at construction.
  ///
  /// The widget that owns this controller cannot build [TrayLabels] until it has
  /// a `BuildContext` — `AppLocalizations` lives on one — so the strings arrive
  /// as a getter and stay live. Today that only matters in principle, since the
  /// app ships one locale; it is written this way so that adding a second one is
  /// a translation rather than a bug hunt through the tray menu.
  final TrayLabels Function() labels;

  /// Ends the session politely before the process dies — see [_quit] for why
  /// this cannot be left to the providers' own teardown.
  final Future<void> Function() shutdown;

  /// Opens the conversation with a device picked out of the Status submenu.
  /// The window is revealed before this runs, so the callback can navigate.
  final void Function(String peerId) onPeerSelected;

  final List<TrayPeerEntry> _peers = <TrayPeerEntry>[];
  bool _hidden = false;
  bool _shutdownDone = false;

  /// True while the window is hidden because of a close, so that the offer
  /// listener knows whether it has to bring the window back to ask a question.
  bool get isHidden => _hidden;

  /// What the menu would say if it were opened right now.
  ///
  /// Built on demand from [_peers] rather than stored, so the summary line can
  /// never disagree with the rows under it.
  TrayMenuState get menuState => _stateFor(_peers);

  /// Connects to the platform and starts obeying events.
  ///
  /// Does nothing at all where there is no tray — see [TrayHost.isSupported].
  /// The check is here rather than in each caller so that no code path can
  /// half-start this on a platform that cannot finish it.
  Future<void> start() async {
    if (!host.isSupported) {
      return;
    }
    await host.start(onEvent: (TrayEvent event) => unawaited(_handle(event)));
    await syncVisibility();
    await _pushMenu();
  }

  /// Pushes the current close-to-tray setting to the tray icon's visibility.
  /// Called on start and again whenever the user changes the switch.
  Future<void> syncVisibility() async {
    if (!host.isSupported) {
      return;
    }
    await host.setTrayVisible(settings.minimizeToTray);
  }

  /// Replaces the device list the Status submenu is built from.
  ///
  /// Silently drops a snapshot identical to the last one. The caller debounces,
  /// but peer heartbeats make "a new list object every few seconds" the normal
  /// case rather than the exception, and a channel write per heartbeat for a
  /// menu nobody has open is pure noise.
  Future<void> setPeers(List<TrayPeerEntry> peers) async {
    if (!host.isSupported) {
      return;
    }
    final TrayMenuState next = _stateFor(peers);
    if (next == menuState) {
      return;
    }
    _peers
      ..clear()
      ..addAll(peers);
    await host.updateMenu(next);
  }

  /// Assembles a menu snapshot for a device list.
  ///
  /// One builder for both the getter and [setPeers], so the "has anything
  /// actually changed" comparison is between two objects put together the same
  /// way. Building them separately would mean a caption added to one and
  /// forgotten in the other, which would make every push look like a change.
  TrayMenuState _stateFor(List<TrayPeerEntry> peers) {
    final TrayLabels text = labels();
    return TrayMenuState(
      openCaption: text.menuOpen,
      statusCaption: text.menuStatus,
      quitCaption: text.menuQuit,
      statusSummary: text.deviceCount(peers.length),
      peers: List<TrayPeerEntry>.unmodifiable(peers),
    );
  }

  /// Sends the current snapshot unconditionally, for [start] — where there is
  /// no previous state to compare against, so the dedupe in [setPeers] would
  /// skip the very first push if the list happened to be empty.
  Future<void> _pushMenu() async {
    if (!host.isSupported) {
      return;
    }
    await host.updateMenu(menuState);
  }

  /// Brings the window back, from the tray menu or a menu device row.
  Future<void> reveal() async {
    _hidden = false;
    await host.show();
  }

  /// Brings the window back *before* something needs the user's attention.
  ///
  /// The case this exists for: close-to-tray is on, the user has hidden the
  /// window, and a peer sends a file while `confirmBeforeReceiving` is on. The
  /// offer dialog would otherwise be raised on a window nobody can see, and the
  /// sender would sit there until [kOfferTimeout] expired waiting for an answer
  /// to a question that was never asked out loud.
  ///
  /// No balloon: the window arriving with a dialog already on it says more than
  /// a notification-area popup would, and is harder to miss.
  Future<void> revealForAttention() async {
    if (!_hidden) {
      return;
    }
    await reveal();
  }

  Future<void> _handle(TrayEvent event) async {
    switch (event) {
      case TrayCloseRequested():
        await _close();
      case TrayOpenRequested():
        await reveal();
      case TrayQuitRequested():
        await _quit();
      case TrayPeerSelected(:final String peerId):
        await reveal();
        onPeerSelected(peerId);
    }
  }

  Future<void> _close() async {
    // No tray to hide into — hiding would leave a running process with no way
    // to reach it, so a close has to mean a close. Unreachable on Windows,
    // which is the only platform that ever sends this event; kept because the
    // alternative is a lockout if that ever stops being true.
    if (!host.isSupported || !settings.minimizeToTray) {
      await _quit();
      return;
    }
    _hidden = true;
    await host.hide();
    if (await settings.claimHint()) {
      // Windows 10 and 11 may swallow this — Focus Assist, or a shell that
      // simply drops it. It is a courtesy; the tray icon is the actual way
      // back, and the hint is never the only signal that the app is still up.
      await host.balloon(title: labels().hintTitle, body: labels().hintBody);
    }
  }

  /// Ends the process, after saying goodbye.
  ///
  /// [shutdown] is not belt-and-braces. Reaching the process exit directly —
  /// which is what `PostQuitMessage` does — ends the message loop and the CRT
  /// tears the process down without giving Dart another turn, so no Riverpod
  /// `onDispose` callback and no `DiscoveryService.stop()` ever runs. The `bye`
  /// frame lives in that stop, and without it every peer waits
  /// [kPeerRemoveAfter] — a full minute — before deciding this device is gone,
  /// instead of learning it immediately from the goodbye.
  ///
  /// Bounded and swallowed on purpose: this is the shutdown path, and the one
  /// thing it must never do is refuse to finish. A transfer in flight is
  /// abandoned here, which is exactly what "quit" means; cleaning up a
  /// half-written file is the receiving end's job either way.
  Future<void> _quit() async {
    if (!_shutdownDone) {
      _shutdownDone = true;
      try {
        await shutdown().timeout(gracePeriod);
      } on Object catch (error) {
        debugPrint('[tray] graceful shutdown did not finish: $error');
      }
    }
    await host.quit();
  }
}
