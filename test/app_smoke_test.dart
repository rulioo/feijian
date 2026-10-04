import 'package:feijian/app.dart';
import 'package:feijian/core/models/peer.dart';
import 'package:feijian/state/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// The local-device provider reads real network interfaces. Overriding it keeps
/// these tests deterministic and free of IO.
const Peer _fakeSelf = Peer(
  id: 'test-self',
  name: 'Test-Box',
  deviceType: DeviceType.windows,
  icon: DeviceIcon.desktop,
  os: 'Windows 11',
  lastIp: '192.168.1.50',
  isOnline: true,
);

Widget _app() {
  return ProviderScope(
    overrides: <Override>[
      selfDeviceProvider.overrideWith((Ref ref) async => _fakeSelf),
      downloadPathProvider.overrideWith((Ref ref) async => '/tmp/Feijian'),
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
}
