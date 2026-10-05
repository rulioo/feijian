import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/providers.dart';

/// Rescans the LAN when the app comes back from being away — design.md §4.1.5.
///
/// Invisible: it wraps the app and only observes. The device list is live while
/// the app is in front of the user — discovery is a plain provider, not an
/// auto-disposed one, so entering a conversation does not stop it and returning
/// from one has nothing to repair — so the moment that actually needs a scan is
/// the one this watches.
///
/// Being away is what invalidates the sockets, and on Android it does so twice
/// over: Doze freezes the process and suspends its sockets, and the phone may
/// have joined a different network by the time it wakes. A membership in a
/// multicast group belongs to the interface it was joined on (§4.1.3), and the
/// interfaces the service is holding are the ones it enumerated at start.
class DiscoveryLifecycle extends ConsumerStatefulWidget {
  const DiscoveryLifecycle({
    required this.child,
    this.minimumAway = const Duration(seconds: 2),
    super.key,
  });

  final Widget child;

  /// How long the app has to have been away before coming back is worth a scan.
  ///
  /// A rebuild closes the listening socket and binds a new one, so the app is
  /// deaf for a few milliseconds each time. That is worth paying to recover
  /// from a freeze, and not worth paying because the user glanced at the app
  /// switcher. Injectable so tests do not have to wait it out.
  final Duration minimumAway;

  @override
  ConsumerState<DiscoveryLifecycle> createState() => _DiscoveryLifecycleState();
}

class _DiscoveryLifecycleState extends ConsumerState<DiscoveryLifecycle>
    with WidgetsBindingObserver {
  /// Set only while the app is genuinely away — not for [_inactive].
  bool _away = false;

  /// When it went away, for [DiscoveryLifecycle.minimumAway].
  DateTime? _leftAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      // Backgrounded for real: the app is off screen and may be frozen. Both
      // states are listed because the sequence differs by platform — Android
      // walks inactive to hidden to paused, while a minimised desktop window
      // stops at hidden.
      case AppLifecycleState.paused || AppLifecycleState.hidden:
        _away = true;
        _leftAt = DateTime.now();

      case AppLifecycleState.resumed:
        // The cold-start resume lands here too, with `_away` still false, so
        // launching does not rescan a service that has just started.
        final DateTime? leftAt = _leftAt;
        final bool worthIt =
            _away &&
            leftAt != null &&
            DateTime.now().difference(leftAt) >= widget.minimumAway;
        _away = false;
        _leftAt = null;
        if (worthIt) {
          ref.read(discoveryServiceProvider).rescan();
        }

      // Deliberately not a departure. `inactive` is also what a lost window
      // focus and a pulled-down notification shade look like, and neither of
      // those is going to have taken the network away.
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        break;
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
