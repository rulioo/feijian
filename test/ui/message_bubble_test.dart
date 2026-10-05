import 'dart:convert';
import 'dart:io';

import 'package:feijian/core/models/message.dart';
import 'package:feijian/core/models/transfer.dart';
import 'package:feijian/l10n/app_localizations.dart';
import 'package:feijian/ui/widgets/attachment_card.dart';
import 'package:feijian/ui/widgets/attachment_image.dart';
import 'package:feijian/ui/widgets/message_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// One bubble, drawn in each of the shapes §6.3 asks for.
///
/// Against the widget rather than through the page, because what is being
/// tested is the *decision* — a card here, a picture there, which buttons this
/// state offers — and the page would only add a database and a provider scope
/// between the test and the thing it is asking about.
void main() {
  Attachment attachment({
    String fileName = 'holiday.png',
    int size = 1024,
    int transferred = 0,
    TransferState state = TransferState.done,
    String? mime,
    String? localPath,
  }) {
    return Attachment(
      id: 'att-1',
      messageId: 'msg-1',
      fileName: fileName,
      size: size,
      mime: mime,
      state: state,
      transferred: transferred,
      localPath: localPath,
    );
  }

  /// A one-pixel PNG, so the path a bubble points at is a real file.
  ///
  /// It is never decoded here: `Image.file` resolves through the real event
  /// loop and a widget test runs in a fake-async zone, so the load neither
  /// finishes nor fails and the image has no size for the whole test. That is
  /// fine for everything below except the hit test, which is why the tap is
  /// asked about at the widget rather than through a finger.
  late Directory scratch;
  late String realPng;

  setUp(() {
    scratch = Directory.systemTemp.createTempSync('feijian-bubble-test');
    realPng = '${scratch.path}${Platform.pathSeparator}holiday.png';
    File(realPng).writeAsBytesSync(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDw'
        'AChwGA60e6kgAAAABJRU5ErkJggg==',
      ),
    );
  });

  tearDown(() {
    try {
      scratch.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows will not remove a file whose read is still outstanding. It is
      // a temporary directory; the operating system gets it eventually.
    }
  });

  /// A file message with no body, which is what the repository writes.
  Message message({
    String? text,
    MessageStatus status = MessageStatus.delivered,
    MessageDirection direction = MessageDirection.outgoing,
  }) {
    return Message(
      id: 'msg-1',
      peerId: 'peer-bob',
      direction: direction,
      type: MessageType.file,
      status: status,
      createdAt: DateTime(2026, 1, 2, 9, 30),
      text: text,
    );
  }

  Future<void> pumpBubble(
    WidgetTester tester, {
    required Message message,
    Attachment? attachment,
    VoidCallback? onOpen,
    VoidCallback? onSaveAs,
    VoidCallback? onCancel,
    VoidCallback? onAccept,
    VoidCallback? onDecline,
    VoidCallback? onOpenImage,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: MessageBubble(
            message: message,
            attachment: attachment,
            onRetry: () {},
            onOpen: onOpen,
            onSaveAs: onSaveAs,
            onCancel: onCancel,
            onAccept: onAccept,
            onDecline: onDecline,
            onOpenImage: onOpenImage,
          ),
        ),
      ),
    );
  }

  testWidgets('a text message is just its text', (WidgetTester tester) async {
    await pumpBubble(tester, message: message(text: 'hello'));
    expect(find.text('hello'), findsOneWidget);
    expect(find.byType(AttachmentCard), findsNothing);
    expect(find.byType(AttachmentImage), findsNothing);
  });

  testWidgets('a file message draws a card, not a missing body', (
    WidgetTester tester,
  ) async {
    await pumpBubble(tester, message: message(), attachment: attachment());
    expect(find.byType(AttachmentCard), findsOneWidget);
    expect(find.text('holiday.png'), findsOneWidget);
    // 1024 bytes, binary units — the number a file manager would show.
    expect(find.textContaining('1.0 KB'), findsOneWidget);
  });

  testWidgets('a finished picture is drawn as a picture', (
    WidgetTester tester,
  ) async {
    await pumpBubble(
      tester,
      message: message(),
      attachment: attachment(localPath: '/nowhere/holiday.png'),
    );
    expect(find.byType(AttachmentImage), findsOneWidget);
    expect(find.byType(AttachmentCard), findsNothing);
  });

  testWidgets('a picture still arriving is a card with a bar, not a photo', (
    WidgetTester tester,
  ) async {
    // A quarter-painted thumbnail reads as a corrupt photo, and the card says
    // "25%" and offers a cancel — which is the truth about a file that is not
    // here yet.
    await pumpBubble(
      tester,
      message: message(),
      attachment: attachment(
        state: TransferState.transferring,
        transferred: 256,
        localPath: '/nowhere/holiday.png',
      ),
    );
    expect(find.byType(AttachmentImage), findsNothing);
    expect(find.byType(AttachmentCard), findsOneWidget);
  });

  testWidgets('a document is a card even once it has arrived', (
    WidgetTester tester,
  ) async {
    await pumpBubble(
      tester,
      message: message(),
      attachment: attachment(
        fileName: 'report.pdf',
        mime: 'application/pdf',
        localPath: '/nowhere/report.pdf',
      ),
    );
    expect(find.byType(AttachmentImage), findsNothing);
    expect(find.byType(AttachmentCard), findsOneWidget);
  });

  group('the bar says how far it has got', () {
    testWidgets('a transfer in flight shows one at its fraction', (
      WidgetTester tester,
    ) async {
      await pumpBubble(
        tester,
        message: message(),
        attachment: attachment(
          size: 1000,
          transferred: 250,
          state: TransferState.transferring,
        ),
      );
      final LinearProgressIndicator bar = tester.widget(
        find.byType(LinearProgressIndicator),
      );
      expect(bar.value, 0.25);
      expect(find.text('25%'), findsOneWidget);
    });

    testWidgets('a transfer that has not been agreed to shows none', (
      WidgetTester tester,
    ) async {
      // A bar over an offer nobody has answered sits at zero and reads as
      // stuck, which is the opposite of what is happening.
      await pumpBubble(
        tester,
        message: message(),
        attachment: attachment(state: TransferState.offered),
      );
      expect(find.byType(LinearProgressIndicator), findsNothing);
    });

    testWidgets('a finished file shows none either', (
      WidgetTester tester,
    ) async {
      await pumpBubble(tester, message: message(), attachment: attachment());
      expect(find.byType(LinearProgressIndicator), findsNothing);
    });
  });

  group('each state offers only what applies to it', () {
    testWidgets('open is offered when the caller can open', (
      WidgetTester tester,
    ) async {
      await pumpBubble(
        tester,
        message: message(),
        attachment: attachment(),
        onOpen: () {},
      );
      expect(find.text('Open'), findsOneWidget);
      expect(find.text('Save as...'), findsNothing);
    });

    testWidgets('save-as is offered alongside it', (WidgetTester tester) async {
      await pumpBubble(
        tester,
        message: message(),
        attachment: attachment(),
        onOpen: () {},
        onSaveAs: () {},
      );
      expect(find.text('Open'), findsOneWidget);
      expect(find.text('Save as...'), findsOneWidget);
    });

    testWidgets('an unanswered offer asks for an answer instead', (
      WidgetTester tester,
    ) async {
      // Open on a file that is only an offer is a button that opens nothing.
      await pumpBubble(
        tester,
        message: message(),
        attachment: attachment(state: TransferState.offered),
        onOpen: () {},
        onSaveAs: () {},
        onAccept: () {},
        onDecline: () {},
      );
      expect(find.text('Accept'), findsOneWidget);
      expect(find.text('Decline'), findsOneWidget);
      expect(find.text('Open'), findsNothing);
      expect(find.text('Save as...'), findsNothing);
    });

    testWidgets('cancel is offered alongside whatever else applies', (
      WidgetTester tester,
    ) async {
      await pumpBubble(
        tester,
        message: message(),
        attachment: attachment(state: TransferState.transferring),
        onCancel: () {},
      );
      expect(find.text('Cancel'), findsOneWidget);
    });

    testWidgets('nothing is offered when the caller offers nothing', (
      WidgetTester tester,
    ) async {
      await pumpBubble(tester, message: message(), attachment: attachment());
      expect(find.byType(TextButton), findsNothing);
    });
  });

  testWidgets('the buttons call back', (WidgetTester tester) async {
    int opened = 0;
    int cancelled = 0;
    await pumpBubble(
      tester,
      message: message(),
      attachment: attachment(),
      onOpen: () => opened++,
      onCancel: () => cancelled++,
    );

    await tester.tap(find.text('Open'));
    await tester.tap(find.text('Cancel'));
    expect(opened, 1);
    expect(cancelled, 1);
  });

  testWidgets('tapping a picture opens the viewer', (
    WidgetTester tester,
  ) async {
    int taps = 0;
    await pumpBubble(
      tester,
      message: message(),
      attachment: attachment(localPath: realPng),
      onOpenImage: () => taps++,
    );

    expect(find.byType(AttachmentImage), findsOneWidget);
    // The thumbnail's own gesture handler, which is the wiring under test. The
    // finger is not used because the image never decodes here — see [realPng] —
    // and a zero-sized box is a box no finger can land on. Whether Flutter
    // routes a touch into a `GestureDetector` is the framework's business; that
    // this widget's `onTap` is the callback the bubble was given is not.
    tester
        .widget<GestureDetector>(
          find.descendant(
            of: find.byType(AttachmentImage),
            matching: find.byType(GestureDetector),
          ),
        )
        .onTap!();

    expect(taps, 1);
  });

  testWidgets('a caption sits under the picture', (WidgetTester tester) async {
    await pumpBubble(
      tester,
      message: message(text: 'from the trip'),
      attachment: attachment(localPath: '/nowhere/holiday.png'),
    );
    expect(find.byType(AttachmentImage), findsOneWidget);
    expect(find.text('from the trip'), findsOneWidget);
  });

  testWidgets('a failed file still shows its card and the retry icon', (
    WidgetTester tester,
  ) async {
    // The message row goes `failed` when the transfer ends without the file
    // (§5.1), and the card has to keep saying what it was.
    await pumpBubble(
      tester,
      message: message(status: MessageStatus.failed),
      attachment: attachment(state: TransferState.failed),
    );
    expect(find.byType(AttachmentCard), findsOneWidget);
    expect(find.text('Failed'), findsOneWidget);
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
  });
}
