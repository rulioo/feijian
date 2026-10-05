import 'dart:async';

import 'package:feijian/core/discovery/peer_source.dart';
import 'package:feijian/core/models/message.dart';
import 'package:feijian/core/models/peer.dart';
import 'package:feijian/core/protocol/payloads.dart';
import 'package:feijian/core/transport/connection_manager.dart';
import 'package:feijian/data/database.dart';
import 'package:feijian/data/repository/chat_repository.dart';
import 'package:feijian/data/repository/peer_repository.dart';
import 'package:feijian/l10n/app_localizations.dart';
import 'package:feijian/state/chat_provider.dart';
import 'package:feijian/state/data_providers.dart';
import 'package:feijian/state/lan_provider.dart';
import 'package:feijian/state/lan_service.dart';
import 'package:feijian/state/providers.dart';
import 'package:feijian/ui/pages/chat_page.dart';
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
  });

  tearDown(() async {
    await service.dispose();
    await db.close();
  });

  /// [manual] puts the peer in the set the "Remove device" action is keyed on —
  /// the stand-in for what `PeerTable._manual` would say about a device the user
  /// typed in by hand.
  Future<void> pumpChat(WidgetTester tester, {bool manual = false}) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          databaseProvider.overrideWithValue(db),
          selectedPeerProvider.overrideWith((Ref ref) => bob),
          discoveredPeersProvider.overrideWith(
            (Ref ref) => Stream<List<Peer>>.value(const <Peer>[bob]),
          ),
          lanServiceProvider.overrideWith((Ref ref) => service),
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
      await chat.saveOutgoing(msgId: msgId, peerId: bob.id, text: text, now: at);
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
    expect(container.read(chatProvider(bob.id)).requireValue.draft, 'half a thought');

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
    expect(find.text('message 59'), findsOneWidget, reason: 'newest, at the bottom');

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
    expect(find.text('message 0'), findsOneWidget, reason: 'and it is reachable');
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
}

/// The real service with its one network side effect removed.
///
/// Opening a conversation asks the manager to keep a connection to that peer
/// alive, which dials: a real `Socket.connect` under the fake-async zone a
/// widget test runs in never completes, and the eight second timeout it arms
/// outlives the tree. Everything else is the production object — a message
/// stored here goes through the same `sendText` and lands in the same row.
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
