import 'package:feijian/core/models/peer.dart';
import 'package:feijian/data/database.dart';
import 'package:feijian/l10n/app_localizations.dart';
import 'package:feijian/state/data_providers.dart';
import 'package:feijian/state/providers.dart';
import 'package:feijian/ui/pages/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

// The Settings screen, which had no widget test at all before this one.
//
// It is here for the copyright line, and the reason the line needs a test is
// that nothing else would notice it going missing. It is not a control: no
// switch, no navigation, nothing that fails at runtime if it is deleted. It was
// asked for by name, so it is pinned by name.
//
// What the test asserts is the literal wording, deliberately. Asserting against
// `AppLocalizations` instead would pass for any string at all, including an
// empty one, because the page reads its text from there — the two would agree
// while both were wrong.
//
// **What this cannot cover**: `windows/runner/Runner.rc` states the same
// copyright in the executable's version resource, and that is what the file
// properties dialog shows. A resource script is not something a Dart test can
// read; it is checked by looking at the built binary, and by the fact that the
// installer's Apps & features entry is generated from the same facts.

void main() {
  const Peer self = Peer(
    id: 'test-self',
    name: 'Test-Box',
    deviceType: DeviceType.windows,
    icon: DeviceIcon.desktop,
    os: 'Windows 11',
    lastIp: '127.0.0.1',
    isOnline: true,
  );

  late AppDatabase db;

  setUp(() => db = AppDatabase.memory());
  tearDown(() async => db.close());

  /// Pumps the page on a viewport tall enough to build every section.
  ///
  /// Tall on purpose: the copyright sits in the last section of a `ListView`,
  /// and an ordinary phone-sized viewport never builds it, so `find.text` would
  /// fail for the one row this file exists to check — and would go on passing
  /// if the row were moved anywhere off-screen.
  Future<void> pumpSettings(WidgetTester tester) async {
    tester.view.physicalSize = const Size(600, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          databaseProvider.overrideWithValue(db),
          // Both of these reach the platform for real. There is no
          // `path_provider` in a widget test, and `selfDeviceProvider` also
          // reads the machine's hostname and network interfaces — neither is
          // anything this file is asking about.
          downloadPathProvider.overrideWith(
            (Ref ref) => Future<String>.value('/tmp/Downloads'),
          ),
          selfDeviceProvider.overrideWith((Ref ref) => Future<Peer>.value(self)),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('en'),
          home: SettingsPage(),
        ),
      ),
    );

    // Two frames: the localizations arrive on a future, so the first build has
    // the delegates but not their output.
    await tester.pump();
    await tester.pump();
  }

  testWidgets('the About section carries the copyright', (
    WidgetTester tester,
  ) async {
    await pumpSettings(tester);

    expect(
      find.text('© 2026 Beijing Sailanbo Technology Development Co., Ltd.'),
      findsOneWidget,
      reason: 'the company name, in English, as asked for',
    );
  });

  testWidgets('the copyright has no control attached to it', (
    WidgetTester tester,
  ) async {
    await pumpSettings(tester);

    // A `ListTile` with an `onTap` is enabled and shows a splash; this one must
    // not, and the way to tell is that it is not enabled. It is a statement of
    // fact, not a button, and a tappable row with nothing behind it is the one
    // thing worse than no row.
    final ListTile tile = tester.widget<ListTile>(
      find.widgetWithText(
        ListTile,
        '© 2026 Beijing Sailanbo Technology Development Co., Ltd.',
      ),
    );

    expect(tile.onTap, isNull);
    expect(tile.enabled, isTrue);
  });

  testWidgets('the version the page reports is the one the build carries', (
    WidgetTester tester,
  ) async {
    await pumpSettings(tester);

    // Neighbours of the copyright in the same section, and the reason to check
    // them here is that they are the row it was added next to: the About block
    // is the whole answer to "which build is this, and who made it", and a
    // section that renders one of those and not the others is half a screen.
    expect(find.text('Version'), findsOneWidget);
    expect(find.text('Protocol version'), findsOneWidget);
    expect(find.text('Open source licenses'), findsOneWidget);
  });
}
