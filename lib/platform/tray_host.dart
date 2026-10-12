import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Something the tray icon or the window told the app to do — design.md §7.2.
///
/// A sealed type rather than a bare enum because one of the four carries data:
/// picking a device out of the Status submenu has to say *which* device. An enum
/// plus a nullable `peerId` would make "open with no peer" and "select peer with
/// no id" both representable, and neither is a thing the native side can send.
sealed class TrayEvent {
  const TrayEvent();
}

/// The user clicked the window's close button.
///
/// Deliberately *not* "the user wants to quit": with close-to-tray on, this is
/// the request to hide, and only the Dart side knows which it is. That is the
/// whole reason the decision is not made in C++ — see [TrayHost.start].
final class TrayCloseRequested extends TrayEvent {
  const TrayCloseRequested();
}

/// The user chose Open, or clicked the tray icon itself.
final class TrayOpenRequested extends TrayEvent {
  const TrayOpenRequested();
}

/// The user chose Quit.
final class TrayQuitRequested extends TrayEvent {
  const TrayQuitRequested();
}

/// The user picked a device from the Status submenu.
final class TrayPeerSelected extends TrayEvent {
  const TrayPeerSelected(this.peerId);

  final String peerId;
}

/// One row in the tray's Status submenu.
class TrayPeerEntry {
  const TrayPeerEntry({required this.id, required this.label});

  final String id;
  final String label;

  @override
  bool operator ==(Object other) =>
      other is TrayPeerEntry && other.id == id && other.label == label;

  @override
  int get hashCode => Object.hash(id, label);
}

/// Everything the native side needs to build the context menu.
///
/// Data rather than widgets, because a native context menu has nowhere to put a
/// Flutter widget: the native side rebuilds the menu from this snapshot at
/// pop-up time, which is also what keeps it current without a timer.
///
/// The captions travel with it even though they never change. A `TrackPopupMenu`
/// takes the text of every item at the moment it is shown, so the alternative
/// is hardcoding three English strings in C++ — which would be a fourth place
/// the product's language lives, and the only one no translator could reach.
class TrayMenuState {
  const TrayMenuState({
    required this.openCaption,
    required this.statusCaption,
    required this.quitCaption,
    required this.statusSummary,
    required this.peers,
  });

  final String openCaption;
  final String statusCaption;
  final String quitCaption;

  /// The disabled first line of the Status submenu — "2 devices online".
  final String statusSummary;

  /// The device rows under it. Empty means the submenu shows [statusSummary]
  /// alone, which is how "No devices online" is expressed.
  final List<TrayPeerEntry> peers;

  @override
  bool operator ==(Object other) =>
      other is TrayMenuState &&
      other.openCaption == openCaption &&
      other.statusCaption == statusCaption &&
      other.quitCaption == quitCaption &&
      other.statusSummary == statusSummary &&
      listEquals(other.peers, peers);

  @override
  int get hashCode => Object.hash(
    openCaption,
    statusCaption,
    quitCaption,
    statusSummary,
    Object.hashAll(peers),
  );
}

/// The Windows window and notification-area icon — design.md §7.2.
///
/// An interface with a real implementation behind it because the decisions it
/// enables are worth testing and the operating system is not. [TrayController]
/// owns every judgement call — hide or quit, what the menu says, whether the
/// hint has been shown — and this is only the wire to the platform. A test
/// substitutes a recorder and asserts on the decisions; nothing about Win32 is
/// covered by that, which [WindowsTrayHost] says in its own words.
///
/// ## Why the close decision is made on this side
///
/// The native window could have been told once, at startup, whether close means
/// hide — one boolean pushed down and no round trip at close time. It is not,
/// because that would put the single most consequential branch in this feature
/// (does clicking X leave the app running, or end it?) somewhere no host test
/// can reach. Instead `WM_CLOSE` comes back up here as [TrayCloseRequested] and
/// the answer goes down. The cost is one channel hop on a close, which is
/// sub-millisecond against a click.
abstract interface class TrayHost {
  /// False on every platform but Windows, and false when the channel is not
  /// answering. Callers check it and do nothing rather than branching on
  /// `Platform` themselves.
  bool get isSupported;

  /// Begins delivering events. Safe to call once, from the widget that owns the
  /// app's lifetime.
  Future<void> start({required void Function(TrayEvent event) onEvent});

  Future<void> hide();
  Future<void> show();

  /// Ends the process. The caller is responsible for whatever has to happen
  /// before that — see [TrayController], which sends the goodbye first.
  Future<void> quit();

  /// Replaces the snapshot the Status submenu is rebuilt from.
  Future<void> updateMenu(TrayMenuState state);

  /// A notification-area balloon, used once to explain where the window went.
  ///
  /// Best effort by nature: Windows 10 and 11 route this through Focus Assist,
  /// which the user may have turned on, and the shell is free to drop it. It is
  /// a courtesy, never the only way to reach the app — the tray icon is.
  Future<void> balloon({required String title, required String body});

  /// Shows or removes the tray icon itself.
  ///
  /// Tied to the close-to-tray setting rather than always-on: an icon in the
  /// notification area is a claim that the app lives there, and a user who has
  /// turned that behaviour off has not made that claim. Flips at runtime,
  /// because the setting does.
  Future<void> setTrayVisible(bool visible);
}

/// [TrayHost] over the `com.feijian.lan/tray` channel — see [TrayHost] for why
/// the decisions are not here.
///
/// The native end is `windows/runner/tray_window.cpp` plus the `WM_CLOSE`,
/// `WM_QUERYENDSESSION`, `WM_ENDSESSION` and `TaskbarCreated` branches in
/// `flutter_window.cpp`. None of that has an automated test and none of it can
/// have one without a real desktop session; it is verified by hand, and the
/// list of what to do so is in the plan that added this file.
class WindowsTrayHost implements TrayHost {
  const WindowsTrayHost();

  static const MethodChannel _channel = MethodChannel('com.feijian.lan/tray');

  /// Set by [start]. Null until then, and null forever off Windows.
  static void Function(TrayEvent event)? _onEvent;

  static bool _handlerInstalled = false;

  @override
  bool get isSupported => Platform.isWindows;

  @override
  Future<void> start({
    required void Function(TrayEvent event) onEvent,
  }) async {
    if (!Platform.isWindows) {
      return;
    }
    _onEvent = onEvent;
    if (_handlerInstalled) {
      return;
    }
    _handlerInstalled = true;
    // Registered once per process and routed through a static, because a
    // channel has exactly one inbound handler: a second host instance would
    // replace this one's callback rather than receive events alongside it.
    // There is only ever one window, so only ever one host — [start] keeps the
    // handler single rather than pretending otherwise.
    _channel.setMethodCallHandler((MethodCall call) async {
      final void Function(TrayEvent)? deliver = _onEvent;
      if (deliver == null) {
        return null;
      }
      // An unknown method is not an error worth raising: this end may be older
      // than the native end during a build, and a menu item it does not know
      // about is a menu item the user should simply not get.
      switch (call.method) {
        case 'closeRequested':
          deliver(const TrayCloseRequested());
        case 'open':
          deliver(const TrayOpenRequested());
        case 'quit':
          deliver(const TrayQuitRequested());
        case 'peerSelected':
          final Object? id = call.arguments is Map
              ? (call.arguments as Map)['peerId']
              : null;
          if (id is String && id.isNotEmpty) {
            deliver(TrayPeerSelected(id));
          }
      }
      return null;
    });
  }

  @override
  Future<void> hide() => _invoke('hide');

  @override
  Future<void> show() => _invoke('show');

  @override
  Future<void> quit() => _invoke('quit');

  @override
  Future<void> setTrayVisible(bool visible) =>
      _invoke('setTrayVisible', <String, Object?>{'visible': visible});

  @override
  Future<void> balloon({required String title, required String body}) =>
      _invoke('balloon', <String, Object?>{'title': title, 'body': body});

  @override
  Future<void> updateMenu(TrayMenuState state) => _invoke(
    'setMenu',
    <String, Object?>{
      'open': state.openCaption,
      'status': state.statusCaption,
      'quit': state.quitCaption,
      'summary': state.statusSummary,
      'peers': <Object?>[
        for (final TrayPeerEntry peer in state.peers)
          <String, Object?>{'id': peer.id, 'label': peer.label},
      ],
    },
  );

  /// Never throws and never reports anything back: every caller of this is
  /// either on a close path that must not be blocked by a platform problem, or
  /// an update whose worst case is a stale menu.
  static Future<void> _invoke(String method, [Object? arguments]) async {
    if (!Platform.isWindows) {
      return;
    }
    try {
      await _channel.invokeMethod<void>(method, arguments);
    } on Object catch (error) {
      debugPrint('[tray] $method failed: $error');
    }
  }
}
