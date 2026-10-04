import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/constants.dart';
import '../core/models/peer.dart';
import '../data/repository/settings_repository.dart';
import 'data_providers.dart';

/// What to do when a file offer arrives (design.md §6.4).
enum AutoAcceptPolicy {
  /// Ask the user every time. The safe default.
  askEveryTime,

  /// Silently accept images below a size threshold — the common case where a
  /// confirmation dialog is pure friction.
  imagesUnderMb,

  /// Accept anything from peers marked trusted.
  trustedDevices,
}

/// User-configurable settings, persisted in the `setting` table (design.md
/// §5.1).
///
/// Every value has a sensible default, so a first launch and a corrupted row
/// both produce a usable app: [SettingsNotifier] reads what it can and leaves
/// the rest at the defaults below.
class AppSettings {
  const AppSettings({
    this.displayName,
    this.deviceIcon,
    this.downloadFolder,
    this.autoAcceptPolicy = AutoAcceptPolicy.askEveryTime,
    this.autoAcceptImageMaxMb = 10,
    this.listenPort = kDiscoveryPort,
    this.multicastAddress = kMulticastGroup,
    this.notificationsEnabled = true,
    this.launchAtStartup = false,
    this.minimizeToTray = true,
    this.backgroundService = true,
    this.languageCode,
  });

  /// Null means "use the system hostname".
  final String? displayName;
  final DeviceIcon? deviceIcon;
  final String? downloadFolder;
  final AutoAcceptPolicy autoAcceptPolicy;
  final int autoAcceptImageMaxMb;
  final int listenPort;
  final String multicastAddress;
  final bool notificationsEnabled;
  final bool launchAtStartup;
  final bool minimizeToTray;
  final bool backgroundService;

  /// Null means "follow the system language" (design.md §8.2).
  final String? languageCode;

  AppSettings copyWith({
    String? displayName,
    DeviceIcon? deviceIcon,
    String? downloadFolder,
    AutoAcceptPolicy? autoAcceptPolicy,
    int? autoAcceptImageMaxMb,
    int? listenPort,
    String? multicastAddress,
    bool? notificationsEnabled,
    bool? launchAtStartup,
    bool? minimizeToTray,
    bool? backgroundService,
    String? languageCode,
  }) {
    return AppSettings(
      displayName: displayName ?? this.displayName,
      deviceIcon: deviceIcon ?? this.deviceIcon,
      downloadFolder: downloadFolder ?? this.downloadFolder,
      autoAcceptPolicy: autoAcceptPolicy ?? this.autoAcceptPolicy,
      autoAcceptImageMaxMb: autoAcceptImageMaxMb ?? this.autoAcceptImageMaxMb,
      listenPort: listenPort ?? this.listenPort,
      multicastAddress: multicastAddress ?? this.multicastAddress,
      notificationsEnabled: notificationsEnabled ?? this.notificationsEnabled,
      launchAtStartup: launchAtStartup ?? this.launchAtStartup,
      minimizeToTray: minimizeToTray ?? this.minimizeToTray,
      backgroundService: backgroundService ?? this.backgroundService,
      languageCode: languageCode ?? this.languageCode,
    );
  }
}

class SettingsNotifier extends Notifier<AppSettings> {
  /// Whether the user has changed anything in this session.
  ///
  /// The stored values are read asynchronously, and a slow disk could land them
  /// after the user has already flipped a switch. Applying the stored set then
  /// would silently undo that change, so once the user has touched anything the
  /// read no longer writes to `state`.
  bool _edited = false;

  @override
  AppSettings build() {
    final SettingsRepository store = ref.watch(settingsRepositoryProvider);
    unawaited(_restore(store));
    return const AppSettings();
  }

  /// Replaces the settings and stores what changed.
  ///
  /// Persisting only the differing keys keeps a toggle from rewriting all
  /// eleven rows, and means a value the user never touched is never overwritten
  /// by a default this build happens to hold.
  void update(AppSettings Function(AppSettings current) change) {
    final AppSettings before = state;
    final AppSettings next = change(before);
    final Map<String, String> encodedBefore = _encode(before);
    final Map<String, String> encodedNext = _encode(next);
    if (mapEquals(encodedBefore, encodedNext)) {
      return;
    }

    _edited = true;
    state = next;

    unawaited(() async {
      try {
        await ref.read(settingsRepositoryProvider).putAll(<String, String>{
          for (final MapEntry<String, String> entry in encodedNext.entries)
            if (encodedBefore[entry.key] != entry.value) entry.key: entry.value,
        });
      } on Object catch (error, stack) {
        // The setting still applies for this session. Losing it at the next
        // launch is a smaller failure than crashing the settings screen.
        debugPrint('[settings] could not save: $error\n$stack');
      }
    }());
  }

  Future<void> _restore(SettingsRepository store) async {
    try {
      final Map<String, String> stored = await store.all();
      if (_edited || stored.isEmpty) {
        return;
      }
      state = _decode(stored);
    } on Object catch (error, stack) {
      // Defaults are already in place.
      debugPrint('[settings] could not load: $error\n$stack');
    }
  }
}

// --- Storage ----------------------------------------------------------------
//
// Enums are stored by `name`, not by a `wire` value: these are UI choices with
// no wire representation, and a renamed enum member reads back as unset and
// falls back to its default — a reverted preference, never a wrong one.

Map<String, String> _encode(AppSettings s) {
  return <String, String>{
    if (s.displayName != null) SettingKeys.displayName: s.displayName!,
    if (s.deviceIcon != null) SettingKeys.deviceIcon: s.deviceIcon!.name,
    if (s.downloadFolder != null)
      SettingKeys.downloadFolder: s.downloadFolder!,
    SettingKeys.autoAcceptPolicy: s.autoAcceptPolicy.name,
    SettingKeys.autoAcceptImageMaxMb: '${s.autoAcceptImageMaxMb}',
    SettingKeys.listenPort: '${s.listenPort}',
    SettingKeys.multicastAddress: s.multicastAddress,
    SettingKeys.notificationsEnabled: '${s.notificationsEnabled}',
    SettingKeys.launchAtStartup: '${s.launchAtStartup}',
    SettingKeys.minimizeToTray: '${s.minimizeToTray}',
    SettingKeys.backgroundService: '${s.backgroundService}',
    if (s.languageCode != null) SettingKeys.languageCode: s.languageCode!,
  };
}

AppSettings _decode(Map<String, String> stored) {
  const AppSettings defaults = AppSettings();
  return AppSettings(
    displayName: stored[SettingKeys.displayName],
    deviceIcon: _enumByName(
      DeviceIcon.values,
      stored[SettingKeys.deviceIcon],
      (DeviceIcon i) => i.name,
    ),
    downloadFolder: stored[SettingKeys.downloadFolder],
    autoAcceptPolicy: _enumByName(
          AutoAcceptPolicy.values,
          stored[SettingKeys.autoAcceptPolicy],
          (AutoAcceptPolicy p) => p.name,
        ) ??
        defaults.autoAcceptPolicy,
    autoAcceptImageMaxMb:
        int.tryParse(stored[SettingKeys.autoAcceptImageMaxMb] ?? '') ??
            defaults.autoAcceptImageMaxMb,
    listenPort:
        int.tryParse(stored[SettingKeys.listenPort] ?? '') ?? defaults.listenPort,
    multicastAddress:
        stored[SettingKeys.multicastAddress] ?? defaults.multicastAddress,
    notificationsEnabled: _bool(
          stored[SettingKeys.notificationsEnabled],
          defaults.notificationsEnabled,
        ),
    launchAtStartup:
        _bool(stored[SettingKeys.launchAtStartup], defaults.launchAtStartup),
    minimizeToTray:
        _bool(stored[SettingKeys.minimizeToTray], defaults.minimizeToTray),
    backgroundService: _bool(
      stored[SettingKeys.backgroundService],
      defaults.backgroundService,
    ),
    languageCode: stored[SettingKeys.languageCode],
  );
}

T? _enumByName<T>(List<T> values, String? stored, String Function(T) name) {
  if (stored == null) {
    return null;
  }
  for (final T value in values) {
    if (name(value) == stored) {
      return value;
    }
  }
  return null;
}

bool _bool(String? stored, bool fallback) {
  return switch (stored) {
    'true' => true,
    'false' => false,
    _ => fallback,
  };
}

final NotifierProvider<SettingsNotifier, AppSettings> settingsProvider =
    NotifierProvider<SettingsNotifier, AppSettings>(SettingsNotifier.new);
