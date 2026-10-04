import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants.dart';
import '../../core/models/peer.dart';
import '../../l10n/app_localizations.dart';
import '../../state/providers.dart';
import '../../state/settings_provider.dart';
import '../theme/device_icons.dart';

/// Settings — design.md §6.4.
///
/// Every control is wired to [settingsProvider] so the shape of the state is
/// settled. Persistence lands in M2 (the `setting` table) and the platform
/// behaviours behind the System toggles land in M5.
class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final AppSettings settings = ref.watch(settingsProvider);
    final SettingsNotifier notifier = ref.read(settingsProvider.notifier);
    final AsyncValue<String> downloadPath = ref.watch(downloadPathProvider);
    final AsyncValue<Peer> self = ref.watch(selfDeviceProvider);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.settingsTitle)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 32),
        children: <Widget>[
          _Section(
            title: l10n.settingsSectionProfile,
            children: <Widget>[
              ListTile(
                title: Text(l10n.settingsDisplayName),
                subtitle: Text(
                  settings.displayName ?? self.valueOrNull?.name ?? '—',
                ),
                trailing: const Icon(Icons.edit_outlined, size: 18),
                onTap: () => _editDisplayName(context, ref, settings),
              ),
              ListTile(
                title: Text(l10n.settingsDeviceIcon),
                subtitle: Text(
                  _iconLabel(
                    l10n,
                    settings.deviceIcon ??
                        self.valueOrNull?.icon ??
                        DeviceIcon.desktop,
                  ),
                ),
                trailing: const Icon(Icons.chevron_right, size: 20),
                onTap: () => _pickDeviceIcon(context, notifier, settings),
              ),
              ListTile(
                title: Text(l10n.settingsAvatar),
                trailing: const Icon(Icons.chevron_right, size: 20),
                onTap: () => _notImplemented(context),
              ),
            ],
          ),
          _Section(
            title: l10n.settingsSectionFiles,
            children: <Widget>[
              ListTile(
                title: Text(l10n.settingsDownloadFolder),
                subtitle: Text(
                  settings.downloadFolder ??
                      downloadPath.valueOrNull ??
                      'Downloads/${l10n.appName}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => _notImplemented(context),
              ),
              ListTile(
                title: Text(l10n.settingsAutoAccept),
                subtitle: Text(_autoAcceptLabel(l10n, settings)),
                onTap: () => _pickAutoAccept(context, notifier, settings),
              ),
            ],
          ),
          _Section(
            title: l10n.settingsSectionNetwork,
            children: <Widget>[
              ListTile(
                title: Text(l10n.settingsListenPort),
                subtitle: Text('${settings.listenPort}'),
                onTap: () => _notImplemented(context),
              ),
              ListTile(
                title: Text(l10n.settingsMulticastAddress),
                subtitle: Text(settings.multicastAddress),
                onTap: () => _notImplemented(context),
              ),
              ListTile(
                title: Text(l10n.settingsEnabledInterfaces),
                subtitle: Text(l10n.settingsEnabledInterfacesHint),
                onTap: () => _notImplemented(context),
              ),
            ],
          ),
          _Section(
            title: l10n.settingsSectionNotifications,
            children: <Widget>[
              SwitchListTile(
                title: Text(l10n.settingsNotifications),
                value: settings.notificationsEnabled,
                onChanged: (bool v) =>
                    notifier.update((AppSettings s) => s.copyWith(
                      notificationsEnabled: v,
                    )),
              ),
            ],
          ),
          _Section(
            title: l10n.settingsSectionSystem,
            children: <Widget>[
              SwitchListTile(
                title: Text(l10n.settingsMinimizeToTray),
                value: settings.minimizeToTray,
                onChanged: (bool v) => notifier.update(
                  (AppSettings s) => s.copyWith(minimizeToTray: v),
                ),
              ),
              SwitchListTile(
                title: Text(l10n.settingsLaunchAtStartup),
                value: settings.launchAtStartup,
                onChanged: (bool v) => notifier.update(
                  (AppSettings s) => s.copyWith(launchAtStartup: v),
                ),
              ),
              SwitchListTile(
                title: Text(l10n.settingsBackgroundService),
                subtitle: Text(l10n.settingsBackgroundServiceHint),
                value: settings.backgroundService,
                onChanged: (bool v) => notifier.update(
                  (AppSettings s) => s.copyWith(backgroundService: v),
                ),
              ),
            ],
          ),
          _Section(
            title: l10n.settingsSectionLanguage,
            children: <Widget>[
              ListTile(
                title: Text(l10n.settingsLanguage),
                // Only English ships in v1, but the plumbing (ARB + locale
                // override) is live so adding a language is one file.
                trailing: const Text('English'),
                onTap: () => _notImplemented(context),
              ),
            ],
          ),
          _Section(
            title: l10n.settingsSectionAbout,
            children: <Widget>[
              ListTile(
                title: Text(l10n.settingsVersion),
                trailing: const Text(kAppVersion),
                onTap: () => _notImplemented(context),
              ),
              ListTile(
                title: Text(l10n.settingsProtocolVersion),
                trailing: Text('$kProtocolVersion'),
                onTap: () => _notImplemented(context),
              ),
              ListTile(
                title: Text(l10n.settingsLicenses),
                trailing: const Icon(Icons.chevron_right, size: 20),
                onTap: () => showLicensePage(
                  context: context,
                  applicationName: l10n.appName,
                  applicationVersion: kAppVersion,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _autoAcceptLabel(AppLocalizations l10n, AppSettings settings) {
    return switch (settings.autoAcceptPolicy) {
      AutoAcceptPolicy.askEveryTime => l10n.settingsAutoAcceptOff,
      AutoAcceptPolicy.imagesUnderMb => l10n.settingsAutoAcceptImages(
        settings.autoAcceptImageMaxMb,
      ),
      AutoAcceptPolicy.trustedDevices => l10n.settingsAutoAcceptTrusted,
    };
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
            child: Text(
              title,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                letterSpacing: 0.8,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Card(child: Column(children: children)),
        ],
      ),
    );
  }
}

String _iconLabel(AppLocalizations l10n, DeviceIcon icon) {
  return switch (icon) {
    DeviceIcon.desktop => l10n.deviceIconDesktop,
    DeviceIcon.laptop => l10n.deviceIconLaptop,
    DeviceIcon.phone => l10n.deviceIconPhone,
    DeviceIcon.tablet => l10n.deviceIconTablet,
  };
}

Future<void> _editDisplayName(
  BuildContext context,
  WidgetRef ref,
  AppSettings settings,
) async {
  final AppLocalizations l10n = AppLocalizations.of(context);
  final TextEditingController controller = TextEditingController(
    text: settings.displayName ?? '',
  );

  final String? name = await showDialog<String>(
    context: context,
    builder: (BuildContext dialogContext) => AlertDialog(
      title: Text(l10n.settingsDisplayName),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: InputDecoration(labelText: l10n.settingsDisplayName),
        onSubmitted: (String v) => Navigator.of(dialogContext).pop(v.trim()),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: Text(l10n.actionCancel),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.of(dialogContext).pop(controller.text.trim()),
          child: Text(l10n.actionAdd),
        ),
      ],
    ),
  );

  controller.dispose();

  // Empty input clears the override and falls back to the system hostname.
  if (name != null) {
    ref.read(settingsProvider.notifier).update(
          (AppSettings s) => s.copyWith(displayName: name.isEmpty ? null : name),
        );
  }
}

Future<void> _pickDeviceIcon(
  BuildContext context,
  SettingsNotifier notifier,
  AppSettings settings,
) async {
  final AppLocalizations l10n = AppLocalizations.of(context);
  final DeviceIcon? picked = await showDialog<DeviceIcon>(
    context: context,
    builder: (BuildContext dialogContext) => SimpleDialog(
      title: Text(l10n.settingsDeviceIcon),
      children: <Widget>[
        for (final DeviceIcon icon in DeviceIcon.values)
          SimpleDialogOption(
            onPressed: () => Navigator.of(dialogContext).pop(icon),
            child: Row(
              children: <Widget>[
                Icon(icon.filledGlyph, size: 20),
                const SizedBox(width: 12),
                Text(_iconLabel(l10n, icon)),
              ],
            ),
          ),
      ],
    ),
  );

  if (picked != null) {
    notifier.update((AppSettings s) => s.copyWith(deviceIcon: picked));
  }
}

Future<void> _pickAutoAccept(
  BuildContext context,
  SettingsNotifier notifier,
  AppSettings settings,
) async {
  final AppLocalizations l10n = AppLocalizations.of(context);
  final AutoAcceptPolicy? picked = await showDialog<AutoAcceptPolicy>(
    context: context,
    builder: (BuildContext dialogContext) => SimpleDialog(
      title: Text(l10n.settingsAutoAccept),
      children: <Widget>[
        for (final AutoAcceptPolicy policy in AutoAcceptPolicy.values)
          SimpleDialogOption(
            onPressed: () => Navigator.of(dialogContext).pop(policy),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(
                switch (policy) {
                  AutoAcceptPolicy.askEveryTime => l10n.settingsAutoAcceptOff,
                  AutoAcceptPolicy.imagesUnderMb =>
                    l10n.settingsAutoAcceptImages(settings.autoAcceptImageMaxMb),
                  AutoAcceptPolicy.trustedDevices =>
                    l10n.settingsAutoAcceptTrusted,
                },
              ),
            ),
          ),
      ],
    ),
  );

  if (picked != null) {
    notifier.update((AppSettings s) => s.copyWith(autoAcceptPolicy: picked));
  }
}

void _notImplemented(BuildContext context) {
  final AppLocalizations l10n = AppLocalizations.of(context);
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text('${l10n.notImplementedTitle} — ${l10n.notImplementedBody}'),
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 2),
    ),
  );
}
