import 'package:feijian/l10n/app_localizations.dart';
import 'package:feijian/ui/widgets/offer_listener.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The question §9.2 makes the default — design.md §9.2.
///
/// Asked of the dialog directly rather than through [OfferListener], because
/// what an offer *is* can only be made in `state/transfer_service_test.dart`,
/// over sockets. What is testable here is the part the user actually reads and
/// presses, and it is the part that has to be got right: a dialog whose
/// dismissal was read as a refusal would turn a back gesture into a decision
/// about somebody else's file.
void main() {
  /// A page with one button that asks the question, and shows what came back.
  Future<void> pumpAsker(
    WidgetTester tester, {
    required void Function(bool?) onAnswer,
    int size = 1024,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) => TextButton(
              onPressed: () async {
                onAnswer(
                  await showFileOfferDialog(
                    context: context,
                    peerName: 'Bob-PC',
                    fileName: 'holiday.png',
                    size: size,
                  ),
                );
              },
              child: const Text('ask'),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('the dialog names the sender, the file and its size', (
    WidgetTester tester,
  ) async {
    await pumpAsker(tester, onAnswer: (_) {}, size: 3 * 1024 * 1024);

    await tester.tap(find.text('ask'));
    await tester.pumpAndSettle();

    expect(find.text('Incoming file'), findsOneWidget);
    expect(
      find.text('Bob-PC wants to send you holiday.png (3.0 MB)'),
      findsOneWidget,
      reason: 'a size in binary units, the same number the card will show',
    );
    expect(find.text('Accept'), findsOneWidget);
    expect(find.text('Decline'), findsOneWidget);
  });

  testWidgets('accepting answers true', (WidgetTester tester) async {
    bool? answer;
    await pumpAsker(tester, onAnswer: (bool? value) => answer = value);

    await tester.tap(find.text('ask'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Accept'));
    await tester.pumpAndSettle();

    expect(answer, isTrue);
  });

  testWidgets('declining answers false', (WidgetTester tester) async {
    bool? answer;
    await pumpAsker(tester, onAnswer: (bool? value) => answer = value);

    await tester.tap(find.text('ask'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Decline'));
    await tester.pumpAndSettle();

    expect(answer, isFalse);
  });

  testWidgets('dismissing answers nothing at all', (WidgetTester tester) async {
    // Not false. A back gesture, or a tap outside, is the user looking away
    // from the question — and reading it as "no" would refuse a file on the
    // sender's behalf over a mis-tap, with a `file_reject` to match.
    bool? answer = true;
    await pumpAsker(tester, onAnswer: (bool? value) => answer = value);

    await tester.tap(find.text('ask'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();

    expect(find.text('Incoming file'), findsNothing);
    expect(answer, isNull);
  });
}
