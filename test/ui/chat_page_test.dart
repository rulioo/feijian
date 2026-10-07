import 'dart:async';
import 'dart:io';

import 'package:feijian/core/discovery/peer_source.dart';
import 'package:feijian/core/models/manifest_entry.dart';
import 'package:feijian/core/models/message.dart';
import 'package:feijian/core/models/peer.dart';
import 'package:feijian/core/models/transfer.dart';
import 'package:feijian/core/protocol/payloads.dart';
import 'package:feijian/core/transport/connection_manager.dart';
import 'package:feijian/data/database.dart';
import 'package:feijian/data/repository/chat_repository.dart';
import 'package:feijian/data/repository/peer_repository.dart';
import 'package:feijian/data/repository/transfer_repository.dart';
import 'package:feijian/l10n/app_localizations.dart';
import 'package:feijian/platform/file_chooser.dart';
import 'package:feijian/state/chat_provider.dart';
import 'package:feijian/state/data_providers.dart';
import 'package:feijian/state/lan_provider.dart';
import 'package:feijian/state/lan_service.dart';
import 'package:feijian/state/providers.dart';
import 'package:feijian/state/transfer_provider.dart';
import 'package:feijian/state/transfer_service.dart';
import 'package:feijian/ui/pages/chat_page.dart';
import 'package:feijian/ui/widgets/attachment_card.dart';
import 'package:feijian/ui/widgets/attachment_image.dart';
import 'package:feijian/ui/widgets/folder_card.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// The chat page against a real database — design.md §6.3.
///
/// No sockets and no fake clock: the page is driven the way a user drives it
/// (typing, tapping send, scrolling up) and asserted against what ends up in
/// the database. The one thing missing is a peer on the other end, which is why
/// every message here stays `pending` — that is also the state the page shows
/// when the peer is away, so it is worth rendering.
///
/// The wire itself is covered by `state/lan_service_test.dart`, over real
/// sockets between two real services. Widget tests cannot do that: they run
/// inside a fake-async zone, where awaiting a real socket bind never completes.
void main() {
  const Peer bob = Peer(
    id: 'peer-bob',
    name: 'Bob-PC',
    deviceType: DeviceType.android,
    icon: DeviceIcon.phone,
    os: 'Android 14',
    lastIp: '127.0.0.1',
    isOnline: true,
  );

  late AppDatabase db;
  late ChatRepository chat;
  late PeerRepository peers;
  late _NoPeers discovery;
  late LanService service;
  late _SpyTransfers transfers;

  /// Where the files these tests send actually live.
  ///
  /// Real files, because the engine reads a real length off one before it
  /// writes the row — a path that only exists as a string would be refused
  /// before anything reached the page.
  late Directory scratch;

  /// The dialogs the page is given, so the two directions can be answered
  /// without a window.
  late _FakeChooser chooser;

  setUp(() {
    db = AppDatabase.memory();
    chat = ChatRepository(db);
    peers = PeerRepository(db);
    discovery = _NoPeers();
    // Constructed but never started: no listener, no port, no sockets — and
    // still the same object the app sends through, so `sendText` writes a real
    // row and finds that there is nowhere to put it on the wire.
    service = _QuietService(
      manager: ConnectionManager(
        port: 0,
        selfHello: const HelloPayload(
          role: ConnectionRole.control,
          deviceId: 'test-self',
          name: 'Test-Box',
          deviceType: DeviceType.windows,
          icon: DeviceIcon.desktop,
          port: 0,
          version: 1,
        ),
      ),
      discovery: discovery,
      chat: chat,
      peers: peers,
    );
    // Constructed but never started, so [TransferService.start] does not run
    // its sweep. The sweep is right in production — a row left saying
    // `transferring` by a killed process would otherwise show a bar stuck at
    // 40% forever — but it would rewrite every row these tests seed, and the
    // states being tested here are the ones a *live* transfer is in.
    // `state/transfer_service_test.dart` covers the sweep against real rows.
    transfers = _SpyTransfers(
      manager: service.manager,
      transfers: TransferRepository(db),
      downloadDirectory: () async => Directory.systemTemp,
    );
    scratch = Directory.systemTemp.createTempSync('feijian-chat-');
    chooser = _FakeChooser();
  });

  tearDown(() async {
    await transfers.dispose();
    await service.dispose();
    await db.close();
    try {
      scratch.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows will not remove a file whose read is still outstanding, and the
      // engine may have one on a file it just refused. The directory is in the
      // system temp folder and its name is unique to this run.
    }
  });

  /// A real file of [bytes] bytes, and its path.
  String makeFile(String name, {int bytes = 2048}) {
    final File file = File(
      '${scratch.path}${Platform.pathSeparator}$name',
    )..writeAsBytesSync(List<int>.filled(bytes, 0x41));
    return file.path;
  }

  /// Lets the engine's filesystem work finish, then rebuilds the page.
  ///
  /// A widget test runs inside a fake-async zone, and the first thing
  /// [TransferService.sendFile] does with a file is `await file.length()` — a
  /// real stat that never completes in one. `runAsync` steps outside the zone
  /// for long enough for it to come back; the continuations it leaves behind are
  /// fake-async microtasks, which the pumps after it flush.
  ///
  /// Only needed where a *real* file is really sent. A test that only asserts on
  /// what the page did with a path — a folder refused, an empty result — does
  /// not reach the engine and does not need this.
  ///
  /// [offers] is how many files the page is about to hand over. They go one at a
  /// time — the next `sendFile` does not start until the last has returned — so
  /// a drop of two files needs two turns outside the zone, not one long one.
  ///
  /// [rounds] overrides that count for work that is a *chain* rather than a
  /// step. A folder is one: [TransferService.sendFolder] walks the tree with
  /// `directory.list` and stats every entry of it before it writes a row, and
  /// each of those is its own completion on the real event loop — four turns for
  /// a folder holding a single file, and the folder tests ask for more than that
  /// so that the number is a margin rather than an exact fit.
  Future<void> settleFileWork(
    WidgetTester tester, {
    int offers = 1,
    int? rounds,
  }) async {
    for (int i = 0; i < (rounds ?? offers); i++) {
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
    }
    for (int i = 0; i < 8; i++) {
      await tester.pump();
    }
  }

  /// [manual] puts the peer in the set the "Remove device" action is keyed on —
  /// the stand-in for what `PeerTable._manual` would say about a device the user
  /// typed in by hand.
  /// [transferEngine] false models the app with no engine up at all — the
  /// provider never resolves, which is what a failed listen port looks like from
  /// the page's side.
  Future<void> pumpChat(
    WidgetTester tester, {
    bool manual = false,
    bool transferEngine = true,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          databaseProvider.overrideWithValue(db),
          selectedPeerProvider.overrideWith((Ref ref) => bob),
          discoveredPeersProvider.overrideWith(
            (Ref ref) => Stream<List<Peer>>.value(const <Peer>[bob]),
          ),
          lanServiceProvider.overrideWith((Ref ref) => service),
          transferServiceProvider.overrideWith(
            (Ref ref) => transferEngine
                ? Future<TransferService>.value(transfers)
                : Completer<TransferService>().future,
          ),
          fileChooserProvider.overrideWith((Ref ref) => chooser),
          if (manual)
            manualPeerIdsProvider.overrideWithValue(const <String>{'peer-bob'}),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: const ChatPage(),
        ),
      ),
    );
    // Several frames, because that is how many things have to land before the
    // page is what a user would see: the localizations load asynchronously, the
    // history query has to come back, and the first build only learns which peer
    // this is — the draft is seeded on the build after the data arrives.
    for (int i = 0; i < 6; i++) {
      await tester.pump();
    }
  }

  /// Writes a message straight to the database, in the order given.
  Future<void> seed(
    String msgId,
    String text, {
    required bool mine,
    required int minute,
    MessageStatus? status,
  }) async {
    final DateTime at = DateTime(2026, 1, 2, 9, minute);
    if (mine) {
      await chat.saveOutgoing(
          msgId: msgId, peerId: bob.id, text: text, now: at);
      if (status != null) {
        await chat.setStatus(msgId, status, deliveredAt: at);
      }
    } else {
      await chat.storeIncoming(
        msgId: msgId,
        peerId: bob.id,
        text: text,
        now: at,
      );
    }
  }

  testWidgets('renders the history oldest first with each state', (
    WidgetTester tester,
  ) async {
    await seed('in-1', '你好 Bob', mine: false, minute: 0);
    await seed(
      'out-1',
      'Hi there',
      mine: true,
      minute: 1,
      status: MessageStatus.delivered,
    );
    await seed('out-2', 'Are you there?', mine: true, minute: 2);

    await pumpChat(tester);

    expect(find.text('你好 Bob'), findsOneWidget);
    expect(find.text('Hi there'), findsOneWidget);
    expect(find.text('Are you there?'), findsOneWidget);

    // Read top to bottom, so the oldest message is the highest on screen.
    final double first = tester.getCenter(find.text('你好 Bob')).dy;
    final double last = tester.getCenter(find.text('Are you there?')).dy;
    expect(first, lessThan(last));

    // State is the sender's business: two ticks for the message the peer
    // acknowledged, a clock for the one still owed, and nothing at all on the
    // message that arrived.
    expect(find.byIcon(Icons.done_all), findsOneWidget);
    expect(find.byIcon(Icons.schedule), findsOneWidget);
    expect(find.byIcon(Icons.check), findsNothing);
    expect(find.byIcon(Icons.error_outline), findsNothing);
  });

  testWidgets('sends what was typed and clears the composer', (
    WidgetTester tester,
  ) async {
    await pumpChat(tester);

    await tester.enterText(find.byType(TextField), 'Hello Bob');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.send));
    await tester.pump();
    await tester.pump();

    final List<Message> rows = await chat.page(bob.id);
    expect(rows.single.text, 'Hello Bob');
    expect(rows.single.direction, MessageDirection.outgoing);
    expect(
      rows.single.status,
      MessageStatus.pending,
      reason: 'stored and owed — nobody is on the other end to acknowledge it',
    );
    expect(find.text('Hello Bob'), findsOneWidget, reason: 'and on screen');

    final TextField composer = tester.widget<TextField>(find.byType(TextField));
    expect(composer.controller?.text, isEmpty);
  });

  testWidgets('refuses to send whitespace', (WidgetTester tester) async {
    await pumpChat(tester);

    await tester.enterText(find.byType(TextField), '   ');
    await tester.pump();

    // The button is disabled rather than silently doing nothing, and the row
    // never reaches the database.
    final IconButton button = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.send),
    );
    expect(button.onPressed, isNull);
    expect(await chat.page(bob.id), isEmpty);
  });

  testWidgets('restores the draft the user left behind', (
    WidgetTester tester,
  ) async {
    await chat.setDraft(bob.id, 'half a thought');
    await pumpChat(tester);

    final ProviderContainer container = ProviderScope.containerOf(
      tester.element(find.byType(ChatPage)),
      listen: false,
    );
    expect(container.read(chatProvider(bob.id)).requireValue.draft,
        'half a thought');

    final TextField composer = tester.widget<TextField>(find.byType(TextField));
    expect(composer.controller?.text, 'half a thought');
  });

  testWidgets('a failed message can be tried again', (
    WidgetTester tester,
  ) async {
    await seed('out-1', 'never arrived', mine: true, minute: 0);
    await chat.setStatus('out-1', MessageStatus.failed, retryCount: 3);
    await pumpChat(tester);

    expect(find.byIcon(Icons.error_outline), findsOneWidget);

    await tester.tap(find.byIcon(Icons.error_outline));
    await tester.pump();
    await tester.pump();

    final List<Message> rows = await chat.page(bob.id);
    expect(
      rows.single.status,
      MessageStatus.pending,
      reason: 'back in the queue, with its retries cleared',
    );
    expect(rows.single.retryCount, 0);
    // The bubble followed the database without a reload of the page.
    expect(find.byIcon(Icons.schedule), findsOneWidget);
    expect(find.byIcon(Icons.error_outline), findsNothing);
  });

  testWidgets('scrolling to the top loads the page before it', (
    WidgetTester tester,
  ) async {
    // One page is 50; 60 messages means the first page comes back full and the
    // page believes there is more.
    for (int i = 0; i < 60; i++) {
      await seed('msg-$i', 'message $i', mine: false, minute: i);
    }

    await pumpChat(tester);

    // Asked of the loaded history rather than of the widgets on screen: a
    // `ListView.builder` only builds what is near the viewport, so counting
    // bubbles would measure the screen and not the page.
    final ProviderContainer container = ProviderScope.containerOf(
      tester.element(find.byType(ChatPage)),
      listen: false,
    );
    ChatState loaded() => container.read(chatProvider(bob.id)).requireValue;

    expect(loaded().messages.length, ChatRepository.kPageSize);
    expect(loaded().messages.first.id, 'msg-10', reason: 'oldest of the page');
    expect(loaded().hasMore, isTrue);
    expect(find.text('message 59'), findsOneWidget,
        reason: 'newest, at the bottom');

    // Reversed list: dragging downwards moves towards the top of the history.
    // The distance is deliberately larger than the history is tall — the drag
    // stops at the end of the list, and the point is to arrive there.
    await tester.drag(find.byType(ListView), const Offset(0, 4000));
    for (int i = 0; i < 4; i++) {
      await tester.pump();
    }

    expect(loaded().messages.length, 60);
    expect(loaded().messages.first.id, 'msg-0');
    expect(
      loaded().hasMore,
      isFalse,
      reason: 'a short page is how the end of the history is known',
    );
    expect(
      find.text('message 0'),
      findsNothing,
      reason: 'appending at the far end must not move what the user is reading',
    );

    // Keep going: the loaded page is up there, and the user is still one drag
    // short of it.
    await tester.drag(find.byType(ListView), const Offset(0, 1000));
    for (int i = 0; i < 4; i++) {
      await tester.pump();
    }
    expect(find.text('message 0'), findsOneWidget,
        reason: 'and it is reachable');
  });

  // --- The message menu, §6.3 ----------------------------------------------

  testWidgets('long-pressing a message offers copy and delete', (
    WidgetTester tester,
  ) async {
    await seed('in-1', '你好 Bob', mine: false, minute: 0);
    await pumpChat(tester);

    await tester.longPress(find.text('你好 Bob'));
    await tester.pumpAndSettle();

    expect(find.text('Copy text'), findsOneWidget);
    expect(find.text('Delete for me'), findsOneWidget);
  });

  testWidgets('right-click opens the same menu', (WidgetTester tester) async {
    // The desktop trigger. A phone has no right button and a desktop user does
    // not long-press, so both paths have to lead to the one menu.
    await seed('in-1', 'Hi there', mine: false, minute: 0);
    await pumpChat(tester);

    await tester.tapAt(
      tester.getCenter(find.text('Hi there')),
      buttons: kSecondaryButton,
    );
    await tester.pumpAndSettle();

    expect(find.text('Copy text'), findsOneWidget);
  });

  testWidgets('copying puts the whole message on the clipboard', (
    WidgetTester tester,
  ) async {
    final List<MethodCall> platform = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall call) async {
        platform.add(call);
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    await seed('in-1', '第二条 🙂', mine: false, minute: 0);
    await pumpChat(tester);

    await tester.longPress(find.text('第二条 🙂'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy text'));
    // Not `pumpAndSettle`: that runs the confirmation's two seconds out and
    // asserts against a SnackBar that has already gone.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final MethodCall written = platform.singleWhere(
      (MethodCall call) => call.method == 'Clipboard.setData',
    );
    expect(
      (written.arguments as Map<Object?, Object?>)['text'],
      '第二条 🙂',
      reason: 'emoji and all, exactly as it was rendered',
    );
  });

  testWidgets('deleting removes the message here and nowhere else', (
    WidgetTester tester,
  ) async {
    await seed('in-1', 'keep me', mine: false, minute: 0);
    await seed('in-2', 'delete me', mine: false, minute: 1);
    await pumpChat(tester);

    await tester.longPress(find.text('delete me'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete for me'));
    await tester.pumpAndSettle();

    expect(find.text('delete me'), findsNothing);
    expect(find.text('keep me'), findsOneWidget);
    final List<Message> rows = await chat.page(bob.id);
    expect(
      rows.single.text,
      'keep me',
      reason: 'a local record, so the row goes and nothing is sent about it',
    );
  });

  testWidgets('clearing the history asks first, then empties it', (
    WidgetTester tester,
  ) async {
    await seed('in-1', 'one', mine: false, minute: 0);
    await seed('out-1', 'two', mine: true, minute: 1);
    await pumpChat(tester);

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clear history'));
    await tester.pumpAndSettle();

    // Asking is the whole point: nothing is gone while the dialog is up.
    expect(await chat.page(bob.id), hasLength(2));

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(
      await chat.page(bob.id),
      hasLength(2),
      reason: 'backing out changes nothing',
    );

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clear history'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(await chat.page(bob.id), isEmpty);
    expect(
      find.text('No messages yet. Say hello to Bob-PC.'),
      findsOneWidget,
      reason: 'the empty state, and the device is still selected',
    );
  });

  testWidgets('device info shows the fields that identify a device', (
    WidgetTester tester,
  ) async {
    await pumpChat(tester);

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Device info'));
    await tester.pumpAndSettle();

    expect(
      find.text('peer-bob'),
      findsOneWidget,
      reason: 'shown in full — it is what tells two same-named devices apart',
    );
    expect(
      find.text('127.0.0.1:24250'),
      findsOneWidget,
      reason: 'and the default port when the peer never announced one',
    );
    expect(find.text('Android'), findsOneWidget);
    expect(find.text('Android 14'), findsOneWidget);
  });

  testWidgets('a hand-added device can be removed, and asks first', (
    WidgetTester tester,
  ) async {
    await pumpChat(tester, manual: true);

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    expect(find.text('Remove device'), findsOneWidget);

    await tester.tap(find.text('Remove device'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('The conversation stays on this device'),
      findsOneWidget,
      reason: 'removing a device is not deleting a conversation, and saying so '
          'is what keeps the two from looking like the same action',
    );

    // The dialog's title and its confirm button carry the same words, so the
    // button is picked out by type rather than by text.
    await tester.tap(find.widgetWithText(TextButton, 'Remove device'));
    await tester.pumpAndSettle();

    expect(discovery.forgotten, <String>['peer-bob']);
    expect(find.text('Removed Bob-PC'), findsOneWidget);
  });

  testWidgets('an announced device is not offered removal', (
    WidgetTester tester,
  ) async {
    // Its presence on the list is the network's decision, not the user's, so
    // there is nothing for this action to do: remove it and the next announce
    // puts it straight back.
    await pumpChat(tester);

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();

    expect(find.text('Device info'), findsOneWidget);
    expect(find.text('Remove device'), findsNothing);
  });

  /// Writes a file message the way the transfer layer writes one, so the page
  /// has to find it the way the page finds it — one query for the whole page,
  /// keyed by message id (§6.3).
  Future<Transfer> seedFile(
    String xferId, {
    String fileName = 'holiday.png',
    int size = 2048,
    String? mime = 'image/png',
    bool mine = false,

    /// Where the file is on this device. Only a send has one, and only a test
    /// that is going to *retry* it needs a path that leads somewhere real: the
    /// engine reads a length off it before it offers anything.
    String? localPath,
    int minute = 0,
  }) {
    final TransferRepository transfers = TransferRepository(db);
    final DateTime at = DateTime(2026, 1, 2, 9, minute);
    return mine
        ? transfers.beginOutgoing(
            xferId: xferId,
            peerId: bob.id,
            fileName: fileName,
            totalSize: size,
            mime: mime,
            localPath: localPath,
            now: at,
          )
        : transfers.beginIncoming(
            xferId: xferId,
            peerId: bob.id,
            fileName: fileName,
            totalSize: size,
            mime: mime,
            now: at,
          );
  }

  testWidgets('a file message renders as a card with its name and size', (
    WidgetTester tester,
  ) async {
    await seed('in-1', 'look at this', mine: false, minute: 0);
    await seedFile('xfer-1', minute: 1);

    await pumpChat(tester);

    expect(find.text('look at this'), findsOneWidget);
    expect(find.byType(AttachmentCard), findsOneWidget);
    expect(find.text('holiday.png'), findsOneWidget);
    expect(
      find.textContaining('2.0 KB'),
      findsOneWidget,
      reason: 'binary units, so the card agrees with the file manager',
    );
    expect(
      find.text('Waiting for your answer'),
      findsOneWidget,
      reason: 'an offer is a question, and nothing has been received yet',
    );
  });

  testWidgets('a received picture appears the moment its bytes land', (
    WidgetTester tester,
  ) async {
    // The report, on both platforms: the photo arrived and the bubble kept
    // showing a file card, and it turned into a photo only later, on some
    // unrelated refresh. Two halves had to line up and only one did — the
    // ending writes the path onto the **attachment row** (`TransferRepository
    // .finish`), while the value the page folds in is the engine's [Transfer],
    // which has no path field at all. So the row was right and the screen was
    // stale, and nothing short of a re-read could move the bubble.
    final Transfer offer = await seedFile('xfer-1', size: 2048, minute: 0);
    final String landed = makeFile('arrived.png');

    await pumpChat(tester);
    expect(
      find.byType(AttachmentCard),
      findsOneWidget,
      reason: 'a picture still moving is a card, and this one has not moved',
    );

    // The ending, as the engine produces it: the row first, then the event.
    await TransferRepository(db).finish(
      offer.id,
      localPath: landed,
      now: DateTime(2026, 1, 2, 9, 1),
    );
    transfers.emitted.add(
      offer.copyWith(state: TransferState.done, bytesDone: 2048),
    );
    await settleFileWork(tester);

    expect(
      find.byType(AttachmentImage),
      findsOneWidget,
      reason: 'the bytes are here and the path is on the row; the bubble is '
          'what has to catch up',
    );
    expect(find.byType(AttachmentCard), findsNothing);
  });

  testWidgets('a conversation of text has no cards in it', (
    WidgetTester tester,
  ) async {
    await seed('in-1', 'hello', mine: false, minute: 0);
    await seed('out-1', 'hello back', mine: true, minute: 1);

    await pumpChat(tester);

    expect(find.byType(AttachmentCard), findsNothing);
    expect(find.byType(AttachmentImage), findsNothing);
  });

  testWidgets('an unanswered offer asks to be answered', (
    WidgetTester tester,
  ) async {
    await seedFile('xfer-1', mine: false);

    await pumpChat(tester);

    expect(find.text('Accept'), findsOneWidget);
    expect(find.text('Decline'), findsOneWidget);
    expect(
      find.text('Cancel'),
      findsNothing,
      reason: 'Cancel and Decline would be two words for one decision',
    );
    expect(find.text('Open'), findsNothing);
  });

  testWidgets('an offer this device sent offers a cancel instead', (
    WidgetTester tester,
  ) async {
    // The same row state, the other direction. §5.1 gives an attachment no
    // direction of its own, so the only thing telling the two apart is the
    // message's — and getting it wrong would offer the sender a button that
    // answers its own offer.
    await seedFile('xfer-1', mine: true);
    await TransferRepository(db).recordProgress(
      'xfer-1',
      state: TransferState.offered,
      bytesDone: 0,
    );

    await pumpChat(tester);

    expect(find.text('Cancel'), findsOneWidget);
    expect(find.text('Accept'), findsNothing);
    expect(find.text('Decline'), findsNothing);
  });

  testWidgets('a transfer still moving offers a cancel and not an open', (
    WidgetTester tester,
  ) async {
    // Open is offered by the page only once the bytes are here. A card that
    // offered it over a half-written file would be offering to open half a
    // file.
    await seedFile('xfer-1',
        fileName: 'report.pdf', mime: 'application/pdf', mine: true);

    await pumpChat(tester);

    expect(find.byType(AttachmentCard), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
    expect(find.text('Open'), findsNothing);
  });

  testWidgets('a file that has landed offers an open and not a cancel', (
    WidgetTester tester,
  ) async {
    final Transfer transfer = await seedFile(
      'xfer-1',
      fileName: 'report.pdf',
      mime: 'application/pdf',
      mine: true,
    );
    await TransferRepository(db).finish(
      transfer.id,
      localPath: '${Directory.systemTemp.path}${Platform.pathSeparator}'
          'feijian-no-such-report.pdf',
      now: DateTime(2026, 1, 2, 9, 1),
    );

    await pumpChat(tester);

    expect(find.text('Open'), findsOneWidget);
    expect(
      find.text('Cancel'),
      findsNothing,
      reason: 'there is no transfer left to stop — the file is here',
    );
    expect(find.text('Save as...'), findsOneWidget);
  });

  testWidgets('a failed file bubble is offered again from its exclamation', (
    WidgetTester tester,
  ) async {
    // The one thing a file's retry must not do is what a text message's does:
    // [ChatController.retry] puts the row back in the outbox, and the outbox is
    // text-only ([MessageDao.pendingFor]) — a file requeued there would sit at
    // `pending` with nothing able to send it. That mistake is invisible in the
    // chat, so the transfer rows are what this counts: one attempt before,
    // two after.
    final String path = makeFile('holiday.png');
    final Transfer first =
        await seedFile('xfer-1', mine: true, localPath: path);
    await TransferRepository(db).end(
      first.id,
      state: TransferState.failed,
      now: DateTime(2026, 1, 2, 9, 1),
    );

    await pumpChat(tester);
    expect(find.byIcon(Icons.error_outline), findsOneWidget);

    await tester.tap(find.byIcon(Icons.error_outline));
    await settleFileWork(tester, offers: 2);

    final Map<String, TransferRow> rows = <String, TransferRow>{
      for (final TransferRow row in await db.select(db.transfers).get())
        row.id: row,
    };
    expect(rows, hasLength(2), reason: 'a second attempt, beside the first');
    final TransferRow again = rows.values.singleWhere(
      (TransferRow row) => row.id != first.id,
    );
    // The same message and the same attachment: a retry sends the same file
    // again, not a second one, and the rows say so.
    expect(again.messageId, first.messageId);
    expect(again.attachmentId, first.attachmentId);

    // Still one bubble and one card. A retry that minted a new message would
    // grow the conversation a file every time the network hiccuped.
    expect(await db.select(db.messages).get(), hasLength(1));
    expect(find.byType(AttachmentCard), findsOneWidget);
    expect(find.text('holiday.png'), findsOneWidget);
  });

  testWidgets('a retry whose file has gone says so and sends nothing', (
    WidgetTester tester,
  ) async {
    final String path = makeFile('moved-away.png');
    final Transfer first =
        await seedFile('xfer-1', mine: true, localPath: path);
    await TransferRepository(db).end(
      first.id,
      state: TransferState.failed,
      now: DateTime(2026, 1, 2, 9, 1),
    );
    File(path).deleteSync();

    await pumpChat(tester);
    await tester.tap(find.byIcon(Icons.error_outline));
    await settleFileWork(tester, offers: 2);

    expect(
      find.text('The file is no longer on this device.'),
      findsOneWidget,
      reason: '§5.2 — a file that has moved is said in its own words, and not '
          'as another failed transfer the user cannot tell from the first',
    );
    expect(
      await db.select(db.transfers).get(),
      hasLength(1),
      reason: 'nothing was begun, so there is nothing half-written to clean up',
    );
  });

  testWidgets('a file this device turned down offers no retry of its own', (
    WidgetTester tester,
  ) async {
    // A declined offer is a failed *message* here too — §4.5 has no third word
    // for it, and [TransferRepository.end] writes `failed` whichever direction
    // the attempt went. That is what makes the page's retry branch safe to key
    // on the status alone: the exclamation is drawn for what this device sent,
    // so the callback it fires can only ever be a send.
    final Transfer refused = await seedFile('xfer-1');
    await TransferRepository(db).end(
      refused.id,
      state: TransferState.declined,
      now: DateTime(2026, 1, 2, 9, 1),
    );

    await pumpChat(tester);

    expect(
      (await chat.page(bob.id)).single.status,
      MessageStatus.failed,
      reason: 'the row really is the one the sender draws an exclamation for',
    );
    expect(find.byIcon(Icons.error_outline), findsNothing);
    expect(find.byType(AttachmentCard), findsOneWidget);
  });

  testWidgets('the paperclip offers every file the dialog came back with', (
    WidgetTester tester,
  ) async {
    chooser.picked = <String>[
      makeFile('one.txt'),
      makeFile('two.pdf'),
    ];
    await pumpChat(tester);

    await tester.tap(find.byIcon(Icons.attach_file));
    await settleFileWork(tester, offers: 2);

    expect(chooser.picks, 1);
    expect(
      find.byType(AttachmentCard),
      findsNWidgets(2),
      reason: 'one transfer per file — §4.6 offers a single file at a time',
    );
    expect(find.text('one.txt'), findsOneWidget);
    expect(find.text('two.pdf'), findsOneWidget);
  });

  testWidgets('a dropped folder is offered beside the file that came with it', (
    WidgetTester tester,
  ) async {
    // A drop is the one way a folder arrives without a dialog, and a directory
    // is what a drop is most likely to carry. It is one message of its own: the
    // file dropped beside it is not swallowed by it, and does not swallow it.
    final String file = makeFile('keep-me.txt');
    chooser.picked = <String>[scratch.path, file];
    await pumpChat(tester);

    await tester.tap(find.byIcon(Icons.attach_file));
    await settleFileWork(tester, rounds: 8);

    expect(find.byType(FolderCard), findsOneWidget);
    expect(
      find.byType(AttachmentCard),
      findsOneWidget,
      reason: 'the folder is its own message; the file beside it still went',
    );
    expect(find.text('keep-me.txt'), findsOneWidget);
    expect(
      find.text('1 file'),
      findsOneWidget,
      reason: 'the folder holds the file that was made in it',
    );
  });

  testWidgets('the folder button sends the folder the dialog came back with', (
    WidgetTester tester,
  ) async {
    makeFile('inside.txt');
    chooser.pickedFolder = scratch.path;
    await pumpChat(tester);

    await tester.tap(find.byIcon(Icons.create_new_folder_outlined));
    await settleFileWork(tester, rounds: 8);

    expect(chooser.folderPicks, 1);
    expect(
      chooser.picks,
      0,
      reason: 'the folder button asks for one directory, not a list of files',
    );
    expect(find.byType(FolderCard), findsOneWidget);
    expect(find.byType(AttachmentCard), findsNothing);
  });

  testWidgets('a folder dialog the user closed sends nothing', (
    WidgetTester tester,
  ) async {
    chooser.pickedFolder = null;
    await pumpChat(tester);

    await tester.tap(find.byIcon(Icons.create_new_folder_outlined));
    for (int i = 0; i < 4; i++) {
      await tester.pump();
    }

    expect(chooser.folderPicks, 1, reason: 'the dialog was opened');
    expect(find.byType(FolderCard), findsNothing);
    expect(
      find.byType(SnackBar),
      findsNothing,
      reason: 'nothing was sent and nothing was asked, so there is nothing to say',
    );
  });

  testWidgets('a folder that cannot be read is refused in its own words', (
    WidgetTester tester,
  ) async {
    // §4.6's refusal has a sentence of its own rather than a file-send failure:
    // the user picked something the walk could not list, which is a different
    // thing to tell them than "one.txt could not be sent".
    chooser.pickedFolder = '${scratch.path}${Platform.pathSeparator}gone';
    await pumpChat(tester);

    await tester.tap(find.byIcon(Icons.create_new_folder_outlined));
    await settleFileWork(tester, rounds: 8);

    expect(
      find.textContaining('cannot be read on this device'),
      findsOneWidget,
    );
    expect(find.byType(FolderCard), findsNothing);
  });

  /// Writes a folder the way the engine does: one message, one attachment per
  /// file, one task transfer that has no attachment of its own — §4.6's shape,
  /// and the reason a folder's card reads two sources.
  ///
  /// Real rows through the real repository, not a hand-built model: what the
  /// card draws is what the engine wrote, and a helper that faked the shape
  /// could agree with the card while disagreeing with the engine.
  Future<Transfer> seedFolder(
    String xferId, {
    String name = 'Photos',
    List<String> files = const <String>['a.png', 'b.png'],
    bool mine = false,
    int minute = 0,
    int size = 1024,
    TransferState? state,
    int bytesDone = 0,
  }) async {
    final TransferRepository repo = TransferRepository(db);
    final DateTime at = DateTime(2026, 1, 2, 9, minute);
    final List<ManifestEntry> entries = <ManifestEntry>[
      for (final String file in files)
        ManifestEntry(
          relPath: file,
          size: size,
          mtime: at.millisecondsSinceEpoch,
        ),
    ];
    final Transfer transfer = mine
        ? await repo.beginOutgoingFolder(
            xferId: xferId,
            peerId: bob.id,
            folderName: name,
            folderPath: scratch.path,
            entries: entries,
            now: at,
          )
        : await repo.beginIncomingFolder(
            xferId: xferId,
            peerId: bob.id,
            folderName: name,
            entries: entries,
            now: at,
          );
    if (state != null) {
      await repo.recordProgress(
        xferId,
        state: state,
        bytesDone: bytesDone,
        now: at,
      );
    }
    return transfer;
  }

  /// Marks the first [count] files of [xferId] as landed, where [at] says.
  Future<void> landFiles(
    Transfer transfer, {
    required int count,
    String directory = r'C:\Downloads\Photos',
  }) async {
    final TransferRepository repo = TransferRepository(db);
    final List<Attachment> rows =
        await repo.attachmentsForMessage(transfer.messageId!);
    for (final Attachment row in rows.take(count)) {
      await repo.finishFile(
        row.id,
        localPath: '$directory${Platform.pathSeparator}${row.fileName}',
      );
    }
  }

  testWidgets('a folder message renders as a card with its count and size', (
    WidgetTester tester,
  ) async {
    await seedFolder('xfer-1');
    await pumpChat(tester);

    expect(find.byType(FolderCard), findsOneWidget);
    expect(find.text('Photos'), findsOneWidget);
    expect(
      find.text('2 files'),
      findsOneWidget,
      reason: 'a folder counts rather than names — §6.3',
    );
    expect(find.textContaining('2.0 KB'), findsOneWidget);
    expect(
      find.text('Waiting for your answer'),
      findsOneWidget,
      reason: 'an offered folder is one question about the whole of it',
    );
    expect(
      find.byType(LinearProgressIndicator),
      findsNothing,
      reason: 'nothing has been agreed to, so a bar would sit at zero',
    );
    // One decision about all of it: §9.2 has no partial accept.
    expect(find.text('Accept'), findsOneWidget);
    expect(find.text('Decline'), findsOneWidget);
    expect(
      find.text('Cancel'),
      findsNothing,
      reason: 'Cancel and Decline would be two words for one decision',
    );
    expect(
      find.byType(AttachmentCard),
      findsNothing,
      reason: 'the files are inside the card, not cards of their own',
    );
  });

  testWidgets('a folder on the way shows the task progress, not a file\'s', (
    WidgetTester tester,
  ) async {
    // §4.6 gives the whole folder one `xferId`, so the bar is the folder's
    // fraction. A file's own progress would sit at zero for every file but the
    // one moving and read as stuck.
    await seedFolder(
      'xfer-1',
      files: const <String>['a.png', 'b.png', 'c.png', 'd.png'],
      state: TransferState.transferring,
      bytesDone: 1024,
    );
    await pumpChat(tester);

    expect(find.text('25%'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(
      find.text('Cancel'),
      findsOneWidget,
      reason: 'a folder being received has something to stop',
    );
  });

  testWidgets('a folder lists the files that landed, each with its own Open', (
    WidgetTester tester,
  ) async {
    final Transfer folder = await seedFolder(
      'xfer-1',
      files: const <String>['a.png', 'b.png', 'c.png'],
      state: TransferState.transferring,
      bytesDone: 2048,
    );
    await landFiles(folder, count: 2);
    await pumpChat(tester);

    // Two arrived, one still coming: the arrived two are reachable by name.
    expect(find.text('a.png'), findsOneWidget);
    expect(find.text('b.png'), findsOneWidget);
    expect(
      find.text('c.png'),
      findsNothing,
      reason: 'a file that has not landed is a name the user cannot act on',
    );
    expect(find.byTooltip('Open'), findsNWidgets(2));
    expect(find.byTooltip('Save as...'), findsNWidgets(2));
  });

  testWidgets("a folder's files are reachable when its task ends", (
    WidgetTester tester,
  ) async {
    // The same defect as the single-picture one above, one level down: a
    // folder's task carries the whole folder's bytes, and each file's own path
    // went onto *its* attachment row as it landed. The task's ending is the
    // moment the last of those is written, so it is the moment the card can
    // start offering Open — and the card reads the rows, not the task.
    final Transfer folder = await seedFolder(
      'xfer-1',
      files: const <String>['a.png'],
      state: TransferState.transferring,
      bytesDone: 512,
    );

    await pumpChat(tester);
    expect(
      find.byTooltip('Open'),
      findsNothing,
      reason: 'the page was read before anything landed',
    );

    await landFiles(folder, count: 1);
    transfers.emitted.add(
      folder.copyWith(state: TransferState.done, bytesDone: 1024),
    );
    await settleFileWork(tester);

    expect(
      find.byTooltip('Open'),
      findsOneWidget,
      reason: 'the file is on disk and its row says so; the card is what has '
          'to catch up',
    );
  });

  testWidgets('a folder names the first few files and counts the rest', (
    WidgetTester tester,
  ) async {
    final Transfer folder = await seedFolder(
      'xfer-1',
      files: const <String>[
        'a.png',
        'b.png',
        'c.png',
        'd.png',
        'e.png',
        'f.png',
        'g.png',
      ],
      state: TransferState.transferring,
      bytesDone: 1024,
    );
    await landFiles(folder, count: 7);
    await pumpChat(tester);

    // A bubble is a bubble: a folder of a thousand files lists the few the user
    // is most likely to reach for and says how many it did not name. Nothing is
    // lost by it — they are on disk, and Open is not the only way to them.
    for (final String name in <String>['a.png', 'b.png', 'c.png', 'd.png', 'e.png']) {
      expect(find.text(name), findsOneWidget);
    }
    expect(find.text('f.png'), findsNothing);
    expect(find.text('…and 2 more'), findsOneWidget);
  });

  testWidgets('a folder that lost a file counts it and keeps what landed', (
    WidgetTester tester,
  ) async {
    // A failed *task* keeps its files (§5.1.1), so the card has to say both
    // things at once: how many did not arrive, and that the rest are here.
    final Transfer folder = await seedFolder(
      'xfer-1',
      files: const <String>['a.png', 'b.png', 'c.png', 'd.png'],
      state: TransferState.transferring,
      bytesDone: 3072,
    );
    await landFiles(folder, count: 3);
    await TransferRepository(db).end(
      'xfer-1',
      state: TransferState.failed,
      now: DateTime(2026, 1, 2, 9, 1),
    );
    await pumpChat(tester);

    expect(
      find.textContaining('did not arrive'),
      findsOneWidget,
      reason: 'the file that did not come is the one worth saying',
    );
    expect(find.text('Failed'), findsOneWidget);
    expect(
      find.byTooltip('Open'),
      findsNWidgets(3),
      reason: 'the three files that made it are still reachable',
    );
    expect(
      find.text('d.png'),
      findsNothing,
      reason: 'the file that did not arrive is not a name to offer Open on',
    );
  });

  testWidgets('a folder that failed offers no retry', (
    WidgetTester tester,
  ) async {
    // §5.2's retry re-reads the source, and a folder's source is not on any row
    // the card holds — so a failed folder says what happened and does not
    // pretend a tap would try again. The alternative is an icon that answers a
    // press with silence.
    final Transfer folder = await seedFolder(
      'xfer-1',
      mine: true,
      files: const <String>['a.png', 'b.png'],
      minute: 0,
    );
    await TransferRepository(db).end(
      'xfer-1',
      state: TransferState.failed,
      now: DateTime(2026, 1, 2, 9, 1),
    );
    expect(folder.id, 'xfer-1');
    await pumpChat(tester);

    // The sender draws the exclamation for a failed message, folder or not.
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    expect(
      (await chat.page(bob.id)).single.status,
      MessageStatus.failed,
      reason: 'the row really is the one that draws the icon',
    );

    await tester.tap(find.byIcon(Icons.error_outline));
    await tester.pump();
    await tester.pump();

    expect(
      (await chat.page(bob.id)).single.status,
      MessageStatus.failed,
      reason: 'nothing behind the icon, so the message never left `failed`',
    );
  });

  testWidgets('answering a folder reaches the engine by the task id', (
    WidgetTester tester,
  ) async {
    // A folder transfer has no `attachment_id` — §4.6 gives the whole of it one
    // `xferId` — so `acceptAttachment` cannot find it and the card has to answer
    // by the task's own id. This is that, and nothing else can witness it: the
    // engine's map is filled from the wire, and no socket completes in here.
    await seedFolder('xfer-1');
    await pumpChat(tester);

    await tester.tap(find.text('Accept'));
    await tester.pump();
    await tester.pump();

    expect(transfers.accepted, <String>['xfer-1']);
    expect(transfers.declined, isEmpty);
  });

  testWidgets('declining a folder is one answer about all of it', (
    WidgetTester tester,
  ) async {
    await seedFolder('xfer-1');
    await pumpChat(tester);

    await tester.tap(find.text('Decline'));
    await tester.pump();
    await tester.pump();

    expect(transfers.declined, <String>['xfer-1']);
    expect(
      transfers.accepted,
      isEmpty,
      reason: '§9.2 has no partial accept, and no accept after a decline',
    );
  });

  testWidgets('cancelling a folder being received stops the task', (
    WidgetTester tester,
  ) async {
    await seedFolder(
      'xfer-1',
      files: const <String>['a.png', 'b.png'],
      state: TransferState.transferring,
      bytesDone: 512,
    );
    await pumpChat(tester);

    await tester.tap(find.text('Cancel'));
    await tester.pump();
    await tester.pump();

    expect(
      transfers.cancelled,
      <String>['xfer-1'],
      reason: 'the task, not one of its files — the files behind it stop too',
    );
  });

  testWidgets('a folder that has arrived offers no buttons at all', (
    WidgetTester tester,
  ) async {
    final Transfer folder = await seedFolder(
      'xfer-1',
      mine: true,
      files: const <String>['a.png'],
    );
    await TransferRepository(db).finish('xfer-1', now: DateTime(2026, 1, 2, 9, 1));
    expect(folder.id, 'xfer-1');
    await pumpChat(tester);

    // Nothing left to stop, and nothing to answer: the card is a name, a count
    // and, for a file that is really there, the way to open it.
    expect(find.text('Cancel'), findsNothing);
    expect(find.text('Accept'), findsNothing);
    expect(find.text('Decline'), findsNothing);
  });

  testWidgets('with no engine up, a picked file is not silently dropped', (
    WidgetTester tester,
  ) async {
    chooser.picked = <String>[makeFile('one.txt')];
    await pumpChat(tester, transferEngine: false);

    await tester.tap(find.byIcon(Icons.attach_file));
    for (int i = 0; i < 4; i++) {
      await tester.pump();
    }

    expect(
      find.textContaining('network service is not running'),
      findsOneWidget,
    );
    expect(find.byType(AttachmentCard), findsNothing);
  });

  testWidgets('an empty picker result is not an error', (
    WidgetTester tester,
  ) async {
    // The user opened the dialog and closed it. Nothing to send and nothing to
    // say — a toast here would be the app answering a question nobody asked.
    chooser.picked = const <String>[];
    await pumpChat(tester);

    await tester.tap(find.byIcon(Icons.attach_file));
    for (int i = 0; i < 4; i++) {
      await tester.pump();
    }

    expect(find.byType(SnackBar), findsNothing);
    expect(find.byType(AttachmentCard), findsNothing);
  });

  testWidgets('save as copies the file the card is showing', (
    WidgetTester tester,
  ) async {
    final String source = makeFile('report.pdf', bytes: 4096);
    final Transfer transfer = await seedFile(
      'xfer-1',
      fileName: 'report.pdf',
      mime: 'application/pdf',
      size: 4096,
    );
    await TransferRepository(db).finish(
      transfer.id,
      localPath: source,
      now: DateTime(2026, 1, 2, 9, 1),
    );
    chooser =
        _FakeChooser(target: '${scratch.path}${Platform.pathSeparator}out.pdf');
    await pumpChat(tester);

    await tester.tap(find.text('Save as...'));
    for (int i = 0; i < 4; i++) {
      await tester.pump();
    }

    expect(
      chooser.copies,
      <(String, String)>[(source, chooser.target!)],
      reason: 'from where it landed, to where the user pointed',
    );
    expect(find.text('Saved'), findsOneWidget);
  });

  testWidgets('a save dialog the user closed says nothing', (
    WidgetTester tester,
  ) async {
    final Transfer transfer = await seedFile(
      'xfer-1',
      fileName: 'report.pdf',
      mime: 'application/pdf',
      mine: true,
    );
    await TransferRepository(db).finish(
      transfer.id,
      localPath: makeFile('report.pdf'),
      now: DateTime(2026, 1, 2, 9, 1),
    );
    chooser = _FakeChooser(target: null);
    await pumpChat(tester);

    await tester.tap(find.text('Save as...'));
    for (int i = 0; i < 4; i++) {
      await tester.pump();
    }

    expect(chooser.copies, isEmpty);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('a platform that cannot save is not offered it', (
    WidgetTester tester,
  ) async {
    // Android, where the system dialog hands back a document this app can only
    // write through a stream the picker does not expose. The file is still here
    // and still opens; there is just nowhere to copy it to.
    final Transfer transfer = await seedFile(
      'xfer-1',
      fileName: 'report.pdf',
      mime: 'application/pdf',
      mine: true,
    );
    await TransferRepository(db).finish(
      transfer.id,
      localPath: makeFile('report.pdf'),
      now: DateTime(2026, 1, 2, 9, 1),
    );
    chooser = _FakeChooser(canSaveAs: false);
    await pumpChat(tester);

    expect(find.text('Open'), findsOneWidget);
    expect(find.text('Save as...'), findsNothing);
  });
}

/// The real service with its one network side effect removed.
///
/// Opening a conversation asks the manager to keep a connection to that peer
/// alive, which dials: a real `Socket.connect` under the fake-async zone a
/// widget test runs in never completes, and the eight second timeout it arms
/// outlives the tree. Everything else is the production object — a message
/// stored here goes through the same `sendText` and lands in the same row.
/// A file dialog that answers without one.
///
/// Both directions, because they are the same seam: [pickFiles] is what the
/// paperclip and a drop ask for, [pickSaveLocation] and [copy] are what Save as
/// does. Nothing here touches a filesystem — the copy is recorded rather than
/// performed, so a test can assert on the two paths without a real destination.
class _FakeChooser implements FileChooser {
  _FakeChooser({this.canSaveAs = true, this.target});

  /// What the picker comes back with. Left empty by default and set by the
  /// tests that pick something, which is what "the user closed the dialog"
  /// looks like from here.
  List<String> picked = const <String>[];

  @override
  final bool canSaveAs;

  /// Where the save dialog points, or null for a dialog the user closed.
  final String? target;

  /// What the folder dialog comes back with, null for one the user closed.
  ///
  /// Separate from [picked] because the folder button asks a different question
  /// than the paperclip: one directory, not a list of files.
  String? pickedFolder;

  int picks = 0;
  int folderPicks = 0;

  /// Every `(from, to)` the page asked to be copied.
  final List<(String, String)> copies = <(String, String)>[];

  @override
  Future<List<String>> pickFiles() async {
    picks++;
    return picked;
  }

  @override
  Future<String?> pickFolder() async {
    folderPicks++;
    return pickedFolder;
  }

  @override
  Future<String?> pickSaveLocation(String fileName) async => target;

  @override
  Future<bool> copy(String from, String to) async {
    copies.add((from, to));
    return true;
  }
}

/// The engine with the three answers a card can give recorded rather than
/// acted on.
///
/// The card's Accept, Decline and Cancel reach the engine by the *task's* id,
/// which is a thing only this can witness: the maps those calls look in are
/// filled from the wire, and a widget test runs in a fake-async zone where no
/// socket completes. Recording the id the page used is the whole assertion.
class _SpyTransfers extends TransferService {
  _SpyTransfers({
    required super.manager,
    required super.transfers,
    required super.downloadDirectory,
  });

  StreamSubscription<Transfer>? _forward;

  final List<String> accepted = <String>[];
  final List<String> declined = <String>[];
  final List<String> cancelled = <String>[];

  /// The engine's progress stream, in the test's hands.
  ///
  /// Real progress arrives from the wire, and no socket completes in a widget
  /// test — so a test that needs the page to see a transfer move has to be the
  /// one moving it. Overriding the getter rather than the service's controller
  /// keeps that entirely on this side: the page subscribes to `changes` either
  /// way, and production has no seam it does not need.
  final StreamController<Transfer> emitted =
      StreamController<Transfer>.broadcast();

  /// The engine's own stream, **forwarded** rather than replaced.
  ///
  /// These tests send real files, and the page has to see those endings too — a
  /// replacement channel would make every real send look like it never moved.
  ///
  /// Attached here, on the page's first read, and not in the constructor. A
  /// constructor runs in `setUp`, which is **outside** the fake-async zone
  /// `testWidgets` builds for the body; a subscription taken there delivers its
  /// events on the real event loop, and each one then waits for `runAsync` to
  /// turn that loop before the page can see it. That is one extra round per
  /// emission, which is invisible on a single file and is exactly enough to
  /// leave the second file of a two-file send unwritten.
  @override
  Stream<Transfer> get changes {
    _forward ??= super.changes.listen(emitted.add);
    return emitted.stream;
  }

  @override
  Future<void> dispose() async {
    // Not awaited: this subscription belongs to the test's fake-async zone, and
    // a cancellation future from that zone is not something teardown — which
    // runs outside it — can wait on.
    unawaited(_forward?.cancel());
    await emitted.close();
    await super.dispose();
  }

  @override
  Future<void> accept(String xferId) async => accepted.add(xferId);

  @override
  Future<void> decline(
    String xferId, {
    RejectReason reason = RejectReason.declined,
  }) async =>
      declined.add(xferId);

  @override
  Future<void> cancel(String xferId) async => cancelled.add(xferId);
}

class _QuietService extends LanService {
  _QuietService({
    required super.manager,
    required super.discovery,
    required super.chat,
    required super.peers,
  });

  @override
  void ensureConnected(Peer peer) {}
}

/// A discovery service that finds nothing, with no sockets behind it.
class _NoPeers implements PeerSource {
  @override
  Stream<void> get changes => const Stream<void>.empty();

  @override
  List<Peer> get peers => const <Peer>[];

  // The peer menu reads `manualIds` to decide whether to offer "Remove device".
  // Always empty here: these tests drive a conversation with an announced peer,
  // and the manual path has its own tests.

  @override
  bool addManual(Peer peer) => false;

  @override
  bool isManual(String id) => false;

  @override
  bool setOnline(String id, {required bool isOnline}) => false;

  /// Peers `forgetPeer` actually reached, so the menu action can be asserted on
  /// the side effect rather than on the snackbar that follows it.
  final List<String> forgotten = <String>[];

  @override
  bool forget(String id) {
    forgotten.add(id);
    return true;
  }
}
