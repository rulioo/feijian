import '../database.dart';

/// Reads and writes the `setting` key/value table — design.md §5.1.
///
/// Values are stored as text and converted here. The table itself deliberately
/// has one `TEXT` value column rather than a column per preference: adding a
/// preference is then a code change instead of a migration, and the set of
/// preferences is a UI concern that changes far more often than the schema
/// should.
///
/// A malformed or missing value falls back to the caller's default rather than
/// throwing. Settings are read during startup, and a hand-edited database or a
/// value written by a newer build must not be able to stop the app from opening.
class SettingsRepository {
  SettingsRepository(this._db);

  final AppDatabase _db;

  /// Everything, as raw strings — handy for diagnostics and for a "reset
  /// settings" screen that needs to enumerate what is stored.
  Future<Map<String, String>> all() async {
    final List<SettingRow> rows = await _db.select(_db.settings).get();
    return <String, String>{
      for (final SettingRow row in rows) row.key: row.value,
    };
  }

  Future<String?> getString(String key) async {
    final SettingRow? row = await _row(key);
    return row?.value;
  }

  /// Reads a bool. Stored as `'true'` / `'false'` rather than `'1'` / `'0'`
  /// because these rows are meant to be legible if anyone opens the file.
  Future<bool?> getBool(String key) async {
    final String? raw = await getString(key);
    return switch (raw) {
      'true' => true,
      'false' => false,
      _ => null,
    };
  }

  Future<int?> getInt(String key) async {
    final String? raw = await getString(key);
    return raw == null ? null : int.tryParse(raw);
  }

  /// Reads a value from a closed set, e.g. `AutoAcceptPolicy` or `DeviceIcon`,
  /// written by the caller as its `wire` string.
  ///
  /// [parse] returns null for anything it does not recognise, which comes out
  /// the same as the key being absent — an unrecognised value is not worth
  /// crashing over, and the caller's default beats a value from a build that no
  /// longer exists.
  Future<T?> getEnum<T>(String key, T? Function(String raw) parse) async {
    final String? raw = await getString(key);
    return raw == null ? null : parse(raw);
  }

  Future<void> putString(String key, String value) {
    return _db.into(_db.settings).insertOnConflictUpdate(
          SettingsCompanion.insert(key: key, value: value),
        );
  }

  Future<void> putBool(String key, bool value) =>
      putString(key, value ? 'true' : 'false');

  Future<void> putInt(String key, int value) => putString(key, '$value');

  Future<int> remove(String key) {
    return (_db.delete(_db.settings)..where((Settings t) => t.key.equals(key)))
        .go();
  }

  /// Writes several settings as one unit, so a partially applied change cannot
  /// be read back — the settings screen saves a whole form at a time.
  Future<void> putAll(Map<String, String> values) {
    return _db.transaction(() async {
      for (final MapEntry<String, String> entry in values.entries) {
        await putString(entry.key, entry.value);
      }
    });
  }

  Future<SettingRow?> _row(String key) {
    return (_db.select(_db.settings)..where((Settings t) => t.key.equals(key)))
        .getSingleOrNull();
  }
}

/// Keys used in the `setting` table.
///
/// Collected in one place because a typo in a key is not a compile error — it
/// silently reads as "unset", and the symptom is a preference that saves
/// successfully and comes back at its default the next time the app starts.
abstract final class SettingKeys {
  static const String displayName = 'display_name';
  static const String deviceIcon = 'device_icon';
  static const String downloadFolder = 'download_folder';
  static const String autoAcceptPolicy = 'auto_accept_policy';
  static const String autoAcceptImageMaxMb = 'auto_accept_image_max_mb';
  static const String listenPort = 'listen_port';
  static const String multicastAddress = 'multicast_address';
  static const String notificationsEnabled = 'notifications_enabled';
  static const String launchAtStartup = 'launch_at_startup';
  static const String minimizeToTray = 'minimize_to_tray';
  static const String backgroundService = 'background_service';
  static const String languageCode = 'language_code';
}
