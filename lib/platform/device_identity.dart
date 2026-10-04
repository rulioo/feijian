import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

/// This device's permanent id — design.md §4.1.
///
/// The id is the primary key for every peer, conversation, message and
/// transfer, so it is generated once and then never changes for the life of the
/// installation. Two consequences shape this file:
///
///  * It lives in a plain file rather than the database, because discovery needs
///    it before the database is open.
///  * A read failure must never silently mint a new id. Peers would see a
///    stranger, and every conversation would appear to start over. Generating
///    is a last resort, not a fallback.
abstract final class DeviceIdentity {
  static const String _fileName = 'device_id';

  static String? _cached;

  /// The persisted id, generating and storing one on first launch.
  ///
  /// When storage is unavailable the app still runs, on an id that changes at
  /// the next restart. Discovery keeps working for this session, which is a
  /// better outcome than refusing to start.
  static Future<String> load() async {
    final String? cached = _cached;
    if (cached != null) {
      return cached;
    }

    try {
      final Directory dir = await getApplicationSupportDirectory();
      final File file = File('${dir.path}${Platform.pathSeparator}$_fileName');

      if (await file.exists()) {
        final String stored = (await file.readAsString()).trim();
        if (_looksUsable(stored)) {
          return _cached = stored;
        }
      }

      final String generated = const Uuid().v4();
      await file.writeAsString(generated, flush: true);
      return _cached = generated;
    } on Exception {
      // No support directory, no write permission, or no plugin binding (as in
      // a plain unit test). Stay usable for this run.
      return _cached = const Uuid().v4();
    }
  }

  /// Clears the in-process cache. Test seam only.
  static void resetCacheForTesting() => _cached = null;

  /// Accepts anything plausibly an id rather than validating a UUID shape.
  ///
  /// A stricter check would be actively harmful here: a stored value that a
  /// future format change made unrecognisable would be rejected, and the device
  /// would quietly take a new identity — the exact failure this class exists to
  /// prevent. Only obviously broken content is discarded.
  static bool _looksUsable(String value) {
    if (value.length < 8 || value.length > 64) {
      return false;
    }
    return !value.contains(RegExp(r'\s'));
  }
}
