import 'dart:io';

import 'package:feijian/l10n/app_localizations.dart';
import 'package:feijian/ui/widgets/drop_region.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Dragging a file onto the conversation — design.md §6.3.
///
/// The drag arrives on a platform channel rather than through Flutter's hit
/// testing, so there is no pointer to drive here: these tests put the same
/// method calls on `desktop_drop` that the Windows plugin puts there — entered,
/// exited, performOperation — and assert on what the widget does with them.
///
/// What this cannot cover is the drop *itself* — whether Windows delivers a
/// path for a file dragged out of Explorer. Nothing in a widget test can.
void main() {
  const MethodChannel channel = MethodChannel('desktop_drop');
  const StandardMethodCodec codec = StandardMethodCodec();

  /// One call, as the plugin would make it.
  Future<void> send(
    WidgetTester tester,
    String method, [
    Object? arguments,
  ]) async {
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
      channel.name,
      codec.encodeMethodCall(MethodCall(method, arguments)),
      (ByteData? _) {},
    );
  }

  /// A point inside the region, in the channel's coordinates.
  ///
  /// The Windows and Android sides of the plugin divide what they send by the
  /// device pixel ratio before it reaches Flutter, so a test has to multiply by
  /// it to arrive where it means to. The other platforms pass it through — the
  /// same branch `DesktopDrop` takes.
  List<double> inside(WidgetTester tester) {
    final Offset centre = tester.getRect(find.byType(DropRegion)).center;
    final double factor = Platform.isWindows || Platform.isAndroid
        ? tester.view.devicePixelRatio
        : 1;
    return <double>[centre.dx * factor, centre.dy * factor];
  }

  /// Hovers over the region, without letting go.
  Future<void> hover(WidgetTester tester) =>
      send(tester, 'entered', inside(tester));

  /// What the widget was told to send, in order.
  late List<List<String>> handed;

  Future<void> pumpRegion(WidgetTester tester) async {
    handed = <List<String>>[];
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: DropRegion(
            onFiles: handed.add,
            child: const Center(child: Text('conversation')),
          ),
        ),
      ),
    );
  }

  testWidgets('dragging in says where to let go, and leaving takes it away', (
    WidgetTester tester,
  ) async {
    await pumpRegion(tester);
    expect(find.text('Drop to send'), findsNothing);

    await hover(tester);
    await tester.pump();
    expect(find.text('Drop to send'), findsOneWidget);
    expect(
      find.text('conversation'),
      findsOneWidget,
      reason: 'the hint covers the page, it does not replace it',
    );

    await send(tester, 'exited');
    await tester.pump();
    expect(find.text('Drop to send'), findsNothing);
  });

  testWidgets('a drop hands over every path and clears the hint', (
    WidgetTester tester,
  ) async {
    await pumpRegion(tester);
    await hover(tester);
    await tester.pump();

    await send(tester, 'performOperation', <String>[
      r'C:\Users\me\holiday.png',
      r'C:\Users\me\report.pdf',
    ]);
    await tester.pump();

    expect(handed, <List<String>>[
      <String>[r'C:\Users\me\holiday.png', r'C:\Users\me\report.pdf'],
    ]);
    expect(
      find.text('Drop to send'),
      findsNothing,
      reason: 'the drop itself puts the drag back to idle on its way through',
    );
  });

  testWidgets('letting go outside the region sends nothing', (
    WidgetTester tester,
  ) async {
    await pumpRegion(tester);

    // Over the window, but not over this widget — the desktop layout has a
    // device list on the other side of the divider.
    await send(tester, 'entered', <double>[-100, -100]);
    await tester.pump();

    expect(find.text('Drop to send'), findsNothing);
    expect(handed, isEmpty);
  });

  testWidgets('a drag that leaves without dropping is not a send', (
    WidgetTester tester,
  ) async {
    // The user dragged a file over the conversation and thought better of it,
    // or dropped it back on the desktop. Nothing was sent, and sending the path
    // on the way out would be the app acting on a decision nobody made.
    await pumpRegion(tester);

    await hover(tester);
    await tester.pump();
    await send(tester, 'exited');
    await tester.pump();

    expect(handed, isEmpty);
  });
}
