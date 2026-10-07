import 'dart:async';
import 'dart:io';

import 'package:feijian/core/models/peer.dart';
import 'package:feijian/core/models/transfer.dart';
import 'package:feijian/core/protocol/payloads.dart';
import 'package:feijian/core/transport/connection_manager.dart';
import 'package:feijian/data/database.dart';
import 'package:feijian/data/repository/transfer_repository.dart';
import 'package:feijian/l10n/app_localizations.dart';
import 'package:feijian/state/data_providers.dart';
import 'package:feijian/state/providers.dart';
import 'package:feijian/state/settings_provider.dart';
import 'package:feijian/state/transfer_provider.dart';
import 'package:feijian/state/transfer_service.dart';
import 'package:feijian/ui/widgets/offer_listener.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// What happens to a file offered to this device — design.md §9.2.
///
/// The dialog itself is `offer_dialog_test.dart`'s; this is the decision about
/// whether to ask at all. It is the whole of the receive-confirmation switch,
/// and it is worth a file of its own because the switch's default is the part
/// that has to be right: an install that asked about every file would be a
/// different product from one that does not, and the difference is one boolean
/// read in the wrong polarity.
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
  late ConnectionManager manager;
  late _FakeOffers transfers;

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
    // Constructed but never started: no listener, no port, and — the point of
    // it — no `start()` sweep, so the rows a test seeds are the rows it reads.
    transfers = _FakeOffers(
      manager: manager,
      transfers: TransferRepository(db),
      downloadDirectory: () async => Directory.systemTemp,
    );
  });

  tearDown(() async {
    await transfers.dispose();
    await manager.dispose();
    await db.close();
  });

  /// A file offer, as the engine would have written it before announcing it.
  Future<Transfer> offer({
    String xferId = 'xfer-1',
    String fileName = 'holiday.png',
    int totalSize = 1024,
  }) {
    return TransferRepository(db).beginIncoming(
      xferId: xferId,
      peerId: bob.id,
      fileName: fileName,
      totalSize: totalSize,
      now: DateTime(2026, 1, 1, 9),
    );
  }

  Future<ProviderContainer> pump(WidgetTester tester) async {
    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        databaseProvider.overrideWithValue(db),
        transferServiceProvider.overrideWith(
          (Ref ref) => Future<TransferService>.value(transfers),
        ),
        peersProvider.overrideWithValue(const <Peer>[bob]),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          // The shell would be a `Scaffold`; the toast an answered offer puts
          // up needs one, so this is the smallest thing that can hold the
          // listener the way the app does.
          home: const Scaffold(body: OfferListener(child: SizedBox.shrink())),
        ),
      ),
    );
    // Two frames: the first build sees a loading service, the second the
    // resolved one it subscribes to.
    await tester.pump();
    await tester.pump();
    return container;
  }

  testWidgets('a fresh install receives an offered file without asking', (
    WidgetTester tester,
  ) async {
    // The report this switch came from: 「接收图片和文件，无需确认，直接接收」. Note
    // that no attachment row is seeded — the automatic path does not read one,
    // which is deliberate. A row that could not be read is a bug in the engine,
    // and refusing the file over it would turn that bug into a lost transfer.
    final ProviderContainer container = await pump(tester);
    expect(
      container.read(settingsProvider).confirmBeforeReceiving,
      isFalse,
      reason: 'off is the default the product ships with',
    );

    transfers.push(await offer());
    await tester.pumpAndSettle();

    expect(transfers.accepted, <String>['xfer-1']);
    expect(transfers.declined, isEmpty);
    expect(
      find.text('Incoming file or folder'),
      findsNothing,
      reason: 'nothing to answer, so nothing may be put on screen to answer',
    );
    expect(
      find.textContaining('wants to send you'),
      findsNothing,
      reason: 'and no question phrased as one either',
    );
  });

  testWidgets('with the switch on, the same offer is put to the user', (
    WidgetTester tester,
  ) async {
    final ProviderContainer container = await pump(tester);
    container.read(settingsProvider.notifier).update(
          (AppSettings s) => s.copyWith(confirmBeforeReceiving: true),
        );

    transfers.push(await offer());
    await tester.pumpAndSettle();

    expect(
      find.text('Bob-PC wants to send you holiday.png (1.0 KB)'),
      findsOneWidget,
      reason: 'the dialog names the sender, the file and its size',
    );
    expect(
      transfers.accepted,
      isEmpty,
      reason: 'nothing is received until the question is answered',
    );

    await tester.tap(find.text('Accept'));
    await tester.pumpAndSettle();

    expect(transfers.accepted, <String>['xfer-1']);
    expect(transfers.declined, isEmpty);
  });

  testWidgets('with the switch on, declining refuses it', (
    WidgetTester tester,
  ) async {
    final ProviderContainer container = await pump(tester);
    container.read(settingsProvider.notifier).update(
          (AppSettings s) => s.copyWith(confirmBeforeReceiving: true),
        );

    transfers.push(await offer());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Decline'));
    await tester.pumpAndSettle();

    expect(transfers.declined, <String>['xfer-1']);
    expect(
      transfers.accepted,
      isEmpty,
      reason: 'the two answers are not interchangeable, even one tap apart',
    );
  });
}

/// The engine with its offer stream in the test's hands.
///
/// An offer is a thing that arrives from a socket, and no socket completes in a
/// widget test — so the test is the one that sends it. Overriding the getter
/// rather than the service's controller keeps that on this side: the listener
/// subscribes to `offers` either way, and production gains no seam it does not
/// need.
class _FakeOffers extends TransferService {
  _FakeOffers({
    required super.manager,
    required super.transfers,
    required super.downloadDirectory,
  });

  final StreamController<Transfer> _pushed =
      StreamController<Transfer>.broadcast();

  final List<String> accepted = <String>[];
  final List<String> declined = <String>[];

  @override
  Stream<Transfer> get offers => _pushed.stream;

  void push(Transfer offer) => _pushed.add(offer);

  @override
  Future<void> accept(String xferId) async => accepted.add(xferId);

  @override
  Future<void> decline(
    String xferId, {
    RejectReason reason = RejectReason.declined,
  }) async =>
      declined.add(xferId);

  @override
  Future<void> dispose() async {
    await _pushed.close();
    await super.dispose();
  }
}
