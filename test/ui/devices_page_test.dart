import 'dart:async';
import 'dart:io';

import 'package:feijian/core/discovery/discovery_service.dart';
import 'package:feijian/core/models/peer.dart';
import 'package:feijian/core/protocol/payloads.dart';
import 'package:feijian/core/transport/connection_manager.dart';
import 'package:feijian/data/database.dart';
import 'package:feijian/data/repository/chat_repository.dart';
import 'package:feijian/data/repository/peer_repository.dart';
import 'package:feijian/l10n/app_localizations.dart';
import 'package:feijian/state/data_providers.dart';
import 'package:feijian/state/lan_provider.dart';
import 'package:feijian/state/lan_service.dart';
import 'package:feijian/state/providers.dart';
import 'package:feijian/state/transfer_provider.dart';
import 'package:feijian/state/transfer_service.dart';
import 'package:feijian/ui/pages/devices_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// The real service with its one network side effect removed.
///
/// Opening a conversation asks the manager to keep a connection alive, which
/// dials: a real `Socket.connect` inside a widget test's fake-async zone never
/// completes. Everything else is the production object.
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
  late DiscoveryService discovery;
  late _QuietService service;

  setUp(() {
    db = AppDatabase.memory();
    chat = ChatRepository(db);
    discovery = DiscoveryService(discoveryPort: 0);
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
      peers: PeerRepository(db),
    );
  });

  tearDown(() async {
    await service.dispose();
    await db.close();
  });

  /// Advances past whatever animation is running, without waiting for quiet.
  ///
  /// `pumpAndSettle` never returns here: the device list keeps a repeating
  /// ticker alive (relative timestamps), so there is always another frame
  /// scheduled. Route transitions run for 300 ms, so this covers them with
  /// margin and leaves the rest of the tree exactly where it was.
  Future<void> settle(WidgetTester tester) async {
    for (int i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 150));
    }
  }

  Future<void> pumpDevices(WidgetTester tester, {Override? peers}) async {
    // A phone, so that tapping a peer pushes the conversation.
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          databaseProvider.overrideWithValue(db),
          discoveryServiceProvider.overrideWithValue(discovery),
          peers ??
              discoveredPeersProvider.overrideWith(
                (Ref ref) => Stream<List<Peer>>.value(const <Peer>[bob]),
              ),
          lanServiceProvider.overrideWith((Ref ref) => service),
          // Tapping a peer pushes the conversation, and the conversation page
          // watches the transfer engine. A future that never completes is the
          // app with no engine up — the state `ChatPage` already handles, and
          // the one that keeps a real `TransferService.start` sweep out of a
          // test that seeded rows by hand.
          transferServiceProvider.overrideWith(
            (Ref ref) => Completer<TransferService>().future,
          ),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('en'),
          home: DevicesPage(),
        ),
      ),
    );
    // Several frames: the localizations load asynchronously and the peer list
    // arrives on a stream, so the first build is not yet what a user sees.
    await settle(tester);
  }

  testWidgets('a discovery that failed to start says so', (
    WidgetTester tester,
  ) async {
    // The bug this screen kept being reported for: "the refresh button finds
    // nothing". Rendering a failed start as an ordinary empty list is what made
    // that unanswerable from the phone — the three hints below all blame the
    // network, and none of them is the reason when the port never opened.
    await pumpDevices(
      tester,
      peers: discoveredPeersProvider.overrideWith(
        (Ref ref) => Stream<List<Peer>>.error(
          const SocketException('discovery port already in use'),
        ),
      ),
    );

    expect(
      find.text('Device discovery is not running'),
      findsOneWidget,
      reason: 'the title has to stop claiming to be scanning',
    );
    expect(
      find.textContaining('Scanning for devices'),
      findsNothing,
      reason: 'nothing is scanning; an animation here is a lie',
    );
    expect(find.byIcon(Icons.wifi_tethering_off), findsOneWidget);
    expect(
      find.textContaining('Your firewall allows'),
      findsNothing,
      reason: 'the network hints are the wrong guesses here, and misdirect',
    );
    // The escape hatch has to survive: a device added by hand still works when
    // discovery cannot run at all.
    expect(find.text('Add device by IP'), findsOneWidget);

    await tester.tap(find.text('Details'));
    await settle(tester);
    expect(
      find.textContaining('discovery port already in use'),
      findsOneWidget,
      reason: 'the actual error is the one thing worth reading off the phone',
    );
  });

  testWidgets('a quiet network still reads as scanning', (
    WidgetTester tester,
  ) async {
    // The other side of the same coin, and the reason `problem` is nullable:
    // with discovery running and nobody out there, "Scanning..." is true and
    // the hints are the right ones. Turning this screen into a warning for every
    // empty network would trade one wrong screen for a worse one.
    await pumpDevices(
      tester,
      peers: discoveredPeersProvider.overrideWith(
        (Ref ref) => Stream<List<Peer>>.value(const <Peer>[]),
      ),
    );

    expect(find.textContaining('Scanning for devices'), findsOneWidget);
    expect(find.textContaining('Your firewall allows'), findsOneWidget);
    expect(find.text('Device discovery is not running'), findsNothing);
  });

  testWidgets('reading a conversation clears the badge on the list', (
    WidgetTester tester,
  ) async {
    // The report, in the order it happened: the badge said 2, the conversation
    // was opened and read, and the 2 was still there on the way back. Opening
    // the conversation is what marks it read, and that write always landed —
    // what was missing was anyone telling the badge. So this walks the whole
    // path rather than asserting on `unreadCount`, which was never wrong.
    await chat.storeIncoming(
      msgId: 'm1',
      peerId: bob.id,
      text: 'one',
      now: DateTime(2026, 1, 1, 9),
    );
    await chat.storeIncoming(
      msgId: 'm2',
      peerId: bob.id,
      text: 'two',
      now: DateTime(2026, 1, 1, 9, 0, 1),
    );

    await pumpDevices(tester);
    expect(
      find.text('2'),
      findsOneWidget,
      reason: 'two unread messages, and the badge is the count',
    );

    await tester.tap(find.text('Bob-PC'));
    await settle(tester);
    expect(find.text('one'), findsOneWidget, reason: 'the conversation opened');

    await tester.pageBack();
    await settle(tester);

    expect(await chat.unreadCount(bob.id), 0);
    expect(
      find.text('2'),
      findsNothing,
      reason: 'the count is read, so the badge has to stop claiming otherwise',
    );
  });

  testWidgets('the unread badge is red, not the accent colour', (
    WidgetTester tester,
  ) async {
    // 「设备未读消息的圆圈及背景色改为红色，便于提醒」. The colour is the whole of the
    // request, so it is the whole of the assertion — and it is asserted against
    // the scheme rather than a literal, because the point is *which* token: the
    // badge used `primary`, the blue this app puts on every accent, where a
    // count reads as decoration rather than as something waiting.
    await chat.storeIncoming(
      msgId: 'm1',
      peerId: bob.id,
      text: 'one',
      now: DateTime(2026, 1, 1, 9),
    );
    await pumpDevices(tester);

    final Finder label = find.text('1');
    expect(label, findsOneWidget, reason: 'one unread message, one badge');

    final Color expected = Theme.of(
      tester.element(label),
    ).colorScheme.error;
    final Container badge = tester.widget<Container>(
      find.ancestor(of: label, matching: find.byType(Container)).first,
    );
    final BoxDecoration decoration = badge.decoration! as BoxDecoration;

    expect(
      decoration.color,
      expected,
      reason: 'the circle behind the count is the colour that means '
          '"something wants you"',
    );
  });
}
