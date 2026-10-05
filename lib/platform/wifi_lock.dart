import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Keeps the Wi-Fi chip delivering multicast to this process — Android only.
///
/// ## Why this is not optional
///
/// Declaring `CHANGE_WIFI_MULTICAST_STATE` in the manifest grants the
/// *permission* to hold a `WifiManager.MulticastLock`. It does not hold one.
/// Until something calls `acquire()`, the Wi-Fi firmware is free to treat every
/// multicast frame as uninteresting and drop it to save power — which is the
/// default on most devices. The socket-level `joinMulticast` still succeeds, so
/// nothing looks wrong from inside the app: the group is joined, the socket is
/// open, no error is raised anywhere, and not one packet arrives. That is the
/// exact silent failure design.md §4.1.1 is written against.
///
/// The lock is held for the life of the process rather than around each
/// announce. This is a LAN tool whose whole purpose is to notice the other
/// device appearing, and a lock that is dropped between rounds is a lock that
/// can be dropped at the moment the other device announces.
///
/// Android only: on Windows the equivalent knob does not exist and does not need
/// to. Everywhere else this is a no-op, so callers do not have to branch.
abstract final class WifiLock {
  static const MethodChannel _channel =
      MethodChannel('com.feijian.lan/wifi_lock');

  /// Whether the lock is actually held, for the settings page and for logs.
  ///
  /// Null means "not asked yet" — distinct from `false`, which means the
  /// question was asked and the answer was no.
  static bool? get isHeld => _isHeld;
  static bool? _isHeld;

  /// Asks the platform to hold a multicast lock. Safe to call more than once.
  ///
  /// Never throws. A device without the permission, without Wi-Fi, or with a
  /// platform channel that is not wired up must still start and still try to
  /// discover peers — the broadcast channel does not need this lock, and
  /// discovery failing is a far better outcome than the app refusing to launch.
  static Future<void> acquire({void Function(String message)? onLog}) async {
    if (!Platform.isAndroid) {
      return;
    }
    try {
      final bool? held = await _channel.invokeMethod<bool>('acquire');
      _isHeld = held ?? false;
      onLog?.call(
        _isHeld!
            ? 'holding a Wi-Fi multicast lock'
            : 'could not hold a Wi-Fi multicast lock; multicast will be '
                'unreliable, broadcast is the remaining channel',
      );
    } on Object catch (error) {
      _isHeld = false;
      onLog?.call('could not hold a Wi-Fi multicast lock: $error');
      debugPrint('[wifi-lock] acquire failed: $error');
    }
  }
}
