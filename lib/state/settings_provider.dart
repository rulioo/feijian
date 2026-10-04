import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/constants.dart';
import '../core/models/peer.dart';

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

/// User-configurable settings.
///
/// M0 holds these in memory only. **TODO(M2): persist to the `setting` table**
/// (design.md §5.1) and load at startup — right now every value resets when the
/// app restarts.
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
  @override
  AppSettings build() => const AppSettings();

  void update(AppSettings Function(AppSettings current) change) {
    state = change(state);
  }
}

final NotifierProvider<SettingsNotifier, AppSettings> settingsProvider =
    NotifierProvider<SettingsNotifier, AppSettings>(SettingsNotifier.new);
