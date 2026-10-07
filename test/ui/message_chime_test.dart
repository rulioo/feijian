import 'dart:async';
import 'dart:io';

import 'package:feijian/core/discovery/peer_source.dart';
import 'package:feijian/core/models/peer.dart';
import 'package:feijian/core/models/transfer.dart';
import 'package:feijian/core/protocol/payloads.dart';
import 'package:feijian/core/transport/connection_manager.dart';
import 'package:feijian/data/database.dart';
import 'package:feijian/data/repository/chat_repository.dart';
import 'package:feijian/data/repository/peer_repository.dart';
import 'package:feijian/data/repository/transfer_repository.dart';
import 'package:feijian/state/data_providers.dart';
import 'package:feijian/state/lan_provider.dart';
import 'package:feijian/state/lan_service.dart';
import 'package:feijian/state/settings_provider.dart';
import 'package:feijian/state/transfer_provider.dart';
import 'package:feijian/state/transfer_service.dart';
import 'package:feijian/ui/widgets/message_chime.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// The sound a new message makes — design.md §6.5.
///
/// Asserted at the platform channel, which is the last thing under this app's
/// control and the first thing that differs between Windows and Android: on the
/// host the chime goes out as `SystemSound.play` on `flutter/platform`, which is
/// exactly what the Windows embedder plays and exactly what Android *ignores* —
/// the reason `MainActivity.kt` has a handler of its own. That Android branch is
/// not covered here and cannot be: it needs a device.
void main() {
  late AppDatabase db;
  late ConnectionManager manager;
  late _FakeLan lan;
  late _FakeTransfers transfers;

  /// Every platform call the app made, in order.
  late List<MethodCall> platform;

  /// How many of them were the alert.
  int rings() => platform
      .where((MethodCall c) => c.method == 'SystemSound.play')
      .length;

  setUp(() {
    db = AppDatabase.memory();
    manager = ConnectionManager(
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
    );
    lan = _FakeLan(
      manager: manager,
      discovery: _NoPeers(),
      chat: ChatRepository(db),
      peers: PeerRepository(db),
    );
    transfers = _FakeTransfers(
      manager: manager,
      transfers: TransferRepository(db),
      downloadDirectory: () async => Directory.systemTemp,
    );
    platform = <MethodCall>[];
  });

  tearDown(() async {
    await transfers.dispose();
    await lan.dispose();
    await db.close();
  });

  Future<ProviderContainer> pump(WidgetTester tester) async {
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

    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        databaseProvider.overrideWithValue(db),
        lanServiceProvider.overrideWith((Ref ref) => lan),
        transferServiceProvider.overrideWith(
          (Ref ref) => Future<TransferService>.value(transfers),
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: MessageChime(child: Scaffold(body: SizedBox.shrink())),
        ),
      ),
    );
    // Two frames: the first build sees both services still loading, the second
    // the resolved pair it subscribes to.
    await tester.pump();
    await tester.pump();
    return container;
  }

  /// Lets the platform call an unawaited `play` leaves behind come back.
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump();
  }

  testWidgets('a message from a peer rings once', (WidgetTester tester) async {
    await pump(tester);
    expect(rings(), 0, reason: 'nothing has arrived yet');

    lan.arrive();
    await settle(tester);

    expect(rings(), 1);
    expect(
      platform.last.arguments,
      'SystemSoundType.alert',
      reason: 'the desktop alert, which is the sound Windows plays for one',
    );
  });

  testWidgets('the notifications switch silences it', (
    WidgetTester tester,
  ) async {
    final ProviderContainer container = await pump(tester);
    container.read(settingsProvider.notifier).update(
          (AppSettings s) => s.copyWith(notificationsEnabled: false),
        );

    lan.arrive();
    await settle(tester);

    expect(
      rings(),
      0,
      reason: 'a user who turned notifications off is not to be told',
    );
  });

  testWidgets("a peer's backlog rings once, not once per message", (
    WidgetTester tester,
  ) async {
    // The case that makes the cooldown worth having: §5.2 makes a message owed
    // until it is delivered, so a device that was away hands over everything it
    // has the moment it reconnects. Thirty chimes in a second is not thirty
    // notifications — it is one unpleasant noise and a switch turned back off.
    await pump(tester);

    for (int i = 0; i < 5; i++) {
      lan.arrive();
    }
    await settle(tester);

    expect(rings(), 1, reason: 'five messages in one burst are one arrival');

    // Past the cooldown, the next one is heard again — this is a de-burster and
    // not a one-shot: a chime that never rang twice would pass the line above.
    await tester.pump(kChimeCooldown);
    lan.arrive();
    await settle(tester);

    expect(rings(), 2);
  });

  testWidgets('an arriving file rings too', (WidgetTester tester) async {
    // A file is not a lesser kind of message: §5.1 stores one as a message with
    // a transfer behind it, and its row is written by the transfer engine rather
    // than by the packet handler — so a chime hung off text alone would be
    // silent for the arrival a user is most likely to be away for.
    await pump(tester);

    transfers.offer(await TransferRepository(db).beginIncoming(
      xferId: 'xfer-1',
      peerId: 'peer-bob',
      fileName: 'holiday.png',
      totalSize: 2048,
      now: DateTime(2026, 1, 1, 9),
    ));
    await settle(tester);

    expect(rings(), 1);
  });
}

/// A `LanService` whose arrivals the test sends.
class _FakeLan extends LanService {
  _FakeLan({
    required super.manager,
    required super.discovery,
    required super.chat,
    required super.peers,
  });

  final StreamController<String> _arrivals =
      StreamController<String>.broadcast();

  @override
  Stream<String> get messagesArrived => _arrivals.stream;

  void arrive() => _arrivals.add('peer-bob');

  @override
  Future<void> dispose() async {
    await _arrivals.close();
    await super.dispose();
  }
}

/// A `TransferService` whose offers the test sends.
class _FakeTransfers extends TransferService {
  _FakeTransfers({
    required super.manager,
    required super.transfers,
    required super.downloadDirectory,
  });

  final StreamController<Transfer> _offers =
      StreamController<Transfer>.broadcast();

  @override
  Stream<Transfer> get offers => _offers.stream;

  void offer(Transfer transfer) => _offers.add(transfer);
}

/// Discovery is not what this file is about, and binding a UDP port to say so
/// would be the only socket in it.
class _NoPeers implements PeerSource {
  @override
  Stream<void> get changes => const Stream<void>.empty();

  @override
  List<Peer> get peers => const <Peer>[];

  @override
  bool addManual(Peer peer) => false;

  @override
  bool isManual(String id) => false;

  @override
  bool setOnline(String id, {required bool isOnline}) => false;

  @override
  bool forget(String id) => false;
}
