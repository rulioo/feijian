import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'l10n/app_localizations.dart';
import 'state/settings_provider.dart';
import 'ui/pages/chat_page.dart';
import 'ui/pages/devices_page.dart';
import 'ui/theme/app_theme.dart';
import 'ui/ui_constants.dart';
import 'ui/widgets/discovery_lifecycle.dart';
import 'ui/widgets/message_chime.dart';
import 'ui/widgets/offer_listener.dart';
import 'ui/widgets/tray_lifecycle.dart';

class FeijianApp extends ConsumerWidget {
  const FeijianApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppSettings settings = ref.watch(settingsProvider);

    // Wrapped around the whole app rather than the devices page: being away is
    // a property of the process, not of whichever page happens to be on top.
    // `MessageChime` and `DiscoveryLifecycle` belong here for the same reason.
    return MessageChime(
      child: DiscoveryLifecycle(
        child: MaterialApp(
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
          // `TrayLifecycle` sits here rather than around the whole app — one
          // level further out and `AppLocalizations.of` in its menu labels
          // would throw, because `MaterialApp` is what provides
          // `Localizations` and a widget above it has none. Still outside the
          // navigator, which is the part that matters: the window is revealed
          // before a dialog can be raised on it (§7.2).
          builder: (BuildContext context, Widget? child) =>
              TrayLifecycle(child: child ?? const SizedBox.shrink()),
          // Inside the navigator, so an offer can put a dialog on screen from
          // wherever the user happens to be (§9.2).
          home: const OfferListener(child: HomeShell()),
        ),
      ),
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
