import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'l10n/app_localizations.dart';
import 'state/settings_provider.dart';
import 'ui/pages/chat_page.dart';
import 'ui/pages/devices_page.dart';
import 'ui/theme/app_theme.dart';
import 'ui/ui_constants.dart';

class FeijianApp extends ConsumerWidget {
  const FeijianApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppSettings settings = ref.watch(settingsProvider);

    return MaterialApp(
      onGenerateTitle: (BuildContext context) =>
          AppLocalizations.of(context).appName,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ThemeMode.system,
      // Plumbing for the language override in settings — null follows the
      // system locale (design.md §8.2).
      locale: settings.languageCode == null
          ? null
          : Locale(settings.languageCode!),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const HomeShell(),
    );
  }
}

/// Picks the master/detail or single-pane shell — design.md §6.1.
///
/// Both layouts are built from the same two pages; only the composition
/// differs, so there is no duplicated UI between desktop and phone.
class HomeShell extends StatelessWidget {
  const HomeShell({super.key});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        if (constraints.maxWidth < kTwoPaneMinWidth) {
          return const DevicesPage();
        }
        return const Row(
          children: <Widget>[
            SizedBox(width: kDevicePaneWidth, child: DevicesPage()),
            VerticalDivider(width: 1),
            Expanded(child: ChatPage()),
          ],
        );
      },
    );
  }
}
