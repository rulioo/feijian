import 'package:feijian/app.dart';
import 'package:feijian/core/models/peer.dart';
import 'package:feijian/state/providers.dart';
import 'package:feijian/ui/pages/chat_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const Peer _fakeSelf = Peer(
  id: 'test-self',
  name: 'Test-Box',
  deviceType: DeviceType.windows,
  icon: DeviceIcon.desktop,
  os: 'Windows 11',
  lastIp: '192.168.1.50',
  isOnline: true,
);

/// The local-device provider reads real network interfaces, and the peer list
/// opens real UDP sockets on port 24250. Overriding both keeps these tests
/// deterministic, fast, and independent of whatever else is on the machine.
Widget _app({List<Peer> peers = const <Peer>[]}) {
  return ProviderScope(
    overrides: <Override>[
      selfDeviceProvider.overrideWith((Ref ref) async => _fakeSelf),
      downloadPathProvider.overrideWith((Ref ref) async => '/tmp/Feijian'),
      discoveredPeersProvider.overrideWith(
        (Ref ref) => Stream<List<Peer>>.value(peers),
      ),
    ],
    child: const FeijianApp(),
  );
}

void main() {
  // The default test surface (800x600) sits below kTwoPaneMinWidth, so these
  // exercise the single-pane phone layout.
  testWidgets('boots to the device list', (WidgetTester tester) async {
    await tester.pumpWidget(_app());
    // Two pumps: one to build, one to settle the overridden futures.
    await tester.pump();
    await tester.pump();

    expect(find.text('Devices'), findsOneWidget);
    // The local device card must show this machine so the user can confirm
    // which name and address peers will see.
    expect(find.text('Test-Box'), findsOneWidget);
  });

  testWidgets('opens settings from the device list', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_app());
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pump();
    // Let the route transition finish; explicit pumps rather than
    // pumpAndSettle, which would hang on the scanning animation.
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('Settings'), findsWidgets);
    expect(find.text('Display name'), findsOneWidget);
  });

  testWidgets('lists a discovered peer and opens its conversation', (
    WidgetTester tester,
  ) async {
    const Peer bob = Peer(
      id: 'peer-bob',
      name: 'Bob-PC',
      deviceType: DeviceType.android,
      icon: DeviceIcon.phone,
      os: 'Android 14',
      lastIp: '192.168.1.105',
      lastPort: 24250,
      isOnline: true,
    );

    await tester.pumpWidget(_app(peers: const <Peer>[bob]));
    await tester.pump();
    await tester.pump();

    expect(find.text('Bob-PC'), findsOneWidget);
    // The empty state must be gone once anything is discovered.
    expect(find.textContaining('Scanning for devices'), findsNothing);

    await tester.tap(find.text('Bob-PC'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byType(ChatPage), findsOneWidget);
  });
}
