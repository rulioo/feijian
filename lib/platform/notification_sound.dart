import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Plays the device's notification sound — one short chime per arrived message.
///
/// ## Why it is two implementations
///
/// Flutter's own `SystemSound.play(SystemSoundType.alert)` is the whole of this
/// on desktop, and its documentation says so: 「Desktop platforms are the only
/// platforms that support a system alert sound, so on mobile platforms
/// (Android, iOS), this will be ignored.」 Ignored, not failed — the call
/// returns normally and nothing is heard, which is the worst way for a feature
/// to be missing. So Windows goes through the framework and Android goes
/// through the `RingtoneManager` in `MainActivity.kt`.
///
/// ## Why the system's sound and not one of ours
///
/// A bundled asset would be the same noise on every device, at a volume the
/// user did not choose, in a ring mode they may have deliberately silenced.
/// The notification tone is *the* tone this phone uses for "something arrived",
/// and it already respects the notification volume, the silent switch and
/// Do-Not-Disturb. A LAN tool is not important enough to override any of that.
abstract final class NotificationSound {
  static const MethodChannel _channel =
      MethodChannel('com.feijian.lan/notification_sound');

  /// Rings once. Never throws, and never waits longer than the platform takes.
  ///
  /// The caller is a listener on a stream of arrived messages: a failure here
  /// has to cost the user a sound, not the message. Every path is therefore
  /// swallowed and logged.
  static Future<void> play({void Function(String message)? onLog}) async {
    try {
      if (Platform.isAndroid) {
        await _channel.invokeMethod<void>('play');
        return;
      }
      await SystemSound.play(SystemSoundType.alert);
    } on Object catch (error) {
      debugPrint('[sound] could not play the notification sound: $error');
      onLog?.call('could not play the notification sound: $error');
    }
  }
}
